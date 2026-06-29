# frozen_string_literal: true

require 'ruby_llm'
require 'json'
require 'net/http'
require 'uri'
require 'nokogiri'
require 'cgi'
require 'readline' rescue nil
require_relative '../lib/ui'

class PesquisaWebTool < RubyLLM::Tool
  description 'Realiza uma pesquisa na web usando SearXNG, lê o conteúdo das principais páginas ' \
              'e devolve um resumo estruturado com fontes. ' \
              'Use quando o usuário precisar de informação atualizada da web: notícias, ' \
              'documentação, tutoriais, preços, lançamentos, eventos, etc. ' \
              'Retorna título, URL e um extrato relevante de cada fonte consultada.'

  param :consulta,
        desc: 'Termos de busca. Use o idioma do usuário quando possível. ' \
              'Ex: "novidades ruby on rails 2026", "preço bitcoin agora"',
        required: true

  param :quantidade,
        desc: 'Quantas páginas abrir e ler (1-8). Padrão 5. Mais = mais lento.',
        required: false

  def initialize(config:)
    super()
    @config = config
  end

  def execute(consulta:, quantidade: nil)
    n = clamp_int(quantidade, default: @config.searxng_max_results, min: 1, max: 8)
    query = consulta.to_s.strip
    raise ArgumentError, 'consulta vazia' if query.empty?

    sp = UI::Spinner.new("Pesquisando no SearXNG: \"#{truncate(query, 50)}\"")
    sp.start
    resultados = searxng_buscar(query, n)
    sp.update("Lendo #{resultados.size} páginas…")
    sp.update("Lendo páginas (0/#{resultados.size})…")
    paginas = resultados.each_with_index.map do |r, i|
      sp.update("Lendo páginas (#{i + 1}/#{resultados.size})…")
      conteudo = extrair_conteudo(r['url'])
      r.merge('conteudo' => conteudo)
    end
    sp.stop(clear: true)

    formatar_resultados(query, paginas)
  rescue StandardError => e
    sp&.stop(clear: true)
    "Erro na pesquisa: #{e.message}"
  end

  private

  def clamp_int(val, default:, min:, max:)
    n = val.nil? ? default : val.to_i
    n = default if n <= 0
    [[n, min].max, max].min
  end

  def truncate(s, n)
    s.length > n ? "#{s[0, n - 1]}…" : s
  end

  # 1) GET SearXNG → JSON com lista de resultados
  #    Tenta JSON primeiro; se o servidor tiver 'json' desabilitado nos formats,
  #    cai pra parsear o HTML (fallback).
  def searxng_buscar(query, n)
    json_results = searxng_tentar_json(query, n)
    return json_results if json_results

    searxng_parsear_html(query, n)
  end

  def searxng_tentar_json(query, n)
    params = {
      q: query,
      format: 'json',
      language: @config.searxng_language,
      safesearch: 0
    }
    q = params.map { |k, v| "#{k}=#{CGI.escape(v.to_s)}" }.join('&')
    url = "#{@config.searxng_url.chomp('/')}/search?#{q}"

    uri = URI(url)
    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                        open_timeout: 8,
                                        read_timeout: @config.searxng_timeout) do |http|
      http.get(uri.request_uri, 'User-Agent' => 'chatia-agent/1.0')
    end
    return nil unless resp.is_a?(Net::HTTPSuccess)

    data = JSON.parse(resp.body)
    results = data['results'] || []
    results.empty? ? nil : results.first(n)
  rescue StandardError
    nil
  end

  def searxng_parsear_html(query, n)
    params = { q: query, language: @config.searxng_language, safesearch: 0 }
    q = params.map { |k, v| "#{k}=#{CGI.escape(v.to_s)}" }.join('&')
    url = "#{@config.searxng_url.chomp('/')}/search?#{q}"

    uri = URI(url)
    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                        open_timeout: 8,
                                        read_timeout: @config.searxng_timeout) do |http|
      http.get(uri.request_uri, 'User-Agent' => 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36')
    end
    raise "SearXNG retornou HTTP #{resp.code}" unless resp.is_a?(Net::HTTPSuccess)

    doc = Nokogiri::HTML(resp.body)
    articles = doc.css('article.result, .result, article')

    results = articles.map do |a|
      a.css('script, style').remove
      link = a.at_css('a.url, h3 a, h4 a, a')
      next nil unless link && link['href']

      href = link['href'].to_s
      next nil if href.start_with?('/search?', 'http://172.16.107.244:8888/search?',
                                    "#{@config.searxng_url.chomp('/')}/search?")
      next nil if href.include?('/search?')

      title = link.text.strip
      title = a.at_css('h3, h4')&.text&.strip if title.empty?
      snippet = a.css('p.content, .content, .snippet, p').first&.text&.strip.to_s

      { 'title' => title, 'url' => href, 'content' => snippet }
    end.compact

    raise 'SearXNG (HTML) não devolveu resultados' if results.empty?

    results.first(n)
  end

  # 2) GET na página → extrai o texto principal
  def extrair_conteudo(url)
    uri = URI(url)
    return '(URL inválida)' unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                        open_timeout: 8, read_timeout: 12) do |http|
      http.get(uri.request_uri, 'User-Agent' => 'Mozilla/5.0 (compatible; chatia/1.0)',
               'Accept' => 'text/html,application/xhtml+xml')
    end
    return '(HTTP não-sucesso)' unless resp.is_a?(Net::HTTPSuccess)
    return '(sem conteúdo)' if resp.body.nil? || resp.body.empty?

    doc = Nokogiri::HTML(resp.body)
    doc.css('script, style, nav, header, footer, aside, form, noscript, svg, iframe').remove

    # tenta primeiro o "miolo" semântico
    main = doc.at_css('main') || doc.at_css('article') || doc.at_css('[role=main]')

    texto = if main
              paragrafos = main.css('p, li, h1, h2, h3, h4').map { |e| e.text.strip }.reject(&:empty?)
              paragrafos.join("\n")
            else
              # fallback: pega todos os <p> e ordena pelos maiores (provável conteúdo)
              paragrafos = doc.css('p').map { |e| e.text.strip }.reject(&:empty?)
              if paragrafos.size >= 3
                paragrafos.sort_by { |t| -t.length }.first(15).reverse.join("\n")
              else
                doc.css('p, li, h1, h2, h3, h4').map { |e| e.text.strip }.reject(&:empty?).join("\n")
              end
            end

    texto = texto.gsub(/\s+/, ' ').gsub(/\n\s*\n+/, "\n\n").strip
    texto.empty? ? '(página sem texto extraível)' : truncate(texto, 1800)
  rescue StandardError => e
    "(erro ao ler página: #{e.class}: #{e.message[0, 120]})"
  end

  def formatar_resultados(query, paginas)
    header = "Pesquisa: \"#{query}\"  ·  fontes consultadas: #{paginas.size}\n"
    body = paginas.each_with_index.map do |p, i|
      snippet = p['content'].to_s.strip
      content = p['conteudo'].to_s.strip
      [
        "[#{i + 1}] #{p['title']}",
        "    URL: #{p['url']}",
        snippet.empty? ? '' : "    Snippet: #{truncate(snippet, 200)}",
        "    Conteúdo extraído: #{truncate(content, 600)}"
      ].reject(&:empty?).join("\n")
    end.join("\n\n")

    footer = "\n\nUse essas fontes para embasar a resposta ao usuário. " \
             "Cite os URLs quando apropriado."

    header + body + footer
  end
end
