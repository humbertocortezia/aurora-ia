# frozen_string_literal: true

require 'ruby_llm'
require_relative 'memory'

# Auto-compactação de contexto: quando a sessão cresce muito, resume
# as mensagens antigas em 1 mensagem de sumário pra caber no contexto
# do modelo. Também gera título da sessão via LLM no /sair.
module Compaction
  module_function

  # Retorna número de mensagens removidas (0 se nada foi feito)
  def maybe_compact(session_id:, cfg:, logger: nil)
    all = Memory.list_messages(session_id: session_id, order: :asc)
    return 0 if all.size < cfg.compaction_threshold

    head_keep = cfg.compaction_keep_head
    tail_keep = cfg.compaction_keep_tail
    return 0 if all.size <= head_keep + tail_keep + 1

    middle = all[head_keep...(all.size - tail_keep)]
    return 0 if middle.empty?

    summary_text = summarize(middle, cfg, logger: logger)
    return 0 if summary_text.nil? || summary_text.empty?

    first_id = middle.first['id'].to_i
    last_id  = middle.last['id'].to_i

    # remove o range do meio
    Memory.delete_messages_in_range(session_id: session_id,
                                    from_id: first_id, to_id: last_id)

    # insere a mensagem de sumário
    Memory.add_message(
      session_id: session_id, role: 'system',
      content: "[Resumo automático de #{middle.size} mensagens anteriores]\n\n#{summary_text}"
    )

    # atualiza summary da sessão também
    Memory.set_session_summary(session_id, summary_text)

    logger&.info("compaction.done session=#{session_id} removed=#{middle.size} " \
                 "first_id=#{first_id} last_id=#{last_id}")
    middle.size
  end

  # Pede pro LLM resumir mensagens em PT-BR, mantendo decisões e contexto importante
  def summarize(messages, cfg, logger: nil)
    lines = messages.first(40).map do |m|
      role = m['role']
      content = m['content'].to_s.gsub(/\s+/, ' ').strip
      "[#{role}] #{truncate(content, 200)}"
    end
    lines << "…(mais #{messages.size - 40} mensagens omitidas)" if messages.size > 40

    prompt = <<~PROMPT
      Resuma a conversa abaixo em PT-BR, em 2-3 parágrafos curtos.
      Foque em:
      - decisões e conclusões
      - definições e conceitos importantes
      - preferências e gostos do usuário
      - ações executadas (e resultados)
      - tópicos que estão sendo estudados
      - números, nomes e dados concretos mencionados

      Seja denso e direto. Use bullets quando ajudar.

      CONVERSA:
      #{lines.join("\n")}
    PROMPT

    chat = RubyLLM.chat(
      model: cfg.llm_model,
      provider: :openai,
      assume_model_exists: true
    )
    chat.with_temperature(0.2)

    response = chat.ask(prompt)
    response&.content.to_s.strip
  rescue StandardError => e
    logger&.error("compaction.summarize failed: #{e.class}: #{e.message}")
    nil
  end

  # Gera um título curto (até 6 palavras) pra sessão
  def generate_title(cfg, first_messages, logger: nil)
    return nil if first_messages.nil? || first_messages.empty?

    lines = first_messages.first(4).map do |m|
      role = m['role']
      content = m['content'].to_s.gsub(/\s+/, ' ').strip
      "[#{role}] #{truncate(content, 200)}"
    end

    prompt = <<~PROMPT
      Gere um título curto (máximo 6 palavras) em PT-BR pra essa conversa.
      Responda APENAS com o título, sem aspas, sem pontuação final.

      CONVERSA INICIAL:
      #{lines.join("\n")}
    PROMPT

    chat = RubyLLM.chat(
      model: cfg.llm_model,
      provider: :openai,
      assume_model_exists: true
    )
    chat.with_temperature(0.2)

    response = chat.ask(prompt)
    title = response&.content.to_s.strip.split("\n").first.to_s.strip
    title = nil if title.empty? || title.length > 80
    title
  rescue StandardError => e
    logger&.warn("compaction.generate_title failed: #{e.class}: #{e.message}")
    nil
  end

  def truncate(s, n)
    s.length > n ? "#{s[0, n - 1]}…" : s
  end
end
