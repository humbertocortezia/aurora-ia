# frozen_string_literal: true

require 'sqlite3'
require 'fileutils'
require 'time'
require 'logger'

# Camada low-level de banco. Abre conexão única, roda migrations,
# expõe helper `query` e `execute` thread-safe via mutex.
module DB
  class MigrationError < StandardError; end

  MIGRATIONS_DIR = File.expand_path('migrations', __dir__)

  class << self
    def open(path:, logger: nil)
      @path   = path
      @logger = logger
      FileUtils.mkdir_p(File.dirname(path))

      @mutex = Mutex.new
      @db    = SQLite3::Database.new(path)
      @db.busy_timeout = 5_000
      @db.results_as_hash = true

      apply_migrations
      @db
    end

    def db
      raise 'DB.open não foi chamado' unless @db

      @db
    end

    def close
      @db&.close
      @db = nil
    end

    # Thread-safe: serializa escritas pra evitar "database is locked"
    def write
      @mutex.synchronize { yield @db }
    end

    # Leituras são thread-safe em WAL, mas ainda passa pelo mutex pra ser consistente
    def read(&block)
      @mutex.synchronize { yield @db }
    end

    private

    def apply_migrations
      # PRAGMAs têm que ser setados fora de transação
      @db.execute('PRAGMA journal_mode = WAL')
      @db.execute('PRAGMA foreign_keys = ON')
      @db.execute('PRAGMA busy_timeout = 5000')

      write do |conn|
        conn.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS schema_info (
            version INTEGER PRIMARY KEY,
            applied_at TEXT NOT NULL
          );
        SQL

        applied = conn.execute('SELECT version FROM schema_info').map { |r| r['version'] }
        files   = Dir[File.join(MIGRATIONS_DIR, '*.sql')].sort
        files.each do |f|
          version = File.basename(f, '.sql').to_i
          next if applied.include?(version)

          sql = File.read(f)
          @logger&.info("db.migration apply=#{version} file=#{File.basename(f)}")
          conn.transaction do
            conn.execute_batch(sql)
            conn.execute('INSERT INTO schema_info (version, applied_at) VALUES (?, ?)',
                         [version, Time.now.iso8601])
          end
        end
      end
    end
  end
end
