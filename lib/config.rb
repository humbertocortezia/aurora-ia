# frozen_string_literal: true

require 'dotenv'
require 'ostruct'

module Config
  module_function

  # Carrega .env (silencioso se não existir) e devolve struct com tudo que precisamos.
  # base_dir = diretório de quem está chamando (ex: agent.rb). Usado pra resolver
  # caminhos relativos do .env (DATA_DIR, LOG_DIR).
  def load(env_file: nil, base_dir: Dir.pwd)
    env_file ||= File.join(base_dir, '.env')
    Dotenv.load(env_file) if File.exist?(env_file)

    OpenStruct.new(
      llm_api_base:         ENV.fetch('LLM_API_BASE', 'https://api.openai.com/v1'),
      llm_api_key:          ENV.fetch('LLM_API_KEY', 'sk-placeholder'),
      llm_model:            ENV.fetch('LLM_MODEL', 'gpt-4o-mini'),
      llm_use_system_role:  truthy?(ENV.fetch('LLM_USE_SYSTEM_ROLE', 'true')),

      searxng_url:          ENV.fetch('SEARXNG_URL', 'http://localhost:8888'),
      searxng_max_results:  ENV.fetch('SEARXNG_MAX_RESULTS', '5').to_i,
      searxng_language:     ENV.fetch('SEARXNG_LANGUAGE', 'pt-BR'),
      searxng_timeout:      ENV.fetch('SEARXNG_TIMEOUT', '15').to_i,

      ipapi_url:            ENV.fetch('IPAPI_URL',
                           'http://ip-api.com/json/?fields=status,message,country,regionName,city,lat,lon,timezone,query'),

      agent_name:           ENV.fetch('AGENT_NAME', 'Aurora'),
      agent_max_tool_calls: ENV.fetch('AGENT_MAX_TOOL_CALLS', '10').to_i,
      agent_thinking:       ENV.fetch('AGENT_THINKING_EFFORT', 'medium'),
      agent_temperature:    ENV.fetch('AGENT_TEMPERATURE', '0.4').to_f,
      agent_thinking_timeout: ENV.fetch('AGENT_THINKING_TIMEOUT', '90').to_i,
      agent_turn_timeout:   ENV.fetch('AGENT_TURN_TIMEOUT', '300').to_i,

      db_path:              File.expand_path(ENV.fetch('DB_PATH', './data/aurora.db'), base_dir),
      compaction_threshold: ENV.fetch('COMPACTION_THRESHOLD', '30').to_i,
      compaction_keep_head: ENV.fetch('COMPACTION_KEEP_HEAD', '5').to_i,
      compaction_keep_tail: ENV.fetch('COMPACTION_KEEP_TAIL', '5').to_i,
      session_history_on_boot: ENV.fetch('SESSION_HISTORY_ON_BOOT', '10').to_i,

      data_dir:             File.expand_path(ENV.fetch('DATA_DIR', './data'), base_dir),
      log_dir:              File.expand_path(ENV.fetch('LOG_DIR', './logs'), base_dir)
    )
  end

  def truthy?(val)
    %w[1 true yes y on].include?(val.to_s.downcase)
  end
end
