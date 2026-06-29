# frozen_string_literal: true

require 'ruby_llm'
require_relative '../lib/memory'

class MemoriaTool < RubyLLM::Tool
  description 'Gerencia o conhecimento cumulativo que o agente tem sobre o que o USUÁRIO aprendeu. ' \
              'Use para registrar tópicos dominados, conceitos novos, dúvidas, preferências de estudo. ' \
              '\n\nAÇÕES:' \
              '\n- "salvar" (padrão): registra/atualiza aprendizado. Se o mesmo (topic, subtopic) já existir, ' \
              'faz merge e atualiza a proficiência (média).' \
              '\n- "listar_topicos": mostra todos os tópicos conhecidos com contagem e proficiência média.' \
              '\n- "buscar": procura aprendizados por topic e/ou subtopic (LIKE).' \
              '\n- "esquecer": apaga um (topic, subtopic) específico.' \
              '\n\nPROFICIÊNCIA (1-5):' \
              '\n- 1 = ouviu falar, não manja' \
              '\n- 2 = entendeu o básico' \
              '\n- 3 = usa com confiança em casos simples' \
              '\n- 4 = domina, consegue ensinar' \
              '\n- 5 = expert' \
              '\n\nEXEMPLOS DE CHAMADA AUTOMÁTICA:' \
              '\n- Usuário: "agora entendi como funciona generics em TS" → salvar(topic="typescript", subtopic="generics", content="…", proficiency=2)' \
              '\n- Usuário: "já usei discriminated unions em vários projetos" → atualizar pra proficiency 4' \
              '\n- Usuário: "esquece o que sabe sobre X" → esquecer(topic="X")'

  param :acao,
        desc: 'Ação: "salvar" (default), "listar_topicos", "buscar" ou "esquecer"',
        required: false

  param :topic,
        desc: 'Tópico principal. Ex: "typescript", "ruby", "rust", "docker".',
        required: false

  param :subtopic,
        desc: 'Subtópico (opcional). Ex: "generics", "interfaces", "blocks".',
        required: false

  param :content,
        desc: 'Descrição do que foi aprendido (1-3 frases, direto ao ponto).',
        required: false

  param :proficiencia,
        desc: 'Nível de 1 (básico) a 5 (expert). Default 2.',
        required: false

  def initialize(logger: nil)
    super()
    @logger = logger
  end

  def execute(acao: 'salvar', topic: nil, subtopic: nil, content: nil, proficiencia: nil)
    case acao.to_s
    when 'listar_topicos', 'listar'
      listar_topicos
    when 'buscar', 'search'
      buscar(topic, subtopic)
    when 'esquecer', 'delete'
      esquecer(topic, subtopic)
    when 'salvar', 'save', '', nil
      salvar(topic, subtopic, content, proficiencia)
    else
      "Ação inválida: #{acao}. Use: salvar | listar_topicos | buscar | esquecer."
    end
  end

  private

  def salvar(topic, subtopic, content, proficiencia)
    if topic.to_s.strip.empty?
      return 'Erro: topic é obrigatório pra salvar.'
    end
    if content.to_s.strip.empty?
      return "Erro: content é obrigatório pra salvar o aprendizado sobre \"#{topic}\"."
    end

    prof = proficiencia.nil? ? 2 : proficiencia.to_i
    r = Memory.learning_save(
      topic: topic, subtopic: subtopic, content: content,
      proficiency: prof, logger: @logger
    )
    sub = r[:subtopic] ? " > #{r[:subtopic]}" : ''
    "#{r[:verb]} o aprendizado: #{r[:topic]}#{sub} (proficiência #{prof}/5)"
  end

  def listar_topicos
    topics = Memory.list_topics
    if topics.empty?
      'Nenhum aprendizado registrado ainda.'
    else
      "Tópicos conhecidos (#{topics.size}):\n" +
        topics.map do |t|
          last = t['last_update'].to_s[0, 10]
          "  • #{t['topic']} — #{t['count']} nota(s), " \
            "proficiência média #{t['avg_proficiency']}/5, último: #{last}"
        end.join("\n")
    end
  end

  def buscar(topic, subtopic)
    rows = Memory.learning_search(topic: topic, subtopic: subtopic, limit: 20)
    if rows.empty?
      "Nada encontrado sobre \"#{topic}\"#{subtopic ? " > #{subtopic}" : ''}."
    else
      "Encontrei #{rows.size} aprendizado(s):\n" +
        rows.map do |r|
          sub = r['subtopic'].to_s.empty? ? '' : " > #{r['subtopic']}"
          "  • [#{r['proficiency']}/5] #{r['topic']}#{sub}\n    " \
            "#{Memory.truncate(r['content'], 150)} (visto #{r['evidence_count']}x)"
        end.join("\n")
    end
  end

  def esquecer(topic, subtopic)
    if topic.to_s.strip.empty?
      return 'Erro: topic é obrigatório pra esquecer.'
    end

    r = Memory.learning_delete(topic: topic, subtopic: subtopic)
    if r[:deleted].to_i > 0
      "Apaguei #{r[:deleted]} aprendizado(s) de \"#{topic}\"#{subtopic ? " > #{subtopic}" : ''}."
    else
      "Nada encontrado pra \"#{topic}\"#{subtopic ? " > #{subtopic}" : ''}."
    end
  end
end
