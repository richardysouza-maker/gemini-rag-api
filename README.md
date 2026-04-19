# gemini-rag-api

> Sistema RAG (Retrieval-Augmented Generation) sobre o Confluence da Amor Saúde.
> Indexa páginas do Confluence no vector store da OpenAI e responde perguntas
> com base na documentação oficial da empresa.

## ✨ O que faz

- 📥 **Indexa** páginas do Confluence Cloud (espaço IGF)
- 🧹 **Limpa** o HTML/storage format do Confluence (macros, layouts, namespaces)
- 🧠 **Gera** embeddings via OpenAI, guardados em um vector store
- 💬 **Responde** perguntas usando GPT-4o-mini + `file_search`
- 🔄 **Sincroniza** automaticamente via webhook (upsert inteligente por hash)
- 🎨 **UI** pronta (chat HTML acessível na raiz)

## 🧱 Stack

- [NestJS 11](https://nestjs.com/) (Node.js 20+)
- [OpenAI SDK](https://github.com/openai/openai-node) — Responses API + Vector Stores + file_search
- [Confluence Cloud REST API v2](https://developer.atlassian.com/cloud/confluence/rest/v2/)
- [cheerio](https://cheerio.js.org/) + [turndown](https://github.com/mixmark-io/turndown) pra parsing HTML → Markdown

## 🚀 Setup local

### Pré-requisitos
- Node.js 20+ (`node -v`)
- Credenciais:
  - API token do Confluence Cloud
  - API key da OpenAI

### Instalação
```bash
git clone https://github.com/richardysouza-maker/gemini-rag-api.git
cd gemini-rag-api
npm install
```

### Configuração
Copie `.env.example` para `.env` e preencha:

```env
CONFLUENCE_BASE_URL=https://amorsaudesuporte.atlassian.net
CONFLUENCE_EMAIL=seu-email@amorsaude.com.br
CONFLUENCE_API_TOKEN=atatt3x...
OPENAI_API_KEY=sk-...
CONFLUENCE_VECTOR_STORE_ID=     # deixe vazio na primeira execução
API_TOKEN=                       # só obrigatório em produção
```

### Rodar
```bash
npm run start:dev
```

Abra `http://localhost:3000` pra ver o chat.

### Primeiro uso (indexar)
```bash
# Indexa o espaço IGF inteiro
curl -X POST http://localhost:3000/rag/confluence/sync-space/1202913290

# Copie o vectorStoreId do log e cole no .env
# Reinicie o Nest
```

### Perguntar
```bash
curl -X POST http://localhost:3000/rag/confluence/ask \
  -H "Content-Type: application/json" \
  -d '{"question":"como funciona o agendamento de atendimento?"}'
```

## 🗺️ Arquitetura

```
┌─────────────┐   webhook   ┌──────────────┐   HTTP    ┌─────────────────┐
│  Confluence ├────────────▶│  CustomApps  ├──────────▶│ gemini-rag-api  │
│   (Cloud)   │             │ (orquestra)  │  POST     │   (NestJS)      │
└─────────────┘             └──────────────┘ /sync-... └────────┬────────┘
                                                                │
                                                                │ upload + query
                                                                ▼
                                                         ┌────────────────┐
                                                         │  OpenAI API    │
                                                         │  • files       │
                                                         │  • vector_stores│
                                                         │  • responses   │
                                                         └────────────────┘
```

**Fluxo de ingestão:**
1. Alguém edita uma página no Confluence
2. Atlassian dispara webhook → CustomApps recebe
3. CustomApps chama `POST /rag/confluence/sync-page` na nossa API
4. Nossa API busca a página, limpa, detecta se mudou (via hash), faz upsert no vector store
5. Registro local em `data/indexed-pages.json` é atualizado

**Fluxo de consulta:**
1. Usuário faz pergunta no chat web
2. Frontend chama `POST /rag/confluence/ask`
3. OpenAI Responses API + `file_search` buscam contexto relevante no vector store
4. GPT-4o-mini gera resposta fundamentada na documentação

## 📂 Estrutura

```
src/
├── modules/
│   ├── ai/services/
│   │   └── vector-store.service.ts       # integração com OpenAI vector stores
│   └── confluence-rag/
│       ├── confluence.service.ts         # cliente da API do Confluence
│       ├── confluence-cleaner.service.ts # storage format → markdown
│       ├── indexed-pages-store.service.ts # registro JSON local
│       ├── api-token.guard.ts            # auth por Bearer token
│       ├── confluence-rag.service.ts     # orquestrador (sync/upsert/ask)
│       ├── confluence-rag.controller.ts  # rotas HTTP
│       └── confluence-rag.module.ts
├── app.module.ts
└── main.ts

public/
└── index.html                             # frontend chat

data/
└── indexed-pages.json                     # registro runtime (gitignored)
```

## 🔌 API

### Públicos
- `GET  /rag/confluence/health` — status
- `POST /rag/confluence/ask` — pergunta

### Protegidos (Bearer `API_TOKEN`)
- `POST /rag/confluence/sync-page` — sincroniza uma página (chamado pelo webhook)
- `POST /rag/confluence/sync-space/:spaceId` — sincroniza espaço inteiro (reconciliação)
- `POST /rag/confluence/ingest/:pageId` — (legado) força reindex
- `POST /rag/confluence/ingest-space/:spaceId` — (legado) força reindex do espaço

Veja [`HANDOFF.md`](./HANDOFF.md) pra detalhes completos sobre payloads.

## ⚠️ Limitações conhecidas

- Arquivos binários (imagens, PDFs anexados) **não são indexados** (só o texto)
- Tabelas complexas podem perder formatação no markdown
- Páginas com permissões restritas que a conta de serviço não vê **não aparecem**
- JSON local não funciona bem em deploys com múltiplas réplicas (migrar pra banco)

## 🚢 Produção

Ver [`HANDOFF.md`](./HANDOFF.md) — documento direcionado ao time de
CustomApps/DevOps explicando deploy, configuração de webhook e cron.

## 📝 Licença

Projeto interno Amor Saúde.
