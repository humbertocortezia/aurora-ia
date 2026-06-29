# frozen_string_literal: true

require 'ruby_llm'

class HoraTool < RubyLLM::Tool
  description 'Retorna a data e hora atual do sistema no fuso horário local. ' \
              'Use quando o usuário perguntar que dia/hora é agora, prazos relativos a agora, etc.'

  def execute
    now = Time.now
    "Agora: #{now.strftime('%A, %d de %B de %Y — %H:%M:%S')} " \
      "(fuso: #{now.zone || 'local'})"
  end
end
