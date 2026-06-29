# frozen_string_literal: true

require_relative '../lib/memory'

# Despacha comandos "/alguma-coisa" digitados pelo usuário.
# Cada handler retorna { action:, payload: } ou :not_handled (não era slash).
module Slash
  module_function

  COMMANDS = %w[/sair /exit /quit /limpar /clear /cls /modelo /model
                /perfil /profile /esquecer /forget /ferramentas /tools
                /ajuda /help /sessoes /sessions /carregar /load
                /apagar-sessao /delete-session].freeze

  def command?(input)
    input.is_a?(String) && input.start_with?('/')
  end

  # ctx = { config:, chat:, current_session_id:, profile:, profile_delete:,
  #         tools_list:, logger: }
  def dispatch(input, ctx)
    return :not_handled unless command?(input)

    parts = input.strip.split(/\s+/)
    cmd   = parts[0].downcase
    args  = parts[1..] || []

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
      UI.help
      { action: :continue }
    else
      UI.warn("Comando desconhecido: #{cmd}. Digite /ajuda.")
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
