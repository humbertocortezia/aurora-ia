# frozen_string_literal: true

require 'time'
require 'json'
require 'yaml'
require_relative 'db'

# Camada de alto nível sobre o DB. CRUD de sessões, mensagens, fatos
# e aprendizados. Tudo thread-safe via DB.write / DB.read.
module Memory
  module_function

  # --- SESSIONS ----------------------------------------------------------------

  def open_session(model: nil)
    now = Time.now.iso8601
    id = DB.write do |conn|
      conn.execute(
        'INSERT INTO sessions (started_at, model) VALUES (?, ?)',
        [now, model]
      )
      conn.last_insert_row_id
    end
    { id: id, started_at: now, message_count: 0 }
  end

  def close_session(id)
    DB.write do |conn|
      conn.execute('UPDATE sessions SET ended_at = ? WHERE id = ?',
                  [Time.now.iso8601, id])
    end
  end

  def get_session(id)
    DB.read do |conn|
      rows = conn.execute('SELECT * FROM sessions WHERE id = ?', [id])
      rows.first&.transform_keys(&:to_s)
    end
  end

  def list_sessions(limit: 20)
    DB.read do |conn|
      conn.execute(<<~SQL, [limit]).map { |r| r.transform_keys(&:to_s) }
        SELECT id, title, started_at, ended_at, message_count
        FROM sessions
        ORDER BY started_at DESC
        LIMIT ?
      SQL
    end
  end

  def set_session_title(id, title)
    DB.write do |conn|
      conn.execute('UPDATE sessions SET title = ? WHERE id = ?', [title, id])
    end
  end

  def set_session_summary(id, summary)
    DB.write do |conn|
      conn.execute('UPDATE sessions SET summary = ? WHERE id = ?', [summary, id])
    end
  end

  # --- MESSAGES ---------------------------------------------------------------

  def add_message(session_id:, role:, content:,
                  tool_name: nil, tool_call_id: nil, tool_arguments: nil,
                  tool_result: nil, thinking: nil,
                  tokens_in: nil, tokens_out: nil)
    now = Time.now.iso8601
    args_json = tool_arguments.is_a?(String) ? tool_arguments : tool_arguments&.to_json

    insert_sql = <<~SQL
      INSERT INTO messages (session_id, role, content, tool_name, tool_call_id,
                            tool_arguments, tool_result, thinking, tokens_in,
                            tokens_out, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    SQL
    insert_args = [session_id, role, content, tool_name, tool_call_id,
                   args_json, tool_result, thinking, tokens_in, tokens_out, now]

    id = nil
    DB.write do |conn|
      conn.execute(insert_sql, insert_args)
      id = conn.last_insert_row_id
      conn.execute('UPDATE sessions SET message_count = message_count + 1 WHERE id = ?',
                  [session_id])
    end
    id
  end

  def list_messages(session_id:, limit: nil, offset: 0, order: :asc)
    dir = order.to_s.downcase == 'desc' ? 'DESC' : 'ASC'
    lim = limit ? "LIMIT #{limit.to_i}" : ''
    DB.read do |conn|
      conn.execute(
        "SELECT * FROM messages WHERE session_id = ? ORDER BY id #{dir} #{lim}",
        [session_id]
      ).map { |r| r.transform_keys(&:to_s) }
    end
  end

  def get_message(id)
    DB.read do |conn|
      row = conn.execute('SELECT * FROM messages WHERE id = ?', [id]).first
      row&.transform_keys(&:to_s)
    end
  end

  def delete_messages_in_range(session_id:, from_id:, to_id:)
    DB.write do |conn|
      conn.execute(
        'DELETE FROM messages WHERE session_id = ? AND id BETWEEN ? AND ?',
        [session_id, from_id, to_id]
      )
    end
  end

  # --- FACTS (perfil) ---------------------------------------------------------

  def facts_all
    DB.read do |conn|
      conn.execute('SELECT key, value, category FROM facts ORDER BY key')
        .map { |r| [r['key'], r['value']] }.to_h
    end
  end

  def fact_set(key:, value:, category: 'user', source_session: nil, source_message: nil,
               logger: nil)
    key = key.to_s
    val = value.to_s
    now = Time.now.iso8601
    existed = DB.read do |conn|
      r = conn.execute('SELECT 1 FROM facts WHERE key = ?', [key]).first
      !r.nil?
    end

    DB.write do |conn|
      if existed
        conn.execute(<<~SQL, [val, category, source_session, source_message, now, key])
          UPDATE facts SET value = ?, category = ?, source_session = ?,
                          source_message = ?, updated_at = ?
          WHERE key = ?
        SQL
      else
        conn.execute(<<~SQL, [key, val, category, source_session, source_message, now, now])
          INSERT INTO facts (key, value, category, source_session, source_message,
                             created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?)
        SQL
      end
    end

    logger&.info("facts.set key=#{key} existed=#{existed}")
    { key: key, value: val, existed: existed }
  end

  def fact_delete(key:, logger: nil)
    key = key.to_s
    existed = DB.read do |conn|
      r = conn.execute('SELECT 1 FROM facts WHERE key = ?', [key]).first
      !r.nil?
    end
    DB.write { |c| c.execute('DELETE FROM facts WHERE key = ?', [key]) } if existed
    logger&.info("facts.delete key=#{key} existed=#{existed}")
    { key: key, existed: existed }
  end

  def facts_to_prompt_block(facts = nil)
    facts ||= facts_all
    return '' if facts.nil? || facts.empty?

    lines = facts.map { |k, v| "- #{k}: #{v}" }
    "\n\nO que você já sabe sobre o usuário (use essas informações livremente, " \
      "não pergunte de novo o que já está aqui):\n#{lines.join("\n")}"
  end

  # --- LEARNINGS --------------------------------------------------------------

  def learning_save(topic:, subtopic: nil, content:, proficiency: 1,
                    session_id: nil, logger: nil)
    topic = topic.to_s.strip
    subtopic = subtopic.to_s.strip
    subtopic = nil if subtopic.empty?
    raise ArgumentError, 'topic é obrigatório' if topic.empty?

    proficiency = [[proficiency.to_i, 1].max, 5].min
    now = Time.now.iso8601

    existed = DB.read do |conn|
      r = conn.execute(
        'SELECT id, content, proficiency, evidence_count FROM learnings WHERE topic = ? AND (subtopic = ? OR (subtopic IS NULL AND ? IS NULL))',
        [topic, subtopic, subtopic]
      ).first
      r.nil? ? nil : r
    end

    if existed
      id = existed['id']
      new_prof = ((existed['proficiency'].to_i + proficiency) / 2.0).round
      new_evidence = existed['evidence_count'].to_i + 1
      DB.write do |conn|
        conn.execute(<<~SQL, [content, new_prof, new_evidence, session_id, now, id])
          UPDATE learnings SET content = ?, proficiency = ?, evidence_count = ?,
                               last_session = ?, updated_at = ?
          WHERE id = ?
        SQL
      end
      verb = 'Atualizei'
    else
      id = DB.write do |conn|
        conn.execute(<<~SQL, [topic, subtopic, content, proficiency, 1, session_id, now, now])
          INSERT INTO learnings (topic, subtopic, content, proficiency,
                                 evidence_count, last_session, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        conn.last_insert_row_id
      end
      verb = 'Salvei'
    end

    logger&.info("learnings.save topic=#{topic} subtopic=#{subtopic.inspect} id=#{id}")
    { id: id, topic: topic, subtopic: subtopic, verb: verb }
  end

  def learning_search(topic: nil, subtopic: nil, limit: 20)
    conditions = []
    params = []
    if topic && !topic.to_s.empty?
      conditions << 'topic LIKE ?'
      params << "%#{topic}%"
    end
    if subtopic && !subtopic.to_s.empty?
      conditions << 'subtopic LIKE ?'
      params << "%#{subtopic}%"
    end
    where = conditions.empty? ? '' : "WHERE #{conditions.join(' AND ')}"

    DB.read do |conn|
      conn.execute(<<~SQL, params + [limit]).map { |r| r.transform_keys(&:to_s) }
        SELECT topic, subtopic, content, proficiency, evidence_count, updated_at
        FROM learnings
        #{where}
        ORDER BY updated_at DESC
        LIMIT ?
      SQL
    end
  end

  def learning_delete(topic:, subtopic: nil)
    topic = topic.to_s
    subtopic = subtopic.to_s
    subquery, params =
      if subtopic.empty?
        ['topic = ?', [topic]]
      else
        ['topic = ? AND subtopic = ?', [topic, subtopic]]
      end

    rows = DB.write { |c| c.execute("DELETE FROM learnings WHERE #{subquery}", params) }
    { topic: topic, subtopic: subtopic, deleted: rows }
  end

  def list_topics
    DB.read do |conn|
      conn.execute(<<~SQL).map { |r| r.transform_keys(&:to_s) }
        SELECT topic, COUNT(*) as count, MAX(updated_at) as last_update,
               ROUND(AVG(proficiency), 1) as avg_proficiency
        FROM learnings
        GROUP BY topic
        ORDER BY last_update DESC
      SQL
    end
  end

  def learnings_to_prompt_block(limit: 30)
    rows = learning_search(limit: limit)
    return '' if rows.empty?

    lines = rows.map do |r|
      sub = r['subtopic'].to_s.empty? ? '' : " > #{r['subtopic']}"
      prof = r['proficiency']
      ev = r['evidence_count']
      "- #{r['topic']}#{sub}: #{truncate(r['content'].to_s, 120)} " \
        "(proficiência #{prof}/5, visto #{ev}x)"
    end

    "\n\nAprendizados do usuário (use pra adaptar explicações — não repita o que " \
      "ele já sabe):\n#{lines.join("\n")}"
  end

  # --- FULL-TEXT SEARCH -------------------------------------------------------

  def search_messages(query, limit: 10)
    return [] if query.to_s.strip.empty?

    DB.read do |conn|
      # usa snippet pra dar contexto
      conn.execute(<<~SQL, [query.to_s, limit]).map { |r| r.transform_keys(&:to_s) }
        SELECT m.id, m.session_id, m.role, m.content, m.tool_name, m.created_at,
               snippet(messages_fts, 0, '⟨', '⟩', '…', 24) AS excerpt
        FROM messages_fts
        JOIN messages m ON m.id = messages_fts.rowid
        WHERE messages_fts MATCH ?
        ORDER BY rank
        LIMIT ?
      SQL
    end
  end

  # --- MIGRATION DO profile.yml LEGADO ----------------------------------------

  def import_legacy_profile(yaml_path:, logger: nil)
    return 0 unless File.exist?(yaml_path)

    data = YAML.safe_load_file(yaml_path, permitted_classes: [Time, Symbol]) || {}
    facts = data['facts'] || {}
    return 0 if facts.empty?

    count = 0
    facts.each do |k, v|
      fact_set(key: k.to_s, value: v.to_s, category: 'user', logger: logger)
      count += 1
    end
    logger&.info("memory.import_legacy from=#{yaml_path} count=#{count}")
    count
  end

  # --- HELPERS ----------------------------------------------------------------

  def truncate(s, n)
    s.length > n ? "#{s[0, n - 1]}…" : s
  end
end
