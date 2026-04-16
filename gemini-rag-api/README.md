# Gemini RAG API

API REST em Node.js para RAG nativo usando o **Gemini File Search Tool** — sem bancos vetoriais externos.

## Instalação

```bash
npm install
cp .env.example .env
# Edite .env com sua GEMINI_API_KEY
```

## Execução

```bash
npm start        # produção
npm run dev      # desenvolvimento (hot reload)
```

---

## Endpoints

### 🗂️ Stores

#### Criar store
```
POST /api/stores
Content-Type: application/json

{ "displayName": "meu-store" }
```
Resposta:
```json
{
  "message": "Store criado com sucesso.",
  "store": { "name": "fileSearchStores/abc123", "displayName": "meu-store" }
}
```

#### Listar stores
```
GET /api/stores
```

#### Deletar store (e todos os documentos)
```
DELETE /api/stores/:storeName
```
Onde `storeName` é apenas o ID, ex: `abc123` (sem o prefixo `fileSearchStores/`).

---

### 📎 Upload de arquivos

#### Enviar arquivo para um store
```
POST /api/upload
Content-Type: multipart/form-data

file         = <arquivo>          (obrigatório)
storeName    = abc123             (obrigatório — ID do store)
displayName  = "Manual v2"        (opcional)
metadata     = '{"ano":"2025"}'   (opcional — JSON com metadados)
```

#### Listar documentos de um store
```
GET /api/upload/:storeName
```

#### Deletar documento
```
DELETE /api/upload/:storeName/:docId
```

---

### 💬 Chat com RAG

#### Enviar prompt
```
POST /api/chat
Content-Type: application/json

{
  "prompt": "Qual é a capacidade de carga?",
  "storeName": "abc123",
  "sessionId": "user-42",          (opcional — mantém histórico)
  "systemPrompt": "Responda em PT-BR sempre.", (opcional)
  "metadataFilter": "ano = \"2025\"",          (opcional)
  "stream": false                              (opcional — default false)
}
```

Resposta:
```json
{
  "answer": "A capacidade de carga é 500kg...",
  "sources": ["manual-tecnico.pdf"],
  "sessionId": "user-42",
  "historyLength": 1
}
```

#### Streaming (SSE)
Com `"stream": true`, a resposta vem como Server-Sent Events:
```
data: {"text":"A capacidade"}
data: {"text":" de carga é"}
data: {"text":" 500kg..."}
data: {"done":true}
```

#### Limpar histórico de sessão
```
DELETE /api/chat/session/:sessionId
```

---

## Exemplo com curl

```bash
# 1. Criar store
curl -X POST http://localhost:3000/api/stores \
  -H "Content-Type: application/json" \
  -d '{"displayName":"meu-projeto"}'

# 2. Upload de PDF
curl -X POST http://localhost:3000/api/upload \
  -F "file=@./manual.pdf" \
  -F "storeName=abc123" \
  -F "displayName=Manual Técnico"

# 3. Perguntar
curl -X POST http://localhost:3000/api/chat \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "Como fazer a manutenção preventiva?",
    "storeName": "abc123",
    "sessionId": "sessao-1"
  }'
```

## Formatos suportados

PDF, DOCX, TXT, JSON, HTML, Markdown, CSV, Excel, SQL, Jupyter Notebooks, arquivos de código e ZIP.

## Preço

- Storage: **gratuito**
- Embeddings em consulta: **gratuito**
- Indexação inicial: **$0,15 por 1M tokens**
