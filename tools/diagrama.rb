# frozen_string_literal: true

require 'ruby_llm'
require 'json'
require_relative '../lib/ui'

# Desenha diagramas no terminal a partir de um JSON estruturado.
# Tipos: tabela, arvore, fluxo (fluxograma/algoritmo) e er (entidade-relação).
class DiagramaTool < RubyLLM::Tool
  C = UI::C

  description <<~DESC
    Desenha um diagrama VISUAL no terminal usando caracteres de caixa (box-drawing).
    Use quando for mais claro MOSTRAR do que descrever: explicar um algoritmo,
    uma estrutura de dados, um esquema de banco, uma hierarquia ou relações.

    Parâmetros:
    - tipo: "tabela" | "arvore" | "fluxo" | "er"
    - titulo: (opcional) título exibido acima do desenho
    - dados: STRING JSON descrevendo o diagrama. O formato depende do tipo:

    tabela → { "colunas": ["Nome","Idade"], "linhas": [["Ana","30"],["Bia","25"]] }

    arvore → { "raiz": "App", "filhos": [
                 { "nome": "models", "filhos": [{"nome":"user.rb"}] },
                 { "nome": "views" }
               ] }

    fluxo  → { "passos": [
                 { "tipo": "inicio",   "texto": "Início" },
                 { "tipo": "processo", "texto": "Ler entrada" },
                 { "tipo": "decisao",  "texto": "x > 0?", "sim": "soma", "nao": "subtrai" },
                 { "tipo": "fim",      "texto": "Fim" }
               ] }
             (tipo de passo: inicio | processo | decisao | fim)

    er     → { "entidades": [
                 { "nome": "users", "campos": ["id PK","nome","email"] },
                 { "nome": "posts", "campos": ["id PK","user_id FK","titulo"] }
               ],
               "relacoes": [
                 { "de": "users", "para": "posts", "card": "1:N", "rotulo": "escreve" }
               ] }
  DESC

  param :tipo,
        desc: 'Tipo do diagrama: "tabela", "arvore", "fluxo" ou "er".',
        required: true

  param :dados,
        desc: 'JSON (string) com a estrutura do diagrama. Veja os formatos na descrição.',
        required: true

  param :titulo,
        desc: 'Título opcional exibido acima do diagrama.',
        required: false

  def execute(tipo:, dados:, titulo: nil)
    spec = dados.is_a?(String) ? JSON.parse(dados) : dados

    case tipo.to_s.strip.downcase
    when 'tabela', 'table'      then render_tabela(spec, titulo)
    when 'arvore', 'árvore', 'tree' then render_arvore(spec, titulo)
    when 'fluxo', 'fluxograma', 'flow' then render_fluxo(spec, titulo)
    when 'er', 'erd', 'entidade' then render_er(spec, titulo)
    else
      "Tipo inválido: #{tipo}. Use: tabela | arvore | fluxo | er."
    end
  rescue JSON::ParserError => e
    "Erro: 'dados' não é um JSON válido (#{e.message}). Reenvie como string JSON."
  rescue StandardError => e
    "Erro ao desenhar diagrama: #{e.class}: #{e.message}"
  end

  private

  def title_line(titulo)
    return unless titulo && !titulo.to_s.empty?

    puts "  #{C::ACCENT}◆#{C::RESET} #{C::BOLD}#{titulo}#{C::RESET}"
    puts
  end

  # --- TABELA ----------------------------------------------------------------
  def render_tabela(spec, titulo)
    cols = (spec['colunas'] || spec['columns'] || spec['headers'] || []).map(&:to_s)
    rows = (spec['linhas'] || spec['rows'] || []).map { |r| Array(r).map(&:to_s) }
    ncol = [cols.length, rows.map(&:length).max || 0].max
    return 'Erro: tabela sem colunas nem linhas.' if ncol.zero?

    cols += [''] * (ncol - cols.length)
    rows = rows.map { |r| r + [''] * (ncol - r.length) }
    w = (0...ncol).map { |i| ([cols[i].length] + rows.map { |r| r[i].length }).max }

    bar = ->(l, m, r) { "  #{C::GRAY}#{l}#{w.map { |x| '─' * (x + 2) }.join(m)}#{r}#{C::RESET}" }
    pipe = "#{C::GRAY}│#{C::RESET}"

    puts
    title_line(titulo)
    puts bar.call('┌', '┬', '┐')
    puts '  ' + pipe + cols.each_index.map { |i| " #{C::BOLD}#{cols[i].ljust(w[i])}#{C::RESET} " }.join(pipe) + pipe
    puts bar.call('├', '┼', '┤')
    rows.each do |r|
      puts '  ' + pipe + r.each_index.map { |i| " #{r[i].ljust(w[i])} " }.join(pipe) + pipe
    end
    puts bar.call('└', '┴', '┘')
    puts

    "Tabela #{ncol}×#{rows.length} desenhada no terminal."
  end

  # --- ARVORE ----------------------------------------------------------------
  def render_arvore(spec, titulo)
    raiz   = spec['raiz'] || spec['root'] || spec['nome'] || spec['name'] || '(raiz)'
    filhos = spec['filhos'] || spec['children'] || []

    puts
    title_line(titulo)
    puts "  #{C::BOLD}#{C::ACCENT}#{raiz}#{C::RESET}"
    n = walk_tree(filhos, '')
    puts

    "Árvore '#{raiz}' desenhada com #{n} nó(s)."
  end

  def walk_tree(nodes, prefix)
    count = 0
    nodes.each_with_index do |node, i|
      last = i == nodes.length - 1
      branch = last ? '└─ ' : '├─ '
      puts "  #{C::GRAY}#{prefix}#{branch}#{C::RESET}#{node_name(node)}"
      count += 1
      kids = node_children(node)
      count += walk_tree(kids, prefix + (last ? '   ' : '│  ')) unless kids.empty?
    end
    count
  end

  def node_name(node)
    node.is_a?(Hash) ? (node['nome'] || node['name'] || node.to_s) : node.to_s
  end

  def node_children(node)
    node.is_a?(Hash) ? (node['filhos'] || node['children'] || []) : []
  end

  # --- FLUXO (algoritmo) -----------------------------------------------------
  MARGIN = '   '

  def render_fluxo(spec, titulo)
    passos = spec['passos'] || spec['steps'] || []
    return 'Erro: fluxo sem passos.' if passos.empty?

    puts
    title_line(titulo)
    passos.each_with_index do |p, i|
      tipo  = (p['tipo'] || p['type'] || 'processo').to_s
      texto = (p['texto'] || p['text'] || '').to_s

      if %w[decisao decisão decision].include?(tipo)
        draw_decision(texto, p)
      else
        draw_box(texto, tipo)
      end
      draw_arrow unless i == passos.length - 1
    end
    puts

    "Fluxograma com #{passos.length} passo(s) desenhado."
  end

  def box_color(tipo)
    case tipo
    when 'inicio', 'início', 'start' then C::GREEN
    when 'fim', 'end'                then C::RED
    else                                  C::CYAN
    end
  end

  def draw_box(texto, tipo)
    inner = " #{texto} "
    w = inner.length
    col = box_color(tipo)
    puts "#{MARGIN}#{col}╭#{'─' * w}╮#{C::RESET}"
    puts "#{MARGIN}#{col}│#{C::RESET}#{C::BOLD}#{inner}#{C::RESET}#{col}│#{C::RESET}"
    puts "#{MARGIN}#{col}╰#{'─' * w}╯#{C::RESET}"
  end

  def draw_decision(texto, p)
    sim = (p['sim'] || p['yes'] || p['true']).to_s
    nao = (p['nao'] || p['não'] || p['no'] || p['false']).to_s
    puts "#{MARGIN}#{C::YELLOW}◇ #{C::BOLD}#{texto}#{C::RESET}"
    puts "#{MARGIN}  #{C::GREEN}├─ sim ─▶#{C::RESET} #{sim}" unless sim.empty?
    puts "#{MARGIN}  #{C::RED}╰─ não ─▶#{C::RESET} #{nao}" unless nao.empty?
  end

  def draw_arrow
    puts "#{MARGIN}#{C::GRAY}  │#{C::RESET}"
    puts "#{MARGIN}#{C::GRAY}  ▼#{C::RESET}"
  end

  # --- ER (entidade-relação) -------------------------------------------------
  def render_er(spec, titulo)
    entidades = spec['entidades'] || spec['entities'] || []
    relacoes  = spec['relacoes'] || spec['relations'] || []
    return 'Erro: ER sem entidades.' if entidades.empty?

    puts
    title_line(titulo)
    entidades.each do |e|
      draw_entity(e)
      puts
    end

    unless relacoes.empty?
      puts "  #{C::DIM}Relações:#{C::RESET}"
      relacoes.each do |r|
        de   = (r['de'] || r['from']).to_s
        para = (r['para'] || r['to']).to_s
        card = (r['card'] || r['cardinalidade'] || '').to_s
        rot  = (r['rotulo'] || r['label'] || '').to_s
        conn = card.empty? ? '────▶' : "──#{card}──▶"
        line = "    #{C::BOLD}#{de}#{C::RESET} #{C::GRAY}#{conn}#{C::RESET} #{C::BOLD}#{para}#{C::RESET}"
        line += "  #{C::DIM}(#{rot})#{C::RESET}" unless rot.empty?
        puts line
      end
      puts
    end

    "Diagrama ER com #{entidades.length} entidade(s) e #{relacoes.length} relação(ões)."
  end

  def draw_entity(e)
    nome   = (e['nome'] || e['name'] || '(entidade)').to_s
    campos = (e['campos'] || e['fields'] || []).map(&:to_s)
    w = ([nome.length] + campos.map(&:length)).max + 2

    head = " #{nome}#{' ' * (w - nome.length - 1)}"
    puts "  #{C::CYAN}┌#{'─' * w}┐#{C::RESET}"
    puts "  #{C::CYAN}│#{C::RESET}#{C::BOLD}#{C::ACCENT}#{head}#{C::RESET}#{C::CYAN}│#{C::RESET}"
    puts "  #{C::CYAN}├#{'─' * w}┤#{C::RESET}"
    campos.each do |campo|
      cell = " #{campo}#{' ' * (w - campo.length - 1)}"
      colored = campo_destacado(cell)
      puts "  #{C::CYAN}│#{C::RESET}#{colored}#{C::CYAN}│#{C::RESET}"
    end
    puts "  #{C::CYAN}└#{'─' * w}┘#{C::RESET}"
  end

  # destaca PK/FK no fim do campo, mantendo a largura
  def campo_destacado(cell)
    if cell =~ /\bPK\b/
      cell.sub(/PK/, "#{C::YELLOW}PK#{C::RESET}")
    elsif cell =~ /\bFK\b/
      cell.sub(/FK/, "#{C::MAGENTA}FK#{C::RESET}")
    else
      cell
    end
  end
end
