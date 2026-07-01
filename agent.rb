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
# 1. Configuração
# -----------------------------------------------------------------------------
cfg = Config.load(base_dir: __dir__)

logger = AgentLogger.build(log_dir: cfg.log_dir)
logger.info("startup model=#{cfg.llm_model} base=#{cfg.llm_api_base} " \
            "searxng=#{cfg.searxng_url} db=#{cfg.db_path} thinking=#{cfg.agent_thinking}")

RubyLLM.configure do |c|
  c.openai_api_key         = cfg.llm_api_key
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
def build_system_prompt(agent_name, cfg, current_session_title: nil)
  facts_block    = Memory.facts_to_prompt_block
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
    ## Estilo
    - Concisa por padrão: respostas curtas e densas valem mais que longas e vagas.
    - Pode usar Markdown (negrito, listas, `código`, blocos ```); o terminal renderiza.
    - Não narre seu processo nem anuncie chamadas de ferramenta — execute e entregue o resultado.
    - Ao citar a web, inclua a fonte entre colchetes: [https://...].
    - Se uma ferramenta falhar, explique em uma frase e ofereça alternativa (sem stacktrace).
    ## Memória persistente (use em silêncio, sem pedir confirmação)
    Só registre informação DURÁVEL e AFIRMADA pelo usuário. Nunca salve hipóteses,
    brainstorming exploratório ("e se eu fizesse…") ou pedidos efêmeros.
    - `user_facts` (acao: "salvar") → fatos SOBRE o usuário: identidade, contexto e
      preferências estáveis (nome, cidade, profissao, empresa, projeto_atual,
      linguagem_favorita). Chave em snake_case; use categoria project/preference/context.
    - `memoria` (acao: "salvar") → CONHECIMENTO que o usuário adquiriu (tópicos de
      estudo, skills). Antes de explicar um tema, use `memoria` (acao: "buscar") para
      ver o que ele já domina e ajustar a profundidade — não repita o básico.
    Roteamento em caso de dúvida: fato pessoal/preferência → user_facts;
    algo que ele aprendeu → memoria. Se já constar abaixo, não pergunte de novo
    nem salve de novo.
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

  tool_count_this_turn = { n: 0 }

  chat.before_tool_call do |tc|
    tool_count_this_turn[:n] += 1
    thinking_spinner.stop(clear: true) if thinking_spinner.running?
    logger.info("tool.call name=#{tc.name} args=#{tc.arguments.inspect} " \
                "turn_n=#{tool_count_this_turn[:n]}")
    UI.tool_call(tc.name, tc.arguments)
    memory_recorder[:on_tool_call]&.call(tc)

    if tool_count_this_turn[:n] > cfg.agent_max_tool_calls
      UI.warn("Limite de #{cfg.agent_max_tool_calls} tool calls atingido neste turno.")
      logger.warn("tool.limit_reached n=#{tool_count_this_turn[:n]} max=#{cfg.agent_max_tool_calls}")
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
unless facts.empty?
  UI.info("Perfil: #{facts.size} fato(s) lembrado(s).")
end
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
      title = Compaction.generate_title(cfg, Memory.list_messages(session_id: current_session_id, limit: 6), logger: logger)
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
      chat = rebuild_chat!(cfg, logger, build_system_prompt(cfg.agent_name, cfg), thinking_spinner, current_session_id, { tools: TOOLS })
    when :change_model
      chat = rebuild_chat!(cfg, logger, build_system_prompt(cfg.agent_name, cfg), thinking_spinner, current_session_id, { tools: TOOLS })
      logger.info("chat.model_changed model=#{cfg.llm_model}")
    when :load_session
      # fecha sessão atual e troca
      Memory.close_session(current_session_id)
      logger.info("session.close id=#{current_session_id} reason=load")
      current_session_id = result[:payload]
      ctx[:current_session_id] = current_session_id
      sess = Memory.get_session(current_session_id)
      logger.info("session.load id=#{current_session_id} title=#{sess&.dig('title')}")
      chat = rebuild_chat!(cfg, logger, build_system_prompt(cfg.agent_name, cfg, current_session_title: sess&.dig('title')), thinking_spinner, current_session_id, { tools: TOOLS })
    when :continue, nil
      # nada
    end
    next
  end

  # persistir msg do user
  msg_id = Memory.add_message(
    session_id: current_session_id, role: 'user', content: input
  )

  # chamada ao modelo
  begin
    chat.with_instructions(build_system_prompt(cfg.agent_name, cfg))

    UI.assistant_start(cfg.agent_name)
    thinking_spinner.update('pensando…')
    thinking_spinner.start

    renderer = UI::Markdown.new(indent: UI::GUTTER)

    response = chat.ask(input) do |chunk|
      thinking_text = chunk.respond_to?(:thinking) ? chunk.thinking : nil
      thinking_str  = thinking_text.respond_to?(:text) ? thinking_text.text : thinking_text.to_s
      if thinking_str && !thinking_str.empty?
        # mostra ao vivo a última linha do raciocínio (1 linha, sem poluir)
        last_line = thinking_str.split("\n").reject(&:empty?).last.to_s
        preview   = UI.truncate(last_line.strip, [UI.term_width - 16, 24].max)
        thinking_spinner.update("pensando · #{preview}")
        thinking_spinner.start unless thinking_spinner.running?
      end

      if chunk.content && !chunk.content.to_s.empty?
        thinking_spinner.stop(clear: true) if thinking_spinner.running?
        renderer.push(chunk.content)
      end
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
