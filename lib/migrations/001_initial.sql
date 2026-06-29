-- 001_initial.sql — schema base da Aurora
-- Idempotente: pode rodar várias vezes sem erro.
-- PRAGMAs são setados fora da transação em lib/db.rb (WAL e foreign_keys).

CREATE TABLE IF NOT EXISTS schema_info (
  version INTEGER PRIMARY KEY,
  applied_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT,
  summary TEXT,                        -- resumo compactado das msgs antigas
  started_at TEXT NOT NULL,
  ended_at TEXT,
  message_count INTEGER DEFAULT 0,
  model TEXT
);
CREATE INDEX IF NOT EXISTS idx_sessions_started ON sessions(started_at DESC);

CREATE TABLE IF NOT EXISTS messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  role TEXT NOT NULL,                  -- user | assistant | tool | system
  content TEXT NOT NULL,
  tool_name TEXT,
  tool_call_id TEXT,
  tool_arguments TEXT,                 -- JSON
  tool_result TEXT,
  thinking TEXT,
  tokens_in INTEGER,
  tokens_out INTEGER,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id);
CREATE INDEX IF NOT EXISTS idx_messages_role ON messages(role);
CREATE INDEX IF NOT EXISTS idx_messages_created ON messages(created_at);

-- Fatos lembrados sobre o usuário (substitui o profile.yml legado)
CREATE TABLE IF NOT EXISTS facts (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  category TEXT,                       -- user | project | preference | context
  source_session INTEGER REFERENCES sessions(id),
  source_message INTEGER REFERENCES messages(id),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_facts_category ON facts(category);

-- Aprendizados cumulativos (ex: "typescript > generics = ... proficiency 2/5")
CREATE TABLE IF NOT EXISTS learnings (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  topic TEXT NOT NULL,
  subtopic TEXT,
  content TEXT NOT NULL,
  proficiency INTEGER DEFAULT 1 CHECK(proficiency BETWEEN 1 AND 5),
  evidence_count INTEGER DEFAULT 1,
  last_session INTEGER REFERENCES sessions(id),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(topic, subtopic)
);
CREATE INDEX IF NOT EXISTS idx_learnings_topic ON learnings(topic);

-- Busca full-text sobre mensagens
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
  content, thinking,
  content='messages', content_rowid='id',
  tokenize="unicode61 remove_diacritics 1"
);

-- Triggers pra manter FTS em sync com a tabela messages
CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
  INSERT INTO messages_fts(rowid, content, thinking)
  VALUES (new.id, new.content, COALESCE(new.thinking, ''));
END;

CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
  INSERT INTO messages_fts(messages_fts, rowid, content, thinking)
  VALUES ('delete', old.id, old.content, COALESCE(old.thinking, ''));
END;

CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages BEGIN
  INSERT INTO messages_fts(messages_fts, rowid, content, thinking)
  VALUES ('delete', old.id, old.content, COALESCE(old.thinking, ''));
  INSERT INTO messages_fts(rowid, content, thinking)
  VALUES (new.id, new.content, COALESCE(new.thinking, ''));
END;
