# frozen_string_literal: true

require 'logger'
require 'fileutils'

module AgentLogger
  module_function

  def build(log_dir:)
    FileUtils.mkdir_p(log_dir)
    path = File.join(log_dir, 'agent.log')

    logger = Logger.new(path, 5, 1_048_576) # 5 arquivos × 1MB
    logger.level = Logger::INFO
    logger.formatter = proc do |severity, time, _progname, msg|
      "[#{time.strftime('%Y-%m-%d %H:%M:%S')}] #{severity.ljust(5)} #{msg}\n"
    end
    logger
  end
end
