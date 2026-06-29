# frozen_string_literal: true

require 'ruby_llm'
require 'dentaku'

class CalculadoraTool < RubyLLM::Tool
  description 'Avalia uma expressão matemática com segurança e retorna o resultado. ' \
              'Suporta +, -, *, /, ** (potência), parênteses, funções (sqrt, sin, cos, log, abs, etc) ' \
              'e constantes (PI, E). ' \
              'Use para qualquer cálculo numérico que o usuário pedir — não tente fazer de cabeça.'

  param :expressao,
        desc: 'Expressão matemática, ex: "(2 + 3) * 4" ou "sqrt(144) + PI"',
        required: true

  def execute(expressao:)
    expr = expressao.to_s.strip
    raise ArgumentError, 'expressão vazia' if expr.empty?

    calc = Dentaku::Calculator.new
    result = calc.evaluate(expr)

    "Expressão: #{expr}\nResultado: #{format_number(result)}"
  rescue Dentaku::ParseError, Dentaku::TokenizerError => e
    "Erro de sintaxe na expressão \"#{expressao}\": #{e.message}"
  rescue ZeroDivisionError
    "Erro: divisão por zero em \"#{expressao}\""
  rescue StandardError => e
    "Erro ao calcular \"#{expressao}\": #{e.message}"
  end

  private

  def format_number(n)
    return n.to_s if n.is_a?(String)
    return 'indefinido' if n.nil? || (n.respond_to?(:nan?) && n.nan?)
    return n.to_i.to_s if n.is_a?(Numeric) && n == n.to_i && n.abs < 1e15

    format('%.6g', n)
  end
end
