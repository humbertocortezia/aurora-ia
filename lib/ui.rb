# frozen_string_literal: true

require 'io/console'

module UI
  module C
    RESET   = "\e[0m"
    BOLD    = "\e[1m"
    DIM     = "\e[2m"
    ITALIC  = "\e[3m"
    UNDER   = "\e[4m"
    REVERSE = "\e[7m"

    CYAN    = "\e[36m"
    YELLOW  = "\e[33m"
    BLUE    = "\e[34m"
    MAGENTA = "\e[35m"
    GREEN   = "\e[32m"
    RED     = "\e[31m"
    WHITE   = "\e[37m"
    GRAY    = "\e[90m"

    # tons suaves (256 cores) — caem de forma graciosa em terminais modernos
    ACCENT  = "\e[38;5;177m"  # lilás (identidade do agente)
    SOFT    = "\e[38;5;110m"  # azul acinzentado
    MUTED   = "\e[38;5;245m"  # cinza médio p/ texto secundário

    # chip de código inline
    CODE_BG = "\e[48;5;236m"
    CODE_FG = "\e[38;5;186m"

    BG_BLUE    = "\e[44m"
    BG_MAGENTA = "\e[45m"

    CLEAR_LINE  = "\e[2K"
    CURSOR_SHOW = "\e[?25h"
    CURSOR_HIDE = "\e[?25l"
  end

  GUTTER = '  '

  module_function

  # Largura do terminal (com fallbacks seguros).
  def term_width
    w = IO.console&.winsize&.last
    w = ENV['COLUMNS'].to_i if w.nil? || w.zero?
    w.zero? ? 80 : w
  rescue StandardError
    80
  end

  def truncate(s, n)
    s = s.to_s
    s.length > n ? "#{s[0, [n - 1, 0].max]}…" : s
  end

  def dim(message)
    "#{C::DIM}#{message}#{C::RESET}"
  end

  # ---------------------------------------------------------------------------
  # Spinner lateral ("pensando…") — escreve na mesma linha, sem poluir.
  # ---------------------------------------------------------------------------
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
        print C::CURSOR_HIDE
        while @running
          frame = FRAMES[i % FRAMES.length]
          line = "#{UI::GUTTER}#{C::ACCENT}#{frame}#{C::RESET} #{C::DIM}#{C::ITALIC}#{@message}#{C::RESET}"
          line = UI.truncate(line, UI.term_width + 64) # +64 compensa códigos ANSI
          print "\r#{C::CLEAR_LINE}#{line}"
          $stdout.flush
          i += 1
          sleep 0.08
        end
        print C::CURSOR_SHOW
      end
    end

    def stop(clear: true, final: nil)
      return unless @running

      @running = false
      @thread&.join(1)
      @thread = nil

      if final
        print "\r#{C::CLEAR_LINE}#{UI::GUTTER}#{C::GREEN}✓#{C::RESET} #{final}#{C::RESET}\n"
      elsif clear
        print "\r#{C::CLEAR_LINE}"
      end
      $stdout.flush
    end

    def update(message)
      @message = message.to_s.gsub(/\s+/, ' ').strip
    end

    def running?
      @running
    end
  end

  # ---------------------------------------------------------------------------
  # Renderizador de Markdown em streaming.
  #
  # Recebe pedaços de texto via #push e renderiza LINHA A LINHA assim que cada
  # linha fica completa (chega um "\n"). Resolve o problema do markdown cru no
  # terminal: headers, negrito, itálico, código, listas, citações, regras.
  # ---------------------------------------------------------------------------
  class Markdown
    def initialize(out: $stdout, indent: UI::GUTTER)
      @out     = out
      @indent  = indent
      @buf     = +''
      @in_code = false
      @wrote   = false
    end

    def push(text)
      return if text.nil? || text.empty?

      @buf << text
      while (idx = @buf.index("\n"))
        line = @buf.slice!(0..idx).chomp
        render_line(line)
      end
    end

    # Esvazia o que sobrou (última linha sem "\n") e fecha código aberto.
    def finish
      render_line(@buf) unless @buf.empty?
      @buf = +''
      if @in_code
        @out.puts "#{@indent}#{C::GRAY}└#{'─' * 10}#{C::RESET}"
        @in_code = false
      end
    end

    def wrote?
      @wrote
    end

    private

    def render_line(raw)
      @wrote = true

      # cerca de bloco de código ```
      if raw.strip.start_with?('```')
        if @in_code
          @in_code = false
          @out.puts "#{@indent}#{C::GRAY}└#{'─' * 10}#{C::RESET}"
        else
          @in_code = true
          lang = raw.strip.tr('`', '').strip
          label = lang.empty? ? 'code' : lang
          @out.puts "#{@indent}#{C::GRAY}┌─ #{C::DIM}#{label}#{C::RESET}"
        end
        return
      end

      if @in_code
        @out.puts "#{@indent}#{C::GRAY}│#{C::RESET} #{C::SOFT}#{raw}#{C::RESET}"
        return
      end

      stripped = raw.strip

      if stripped.empty?
        @out.puts
        return
      end

      # regra horizontal: ---, ***, ___
      if stripped.match?(/\A([-*_])\1{2,}\z/) || stripped.match?(/\A(-\s){3,}-?\z/)
        rule = '─' * [UI.term_width - @indent.length - 2, 12].min
        @out.puts "#{@indent}#{C::GRAY}#{rule}#{C::RESET}"
        return
      end

      # cabeçalhos # ## ###
      if (m = raw.match(/\A(\#{1,6})\s+(.*)\z/))
        text = strip_markers(m[2])
        color = case m[1].length
                when 1 then "#{C::BOLD}#{C::ACCENT}"
                when 2 then "#{C::BOLD}#{C::CYAN}"
                else        "#{C::BOLD}#{C::WHITE}"
                end
        @out.puts unless m[1].length >= 3 # respiro antes de h1/h2
        @out.puts "#{@indent}#{color}#{text}#{C::RESET}"
        return
      end

      # citação >
      if (m = raw.match(/\A>\s?(.*)\z/))
        @out.puts "#{@indent}#{C::GRAY}▏#{C::RESET} #{C::DIM}#{C::ITALIC}#{inline(m[1])}#{C::RESET}"
        return
      end

      # lista ordenada
      if (m = raw.match(/\A(\s*)(\d+)\.\s+(.*)\z/))
        @out.puts "#{@indent}#{m[1]}#{C::CYAN}#{m[2]}.#{C::RESET} #{inline(m[3])}"
        return
      end

      # lista não ordenada
      if (m = raw.match(/\A(\s*)[-*+]\s+(.*)\z/))
        @out.puts "#{@indent}#{m[1]}#{C::ACCENT}•#{C::RESET} #{inline(m[2])}"
        return
      end

      @out.puts "#{@indent}#{inline(raw)}"
    end

    # Estilo inline: `código`, **negrito**, *itálico*, [texto](url).
    def inline(s)
      out = s.dup
      out = out.gsub(/`([^`]+)`/) { "#{C::CODE_BG}#{C::CODE_FG} #{Regexp.last_match(1)} #{C::RESET}" }
      out = out.gsub(/\*\*(.+?)\*\*/) { "#{C::BOLD}#{Regexp.last_match(1)}#{C::RESET}" }
      out = out.gsub(/__(.+?)__/) { "#{C::BOLD}#{Regexp.last_match(1)}#{C::RESET}" }
      out = out.gsub(/\[([^\]]+)\]\(([^)]+)\)/) do
        "#{C::UNDER}#{C::CYAN}#{Regexp.last_match(1)}#{C::RESET} #{C::DIM}#{Regexp.last_match(2)}#{C::RESET}"
      end
      out = out.gsub(/(?<![\*\w])\*(?!\s)([^*\n]+?)(?<!\s)\*(?![\*\w])/) do
        "#{C::ITALIC}#{Regexp.last_match(1)}#{C::RESET}"
      end
      out
    end

    def strip_markers(s)
      s.gsub(/\*\*(.+?)\*\*/, '\1')
       .gsub(/__(.+?)__/, '\1')
       .gsub(/`([^`]+)`/, '\1')
       .gsub(/\*(.+?)\*/, '\1')
    end
  end

  # ---------------------------------------------------------------------------
  # Blocos de alto nível
  # ---------------------------------------------------------------------------
  def banner(name)
    width = 45
    label = "✦ #{name}  — agente com ferramentas"
    pad   = [width - label.length - 2, 0].max
    line  = '─' * width
    puts
    puts "  #{C::ACCENT}╭#{line}╮#{C::RESET}"
    puts "  #{C::ACCENT}│#{C::RESET}  #{C::BOLD}#{C::WHITE}✦ #{name}#{C::RESET}  #{C::MUTED}— agente com ferramentas#{C::RESET}#{' ' * pad}#{C::ACCENT}│#{C::RESET}"
    puts "  #{C::ACCENT}╰#{line}╯#{C::RESET}"
    puts
  end

  # linha de boot alinhada: rótulo à esquerda, valor em destaque
  def boot_line(pairs)
    parts = pairs.map { |k, v| "#{C::MUTED}#{k}#{C::RESET} #{C::DIM}#{v}#{C::RESET}" }
    puts "  #{parts.join("  #{C::GRAY}·#{C::RESET}  ")}"
  end

  def divider
    puts "  #{C::GRAY}#{'─' * [term_width - 4, 40].min}#{C::RESET}"
  end

  def user(message)
    puts "  #{C::BOLD}#{C::BLUE}Você#{C::RESET}  #{C::DIM}›#{C::RESET} #{message}"
  end

  def assistant_start(label)
    puts
    puts "  #{C::ACCENT}✦#{C::RESET} #{C::BOLD}#{label}#{C::RESET}"
  end

  def assistant_end
    puts
  end

  def info(message)
    puts "  #{C::CYAN}ℹ#{C::RESET}  #{C::DIM}#{message}#{C::RESET}"
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
    puts "  #{C::ACCENT}✎#{C::RESET}  #{C::DIM}lembrei#{C::RESET} #{C::BOLD}#{key}#{C::RESET} #{C::DIM}=#{C::RESET} #{value}"
  end

  def forgotten(key)
    puts "  #{C::ACCENT}⌫#{C::RESET}  #{C::DIM}esqueci#{C::RESET} #{C::BOLD}#{key}#{C::RESET}"
  end

  def profile_list(facts)
    if facts.empty?
      puts "  #{C::DIM}(perfil vazio — nada lembrado ainda)#{C::RESET}"
    else
      facts.each do |key, value|
        puts "  #{C::ACCENT}•#{C::RESET}  #{C::BOLD}#{key}#{C::RESET} #{C::DIM}=#{C::RESET} #{value}"
      end
    end
  end

  def tool_call(name, args)
    args_str = if args.is_a?(Hash)
                 args.map { |k, v| "#{C::MUTED}#{k}#{C::RESET}#{C::DIM}=#{C::RESET}#{truncate(v.to_s, 40)}" }.join("#{C::DIM}, #{C::RESET}")
               else
                 args.to_s
               end
    puts
    puts "  #{C::ACCENT}⏵#{C::RESET} #{C::BOLD}#{name}#{C::RESET}#{C::DIM}(#{C::RESET}#{args_str}#{C::DIM})#{C::RESET}"
  end

  def tool_result(name, preview)
    preview = truncate(preview.to_s.gsub(/\s+/, ' '), 90)
    puts "  #{C::GREEN}↳#{C::RESET} #{C::DIM}#{name} → #{preview}#{C::RESET}"
  end

  # Palette de comandos (mostrada ao digitar "/" sozinho ou /ajuda).
  # specs = [{ names:, arg:, desc:, group: }, ...]
  def command_palette(specs, title: 'Comandos')
    puts
    puts "  #{C::BOLD}#{C::ACCENT}/#{C::RESET} #{C::BOLD}#{title}#{C::RESET} #{C::DIM}— digite para filtrar, TAB completa#{C::RESET}"
    puts

    grouped = specs.group_by { |s| s[:group] }
    name_w = specs.map { |s| usage(s).length }.max

    grouped.each do |group, items|
      puts "  #{C::MUTED}#{group}#{C::RESET}"
      items.each do |s|
        usage = usage(s).ljust(name_w)
        puts "    #{C::CYAN}#{usage}#{C::RESET}  #{C::DIM}#{s[:desc]}#{C::RESET}"
      end
      puts
    end
  end

  def usage(spec)
    spec[:arg] ? "#{spec[:names].first} #{spec[:arg]}" : spec[:names].first
  end

  def help(specs)
    command_palette(specs, title: 'Ajuda')
  end
end

at_exit { print UI::C::CURSOR_SHOW; $stdout.flush }
