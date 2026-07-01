# frozen_string_literal: true

require_relative '../lib/memory'

# Despacha comandos "/alguma-coisa" digitados pelo usuário.
# Cada handler retorna { action:, payload: } ou :not_handled (não era slash).
module Slash
  module_function

  # Registry único: fonte da verdade para dispatch, palette, autocomplete e ajuda.
  COMMAND_SPECS = [
    { names: %w[/ajuda /help],                  arg: nil,    group: 'Geral',    desc: 'Mostra esta lista de comandos' },
    { names: %w[/ferramentas /tools],           arg: nil,    group: 'Geral',    desc: 'Lista as ferramentas disponíveis' },
    { names: %w[/sair /exit /quit],             arg: nil,    group: 'Geral',    desc: 'Encerra o chat (gera título da sessão)' },

    { names: %w[/limpar /clear /cls],           arg: nil,    group: 'Sessões',  desc: 'Começa uma nova conversa' },
    { names: %w[/sessoes /sessions],            arg: nil,    group: 'Sessões',  desc: 'Lista as últimas sessões salvas' },
    { names: %w[/carregar /load],               arg: '<N>',  group: 'Sessões',  desc: 'Continua a sessão de número N' },
    { names: %w[/apagar-sessao /delete-session],arg: '<N>',  group: 'Sessões',  desc: 'Remove a sessão N do banco' },

    { names: %w[/modelo /model],                arg: '[nome]', group: 'Config', desc: 'Mostra ou troca o modelo em uso' },
    { names: %w[/perfil /profile],              arg: nil,    group: 'Memória',  desc: 'Mostra os fatos lembrados sobre você' },
    { names: %w[/esquecer /forget],             arg: '<chave>', group: 'Memória', desc: 'Apaga um fato do seu perfil' }
  ].freeze

  COMMANDS = COMMAND_SPECS.flat_map { |s| s[:names] }.freeze

  # Nomes "principais" (primeiro alias de cada comando) — usados no autocomplete.
  PRIMARY_NAMES = COMMAND_SPECS.map { |s| s[:names].first }.freeze

  def command?(input)
    input.is_a?(String) && input.start_with?('/')
  end

  # Sugestões para o autocomplete do Readline (TAB).
  def completions(prefix)
    return [] unless prefix.to_s.start_with?('/')

    PRIMARY_NAMES.select { |n| n.start_with?(prefix) }
  end

  # Comando mais parecido com o que foi digitado (para "você quis dizer?").
  def suggest(cmd)
    cmd = cmd.to_s.downcase
    by_prefix = PRIMARY_NAMES.select { |n| n.start_with?(cmd[0, 3]) }
    return by_prefix.first unless by_prefix.empty?

    PRIMARY_NAMES.min_by { |n| levenshtein(n, cmd) }
  end

  def levenshtein(a, b)
    m = Array.new(a.length + 1) { |i| [i] + Array.new(b.length, 0) }
    (0..b.length).each { |j| m[0][j] = j }
    (1..a.length).each do |i|
      (1..b.length).each do |j|
        cost = a[i - 1] == b[j - 1] ? 0 : 1
        m[i][j] = [m[i - 1][j] + 1, m[i][j - 1] + 1, m[i - 1][j - 1] + cost].min
      end
    end
    m[a.length][b.length]
  end

  # ctx = { config:, chat:, current_session_id:, profile:, profile_delete:,
  #         tools_list:, logger: }
  def dispatch(input, ctx)
    return :not_handled unless command?(input)

    parts = input.strip.split(/\s+/)
    cmd   = parts[0].downcase
    args  = parts[1..] || []

    # "/" sozinho (ou "/?") → abre a palette de comandos
    if cmd == '/' || cmd == '/?'
      UI.command_palette(COMMAND_SPECS)
      return { action: :continue }
    end

    case cmd
    when '/sair', '/exit', '/quit'
      { action: :exit }
    when '/limpar', '/clear', '/cls'
      { action: :clear_history }
    when '/modelo', '/model'
      handle_model(args, ctx)
    when '/perfil', '/profile'
      handle_profile(ctx)
    when '/esquecer', '/forget'
      handle_forget(args, ctx)
    when '/ferramentas', '/tools'
      handle_tools(ctx)
      { action: :continue }
    when '/sessoes', '/sessions'
      handle_sessions(ctx)
    when '/carregar', '/load'
      handle_load(args, ctx)
    when '/apagar-sessao', '/delete-session'
      handle_delete_session(args, ctx)
    when '/ajuda', '/help'
      UI.help(COMMAND_SPECS)
      { action: :continue }
    else
      hint = suggest(cmd)
      msg = "Comando desconhecido: #{cmd}."
      msg += " Você quis dizer #{UI::C::CYAN}#{hint}#{UI::C::RESET}?" if hint
      UI.warn("#{msg} Digite #{UI::C::CYAN}/#{UI::C::RESET} para ver todos.")
      { action: :continue }
    end
  end

  # --- handlers ------------------------------------------------------------

  def handle_model(args, ctx)
    cfg = ctx[:config]

    if args.empty?
      UI.info("Modelo atual: #{cfg.llm_model}  #{UI::C::DIM}(api: #{cfg.llm_api_base})#{UI::C::RESET}")
      UI.info('uso: /modelo <nome>')
      return { action: :continue }
    end

    cfg.llm_model = args.join(' ')
    UI.success("Modelo alterado para: #{cfg.llm_model}")
    { action: :change_model, payload: cfg.llm_model }
  end

  def handle_profile(ctx)
    facts = Memory.facts_all
    if facts.empty?
      UI.info('Perfil vazio. Fale sobre você que eu lembro (ex: "meu nome é X").')
    else
      UI.profile_list(facts)
    end
    { action: :continue }
  end

  def handle_forget(args, ctx)
    if args.empty?
      UI.warn('Uso: /esquecer CHAVE  (ex: /esquecer nome)')
      return { action: :continue }
    end

    key = args.join(' ')
    result = Memory.fact_delete(key: key, logger: ctx[:logger])

    if result[:existed]
      UI.forgotten(key)
    else
      UI.warn("Chave \"#{key}\" não estava no perfil.")
    end
    { action: :continue }
  end

  def handle_tools(ctx)
    UI.info('Ferramentas disponíveis:')
    ctx[:tools_list].each do |t|
      desc = (t.respond_to?(:description) ? t.description : t.respond_to?(:desc) ? t.desc : '').to_s
      desc = desc.split("\n").first.to_s.strip
      puts "    #{UI::C::CYAN}•#{UI::C::RESET}  #{UI::C::BOLD}#{t.name}#{UI::C::RESET}  " \
           "#{UI::C::DIM}— #{UI.truncate(desc, 70)}#{UI::C::RESET}"
    end
  end

  def handle_sessions(ctx)
    sessions = Memory.list_sessions(limit: 15)
    current = ctx[:current_session_id]
    if sessions.empty?
      UI.info('Nenhuma sessão salva ainda.')
    else
      UI.info('Últimas sessões:')
      sessions.each do |s|
        marker = (s['id'] == current) ? "#{UI::C::GREEN}▸#{UI::C::RESET}" : ' '
        title  = s['title'].to_s.empty? ? '(sem título)' : s['title']
        when_  = s['started_at'].to_s[0, 16].gsub('T', ' ')
        n      = s['message_count']
        puts "  #{marker} #{UI::C::CYAN}##{s['id']}#{UI::C::RESET}  " \
             "#{UI::C::DIM}#{when_}#{UI::C::RESET}  #{title}  " \
             "#{UI::C::DIM}(#{n} msgs)#{UI::C::RESET}"
      end
    end
    { action: :continue }
  end

  def handle_load(args, ctx)
    if args.empty?
      UI.warn('Uso: /carregar <N>     (use /sessoes pra listar)')
      return { action: :continue }
    end

    target = args[0].to_i
    if target <= 0
      UI.warn("ID inválido: #{args[0]}")
      return { action: :continue }
    end

    sess = Memory.get_session(target)
    unless sess
      UI.warn("Sessão ##{target} não encontrada.")
      return { action: :continue }
    end

    if sess['ended_at']
      Memory.close_session(target) # garante ended_at atualizada
    end

    UI.success("Sessão ##{target} carregada: #{sess['title'] || '(sem título)'} " \
               "(#{sess['message_count']} mensagens)")
    { action: :load_session, payload: target }
  end

  def handle_delete_session(args, ctx)
    if args.empty?
      UI.warn('Uso: /apagar-sessao <N>     (use /sessoes pra listar)')
      return { action: :continue }
    end

    target = args[0].to_i
    if target <= 0
      UI.warn("ID inválido: #{args[0]}")
      return { action: :continue }
    end

    if target == ctx[:current_session_id]
      UI.warn("Não dá pra apagar a sessão atual. Mude de sessão primeiro.")
      return { action: :continue }
    end

    DB.write { |c| c.execute('DELETE FROM sessions WHERE id = ?', [target]) }
    UI.success("Sessão ##{target} apagada.")
    { action: :continue }
  end
end
