# SearXNG — servidor de busca para a Aurora

Este diretório tem o setup versionado da instância SearXNG que a Aurora
(agente em `../agent.rb`) usa pra fazer pesquisa na web.

A Aurora chama `http://SEU_IP:8888/search?…&format=json` e a tool
`pesquisar_web` faz fallback automático pra HTML se o JSON não estiver
habilitado.

---

## Setup (no servidor onde o SearXNG vai rodar)

### 1. Copie este diretório pro servidor

```bash
# da sua máquina local
scp -r searxng/ usuario@seu-servidor:/opt/searxng/
```

### 2. Gere o secret e crie o `.env`

```bash
cd /opt/searxng
cp .env.example .env
sed -i "s|SEARXNG_SECRET=.*|SEARXNG_SECRET=$(openssl rand -hex 32)|" .env
cat .env   # confira
```

### 3. (Opcional) Edite `config/settings.yml`

Por padrão já vem com JSON habilitado e idioma PT-BR. Se quiser:

- Trocar `default_lang` pra outro idioma
- Habilitar o plugin `limiter` se o servidor estiver exposto publicamente
- Adicionar/remover engines em `engines`

### 4. Suba o container

```bash
docker compose up -d
docker compose logs -f searxng    # acompanhe o boot
```

### 5. Valide

```bash
# HTML (deve abrir a interface)
curl -sI http://localhost:8888/ | head -3

# JSON (deve devolver 200, não 403)
curl -s 'http://localhost:8888/search?q=ruby&format=json' | head -c 200
```

---

## Migração a partir de um `docker run` antigo

Se você já tem um container chamado `searxng` rodando (do `docker run`
que você usou antes), faça assim:

### 1. Copie o estado atual (se tiver config customizada)

```bash
# copia settings, limiter.yml, etc do container pra dentro de ./config
docker cp searxng:/etc/searxng/. ./config/
```

Se você **não** customizou nada (usou o default), pode pular este passo —
o `settings.yml` deste repo já tem o mínimo necessário (JSON habilitado, PT-BR).

### 2. Pare e remova o container antigo

```bash
docker stop searxng
docker rm searxng
```

### 3. Verifique se a porta 8888 está livre

```bash
ss -lntp | grep 8888    # ou: netstat -lntp | grep 8888
```

### 4. Suba pelo compose

```bash
cd /opt/searxng
cp .env.example .env
# ajuste SEARXNG_SECRET, SEARXNG_BIND_ADDR, SEARXNG_PORT_HOST conforme precisar
docker compose up -d
```

---

## Estrutura

```
searxng/
├── docker-compose.yml       # definição do serviço
├── .env.example             # template pro .env (com SEARXNG_SECRET etc)
├── .env                     # criado por você (NÃO versionar)
├── config/
│   └── settings.yml         # customizações sobre os defaults da imagem
└── data/                    # cache do SearXNG (NÃO versionar)
```

## Manutenção

```bash
docker compose pull          # atualiza a imagem
docker compose up -d         # reinicia com a imagem nova
docker compose logs -f       # logs em tempo real
docker compose down          # para o container (NÃO apaga volumes)
```

## Conectando a Aurora

No `.env` da Aurora (`chat2/.env` na máquina onde o agente roda):

```bash
SEARXNG_URL=http://IP_DO_SERVIDOR:8888
```

Se o servidor tiver HTTPS (recomendado pra produção, ex: atrás de um Nginx
com certbot), use a URL HTTPS:

```bash
SEARXNG_URL=https://searxng.exemplo.com
```
