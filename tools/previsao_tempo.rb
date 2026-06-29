# frozen_string_literal: true

require 'ruby_llm'
require 'json'
require 'net/http'
require 'uri'
require 'date'
require 'readline' rescue nil # silencia warning em alguns sistemas
require_relative '../lib/ui'

class PrevisaoTempoTool < RubyLLM::Tool
  description 'Busca a previsão do tempo para os próximos 7 dias de uma cidade ' \
              'e exibe uma tabela formatada no terminal. ' \
              'Use quando o usuário perguntar sobre clima, tempo, previsão, vai chover, ' \
              'temperatura, etc. Aceita cidades em qualquer idioma — retorna dados em PT-BR.'

  param :cidade,
        desc: 'Nome da cidade. Ex: "São Paulo", "Rio de Janeiro", "Curitiba", "Berlin"',
        required: true

  DIAS_SEMANA = %w[Dom Seg Ter Qua Qui Sex Sáb].freeze

  CLIMA = {
    0  => ['☀️',  'Céu limpo'],
    1  => ['🌤️', 'Quase limpo'],
    2  => ['⛅',  'Parcialmente nublado'],
    3  => ['☁️',  'Nublado'],
    45 => ['🌫️', 'Neblina'],
    48 => ['🌫️', 'Neblina gelada'],
    51 => ['🌦️', 'Garoa leve'],
    53 => ['🌦️', 'Garoa'],
    55 => ['🌧️', 'Garoa forte'],
    61 => ['🌧️', 'Chuva leve'],
    63 => ['🌧️', 'Chuva moderada'],
    65 => ['🌧️', 'Chuva forte'],
    71 => ['🌨️', 'Neve leve'],
    73 => ['🌨️', 'Neve'],
    75 => ['❄️',  'Neve forte'],
    80 => ['🌦️', 'Pancadas leves'],
    81 => ['🌧️', 'Pancadas'],
    82 => ['⛈️', 'Pancadas fortes'],
    95 => ['⛈️', 'Tempestade'],
    96 => ['⛈️', 'Tempestade c/ granizo'],
    99 => ['⛈️', 'Tempestade forte']
  }.freeze

  def execute(cidade:)
    dados = with_spinner("Consultando previsão para #{cidade}…") { buscar(cidade) }
    exibir_tabela(dados)
    resumo_texto(dados)
  rescue StandardError => e
    "Erro ao buscar previsão: #{e.message}"
  end

  private

  def buscar(cidade)
    coords = geocodificar(cidade)
    dias = buscar_previsao(coords[:latitude], coords[:longitude], coords[:timezone])
    { cidade: coords[:nome], pais: coords[:pais], dias: dias }
  end

  def geocodificar(cidade)
    url = "https://geocoding-api.open-meteo.com/v1/search?name=" \
          "#{URI.encode_uri_component(cidade)}&count=1&language=pt&format=json"
    data = http_get_json(url)
    r = data.dig('results', 0) or raise "Cidade não encontrada: #{cidade}"

    {
      nome:      "#{r['name']}, #{r['country']}",
      latitude:  r['latitude'],
      longitude: r['longitude'],
      timezone:  r['timezone'] || 'auto'
    }
  end

  def buscar_previsao(lat, lon, tz)
    params = {
      latitude: lat,
      longitude: lon,
      daily: 'temperature_2m_max,temperature_2m_min,weathercode,' \
             'precipitation_probability_max,windspeed_10m_max',
      timezone: tz,
      forecast_days: 7
    }
    q = params.map { |k, v| "#{k}=#{URI.encode_uri_component(v.to_s)}" }.join('&')
    data = http_get_json("https://api.open-meteo.com/v1/forecast?#{q}")
    daily = data['daily']

    daily['time'].each_index.map do |i|
      codigo = daily['weathercode'][i]
      emoji, descricao = CLIMA.fetch(codigo, ['🌡️', 'Desconhecido'])
      {
        data:       daily['time'][i],
        dia_semana: DIAS_SEMANA[Date.parse(daily['time'][i]).wday],
        emoji:      emoji,
        descricao:  descricao,
        min:        daily['temperature_2m_min'][i].round(1),
        max:        daily['temperature_2m_max'][i].round(1),
        chuva_pct:  daily['precipitation_probability_max'][i],
        vento_kmh:  daily['windspeed_10m_max'][i].round(1)
      }
    end
  end

  def http_get_json(url)
    uri = URI(url)
    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                        open_timeout: 10, read_timeout: 15) do |http|
      http.get(uri.request_uri)
    end
    raise "API retornou HTTP #{resp.code}" unless resp.is_a?(Net::HTTPSuccess)

    JSON.parse(resp.body)
  end

  def with_spinner(msg)
    sp = UI::Spinner.new(msg)
    sp.start
    result = yield
    sp.stop(clear: true)
    result
  rescue StandardError => e
    sp&.stop(clear: true)
    raise e
  end

  def exibir_tabela(dados)
    a = UI::C
    largura = 68

    puts
    puts "  #{a::BOLD}#{a::CYAN}╔#{'═' * (largura - 2)}╗#{a::RESET}"
    titulo = "  🌍  PREVISÃO — #{dados[:cidade]}"
    padding = largura - 4 - titulo.length
    puts "  #{a::BOLD}#{a::CYAN}║#{a::RESET}#{a::BOLD}#{a::WHITE}#{titulo}#{' ' * [padding, 0].max}#{a::CYAN}║#{a::RESET}"
    puts "  #{a::BOLD}#{a::CYAN}╠#{'═' * (largura - 2)}╣#{a::RESET}"

    cab = format_row('Dia', 'Data', 'Tempo', 'Mín', 'Máx', 'Chuva', 'Vento', header: true)
    puts "  #{a::BOLD}#{a::CYAN}║#{a::RESET}#{a::DIM}#{cab}#{a::CYAN}║#{a::RESET}"
    puts "  #{a::BOLD}#{a::CYAN}╠#{'─' * (largura - 2)}╣#{a::RESET}"

    dados[:dias].each_with_index do |dia, idx|
      sleep(0.12)
      temp_cor = cor_temperatura(dia[:max])
      linha = format_row(
        dia[:dia_semana], dia[:data][5..],
        "#{dia[:emoji]} #{dia[:descricao][0, 12]}",
        "#{dia[:min]}°", "#{dia[:max]}°",
        "#{dia[:chuva_pct]}%", "#{dia[:vento_kmh]}km/h"
      )
      prefixo = idx.zero? ? "#{a::BOLD}#{a::YELLOW}▶ #{a::RESET}" : '  '
      cor_linha = idx.zero? ? a::BOLD : ''
      puts "  #{a::BOLD}#{a::CYAN}║#{a::RESET}#{prefixo}#{cor_linha}#{temp_cor}#{linha}#{a::RESET}#{a::CYAN}║#{a::RESET}"
    end

    puts "  #{a::BOLD}#{a::CYAN}╚#{'═' * (largura - 2)}╝#{a::RESET}"
    puts "  #{a::DIM}Fonte: Open-Meteo · open-meteo.com#{a::RESET}"
    puts
  end

  def format_row(dia, data, tempo, min, max, chuva, vento, header: false)
    if header
      format(' %-4s │ %-5s │ %-14s │ %-4s │ %-4s │ %-5s │ %-7s ',
             dia, data, tempo, min, max, chuva, vento)
    else
      format(' %-4s │ %-5s │ %-14s │ %4s │ %4s │ %5s │ %7s ',
             dia, data, tempo, min, max, chuva, vento)
    end
  end

  def cor_temperatura(max)
    a = UI::C
    case max
    when 0..15  then a::BLUE
    when 16..25 then a::GREEN
    when 26..32 then a::YELLOW
    else a::RED
    end
  end

  def resumo_texto(dados)
    linhas = dados[:dias].map do |d|
      "#{d[:dia_semana]} #{d[:data]}: #{d[:descricao]}, " \
        "#{d[:min]}°~#{d[:max]}°C, chuva #{d[:chuva_pct]}%, " \
        "vento #{d[:vento_kmh]}km/h"
    end
    "Previsão 7 dias para #{dados[:cidade]}:\n#{linhas.join("\n")}"
  end
end
