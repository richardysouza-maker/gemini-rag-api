# HANDOFF — RAG Confluence para CustomApps

> **Contexto:** este documento é destinado ao time de CustomApps.
> Ele explica o que precisa ser feito para colocar a solução em produção
> e automatizar a sincronização com o Confluence.

## 🎯 O que este projeto faz

É uma API em Node.js/NestJS que:

1. Busca páginas do Confluence Cloud (espaço IGF atualmente)
2. Limpa o HTML/storage format e converte para markdown
3. Indexa na OpenAI como vector store (RAG)
4. Responde perguntas via `file_search` usando GPT-4o-mini

A interface de perguntas já existe (HTML simples na raiz `/`).

---

## ✅ O que PRECISA ser feito (trabalho do time de CustomApps)

### 1. Deploy da aplicação Node.js

É uma app NestJS padrão. Qualquer plataforma que rode Node.js 20+ serve:
- Servidor interno Node.js / PM2
- Container Docker
- Kubernetes
- Railway / Fly.io / Render / AWS ECS / etc

**Requisitos de runtime:**
- Node.js 20 LTS ou superior
- Saída HTTP para:
  - `https://amorsaudesuporte.atlassian.net` (API do Confluence)
  - `https://api.openai.com` (OpenAI)
- Escrita em disco para a pasta `data/` (registro de páginas indexadas em JSON)
- Porta de entrada HTTP (padrão 3000) exposta publicamente ou via gateway interno

**Como rodar:**
```bash
npm ci
npm run build
npm run start:prod
```

### 2. Variáveis de ambiente necessárias

| Variável | Descrição | Obrigatória |
|---|---|---|
| `CONFLUENCE_BASE_URL` | URL base do Confluence (ex.: `https://amorsaudesuporte.atlassian.net`) | ✅ |
| `CONFLUENCE_EMAIL` | Email da conta de serviço Atlassian | ✅ |
| `CONFLUENCE_API_TOKEN` | API token do Atlassian | ✅ |
| `OPENAI_API_KEY` | Chave da OpenAI (conta da empresa) | ✅ |
| `CONFLUENCE_VECTOR_STORE_ID` | ID do vector store já criado | ✅ (após primeiro sync) |
| `API_TOKEN` | Token compartilhado pra autenticar chamadas automatizadas (gerem um token forte tipo UUID) | ✅ (obrigatório em prod) |
| `PORT` | Porta HTTP (default 3000) | ❌ |

⚠️ **Sem `API_TOKEN` os endpoints de sync ficam abertos.** Não subir em produção sem isso.

### 3. Configurar webhook no Confluence Cloud

No admin Atlassian (quem for admin do site):

**Eventos a escutar:**
- `page_created`
- `page_updated`
- `page_removed` (ou `page_restored` + `page_trashed`, depende da versão)

**Filtro recomendado:** só páginas do espaço **IGF** (spaceId: `1202913290`)

**Endpoint do webhook (NÃO é sua API direto — é a CustomApps):**
A CustomApps recebe o webhook primeiro, filtra/enriquece, e chama a API:

```
POST https://<URL_DA_API_EM_PRODUCAO>/rag/confluence/sync-page

Headers:
  Authorization: Bearer <API_TOKEN>
  Content-Type: application/json

Body:
  {
    "pageId": "<ID_DA_PAGINA_DO_EVENTO>",
    "eventType": "updated"  // ou "created" ou "removed"
  }
```

**Resposta (sucesso):**
```json
{
  "pageId": "1202913561",
  "title": "Núcleo de IA",
  "status": "updated",         // "new" | "updated" | "unchanged" | "removed" | "skipped" | "failed"
  "vectorStoreFileId": "file-..."
}
```

**Resposta (erro):**
HTTP 4xx/5xx com JSON de erro padrão NestJS.

### 4. Configurar job de reconciliação diário

Webhook pode falhar (API fora do ar, evento perdido, etc). Precisa de um job que "varre" o espaço inteiro 1x por dia e pega o que escapou.

**Agendamento sugerido:** todo dia às 03:00 BRT (hora de baixo tráfego).

**Chamada:**
```
POST https://<URL_DA_API_EM_PRODUCAO>/rag/confluence/sync-space/1202913290

Headers:
  Authorization: Bearer <API_TOKEN>
```

**Resposta:**
```json
{
  "spaceId": "1202913290",
  "vectorStoreId": "vs_...",
  "new": 2,
  "updated": 5,
  "unchanged": 40,
  "removed": 1,
  "skipped": 0,
  "failed": 0,
  "durationMs": 45000,
  "results": [...]
}
```

O job pode levar **vários minutos** dependendo do volume. Configurem timeout de pelo menos 10min.

---

## 🔐 Segurança

- **Token compartilhado**: gerem um `API_TOKEN` forte (UUID/random 32+ chars) e configurem nos dois lados (CustomApps e nas env vars da API).
- **HTTPS obrigatório** em produção — o token trafega no header.
- **Nunca loguem o valor do token** em logs de auditoria.
- **Rotação**: recomendado rotacionar a cada 6 meses ou se houver suspeita de vazamento.

---

## 🧪 Como testar depois do deploy

1. Testar saúde:
```bash
curl https://<URL>/rag/confluence/health
# → { "ok": true, "vectorStoreConfigured": true, "registeredPages": 4, "authProtected": true }
```

2. Testar auth (deve falhar sem token):
```bash
curl -X POST https://<URL>/rag/confluence/sync-page \
  -H "Content-Type: application/json" \
  -d '{"pageId":"1202913561"}'
# → 401 Unauthorized
```

3. Testar auth (deve funcionar com token):
```bash
curl -X POST https://<URL>/rag/confluence/sync-page \
  -H "Authorization: Bearer SEU_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"pageId":"1202913561","eventType":"updated"}'
# → { "status": "unchanged", ... }
```

4. Testar a pergunta (público):
```bash
curl -X POST https://<URL>/rag/confluence/ask \
  -H "Content-Type: application/json" \
  -d '{"question":"o que é o Núcleo de IA?"}'
# → resposta do RAG
```

---

## 📋 Endpoints — referência rápida

| Método | Rota | Auth | Descrição |
|---|---|---|---|
| GET | `/rag/confluence/health` | ❌ | Saúde do serviço |
| POST | `/rag/confluence/ask` | ❌ | Faz pergunta ao RAG |
| POST | `/rag/confluence/sync-page` | ✅ | Sincroniza uma página (webhook) |
| POST | `/rag/confluence/sync-space/:spaceId` | ✅ | Sincroniza espaço inteiro (cron) |
| POST | `/rag/confluence/ingest/:pageId` | ✅ | (Legado) Força reindex |
| POST | `/rag/confluence/ingest-space/:spaceId` | ✅ | (Legado) Força reindex do espaço |

---

## 💾 Persistência de estado

A aplicação grava em `data/indexed-pages.json` um registro das páginas já indexadas
(ID, version, hash do conteúdo, ID do arquivo na OpenAI). Isso permite detectar
mudanças sem chamar a OpenAI desnecessariamente.

**Importante:**
- Em deploys com disk efêmero (container recriado a cada deploy), **usar volume
  persistente** pra `data/` OU migrar pra banco de dados.
- Se o JSON for perdido, o próximo `sync-space` vai re-indexar tudo (não é
  catastrófico, mas gera custo extra de API da OpenAI).

**Sugestão de upgrade:** migrar pra Postgres/Redis quando volume crescer.

---

## 🆘 Dúvidas

Qualquer dúvida sobre o código, falar com **Richardy Souza**.
