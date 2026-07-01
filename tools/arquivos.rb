# frozen_string_literal: true

require 'ruby_llm'
require 'find'
require 'open3'
require 'shellwords'

# =============================================================================
#  Ferramentas de LEITURA de arquivos e código — SOMENTE LEITURA.
#  Nenhuma destas ferramentas escreve, cria, move ou apaga nada no disco.
#  Objetivo: permitir ao agente ler e analisar código para sugerir melhorias.
# =============================================================================

module ArquivosSupport
  # diretórios ruidosos que quase nunca interessam para análise de código
  IGNORAR = %w[
    .git .hg .svn node_modules vendor .bundle tmp log logs dist build
    .next .nuxt target coverage .cache __pycache__ .venv venv .idea .vscode
  ].freeze

  # extensões tratadas como binárias (não faz sentido despejar no contexto)
  BIN_EXT = %w[
    .png .jpg .jpeg .gif .webp .ico .bmp .pdf .zip .gz .tar .rar .7z
    .mp3 .mp4 .mov .avi .mkv .wav .ogg .exe .dll .so .dylib .bin .o
    .class .jar .woff .woff2 .ttf .eot .sqlite .db
  ].freeze

  module_function

  def expandir(caminho)
    File.expand_path(caminho.to_s.strip)
  end

  def ignorar_dir?(nome)
    IGNORAR.include?(File.basename(nome))
  end

  def binario_ext?(caminho)
    BIN_EXT.include?(File.extname(caminho).downcase)
  end

  # heurística: lê um pedaço e procura byte nulo
  def binario_conteudo?(caminho)
    trecho = File.binread(caminho, 8000)
    trecho&.include?("\x00") || false
  rescue StandardError
    false
  end

  def truthy?(val)
    %w[1 true yes y sim on].include?(val.to_s.strip.downcase)
  end

  def clamp(val, min, max, default)
    n = val.nil? || val.to_s.strip.empty? ? default : val.to_i
    [[n, min].max, max].min
  end

  def humano(bytes)
    return "#{bytes}B" if bytes < 1024

    kb = bytes / 1024.0
    return format('%.1fKB', kb) if kb < 1024

    format('%.1fMB', kb / 1024.0)
  end
end

# -----------------------------------------------------------------------------
#  ler_arquivo — lê o conteúdo de UM arquivo de texto, com números de linha.
# -----------------------------------------------------------------------------
class LerArquivoTool < RubyLLM::Tool
  include ArquivosSupport

  MAX_LINHAS  = 1500  # sem faixa definida, lê no máximo isto
  MAX_COLUNAS = 1000  # trunca linhas absurdamente longas

  description 'Lê o conteúdo de um arquivo de texto do sistema (SOMENTE LEITURA) ' \
              'e devolve com números de linha, para você analisar código e sugerir ' \
              'melhorias. Aceita uma faixa opcional de linhas (inicio/fim) para ' \
              'arquivos grandes. Não escreve nem altera nada.'

  param :caminho,
        desc: 'Caminho do arquivo (relativo ou absoluto). Ex: "lib/ui.rb", "~/proj/app.rb".',
        required: true

  param :inicio,
        desc: 'Linha inicial (1-indexada), opcional. Use para ler só um trecho.',
        required: false

  param :fim,
        desc: 'Linha final (1-indexada), opcional.',
        required: false

  def execute(caminho:, inicio: nil, fim: nil)
    path = expandir(caminho)

    return "Erro: arquivo não encontrado: #{caminho}" unless File.exist?(path)
    return "Erro: isto é um diretório, use 'listar_diretorio': #{caminho}" if File.directory?(path)
    return "Erro: sem permissão de leitura: #{caminho}" unless File.readable?(path)
    if binario_ext?(path) || binario_conteudo?(path)
      return "Erro: '#{caminho}' parece ser binário (#{humano(File.size(path))}); não dá pra ler como texto."
    end

    linhas = File.readlines(path, chomp: true)
    total = linhas.size

    ini = inicio ? [inicio.to_i, 1].max : 1
    endl = fim ? fim.to_i : total

    aviso = nil
    if inicio.nil? && fim.nil? && total > MAX_LINHAS
      endl = MAX_LINHAS
      aviso = "(arquivo tem #{total} linhas; mostrando 1–#{MAX_LINHAS}. Use inicio/fim para ver o resto.)"
    end

    ini = [ini, total].min
    endl = [endl, total].min
    return "Arquivo vazio: #{caminho}" if total.zero?

    largura = endl.to_s.length
    corpo = (ini..endl).map do |n|
      conteudo = linhas[n - 1].to_s
      conteudo = "#{conteudo[0, MAX_COLUNAS]}…(linha truncada)" if conteudo.length > MAX_COLUNAS
      "#{n.to_s.rjust(largura)}| #{conteudo}"
    end.join("\n")

    cabecalho = "#{path}  (#{total} linhas, #{humano(File.size(path))})"
    cabecalho += "\n#{aviso}" if aviso
    "#{cabecalho}\n\n#{corpo}"
  rescue StandardError => e
    "Erro ao ler '#{caminho}': #{e.class}: #{e.message}"
  end
