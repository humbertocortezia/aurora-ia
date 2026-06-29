# frozen_string_literal: true

module UI
  module C
    RESET   = "\e[0m"
    BOLD    = "\e[1m"
    DIM     = "\e[2m"
    ITALIC  = "\e[3m"
    UNDER   = "\e[4m"
    CYAN    = "\e[36m"
    YELLOW  = "\e[33m"
    BLUE    = "\e[34m"
    MAGENTA = "\e[35m"
    GREEN   = "\e[32m"
    RED     = "\e[31m"
    WHITE   = "\e[37m"
    GRAY    = "\e[90m"

    BG_BLUE   = "\e[44m"
    BG_MAGENTA = "\e[45m"

    CLEAR_LINE = "\e[2K"
    CURSOR_SHOW = "\e[?25h"
    CURSOR_HIDE = "\e[?25l"
  end

  # Spinner animado que escreve na MESMA linha (\r) — não polui o terminal.
  # Roda em uma thread separada. Use start/stop pareados.
  class Spinner
    FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

    attr_accessor :message

    def initialize(message = '...')
      @message = message
      @running = false
      @thread  = nil
    end

    def start
      return if @running

      @running = true
      @thread = Thread.new do
        i = 0
        # esconde cursor só durante o spinner
        print C::CURSOR_HIDE
        while @running
          frame = FRAMES[i % FRAMES.length]
          print "\r  #{C::CYAN}#{frame}#{C::RESET} #{C::DIM}#{@message}#{C::RESET}"
          $stdout.flush
          i += 1
          sleep 0.08
        end
        print C::CURSOR_SHOW
      end
    end

    # clear: true  → só limpa a linha (caso padrão, sem deixar resíduo)
    # final:       → imprime "✓ mensagem" na linha e quebra
    def stop(clear: true, final: nil)
      return unless @running

      @running = false
      @thread&.join(1)
      @thread = nil

      if final
        print "\r#{C::CLEAR_LINE}  #{C::GREEN}✓#{C::RESET} #{final}#{C::RESET}\n"
      elsif clear
        print "\r#{C::CLEAR_LINE}"
      end
      $stdout.flush
    end

    def update(message)
      @message = message
    end

    def running?
      @running
    end
  end

  module_function

  def banner(name)
    print "\n"
    puts "  #{C::BOLD}#{C::MAGENTA}╭───────────────────────────────────────────╮#{C::RESET}"
    puts "  #{C::BOLD}#{C::MAGENTA}│#{C::RESET}   #{C::BOLD}#{C::WHITE}✦  #{name}#{C::RESET}  #{C::DIM}— agente com ferramentas#{C::RESET}  #{C::MAGENTA}│#{C::RESET}"
    puts "  #{C::BOLD}#{C::MAGENTA}╰───────────────────────────────────────────╯#{C::RESET}"
    print "\n"
  end

  def user(message)
    puts "  #{C::BOLD}#{C::BLUE}Você#{C::RESET}  #{C::DIM}›#{C::RESET} #{message}"
  end

  # label fica no formato "Aurora" (nome do agente)
  def assistant_start(label)
    print "  #{C::BOLD}#{C::MAGENTA}#{label}#{C::RESET}  #{C::DIM}›#{C::RESET} "
    $stdout.flush
  end

  def assistant_end
    print "\n"
  end

  def info(message)
    puts "  #{C::CYAN}ℹ#{C::RESET}  #{C::DIM}#{message}#{C::RESET}"
  end

  def dim(message)
    "#{C::DIM}#{message}#{C::RESET}"
  end

  def warn(message)
    puts "  #{C::YELLOW}⚠#{C::RESET}  #{message}"
  end

  def error(message)
    puts "  #{C::RED}✗#{C::RESET}  #{message}"
  end

  def success(message)
    puts "  #{C::GREEN}✓#{C::RESET}  #{message}"
  end

  def remembered(key, value)
    puts "  #{C::MAGENTA}💾#{C::RESET}  #{C::DIM}Lembrei: #{C::RESET}#{C::BOLD}#{key}#{C::RESET}#{C::DIM} = #{C::RESET}#{value}"
  end

  def forgotten(key)
    puts "  #{C::MAGENTA}🗑#{C::RESET}  #{C::DIM}Esqueci: #{C::RESET}#{C::BOLD}#{key}#{C::RESET}"
  end

  def profile_list(facts)
    if facts.empty?
      puts "  #{C::DIM}(perfil vazio — nada lembrado ainda)#{C::RESET}"
    else
      facts.each do |key, value|
        puts "  #{C::MAGENTA}•#{C::RESET}  #{C::BOLD}#{key}#{C::RESET}#{C::DIM} = #{C::RESET}#{value}"
      end
    end
  end

  def tool_call(name, args)
    args_str = args.is_a?(Hash) ? args.map { |k, v| "#{k}=#{truncate(v.to_s, 40)}" }.join(', ') : args.to_s
    puts "  #{C::CYAN}⏵#{C::RESET}  #{C::BOLD}#{name}#{C::RESET}#{C::DIM}(#{args_str})#{C::RESET}"
  end

  def tool_result(name, preview)
    preview = truncate(preview.to_s.gsub("\n", ' '), 90)
    puts "  #{C::GREEN}↳#{C::RESET}  #{C::DIM}#{name} → #{preview}#{C::RESET}"
  end

  def help
    puts "  #{C::BOLD}Comandos disponíveis:#{C::RESET}"
    puts "    #{C::CYAN}/sair#{C::RESET}                  encerra o chat"
    puts "    #{C::CYAN}/limpar#{C::RESET}                começa nova conversa (fecha sessão atual, abre outra)"
    puts "    #{C::CYAN}/sessoes#{C::RESET}               lista últimas sessões salvas"
    puts "    #{C::CYAN}/carregar N#{C::RESET}             continua a sessão #N"
    puts "    #{C::CYAN}/apagar-sessao N#{C::RESET}        remove a sessão #N do banco"
    puts "    #{C::CYAN}/modelo#{C::RESET} [nome]         mostra ou troca o modelo"
    puts "    #{C::CYAN}/perfil#{C::RESET}                mostra fatos lembrados sobre você"
    puts "    #{C::CYAN}/esquecer CHAVE#{C::RESET}        apaga um fato do perfil"
    puts "    #{C::CYAN}/ferramentas#{C::RESET}           lista tools disponíveis"
    puts "    #{C::CYAN}/ajuda#{C::RESET}                 esta mensagem"
    puts ""
  end

  def truncate(s, n)
    s.length > n ? "#{s[0, n - 1]}…" : s
  end

  # Garante que o cursor volte visível mesmo em caso de exceção
  def self.at_exit
    print C::CURSOR_SHOW
  end
end

at_exit { UI::C::CURSOR_SHOW and $stdout.flush }
