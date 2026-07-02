# frozen_string_literal: true

# =============================================================================
#  Aurora — agente de IA com ferramentas, streaming, thinking, memória
# =============================================================================
#  Stack: RubyLLM (Qwen3 local via OpenAI-compat), Dentaku, Nokogiri, SQLite.
#
#  Recursos:
#   • Streaming no terminal com painel "thinking" (spinner lateral)
#   • Tools: previsão do tempo, pesquisa web (SearXNG), localidade, calculadora,
#     hora atual, fatos do usuário, memória de aprendizados
#   • Memória persistente em SQLite (sessões, mensagens, fatos, aprendizados)
#   • Busca full-text (FTS5) sobre todas as mensagens
#   • Auto-compactação de contexto quando a sessão cresce
#   • Comandos slash: /sair, /limpar, /sessoes, /carregar, /apagar-sessao,
#     /modelo, /perfil, /esquecer, /ferramentas, /ajuda
#   • Limite de tool calls por turno (anti-loop)
#   • Log em logs/agent.log
# =============================================================================

require 'readline'
require 'json'
require 'time'

# Exceções lançadas pelo watchdog de turn/timeout
class ThinkingTimeout < StandardError; end
class TurnTimeout < StandardError; end

require 'ruby_llm'

require_relative 'lib/ui'
require_relative 'lib/config'
require_relative 'lib/logger'
require_relative 'lib/db'
require_relative 'lib/memory'
require_relative 'lib/compaction'
require_relative 'lib/slash'

require_relative 'tools/hora'
require_relative 'tools/calculadora'
require_relative 'tools/previsao_tempo'
require_relative 'tools/localidade'
require_relative 'tools/searxng'
require_relative 'tools/user_facts'
require_relative 'tools/memoria'
require_relative 'tools/diagrama'
require_relative 'tools/arquivos'

# -----------------------------------------------------------------------------
# Monkey-patch: permite que callbacks before_tool_call cancelem a execução
# da tool (skip) ou parem o loop de tools do turno (halt).
# -----------------------------------------------------------------------------
module RubyLLM
  class Chat
    ToolHaltSignal = Class.new(StandardError)
    ToolSkipSignal = Class.new(StandardError)

    alias _aurora_orig_execute_tool_with_callbacks execute_tool_with_callbacks

    def execute_tool_with_callbacks(tool_call)
      _aurora_orig_execute_tool_with_callbacks(tool_call)
    rescue ToolHaltSignal => e
      Tool::Halt.new(e.message)
    rescue ToolSkipSignal => e
      { error: e.message }
    end
  end
end

# -----------------------------------------------------------------------------
# 1. Configuração
# -----------------------------------------------------------------------------
cfg = Config.load(base_dir: __dir__)

logger = AgentLogger.build(log_dir: cfg.log_dir)
logger.info("startup model=#{cfg.llm_model} base=#{cfg.llm_api_base} " \
            "searxng=#{cfg.searxng_url} db=#{cfg.db_path} thinking=#{cfg.agent_thinking}")

RubyLLM.configure do |c|
  c.openai_api_key = cfg.llm_api_key
  c.openai_api_base         = cfg.llm_api_base
  c.openai_use_system_role  = cfg.llm_use_system_role
  c.request_timeout         = 180
  c.max_retries             = 2
  c.logger                  = logger
  c.log_level               = :info
end

# -----------------------------------------------------------------------------
# 2. Banco de dados (SQLite) + migração do profile.yml legado
# -----------------------------------------------------------------------------
DB.open(path: cfg.db_path, logger: logger)

legacy_yml = File.join(cfg.data_dir, 'profile.yml')
if File.exist?(legacy_yml) && Memory.facts_all.empty?
  n = Memory.import_legacy_profile(yaml_path: legacy_yml, logger: logger)
  if n > 0
    UI.success("Migrados #{n} fato(s) do profile.yml legado para o banco.")
    File.rename(legacy_yml, "#{legacy_yml}.migrated")
    logger.info("legacy.profile.migrated count=#{n} backup=#{legacy_yml}.migrated")
  end
end