end

# -----------------------------------------------------------------------------
#  listar_diretorio — mostra a árvore de um diretório (SOMENTE LEITURA).
# -----------------------------------------------------------------------------
class ListarDiretorioTool < RubyLLM::Tool
  include ArquivosSupport

  MAX_ENTRADAS = 800

  description 'Lista o conteúdo de um diretório em forma de árvore (SOMENTE LEITURA). ' \
              'Ignora pastas ruidosas (.git, node_modules, vendor, tmp, etc). ' \
              'Use para entender a estrutura de um projeto antes de ler arquivos.'

  param :caminho,
        desc: 'Diretório a listar. Padrão: "." (diretório atual).',
        required: false

  param :profundidade,
        desc: 'Níveis de recursão (1 a 6). Padrão: 2.',
        required: false

  param :mostrar_ocultos,
        desc: 'Se "true", inclui arquivos/pastas que começam com ponto. Padrão: false.',
        required: false

  def execute(caminho: '.', profundidade: nil, mostrar_ocultos: nil)
    root = expandir(caminho.to_s.empty? ? '.' : caminho)

    return "Erro: diretório não encontrado: #{caminho}" unless File.exist?(root)
    return "Erro: não é um diretório, use 'ler_arquivo': #{caminho}" unless File.directory?(root)

    @depth_max = clamp(profundidade, 1, 6, 2)
    @show_hidden = truthy?(mostrar_ocultos)
    @count = 0
    @truncou = false

    linhas = []
    render(root, '', 1, linhas)

    rodape = @truncou ? "\n… (parou em #{MAX_ENTRADAS} entradas; use um caminho mais específico)" : ''
    "#{root}/\n#{linhas.join("\n")}#{rodape}"
  rescue StandardError => e
    "Erro ao listar '#{caminho}': #{e.class}: #{e.message}"
  end

  private

  def render(dir, prefix, nivel, linhas)
    return if nivel > @depth_max || @truncou

    entradas = Dir.children(dir).sort_by { |n| [File.directory?(File.join(dir, n)) ? 0 : 1, n.downcase] }
    entradas.reject! { |n| n.start_with?('.') } unless @show_hidden

    entradas.each_with_index do |nome, i|
      if @count >= MAX_ENTRADAS
        @truncou = true
        return
      end
      @count += 1

      full = File.join(dir, nome)
      last = i == entradas.length - 1
      branch = last ? '└─ ' : '├─ '

      if File.directory?(full)
        marcador = ignorar_dir?(full) ? "#{nome}/  (ignorado)" : "#{nome}/"
        linhas << "#{prefix}#{branch}#{marcador}"
        next if ignorar_dir?(full)

        render(full, prefix + (last ? '   ' : '│  '), nivel + 1, linhas)
      else
        tam = begin
          " (#{humano(File.size(full))})"
        rescue StandardError
          ''
        end
        linhas << "#{prefix}#{branch}#{nome}#{tam}"
      end
    end
  end
end

