# Aurora

> **Projeto de estudo em Ruby**: agente de IA conversacional com ferramentas, memória persistente e streaming — escrito do zero para aprender Ruby, RAG, function calling, SQLite e integração com LLMs locais.

Aurora conversa com você no terminal, lembra de quem você é, sabe o que você já aprendeu, pesquisa na web, consulta previsão do tempo, faz cálculos e persiste tudo entre sessões. Tudo em **~2000 linhas de Ruby puro**, com poucas dependências.

---

## Sumário

- [Stack](#stack)
- [Como funciona](#como-funciona)
- [Pré-requisitos](#pré-requisitos)
- [Setup em 5 minutos](#setup-em-5-minutos)
- [Configurando o provedor de LLM](#configurando-o-provedor-de-llm)
  - [1. llama.cpp local (o que esse projeto usa)](#1-llamacpp-local-o-que-esse-projeto-usa)
  - [2. Ollama](#2-ollama)
  - [3. OpenRouter](#3-openrouter)
  - [4. OpenAI oficial](#4-openai-oficial)
  - [5. Qualquer OpenAI-compat (LM Studio, vLLM, etc)](#5-qualquer-openai-compat-lm-studio-vllm-etc)
- [Banco de dados: como ele é criado](#banco-de-dados-como-ele-é-criado)
- [Comandos slash](#comandos-slash)
- [Memória persistente](#memória-persistente)
- [SearXNG (pesquisa na web)](#searxng-pesquisa-na-web)
- [Estrutura do projeto](#estrutura-do-projeto)
- [Troubleshooting](#troubleshooting)

---

## Stack

| Camada | Tecnologia | Por quê |
|---|---|---|
| LLM client | [ruby_llm](https://rubyllm.com) 1.16 | API unificada, OpenAI-compat, streaming, function calling |
| LLM server | [llama.cpp](https://github.com/ggerganov/llama.cpp) (server) | OpenAI-compat, roda Qwen3 35B no Qwen3.6 local |
| Banco | SQLite 3 + FTS5 | Arquivo único, zero infra, busca full-text embutida |
| HTTP | Net::HTTP (stdlib) | Sem gem extra |
| HTML | Nokogiri | Extração de conteúdo das páginas na pesquisa web |
| Expressões | Dentaku | Calculadora segura (sem `eval`) |
| Config | dotenv | `.env` em vez de hardcoded |

---

## Como funciona

```
┌────────────────┐     ┌──────────────────┐     ┌────────────────────┐
│  Você digita   │ ──▶ │  agent.rb (loop) │ ──▶ │  LLM (Qwen3 local) │
│  no terminal   │ ◀── │  streaming + log │ ◀── │  OpenAI-compat     │
└────────────────┘     └────┬─────────────┘     └────────────────────┘
                            │
              ┌─────────────┼─────────────┐
              ▼             ▼             ▼
        ┌──────────┐  ┌──────────┐  ┌──────────┐
        │  Tools   │  │ SQLite   │  │  Logs    │
        │ 6 tools  │  │ aurora.db│  │ agent.log│
        └──────────┘  └──────────┘  └──────────┘
```

Quando você digita algo:
1. **Aurora** manda pro **LLM** (Qwen3 via llama.cpp) com a system prompt + histórico injetado
2. O LLM responde em **streaming** (você vê token a token)
3. Se precisa de uma tool (previsão, busca, calculadora, etc), o LLM pede e a Aurora executa
4. O resultado volta pro LLM, que finaliza a resposta
5. Tudo é **persistido em SQLite** (mensagens, fatos, aprendizados)
6. **Auto-compactação** mantém o histórico gerenciável

---

## Pré-requisitos

- **Ruby 3.4+** (testado em 3.4.8)
- **Bundler 2.x** (`gem install bundler`)
- **Algum servidor LLM** compatível com a API OpenAI:
  - [llama.cpp server](https://github.com/ggerganov/llama.cpp/blob/master/examples/server/README.md) (recomendado pra rodar local sem GPU forte)
  - [Ollama](https://ollama.com) (mais simples de instalar)
  - [LM Studio](https://lmstudio.ai) (GUI, fácil)
  - [OpenRouter](https://openrouter.ai) (cloud, paga)
  - [OpenAI](https://platform.openai.com) (cloud, paga)

---

## Setup em 5 minutos

```bash
# 1. Clonar
git clone https://github.com/humbertocortezia/aurora-ia.git
cd aurora-ia

# 2. Instalar dependências
bundle install

# 3. Copiar config de exemplo e ajustar a URL do seu servidor LLM
cp .env.example .env
$EDITOR .env

# 4. Rodar
ruby agent.rb
```

Na primeira execução, Aurora:
- Cria `data/aurora.db` (SQLite, com WAL + FTS5)
- Roda as migrations automaticamente
- Abre a sessão #1
- Espera você digitar

**Teste rápido:**
```
Você  › oi
Aurora  › Oi! Sou a Aurora, como posso te ajudar?
Você  › quanto é 15% de 847?
⏵  calculadora(expressao=0.15*847)
↳  retorno → Expressão: 0.15*847  Resultado: 127.05
Aurora  › 15% de 847 é 127,05.
Você  › /sair
✓  Sessão #1 fechada: Saudação inicial
```

---

## Configurando o provedor de LLM

O `.env` aponta pra **qualquer endpoint OpenAI-compat**. Trocar de provedor é só editar 2-3 linhas.

### 1. llama.cpp local (o que esse projeto usa)

Esse projeto foi criado e testado com o **llama.cpp** rodando Qwen3-35B em uma máquina local, exposto como servidor HTTP compatível com a API OpenAI. É assim:

**Setup do llama.cpp (no servidor da LLM):**

```bash
# Compilar (uma vez)
git clone https://github.com/ggerganov/llama.cpp
cd llama.cpp && make

# Baixar um modelo (Qwen3-30B-A3B em GGUF, ~18GB)
#   https://huggingface.co/Qwen/Qwen3-30B-A3B-Instruct-2507-GGUF

# Subir o servidor (porta 8001)
./llama-server \
  -m /path/to/qwen3-30b-a3b-instruct-2507-q4_k_m.gguf \
  -c 262144 \
  --host 0.0.0.0 \
  --port 8001 \
  --jinja
```

**Config no `.env` da Aurora:**
```bash
LLM_API_BASE=http://IP_DO_SERVIDOR:8001/v1
LLM_API_KEY=sk-qualquer        # llama.cpp ignora, mas a Aurora envia
LLM_MODEL=Qwen3-30B-A3B-Instruct
LLM_USE_SYSTEM_ROLE=true       # llama.cpp aceita role "system"
```

### 2. Ollama

[Ollama](https://ollama.com) é a forma mais simples de rodar LLMs localmente.

```bash
# Instalar (Linux)
curl -fsSL https://ollama.com/install.sh | sh

# Baixar modelo
ollama pull qwen3:30b-a3b
# ou: llama3.1:70b, mistral, etc

# Ollama já expõe OpenAI-compat em :11434
```

**Config no `.env`:**
```bash
LLM_API_BASE=http://localhost:11434/v1
LLM_API_KEY=ollama             # ignorado, mas obrigatório
LLM_MODEL=qwen3:30b-a3b
LLM_USE_SYSTEM_ROLE=true
```

### 3. OpenRouter

[OpenRouter](https://openrouter.ai) dá acesso a **centenas de modelos** (Claude, GPT-4, Gemini, Llama, etc) com uma única API key.

```bash
# Pegar key em https://openrouter.ai/keys
```

**Config no `.env`:**
```bash
LLM_API_BASE=https://openrouter.ai/api/v1
LLM_API_KEY=sk-or-v1-xxxxx
LLM_MODEL=anthropic/claude-3.5-sonnet   # ou qwen/qwen-2.5-72b-instruct
LLM_USE_SYSTEM_ROLE=true
```

### 4. OpenAI oficial

```bash
# Pegar key em https://platform.openai.com/api-keys
```

**Config no `.env`:**
```bash
LLM_API_BASE=https://api.openai.com/v1
LLM_API_KEY=sk-proj-xxxxx
LLM_MODEL=gpt-4o-mini
LLM_USE_SYSTEM_ROLE=false      # OpenAI novo usa role "developer"
```

### 5. Qualquer OpenAI-compat (LM Studio, vLLM, etc)

O princípio é o mesmo: descobre a URL base que o servidor expõe, coloca uma key qualquer (alguns ignoram, outros validam), e o nome do modelo exatamente como o servidor retorna em `/v1/models`.

```bash
# Testar se o servidor tá respondendo
curl -s http://SEU_IP:PORTA/v1/models | jq .
```

---

## Banco de dados: como ele é criado

**Aurora usa SQLite, arquivo único em `data/aurora.db`.** Nada de servidor, nada de Docker. Backup = `cp`.

### Primeira execução

Quando você roda `ruby agent.rb` pela primeira vez:

1. Aurora verifica se `data/` existe (cria se não)
2. Abre conexão SQLite no `data/aurora.db`
3. Habilita `PRAGMA journal_mode = WAL` (concorrência + crash safety)
4. Habilita `PRAGMA foreign_keys = ON`
5. Lê `lib/migrations/*.sql` em ordem
6. Pra cada migration não aplicada: abre transação, executa batch, grava em `schema_info`
7. Cria as 5 tabelas (sessões, mensagens, fatos, aprendizados, FTS5)

Você não precisa fazer NADA. Olhe no log:
```
[INFO] db.migration apply=1 file=001_initial.sql
```

### Estrutura das tabelas

```
sessions       (id, title, summary, started_at, ended_at, message_count, model)
messages       (id, session_id, role, content, tool_name, tool_call_id,
                tool_arguments, tool_result, thinking, tokens_in/out, created_at)
facts          (key PRIMARY KEY, value, category, source_session, source_message, ...)
learnings      (id, topic, subtopic, content, proficiency 1-5, evidence_count, ...)
messages_fts   (FTS5 virtual table: content + thinking, busca em PT-BR sem acentos)
```

### Adicionar uma migration

1. Crie `lib/migrations/002_o_que_voce_quiser.sql` com o SQL idempotente (`CREATE TABLE IF NOT EXISTS …`)
2. Reinicie o agente
3. A migration roda automaticamente e fica registrada em `schema_info`

### Inspecionar o banco direto

```bash
sqlite3 data/aurora.db

# Ver sessões
SELECT id, title, message_count, started_at FROM sessions;

# Buscar nas mensagens por palavra-chave (FTS5)
SELECT snippet(messages_fts, 0, '⟨', '⟩', '…', 16)
FROM messages_fts WHERE messages_fts MATCH 'typescript';

# Ver seus aprendizados
SELECT topic, subtopic, proficiency, content FROM learnings;

# Ver fatos (perfil)
SELECT key, value, category FROM facts;
```

### Backup

```bash
# simples
cp data/aurora.db ~/backup/aurora-$(date +%F).db

# ou dump SQL
sqlite3 data/aurora.db .dump > ~/backup/aurora-$(date +%F).sql
```

### Resetar tudo

```bash
rm -f data/aurora.db data/aurora.db-*   # apaga o banco
ruby agent.rb                            # recria do zero
```

---

## Comandos slash

| Comando | O que faz |
|---|---|
| `/sair` | Encerra, fecha sessão, gera título via LLM |
| `/limpar` | Fecha sessão atual, abre nova |
| `/sessoes` | Lista últimas 15 sessões salvas |
| `/carregar N` | Continua a sessão #N (injeta histórico no contexto) |
| `/apagar-sessao N` | Remove a sessão #N do banco |
| `/modelo [nome]` | Mostra ou troca o modelo sem reiniciar |
| `/perfil` | Lista fatos lembrados sobre você |
| `/esquecer CHAVE` | Apaga um fato (ex: `/esquecer nome`) |
| `/ferramentas` | Lista tools disponíveis |
| `/ajuda` | Mostra ajuda |

---

## Memória persistente

### Fatos (perfil)
Quando você diz algo pessoal persistente (nome, profissão, cidade…), Aurora detecta e salva automaticamente. Chaves em snake_case. Visualize com `/perfil`.

### Aprendizados
Quando você diz "agora entendi X" / "já sabia disso" / "esquece que tinha dúvida sobre Y", Aurora registra o aprendizado com **proficiência 1-5** (1 = ouviu falar, 5 = expert). Antes de explicar algo, ela consulta a própria base pra **não repetir o básico**.

### Sessões
Cada execução é uma sessão. Ao `/sair`, o **título é gerado pelo LLM** com base nas primeiras mensagens. Para retomar:
```
/sessoes          # lista
/carregar 3       # continua a #3 com o histórico injetado
```

### Auto-compactação
A cada `COMPACTION_THRESHOLD` mensagens (default 30), Aurora pede pro LLM **resumir** as mensagens antigas em 1 mensagem de sumário, mantendo decisões e contexto importante. Configurável no `.env`:
```
COMPACTION_THRESHOLD=30
COMPACTION_KEEP_HEAD=5
COMPACTION_KEEP_TAIL=5
SESSION_HISTORY_ON_BOOT=10
```

---

## SearXNG (pesquisa na web)

A tool `pesquisar_web` consulta o **SearXNG** (motor de busca open-source self-hosted) e em seguida abre e lê as principais páginas. Auto-fallback: tenta `format=json`, se 403 parsea HTML.

O setup completo (compose, settings, .env, migração) está em `searxng/`. Veja [`searxng/README.md`](searxng/README.md).

---

## Estrutura do projeto

```
aurora-ia/
├── agent.rb                  # entrypoint + loop principal
├── lib/
│   ├── ui.rb                 # cores ANSI, Spinner, banner
│   ├── config.rb             # carrega .env → struct
│   ├── logger.rb             # logs/agent.log rotacionado
│   ├── db.rb                 # conexão SQLite + migration runner
│   ├── memory.rb             # CRUD: sessions, messages, facts, learnings, FTS5
│   ├── compaction.rb         # auto-compactação + geração de título via LLM
│   └── slash.rb              # /comandos
├── lib/migrations/
│   └── 001_initial.sql       # schema inicial (idempotente)
├── tools/
│   ├── hora.rb               # data/hora atual
│   ├── calculadora.rb        # expressões matemáticas (Dentaku)
│   ├── previsao_tempo.rb     # Open-Meteo, 7 dias, tabela colorida
│   ├── localidade.rb         # ip-api.com (com cache 24h)
│   ├── searxng.rb            # SearXNG + Nokogiri (extrai conteúdo)
│   ├── user_facts.rb         # perfil do usuário (snake_case)
│   └── memoria.rb            # aprendizados cumulativos (topic/proficiência)
├── data/                     # aurora.db, profile.yml.migrated (gerados em runtime)
├── logs/                     # agent.log
├── searxng/                  # setup do servidor SearXNG
├── Gemfile
├── .env.example
└── .gitignore
```

---

## Troubleshooting

**Erro `Connection refused` em LLM_API_BASE**
- O servidor LLM não tá rodando, ou tá em outra porta
- Testa: `curl -s $LLM_API_BASE/models | head`

**Erro `SearXNG retornou HTTP 403`**
- JSON não está habilitado no seu SearXNG
- Solução: adicione `json` em `search.formats` no `settings.yml` do SearXNG, OU use a versão com fallback HTML (já é o que Aurora faz por padrão)

**Aurora não detecta que eu aprendi algo**
- Tente ser mais explícito: "agora entendi que X = Y" ou "já sabia fazer X"
- Ou use a tool manualmente via slash: pergunte "liste os tópicos que você lembra" e a Aurora invoca a tool `memoria`

**Sessão anterior não aparece em `/sessoes`**
- A sessão só é "salva" quando você dá `/sair` ou `/limpar`
- Se você fechar o terminal com Ctrl+C, a sessão fica com `ended_at=NULL` mas ainda é listada

**Contexto do modelo estourou**
- Aumente `COMPACTION_THRESHOLD` no `.env` (compacta mais cedo)
- Ou use `/limpar` pra começar uma sessão nova

**Como vejo os logs?**
- `tail -f logs/agent.log` — tudo é logado: tool calls, tokens, tempo de resposta

---

## Licença

MIT.
