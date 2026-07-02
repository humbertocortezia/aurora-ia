# frozen_string_literal: true

require 'ruby_llm'
require_relative '../lib/memory'

class UserFactsTool < RubyLLM::Tool
  description 'Gerencia o perfil persistente do usuário: salva, lista ou apaga fatos. ' \
              'Salve automaticamente (sem pedir confirmação) quando o usuário revelar uma ' \
              'informação pessoal estável: nome, idade, profissão, cidade, gostos, hábitos, ' \
              'projetos, linguagem favorita, etc. Salve apenas uma vez por informação — se já ' \
              'está no perfil, não salve de novo. ' \
              'Chaves sugeridas (snake_case): nome, idade, cidade, profissao, empresa, hobbies, ' \
              'preferencias, projeto_atual, linguagem_favorita. ' \
              '\n\nDIFERENÇA DE MemoriaTool: ' \
              'ESTA tool guarda fatos SOBRE o usuário (identidade, preferências, contexto). ' \
              'A MemoriaTool guarda CONHECIMENTOS que o usuário adquiriu (estudos, skills, tópicos aprendidos).'

  params do
    string :acao,
           description: 'Ação: "salvar" (cria/atualiza), "listar" (mostra tudo), ' \
                        'ou "esquecer" (apaga uma chave)',
           enum: %w[salvar listar esquecer]

    string :chave,
           description: 'Chave do fato (snake_case). Ex: "nome", "profissao". ' \
                        'Obrigatória para salvar e esquecer.',
           required: false

    string :valor,
           description: 'Valor do fato. Ex: "Humberto", "Desenvolvedor Ruby". ' \
                        'Obrigatório para salvar.',
           required: false

    string :categoria,
           description: 'Categoria opcional: "user" (default), "project", "preference", "context".',
           required: false
  end

  def initialize(logger: nil, current_session_id: nil)
    super()
    @logger = logger
    @session_id = current_session_id
  end

  def execute(acao:, chave: nil, valor: nil, categoria: nil)
    case acao
    when 'salvar'
      salvar(chave, valor, categoria)
    when 'listar'
      listar
    when 'esquecer'
      esquecer(chave)
    else
      "Ação inválida: #{acao}. Use: salvar | listar | esquecer."
    end
  end

  private

  def salvar(chave, valor, categoria)
    return 'Erro: chave é obrigatória para salvar.' if chave.nil? || chave.to_s.strip.empty?
    return "Erro: valor é obrigatório para salvar \"#{chave}\"." if valor.nil? || valor.to_s.strip.empty?

    r = Memory.fact_set(
      key: chave, value: valor, category: categoria || 'user',
      source_session: @session_id, logger: @logger
    )
    verb = r[:existed] ? 'Atualizei' : 'Salvei'
    "#{verb} no perfil: #{r[:key]} = #{r[:value]}"
  end

  def listar
    facts = Memory.facts_all
    if facts.empty?
      'Perfil vazio. Nada lembrado ainda.'
    else
      "Fatos lembrados (#{facts.size}):\n" + facts.map { |k, v| "- #{k}: #{v}" }.join("\n")
    end
  end

  def esquecer(chave)
    return 'Erro: chave é obrigatória para esquecer.' if chave.nil? || chave.to_s.strip.empty?

    r = Memory.fact_delete(key: chave, logger: @logger)
    if r[:existed]
      "Apaguei do perfil: #{r[:key]}"
    else
      "Chave \"#{chave}\" não existia no perfil."
    end
  end
end