# -----------------------------------------------------------------------------
#  buscar_codigo — procura um padrão em arquivos (grep, SOMENTE LEITURA).
#  Usa ripgrep (rg) se disponível; senão cai para busca em Ruby puro.
# -----------------------------------------------------------------------------
class BuscarCodigoTool < RubyLLM::Tool
  include ArquivosSupport

  MAX_RESULTADOS = 80
  MAX_BYTES_ARQ  = 2_000_000 # não escaneia arquivos gigantes no fallback

  description 'Procura um texto/expressão em arquivos de um diretório (como o grep), ' \
              'SOMENTE LEITURA. Retorna arquivo:linha: trecho. Ótimo para encontrar ' \
              'onde uma função, classe ou string é usada antes de analisar.'

  param :padrao,
        desc: 'Texto ou expressão regular a procurar. Ex: "def execute", "TODO", "class \\w+Tool".',
        required: true

  param :caminho,
        desc: 'Diretório ou arquivo onde buscar. Padrão: "." (atual).',
        required: false

  param :ignorar_maiusculas,
        desc: 'Se "true", ignora diferença de maiúsculas/minúsculas. Padrão: false.',
        required: false

  def execute(padrao:, caminho: '.', ignorar_maiusculas: nil)
    pat = padrao.to_s
    return 'Erro: padrão vazio.' if pat.strip.empty?

    base = expandir(caminho.to_s.empty? ? '.' : caminho)
    return "Erro: caminho não encontrado: #{caminho}" unless File.exist?(base)

    ci = truthy?(ignorar_maiusculas)
    resultados =
      if ripgrep_disponivel?
        buscar_com_rg(pat, base, ci)
      else
        buscar_ruby(pat, base, ci)
      end

    return "Nenhum resultado para /#{pat}/ em #{caminho}." if resultados.empty?

    corte = resultados.length > MAX_RESULTADOS
    lista = resultados.first(MAX_RESULTADOS).join("\n")
    rodape = corte ? "\n… (+#{resultados.length - MAX_RESULTADOS} resultados; refine o padrão)" : ''
    motor = ripgrep_disponivel? ? 'ripgrep' : 'ruby'
    "#{resultados.length} resultado(s) para /#{pat}/ (motor: #{motor}):\n#{lista}#{rodape}"
  rescue StandardError => e
    "Erro na busca: #{e.class}: #{e.message}"
  end

  private

  def ripgrep_disponivel?
    return @rg unless @rg.nil?

    @rg = system('command -v rg > /dev/null 2>&1')
  end

  def buscar_com_rg(pat, base, ci)
    args = ['rg', '--line-number', '--no-heading', '--color', 'never',
            '--max-count', MAX_RESULTADOS.to_s, '-e', pat, base]
    args.insert(1, '-i') if ci
    ArquivosSupport::IGNORAR.each { |d| args.insert(1, '--glob'); args.insert(2, "!#{d}") }

    out, _err, _status = Open3.capture3(*args)
    out.each_line.map do |ln|
      formatar_rg(ln.chomp, base)
    end.compact.first(MAX_RESULTADOS + 1)
  end

  def formatar_rg(linha, base)
    # formato rg: caminho:linha:conteudo
    caminho, num, resto = linha.split(':', 3)
    return nil unless num =~ /\A\d+\z/

    rel = caminho.sub("#{base}/", '')
    "  #{rel}:#{num}: #{resto.to_s.strip[0, 200]}"
  end

  def buscar_ruby(pat, base, ci)
    regex = Regexp.new(pat, ci ? Regexp::IGNORECASE : 0)
    achados = []

    alvos = File.file?(base) ? [base] : arquivos_de(base)
    alvos.each do |arq|
      next if binario_ext?(arq)
      next if File.size(arq) > MAX_BYTES_ARQ
      next if binario_conteudo?(arq)

      File.foreach(arq).with_index(1) do |linha, n|
        next unless linha =~ regex

        rel = arq.sub("#{base}/", '')
        achados << "  #{rel}:#{n}: #{linha.strip[0, 200]}"
        return achados if achados.length > MAX_RESULTADOS
      end
    end
    achados
  rescue RegexpError => e
    ["Erro: expressão inválida (#{e.message})."]
  end

  def arquivos_de(base)
    lista = []
    Find.find(base) do |path|
      if File.directory?(path)
        Find.prune if ignorar_dir?(path)
        next
      end
      lista << path
    end
    lista
  end
end
