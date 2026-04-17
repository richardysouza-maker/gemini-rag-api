# rag-a-confluence

Pipeline para extrair uma Knowledge Base do **Confluence Cloud** e servir
via RAG com **Gemini File Search**, com interface visual de chat para testes.

Fluxo:

```
Confluence REST API v2  →  JSON  →  Markdown  →  Gemini File Search  →  Chat
     (storage format)     (raw)  (markdownify)                    (Streamlit / CLI)
```

---

## Estrutura do projeto

```
rag-a-confluence/
├── .env.example                  template de credenciais
├── requirements.txt              dependências Python
├── prompt.md                     system prompt do assistente
│
├── generate_confluence_kb.py     extrator Confluence → JSON
├── json_to_md.py                 JSON → Markdown consolidado
├── gemini_rag.py                 CLI de upload / ask / chat
└── chat_app.py                   interface visual Streamlit
```

---

## Setup

### 1. Ambiente Python

```bash
cd rag-a-confluence
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### 2. Credenciais

```bash
cp .env.example .env
```

Preencha o `.env`:

- **CONFLUENCE_DOMAIN** — subdomínio do Atlassian, sem `https://`
  Ex: `growmate.atlassian.net`

- **CONFLUENCE_EMAIL** — email da sua conta Atlassian

- **CONFLUENCE_API_TOKEN** — gere em
  https://id.atlassian.com/manage-profile/security/api-tokens

- **CONFLUENCE_SPACE_ID** — id numérico **ou** key do space
  (ex: `TC` ou `349339657`). Se passar a key, o script resolve o id
  automaticamente.

- **GEMINI_API_KEY** — gere em https://aistudio.google.com/apikey

---

## Uso

### 1. Extrair a KB do Confluence

```bash
python generate_confluence_kb.py
```

Opções:
- `--skip-blogposts` — extrai apenas pages
- `--output meu.json` — define o nome do arquivo de saída

Saída: `confluence_kb_YYYY-MM-DD.json`.

### 2. Converter para Markdown

```bash
python json_to_md.py
```

Detecta automaticamente o JSON mais recente e gera
`confluence_kb_YYYY-MM-DD.md`.

### 3. Upload no Gemini File Search

```bash
python gemini_rag.py upload confluence_kb_YYYY-MM-DD.md
```

O nome do store é salvo em `.gemini_store` para reuso automático
nos comandos seguintes.

### 4. Testar o RAG

Três formas disponíveis — use a que preferir.

#### 4a. Interface visual (Streamlit) — recomendado

```bash
streamlit run chat_app.py
```

Abre em `http://localhost:8501`. Oferece:
- chat multi-turn com histórico
- system prompt do `prompt.md` já carregado
- painel lateral com modelo, store e tamanho do prompt
- expansor de fontes por resposta
- botão "Nova conversa" para resetar

#### 4b. Chat interativo no terminal

```bash
python gemini_rag.py chat
```

Comandos no chat: `/reset` (limpa histórico), `/sair` (encerra).

#### 4c. Pergunta one-shot

```bash
python gemini_rag.py ask "como acessar o sistema?"
```

### 5. Gerenciar stores

```bash
python gemini_rag.py list                         # lista stores
python gemini_rag.py delete fileSearchStores/xxx  # remove um store
```

---

## Estrutura do JSON gerado

```json
{
  "id": "12345678",
  "title": "Como configurar X",
  "type": "page",
  "space_id": "349339657",
  "space_key": "TC",
  "parent_id": "12345677",
  "status": "current",
  "url": "https://SEUDOMINIO.atlassian.net/wiki/spaces/TC/pages/12345678/...",
  "created_at": "2025-01-15T10:30:00Z",
  "modified_time": "2025-12-01T14:22:00Z",
  "version": 4,
  "content": "# Como configurar X\n\n..."
}
```

Campo `type` assume `page` ou `blogpost`.

---

## Reindexar depois de mudanças no Confluence

```bash
python generate_confluence_kb.py
python json_to_md.py
python gemini_rag.py delete $(cat .gemini_store)
python gemini_rag.py upload confluence_kb_YYYY-MM-DD.md
```

---

## Customização do assistente

Edite `prompt.md` para ajustar o tom, escopo e regras do assistente.
Ele é carregado automaticamente como system prompt em:
- `streamlit run chat_app.py`
- `python gemini_rag.py chat`

O `ask` one-shot **não** usa o system prompt (é consulta pura ao RAG).

---

## Troubleshooting

**`ERRO: variáveis de ambiente faltando`**
O `.env` não existe ou está incompleto. Rode `cp .env.example .env`
e preencha todos os campos.

**`ERRO: nenhum store salvo em .gemini_store`**
Você ainda não fez o upload. Rode
`python gemini_rag.py upload confluence_kb_*.md` primeiro.

**Respostas sem fontes**
Significa que o conteúdo não está na base ou o Gemini não achou
relevante. Reveja se a página existe no Confluence e se foi extraída
(verifique o JSON).

**HTTP 401 ao extrair do Confluence**
Token expirado ou email errado. Gere um novo em
https://id.atlassian.com/manage-profile/security/api-tokens.
