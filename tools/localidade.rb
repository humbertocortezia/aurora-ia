# frozen_string_literal: true

require 'ruby_llm'
require 'json'
require 'net/http'
require 'uri'
require 'fileutils'
require 'time'
require_relative '../lib/ui'

class LocalidadeTool < RubyLLM::Tool
  description 'Descobre a cidade e o país do usuário via geolocalização por IP. ' \
              'Cacheia o resultado por 24h. ' \
              'Use quando o usuário perguntar "onde eu estou?", "minha cidade", ' \
              'ou implicitamente precisar da localização (ex: "vai chover aqui?").'

  def initialize(config:)
    super()
    @config = config
  end

  def execute
    cached = ler_cache
    if cached && dentro_24h?(cached['cached_at'])
      dados = cached['dados']
    else
      dados = with_spinner('Detectando sua localização por IP…') { buscar_ipapi }
      gravar_cache(dados)
    end

    return "Localidade: #{dados['city']}, #{dados['regionName']} — #{dados['country']} " \
           "(lat #{dados['lat']}, lon #{dados['lon']}, fuso #{dados['timezone']})"
  rescue StandardError => e
    "Erro ao detectar localização: #{e.message}"
  end

  private

  def buscar_ipapi
    uri = URI(@config.ipapi_url)
    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                        open_timeout: 8, read_timeout: 12) do |http|
      http.get(uri.request_uri)
    end
    raise "HTTP #{resp.code}" unless resp.is_a?(Net::HTTPSuccess)

    data = JSON.parse(resp.body)
    raise data['message'] || 'Resposta inesperada' unless data['status'] == 'success'

    data
  end

  def cache_path
    File.join(@config.data_dir, 'localidade.json')
  end

  def ler_cache
    return nil unless File.exist?(cache_path)

    JSON.parse(File.read(cache_path))
  rescue StandardError
    nil
  end

  def gravar_cache(dados)
    FileUtils.mkdir_p(File.dirname(cache_path))
    File.write(cache_path,
               { 'cached_at' => Time.now.iso8601, 'dados' => dados }.to_json)
  end

  def dentro_24h?(iso)
    t = Time.parse(iso)
    (Time.now - t) < 86_400
  rescue StandardError
    false
  end

  def with_spinner(msg)
    sp = UI::Spinner.new(msg)
    sp.start
    r = yield
    sp.stop(clear: true)
    r
  rescue StandardError => e
    sp&.stop(clear: true)
    raise e
  end
end