# -----------------------------------------------------------------------------
# 3. System prompt
# -----------------------------------------------------------------------------
def build_system_prompt(agent_name, _cfg, current_session_title: nil)
  facts_block = Memory.facts_to_prompt_block
  learnings_block = Memory.learnings_to_prompt_block(limit: 30)

  session_block =
    if current_session_title && !current_session_title.to_s.empty?
      "\n\nSessão atual: \"#{current_session_title}\""
    else
      "\n\nSessão atual: (sem título ainda — será gerado quando você sair com /sair)"
    end

  <<~PROMPT
    Você é #{agent_name}, uma assistente de IA em português do Brasil: direta, curiosa e útil.
    Hoje é #{Time.now.strftime('%d/%m/%Y')}.

    ## Estilo de resposta
    - Concisa por padrão: respostas curtas e densas valem mais que longas e vagas.
    - Use Markdown (negrito, listas, `código`, blocos ```); o terminal renderiza.
    - Não narre seu processo nem anuncie chamadas de ferramenta — execute e entregue o resultado.
    - Se uma ferramenta falhar, explique em uma frase e ofereça alternativa (sem stacktrace).

    ## Raciocínio interno (thinking)
    - MANTENHA O RACIOCÍNIO CURTO. Decida uma vez e vá para a resposta; não revire
      a mesma decisão várias vezes.
    - Se está em dúvida entre duas ações, escolha a mais simples e prossiga.

    ## Início de conversa e memória contextual
    - Se ainda não souber o nome do usuário, pergunte antes de prosseguir.
    - Se já souber, apenas responda à pergunta atual.
    - Se ele perguntar sobre o que falavam antes, recupere o contexto no histórico
      arquivado e continue a conversa de onde parou.

    ## Quando buscar na web
    Use `pesquisa_web` quando a resposta depende de informação que:
      (a) muda no tempo (preços, versões, notícias, status de serviços); ou
      (b) você NÃO tem certeza o suficiente para afirmar de memória.
    NÃO busque na web para:
      - conceitos gerais que você domina (ex.: "o que é um callback?");
      - cumprimentos ou perguntas sobre o próprio usuário.
    Regra única: em caso de dúvida se sabe, pesquise; em caso de certeza, responda.
    Ao citar a web, inclua a fonte entre colchetes: [https://...].

    ## Ferramentas — regras de uso
    - Não anuncie chamadas; execute e entregue o resultado.
    - Não chame a mesma tool com os mesmos argumentos mais de uma vez no mesmo turno.
    - Se já salvou um fato ou aprendizado nesta conversa, não salve de novo.

    ## Memória persistente (silenciosa, sem pedir confirmação)
    Registre ONLY informação DURÁVEL e AFIRMADA pelo usuário:
      - NÃO salve brainstorming exploratório ("e se eu fizesse…") nem pedidos efêmeros.
      - NÃO salve a mesma informação duas vezes. Se já consta nos blocos abaixo, ignore.

    `user_facts` (acao: "salvar") → fatos SOBRE o usuário: identidade, contexto e
      preferências estáveis (nome, cidade, profissao, empresa, projeto_atual,
      linguagem_favorita). Chave em snake_case; use categoria project/preference/context.

    `memoria` (acao: "salvar") → CONHECIMENTO que o usuário adquiriu (tópicos de
      estudo, skills). Antes de explicar um tema, use `memoria` (acao: "buscar")
      para ver o que ele já domina e ajustar a profundidade — não repita o básico.

    Roteamento (ÚNICA regra): fato pessoal/preferência → `user_facts`;
      conhecimento que ele aprendeu → `memoria`. Sempre.

    ## Data e tempo
    - Quando a resposta depender de data/hora atuais ou de algo que muda no tempo,
      use a ferramenta de hora em vez de assumir.
    #{facts_block}
    #{learnings_block}
    #{session_block}
  PROMPT
end

# -----------------------------------------------------------------------------
# 4. Tools
# -----------------------------------------------------------------------------
def build_tools(cfg, logger, current_session_id)
  [
    HoraTool.new,
    CalculadoraTool.new,
    PrevisaoTempoTool.new,
    LocalidadeTool.new(config: cfg),
    PesquisaWebTool.new(config: cfg),
    UserFactsTool.new(logger: logger, current_session_id: current_session_id),
    MemoriaTool.new(logger: logger),
    DiagramaTool.new,
    LerArquivoTool.new,
    ListarDiretorioTool.new,
    BuscarCodigoTool.new
  ]
end

# -----------------------------------------------------------------------------
# 5. Spinner compartilhado (lateral, "pensando…")
# -----------------------------------------------------------------------------
thinking_spinner = UI::Spinner.new('pensando…')

# -----------------------------------------------------------------------------
# 6. Construção / reset do chat
# -----------------------------------------------------------------------------
def build_chat(cfg, system_prompt, tools, thinking_spinner, logger, memory_recorder)
  chat = RubyLLM.chat(
    model: cfg.llm_model,
    provider: :openai,
    assume_model_exists: true
  )
  chat.with_temperature(cfg.agent_temperature)
  chat.with_instructions(system_prompt)
  chat.with_tools(*tools, replace: true)

  begin
    chat.with_thinking(effort: cfg.agent_thinking.to_sym)
  rescue StandardError => e
    logger.warn("with_thinking falhou: #{e.message} — seguindo sem thinking explícito")
  end

  turn_state = { count: 0, seen: Set.new }
  chat.instance_variable_set(:@_aurora_turn_state, turn_state)

  chat.before_tool_call do |tc|
    # assinatura canônica para dedupe
    sig = "#{tc.name}:#{tc.arguments.to_h.sort_by { |k, _| k.to_s }.inspect}"
    if turn_state[:seen].include?(sig)
      UI.warn("Tool '#{tc.name}' já chamada com os mesmos argumentos neste " \
              'turno — bloqueada.')
      logger.warn("tool.duplicate name=#{tc.name} args=#{tc.arguments.inspect}")
      raise RubyLLM::Chat::ToolSkipSignal,
            "Tool '#{tc.name}' já foi chamada com estes mesmos argumentos neste " \
            'turno. NÃO repita — siga a conversa e responda ao usuário.'
    end
    turn_state[:seen] << sig

    turn_state[:count] += 1
    thinking_spinner.stop(clear: true) if thinking_spinner.running?
    logger.info("tool.call name=#{tc.name} args=#{tc.arguments.inspect} " \
                "turn_n=#{turn_state[:count]}")
    UI.tool_call(tc.name, tc.arguments)
    memory_recorder[:on_tool_call]&.call(tc)

    if turn_state[:count] > cfg.agent_max_tool_calls
      UI.warn("Limite de #{cfg.agent_max_tool_calls} tool calls atingido neste turno.")
      logger.warn("tool.limit_reached n=#{turn_state[:count]} max=#{cfg.agent_max_tool_calls}")
      raise RubyLLM::Chat::ToolHaltSignal,
            "Você atingiu o limite de #{cfg.agent_max_tool_calls} chamadas de " \
            'ferramenta neste turno. Pare de chamar tools e responda ao usuário agora.'
    end
  end

  chat.after_tool_result do |result|
    preview = result.is_a?(String) ? result : result.inspect
    logger.info("tool.result preview=#{preview[0, 200].inspect}")
    UI.tool_result('retorno', preview)
    memory_recorder[:on_tool_result]&.call(preview)
  end

  chat
end

# -----------------------------------------------------------------------------
# 7. Sessão atual
# -----------------------------------------------------------------------------
current_session = Memory.open_session(model: cfg.llm_model)
current_session_id = current_session[:id]
logger.info("session.open id=#{current_session_id}")

# -----------------------------------------------------------------------------
# 8. Tools + chat
# -----------------------------------------------------------------------------
TOOLS = build_tools(cfg, logger, current_session_id)

system_prompt = build_system_prompt(cfg.agent_name, cfg, current_session_title: nil)
chat = build_chat(cfg, system_prompt, TOOLS, thinking_spinner, logger,
                  on_tool_call: nil, on_tool_result: nil)

# -----------------------------------------------------------------------------
# 9. Banner e boot
# -----------------------------------------------------------------------------
UI.banner(cfg.agent_name)
UI.boot_line('modelo' => cfg.llm_model, 'api' => cfg.llm_api_base)
UI.boot_line('searxng' => cfg.searxng_url, 'tools' => TOOLS.size)
UI.boot_line('sessão' => "##{current_session_id}", 'db' => File.basename(cfg.db_path))
puts

facts = Memory.facts_all
UI.info("Perfil: #{facts.size} fato(s) lembrado(s).") unless facts.empty?
topics = Memory.list_topics
unless topics.empty?
  UI.info("Aprendizados: #{topics.size} tópico(s) — " \
          "#{topics.first(3).map { |t| t['topic'] }.join(', ')}#{topics.size > 3 ? '…' : ''}")
end
UI.info("Digite #{UI::C::CYAN}/#{UI::C::RESET}#{UI::C::DIM} para ver os comandos, ou faça uma pergunta.")

# Autocomplete dos comandos slash (TAB completa, dupla-TAB lista)
Readline.completion_append_character = ' '
Readline.completer_word_break_characters = ''
Readline.completion_proc = proc { |s| Slash.completions(s) }

# -----------------------------------------------------------------------------
# 10. Loop principal
# -----------------------------------------------------------------------------
ctx = {
  config: cfg,
  current_session_id: current_session_id,
  tools_list: TOOLS,
  logger: logger
}

logger.info('loop.start')

# Hook chamado sempre que o chat for reconstruído (ex: /limpar, /carregar, /modelo)
def rebuild_chat!(cfg, logger, system_prompt, thinking_spinner, current_session_id, tools_holder)
  chat = build_chat(
    cfg, system_prompt, tools_holder[:tools], thinking_spinner, logger,
    on_tool_call: nil, on_tool_result: nil
  )
  # aplica system prompt novo
  chat.with_instructions(system_prompt)
  # recarrega histórico da sessão injetando msgs anteriores
  inject_session_history_into_chat(chat, current_session_id, cfg)
  chat
end

def inject_session_history_into_chat(chat, session_id, cfg)
  msgs = Memory.list_messages(session_id: session_id, limit: cfg.session_history_on_boot * 2,
                              order: :asc)
  # injeta só user + assistant (pula tool pra não poluir)
  msgs.each do |m|
    next unless %w[user assistant].include?(m['role'])

    content = m['content'].to_s
    next if content.empty?

    if m['role'] == 'user'
      chat.add_message(role: :user, content: content)
    else
      # assistant: precisa incluir tool_calls se houver
      # simplificado: injeta como texto puro (sem tool_calls, o modelo vai lidar)
      chat.add_message(role: :assistant, content: content)
    end
  end
end

loop do
  begin
    input = Readline.readline("#{UI::C::BOLD}#{UI::C::BLUE}Você#{UI::C::RESET}  #{UI::C::DIM}›#{UI::C::RESET} ", true)
  rescue Interrupt
    puts
    UI.info('Até mais!')
    Memory.close_session(current_session_id)
    logger.info("session.close id=#{current_session_id} reason=interrupt")
    logger.info('loop.exit signal=interrupt')
    break
  end

  if input.nil?
    puts
    UI.info('Até mais!')
    Memory.close_session(current_session_id)
    logger.info("session.close id=#{current_session_id} reason=eof")
    logger.info('loop.exit signal=eof')
    break
  end

  input = input.strip
  next if input.empty?

  logger.info("user.input text=#{input.inspect}")

  # slash commands
  if Slash.command?(input)
    result = Slash.dispatch(input, ctx)
    case result[:action]
    when :exit
      # fecha sessão e gera título
      Memory.close_session(current_session_id)
      title = Compaction.generate_title(cfg, Memory.list_messages(session_id: current_session_id, limit: 6),
                                        logger: logger)
      Memory.set_session_title(current_session_id, title) if title
      logger.info("session.close id=#{current_session_id} title=#{title.inspect} command=/sair")
      break
    when :clear_history
      # fecha sessão atual e abre nova
      Memory.close_session(current_session_id)
      logger.info("session.close id=#{current_session_id} reason=clear")
      current_session = Memory.open_session(model: cfg.llm_model)
      current_session_id = current_session[:id]
      ctx[:current_session_id] = current_session_id
      logger.info("session.open id=#{current_session_id} reason=clear")
      UI.info("Nova sessão ##{current_session_id}.")
      chat = rebuild_chat!(cfg, logger, build_system_prompt(cfg.agent_name, cfg), thinking_spinner, current_session_id,
                           { tools: TOOLS })
    when :change_model
      chat = rebuild_chat!(cfg, logger, build_system_prompt(cfg.agent_name, cfg), thinking_spinner, current_session_id,
                           { tools: TOOLS })
      logger.info("chat.model_changed model=#{cfg.llm_model}")
    when :load_session
      # fecha sessão atual e troca
      Memory.close_session(current_session_id)
      logger.info("session.close id=#{current_session_id} reason=load")
      current_session_id = result[:payload]
      ctx[:current_session_id] = current_session_id
      sess = Memory.get_session(current_session_id)
      logger.info("session.load id=#{current_session_id} title=#{sess&.dig('title')}")
      chat = rebuild_chat!(cfg, logger,
                           build_system_prompt(cfg.agent_name, cfg, current_session_title: sess&.dig('title')), thinking_spinner, current_session_id, { tools: TOOLS })
    when :continue, nil
      # nada
    end
    next
  end

  # persistir msg do user
  Memory.add_message(
    session_id: current_session_id, role: 'user', content: input
  )

  # chamada ao modelo
  begin
    chat.with_instructions(build_system_prompt(cfg.agent_name, cfg))

    UI.assistant_start(cfg.agent_name)
    thinking_spinner.update('pensando…')
    thinking_spinner.start

    renderer = UI::Markdown.new(indent: UI::GUTTER)

    turn_state = chat.instance_variable_get(:@_aurora_turn_state) || { count: 0, seen: Set.new }
    turn_state[:count] = 0
    turn_state[:seen].clear

    # watchdog de turn: aborta se só-thinking por muito tempo ou turn total exceder
    monitor = {
      running: true,
      started_at: Time.now,
      last_chunk_at: Time.now,
      content_started: false
    }
    ask_thread = Thread.current

    watchdog = Thread.new do
      while monitor[:running]
        sleep 3
        now = Time.now
        elapsed = now - monitor[:started_at]
        monitor[:last_chunk_at]

        if !monitor[:content_started] && elapsed > cfg.agent_thinking_timeout
          monitor[:running] = false
          ask_thread.raise(ThinkingTimeout,
                           "thinking sem risposta dopo #{cfg.agent_thinking_timeout}s")
          break
        end

        next unless elapsed > cfg.agent_turn_timeout

        monitor[:running] = false
        ask_thread.raise(TurnTimeout,
                         "turn excedeu #{cfg.agent_turn_timeout}s")
        break
      end
    end

    begin
      response = chat.ask(input) do |chunk|
        monitor[:last_chunk_at] = Time.now

        thinking_text = chunk.respond_to?(:thinking) ? chunk.thinking : nil
        thinking_str  = thinking_text.respond_to?(:text) ? thinking_text.text : thinking_text.to_s
        if thinking_str && !thinking_str.empty?
          last_line = thinking_str.split("\n").reject(&:empty?).last.to_s
          preview   = UI.truncate(last_line.strip, [UI.term_width - 16, 24].max)
          thinking_spinner.update("pensando · #{preview}")
          thinking_spinner.start unless thinking_spinner.running?
        end

        if chunk.content && !chunk.content.to_s.empty?
          monitor[:content_started] = true
          thinking_spinner.stop(clear: true) if thinking_spinner.running?
          renderer.push(chunk.content)
        end
      end
    ensure
      monitor[:running] = false
      watchdog&.join(2)
      watchdog&.kill
    end

    thinking_spinner.stop(clear: true)
    renderer.finish
    UI.assistant_end

    assistant_content = response&.content.to_s
    thinking_content  = response.respond_to?(:thinking) ? response.thinking&.text.to_s : nil
    tokens_in  = response&.tokens&.input
    tokens_out = response&.tokens&.output

    if assistant_content.empty? && thinking_content.empty?
      UI.warn('O modelo não devolveu conteúdo. (Resposta vazia.)')
      logger.warn('model.empty_response')
    else
      # persistir resposta do assistant
      Memory.add_message(
        session_id: current_session_id, role: 'assistant',
        content: assistant_content, thinking: thinking_content,
        tokens_in: tokens_in, tokens_out: tokens_out
      )

      # log de tokens
      logger.info("model.tokens in=#{tokens_in} out=#{tokens_out}")
    end

    # auto-compactação?
    sess = Memory.get_session(current_session_id)
    if sess && sess['message_count'].to_i >= cfg.compaction_threshold && sess['message_count'].to_i % cfg.compaction_threshold == 0
      Compaction.maybe_compact(session_id: current_session_id, cfg: cfg, logger: logger)
    end
  rescue ThinkingTimeout => e
    thinking_spinner.stop(clear: true)
    renderer&.finish
    UI.warn("Pensei demais e travou no raciocínio (#{cfg.agent_thinking_timeout}s sem resposta). " \
            'Tente reformular a pergunta, ou aumente AGENT_THINKING_TIMEOUT.')
    logger.error("thinking.timeout #{e.message}")
  rescue TurnTimeout => e
    thinking_spinner.stop(clear: true)
    renderer&.finish
    UI.warn("Turno excedeu #{cfg.agent_turn_timeout}s e foi abortado.")
    logger.error("turn.timeout #{e.message}")
  rescue RubyLLM::Error => e
    thinking_spinner.stop(clear: true)
    UI.error("Erro do modelo: #{e.message}")
    logger.error("model.error #{e.class}: #{e.message}")
  rescue StandardError => e
    thinking_spinner.stop(clear: true)
    UI.error("Erro inesperado: #{e.class}: #{e.message}")
    logger.error("unexpected.error #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
  end
end

DB.close
logger.info('loop.end')
