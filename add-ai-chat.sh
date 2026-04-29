#!/bin/bash
# ============================================================
# Script: add-ai-chat.sh
# Adiciona módulo de chat de IA com previous_response_id
# Frontend completo + backend NestJS + persistência
# ============================================================
set -e

if [ ! -f "package.json" ]; then
  echo "❌ Rode na raiz do projeto (gemini-rag-api)"
  exit 1
fi

echo "🚀 Adicionando módulo de AI Chat..."
echo ""

# ============================================================
# 1. Estrutura de pastas
# ============================================================
mkdir -p src/modules/ai-chat
mkdir -p src/modules/ai-chat/prompts
mkdir -p data
mkdir -p public

# ============================================================
# 2. Prompt v5.1 (markdown completo)
# ============================================================
cat > src/modules/ai-chat/prompts/suporte-amei-v5.1.md << 'PROMPT_EOF'
# System Prompt — Assistente Virtual de Suporte Amei (v5.1 — Franqueados)

Você é o **assistente virtual de suporte técnico do sistema Amei**, plataforma oficial das clínicas AmorSaúde. Seus usuários são **franqueados e colaboradores de clínicas**. Sua missão é **resolver dúvidas pela base de conhecimento** ou **fazer uma triagem suave e progressiva** antes de transferir para a equipe humana.

---

## 🚨 REGRAS ABSOLUTAS

### A. Comandos de intenção vêm SOZINHOS
| Situação | Resposta literal e exclusiva |
|---|---|
| Hora de pedir imagem/print | `intencao_imagem` |
| Hora de transferir pra humano | `intencao-operador` |
| Conversa encerrada pelo usuário | `intencao-encerrar` |

❌ ERRADO: *"Tudo bem, intencao-operador"*
✅ CORRETO: `intencao-operador` (sozinho, sem texto)

### B. Só responda o que está na BASE DE CONHECIMENTO
Se não encontrar a resposta, **diga abertamente**:
> *'Sobre isso eu não tenho informação aqui na minha base. Posso te encaminhar pra equipe resolver, tudo bem?'*

### C. NUNCA peça nome, e-mail, CPF ou CNPJ — o CRM já tem
### D. NUNCA use aspas duplas — use *itálico* ou 'aspas simples'
### E. NUNCA responda fora do escopo do Amei
> *'Sou o assistente do suporte do sistema Amei, então só consigo te ajudar com dúvidas sobre a plataforma. Tem alguma questão sobre o Amei que eu possa te ajudar?'*

---

## 1) Persona e tom
- **Cordial e profissional**
- **Empática** — entenda que problemas travam atendimento
- **Suave** — nunca pareça interrogatório
- **Objetiva** — textos curtos, passo a passo numerado
- Evite *'show!', 'beleza!'*. Prefira: *'Perfeito', 'Entendi', 'Certo', 'Tranquilo'*

---

## 2) 🧠 MEMÓRIA DE CONTEXTO

Você TEM acesso ao histórico completo da conversa. Use ativamente:
- ✅ Lembre tudo que foi dito antes
- ✅ Não repita perguntas já respondidas
- ✅ Acompanhe mudanças de tópico
- ✅ *'me dá mais detalhes', 'e isso?'* refere-se ao **último assunto**
- ❌ NUNCA misture contextos

### 🟡 AMBIGUIDADE — REGRA CRÍTICA

Se o usuário fizer pergunta vaga (*'e depois?', 'me dá mais detalhes'*) E houver MÚLTIPLOS TEMAS abertos na conversa, **PERGUNTE DE QUAL TEMA** antes de responder:

```
Usuário: como funciona overbooking?
Você: [responde]
Usuário: como cadastro paciente?
Você: [responde]
Usuário: e depois?

✅ "Você quer continuar sobre cadastro de paciente ou sobre overbooking?"
❌ chutar um dos dois sem confirmar
❌ iniciar triagem do nada
```

Se houver **um único tema** sem ambiguidade, responda direto.

---

## 3) FLUXO GERAL
```
1. Usuário pergunta → BUSQUE na base
2a. Encontrou → responde + "Posso ajudar em mais algo?"
2b. NÃO encontrou → "Sobre isso eu não tenho informação aqui na minha base. Posso te encaminhar pra equipe resolver, tudo bem?"
3. Usuário pediu humano → vai pra TRIAGEM
```

---

## 4) 🎯 TRIAGEM PROGRESSIVA

### 4.0) ⛔ QUANDO NÃO ENTRAR EM TRIAGEM

**Triagem só pode iniciar por UM destes 4 motivos:**
1. ✅ Usuário pediu humano explicitamente
2. ✅ Você não achou na base + usuário aceitou encaminhar
3. ✅ Usuário disse que não conseguiu resolver
4. ✅ Usuário relatou problema técnico

**Se NENHUM ocorrer, NÃO inicie triagem.** Apenas responda a dúvida.

### 4.1) Princípios
- ⚡ **UMA pergunta por turno**
- 🤝 **Frase curta de empatia** antes (*'Entendi', 'Certo'*)
- 🧠 Use o que já foi dito, não pergunte de novo
- 🚫 Não insista — recusou? siga em frente

### 4.2) Estrutura (ordem obrigatória)
```
ETAPA 1 → Classificar (1 pergunta)
ETAPA 2-4 → Perguntas específicas da categoria (1 por turno)
ETAPA 5 → Pedir imagem (responder APENAS: intencao_imagem)
ETAPA 6 → Aviso "Vou te encaminhar agora..."
ETAPA 7 → Transferir (responder APENAS: intencao-operador)
```

### 4.3) ETAPA 1 — Classificação
Se ainda não descreveu: *'Pra te encaminhar melhor, me conta brevemente: o que está acontecendo?'*

Se já descreveu, pule essa pergunta.

### 4.4) Perguntas por categoria (UMA por turno)

#### 📘 Dúvida de uso
1. *'O que você está tentando fazer no sistema?'*
2. *'Em que ponto exatamente você travou?'*

#### 🔴 Erro no sistema
1. *'Em qual tela ou menu isso acontece?'*
2. *'O que você estava tentando fazer quando deu erro?'*
3. *'Apareceu alguma mensagem? Me escreve o que diz.'*

#### 👤 Paciente/agendamento
1. *'Qual o nome do paciente?'*
2. *'O que você tentou fazer (cadastrar, agendar, editar, cancelar)?'*
3. *'Em que ponto o sistema travou?'*

#### 💰 Financeiro/fiscal
1. *'É sobre faturamento, NF, cobrança ou outra coisa?'*
2. *'De que período estamos falando?'*
3. *'Me descreve brevemente o que aconteceu.'*

#### 🔐 Acesso
1. *'Qual usuário/login você está usando?'*
2. *'Aparece alguma mensagem? Me escreve o que diz.'*
3. *'Há quanto tempo não consegue acessar?'*

#### ❓ Outro
1. *'Me descreve com mais detalhes?'*
2. *'Quando isso começou?'*

### 4.5) ETAPA 5 — Imagem
Após perguntas, responda APENAS:
```
intencao_imagem
```

### 4.6) ETAPA 6 — Aviso
Após o usuário enviar (ou pular) a imagem:
> *'Perfeito, com isso já tenho tudo. Vou te encaminhar agora pra equipe resolver. Aguarda só um instante.'*

### 4.7) ETAPA 7 — Transferir
No próximo turno, responda APENAS:
```
intencao-operador
```

### 4.8) Atalhos
- Recusou pergunta → pule
- Já deu várias infos → pule perguntas respondidas
- Irritado/urgente → vá direto pro aviso + transfere
- Desistiu (*'esquece'*) → encerre + `intencao-encerrar`

---

## 5) Temas críticos
- **Sistema fora do ar** → busca *'plano de contingência'* na base
- **API DB Diagnósticos** → orienta lançar direto na plataforma do laboratório
- **Maquininha MaisTodos** → orienta contatar suporte da MaisTodos (NÃO transfere)

---

## 6) Horário humano (só se perguntarem)
- Seg-Sex: 07:00-22:00
- Sábado: 08:00-13:00
- Dom/feriados: sem atendimento

---

## 7) EXEMPLOS

### Exemplo 1 — Dúvida resolvida
```
Usuário: como libero overbooking?
Você: Para liberar grade de overbooking:
1. Acesse o menu Agenda
2. Selecione o profissional e a data
3. Clique em Configurar grade
4. Marque Overbooking permitido
5. Salve

Ficou claro? Posso ajudar em mais algo?

Usuário: consegui, obrigado
Você: intencao-encerrar
```

### Exemplo 2 — Fora de escopo
```
Usuário: quem é o presidente do Brasil?
Você: Sou o assistente do suporte do sistema Amei, então só consigo te ajudar com dúvidas sobre a plataforma. Tem alguma questão sobre o Amei que eu possa te ajudar?
```

### Exemplo 3 — Triagem completa
```
Usuário: quero falar com atendente
Você: Pra te encaminhar melhor, me conta brevemente: o que está acontecendo?

Usuário: deu erro ao salvar paciente
Você: Entendi. Em qual tela ou menu isso acontece?

Usuário: tela de cadastro
Você: Certo. O que você estava tentando fazer quando deu erro?

Usuário: cadastrando novo, cliquei salvar e deu erro
Você: Tranquilo. Apareceu alguma mensagem? Me escreve o que diz.

Usuário: erro 500
Você: intencao_imagem

Usuário: [envia ou pula]
Você: Perfeito, com isso já tenho tudo. Vou te encaminhar agora pra equipe resolver. Aguarda só um instante.

[próximo turno]
Você: intencao-operador
```

### Exemplo 4 — Ambiguidade
```
Usuário: como funciona overbooking?
Você: [responde]
Usuário: como cadastro paciente?
Você: [responde]
Usuário: e depois?
Você: Você quer continuar sobre cadastro de paciente ou sobre overbooking?
```

### Exemplo 5 — NÃO encontrado
```
Usuário: como emito nota fiscal?
Você: Sobre isso eu não tenho informação aqui na minha base. Posso te encaminhar pra equipe resolver, tudo bem?

Usuário: pode sim
Você: É sobre faturamento, NF, cobrança ou outra coisa?

[continua triagem...]
```

### Exemplo 6 — Irritado
```
Usuário: socorro, urgente, AGORA
Você: Entendi a urgência. Vou te encaminhar agora pra equipe resolver. Aguarda só um instante.

[próximo turno]
Você: intencao-operador
```

---

## 8) Checklist mental
1. Pergunta é sobre Amei? Se NÃO → redirecione
2. Achei na base? SIM → responda. NÃO → avise + ofereça transferência
3. Estou em triagem? UMA pergunta por turno, frase curta de empatia
4. Comandos sempre SOZINHOS, sem texto
5. Imagem só na ETAPA 5
6. Antes de `intencao-operador` → aviso primeiro
7. Aspas duplas? Troque por *itálico* ou 'aspas simples'
8. Mudou assunto? Acompanhe — não volte ao antigo
9. Pedi nome/CPF/CNPJ/e-mail? REMOVA, CRM tem
PROMPT_EOF

echo "✅ Prompt v5.1 criado"

# ============================================================
# 3. ConversationsStoreService — gerencia conversas em JSON
# ============================================================
cat > src/modules/ai-chat/conversations-store.service.ts << 'TS_EOF'
import { Injectable, Logger, OnModuleInit } from "@nestjs/common";
import * as fs from "fs";
import * as path from "path";

export interface ChatMessage {
  role: "user" | "assistant";
  content: string;
  timestamp: number;
  response_id?: string;
  intent?: string | null;
}

export interface Conversation {
  id: string;
  title: string;
  last_response_id: string | null;
  messages: ChatMessage[];
  status: "active" | "transferred" | "closed";
  created_at: number;
  updated_at: number;
}

@Injectable()
export class ConversationsStoreService implements OnModuleInit {
  private readonly logger = new Logger(ConversationsStoreService.name);
  private readonly filePath = path.resolve(process.cwd(), "data", "conversations.json");
  private cache: Record<string, Conversation> = {};

  onModuleInit() {
    this.load();
  }

  private load() {
    try {
      if (fs.existsSync(this.filePath)) {
        const raw = fs.readFileSync(this.filePath, "utf-8");
        this.cache = JSON.parse(raw);
        this.logger.log(`Carregadas ${Object.keys(this.cache).length} conversas`);
      } else {
        this.cache = {};
        this.persist();
      }
    } catch (e: any) {
      this.logger.error(`Erro ao carregar conversas: ${e.message}`);
      this.cache = {};
    }
  }

  private persist() {
    try {
      const dir = path.dirname(this.filePath);
      if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
      fs.writeFileSync(this.filePath, JSON.stringify(this.cache, null, 2));
    } catch (e: any) {
      this.logger.error(`Erro ao persistir: ${e.message}`);
    }
  }

  create(title?: string): Conversation {
    const id = `conv_${Date.now()}_${Math.random().toString(36).substring(2, 8)}`;
    const conv: Conversation = {
      id,
      title: title || `Conversa ${new Date().toLocaleString("pt-BR")}`,
      last_response_id: null,
      messages: [],
      status: "active",
      created_at: Date.now(),
      updated_at: Date.now(),
    };
    this.cache[id] = conv;
    this.persist();
    return conv;
  }

  get(id: string): Conversation | null {
    return this.cache[id] || null;
  }

  list(): Conversation[] {
    return Object.values(this.cache).sort((a, b) => b.updated_at - a.updated_at);
  }

  addMessage(id: string, message: ChatMessage, responseId?: string, intent?: string | null) {
    const conv = this.cache[id];
    if (!conv) throw new Error(`Conversa ${id} não encontrada`);

    conv.messages.push(message);
    if (responseId) conv.last_response_id = responseId;
    if (intent === "intencao-operador") conv.status = "transferred";
    if (intent === "intencao-encerrar") conv.status = "closed";
    conv.updated_at = Date.now();

    // Atualiza título com a primeira mensagem do usuário
    if (message.role === "user" && conv.messages.filter(m => m.role === "user").length === 1) {
      conv.title = message.content.length > 50
        ? message.content.substring(0, 50) + "..."
        : message.content;
    }

    this.persist();
  }

  delete(id: string): boolean {
    if (!this.cache[id]) return false;
    delete this.cache[id];
    this.persist();
    return true;
  }

  clear(): number {
    const count = Object.keys(this.cache).length;
    this.cache = {};
    this.persist();
    return count;
  }
}
TS_EOF

echo "✅ ConversationsStoreService criado"

# ============================================================
# 4. AiChatService — chama OpenAI com previous_response_id
# ============================================================
cat > src/modules/ai-chat/ai-chat.service.ts << 'TS_EOF'
import { Injectable, Logger, OnModuleInit, BadRequestException } from "@nestjs/common";
import OpenAI from "openai";
import * as fs from "fs";
import * as path from "path";
import { ConversationsStoreService } from "./conversations-store.service";

export interface ChatResponse {
  conversation_id: string;
  response: string;
  response_id: string;
  intent_detected: string | null;
  status: "active" | "transferred" | "closed";
}

@Injectable()
export class AiChatService implements OnModuleInit {
  private readonly logger = new Logger(AiChatService.name);
  private openai: OpenAI;
  private systemPrompt: string;
  private readonly model = "gpt-4o-mini"; // troque para gpt-5.1 quando disponível
  private readonly temperature = 0.2;

  constructor(private readonly store: ConversationsStoreService) {}

  onModuleInit() {
    this.openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
    const promptPath = path.resolve(__dirname, "prompts", "suporte-amei-v5.1.md");
    if (!fs.existsSync(promptPath)) {
      // Fallback caso esteja rodando do dist/
      const altPath = path.resolve(process.cwd(), "src/modules/ai-chat/prompts/suporte-amei-v5.1.md");
      this.systemPrompt = fs.readFileSync(altPath, "utf-8");
    } else {
      this.systemPrompt = fs.readFileSync(promptPath, "utf-8");
    }
    this.logger.log(`Prompt carregado: ${this.systemPrompt.length} chars`);
  }

  /**
   * Detecta intenção SE for resposta sozinha (sem outro texto)
   */
  private detectIntent(text: string): string | null {
    const trimmed = text.trim().toLowerCase();
    if (trimmed === "intencao_imagem") return "intencao_imagem";
    if (trimmed === "intencao-operador") return "intencao-operador";
    if (trimmed === "intencao-encerrar") return "intencao-encerrar";
    return null;
  }

  async sendMessage(conversationId: string, userMessage: string): Promise<ChatResponse> {
    const vectorStoreId = process.env.CONFLUENCE_VECTOR_STORE_ID;
    if (!vectorStoreId) {
      throw new BadRequestException(
        "CONFLUENCE_VECTOR_STORE_ID não configurado no .env"
      );
    }

    const conv = this.store.get(conversationId);
    if (!conv) {
      throw new BadRequestException(`Conversa ${conversationId} não encontrada`);
    }

    if (conv.status !== "active") {
      throw new BadRequestException(
        `Conversa está com status '${conv.status}'. Crie uma nova conversa.`
      );
    }

    // Salva mensagem do usuário
    this.store.addMessage(conversationId, {
      role: "user",
      content: userMessage,
      timestamp: Date.now(),
    });

    // Monta payload
    const payload: any = {
      model: this.model,
      instructions: this.systemPrompt,
      input: [{ role: "user", content: userMessage }],
      tools: [
        {
          type: "file_search",
          vector_store_ids: [vectorStoreId],
        },
      ],
      temperature: this.temperature,
    };

    // SÓ adiciona previous_response_id se existir (não enviar null/vazio)
    if (conv.last_response_id) {
      payload.previous_response_id = conv.last_response_id;
      this.logger.debug(`Usando previous_response_id: ${conv.last_response_id}`);
    } else {
      this.logger.debug(`Primeira mensagem da conversa ${conversationId} (sem previous_response_id)`);
    }

    let response: any;
    try {
      response = await this.openai.responses.create(payload);
    } catch (err: any) {
      this.logger.error(`Erro OpenAI: ${err.message}`);
      throw new BadRequestException(`Erro na OpenAI: ${err.message}`);
    }

    const responseText = response.output_text || "";
    const responseId = response.id;
    const intent = this.detectIntent(responseText);

    // Salva resposta
    this.store.addMessage(
      conversationId,
      {
        role: "assistant",
        content: responseText,
        timestamp: Date.now(),
        response_id: responseId,
        intent,
      },
      responseId,
      intent
    );

    const updatedConv = this.store.get(conversationId);

    return {
      conversation_id: conversationId,
      response: responseText,
      response_id: responseId,
      intent_detected: intent,
      status: updatedConv?.status || "active",
    };
  }
}
TS_EOF

echo "✅ AiChatService criado"

# ============================================================
# 5. AiChatController — endpoints REST
# ============================================================
cat > src/modules/ai-chat/ai-chat.controller.ts << 'TS_EOF'
import {
  Controller, Post, Get, Delete, Body, Param, BadRequestException,
} from "@nestjs/common";
import { AiChatService } from "./ai-chat.service";
import { ConversationsStoreService } from "./conversations-store.service";

@Controller("ai")
export class AiChatController {
  constructor(
    private readonly chatService: AiChatService,
    private readonly store: ConversationsStoreService,
  ) {}

  /**
   * Cria uma nova conversa (zera contexto)
   * POST /ai/conversations
   */
  @Post("conversations")
  createConversation(@Body() body: { title?: string }) {
    return this.store.create(body?.title);
  }

  /**
   * Lista todas as conversas
   * GET /ai/conversations
   */
  @Get("conversations")
  listConversations() {
    return this.store.list();
  }

  /**
   * Pega histórico de uma conversa
   * GET /ai/conversations/:id
   */
  @Get("conversations/:id")
  getConversation(@Param("id") id: string) {
    const conv = this.store.get(id);
    if (!conv) throw new BadRequestException(`Conversa ${id} não encontrada`);
    return conv;
  }

  /**
   * Apaga uma conversa
   * DELETE /ai/conversations/:id
   */
  @Delete("conversations/:id")
  deleteConversation(@Param("id") id: string) {
    const ok = this.store.delete(id);
    return { deleted: ok, id };
  }

  /**
   * Envia mensagem em uma conversa
   * POST /ai/chat
   */
  @Post("chat")
  async chat(@Body() body: { conversation_id: string; message: string }) {
    if (!body?.conversation_id) {
      throw new BadRequestException("conversation_id é obrigatório");
    }
    if (!body?.message?.trim()) {
      throw new BadRequestException("message é obrigatório");
    }
    return this.chatService.sendMessage(body.conversation_id, body.message);
  }

  /**
   * Apaga TODAS as conversas (cuidado!)
   * DELETE /ai/conversations
   */
  @Delete("conversations")
  clearAll() {
    const count = this.store.clear();
    return { cleared: count };
  }
}
TS_EOF

echo "✅ AiChatController criado"

# ============================================================
# 6. AiChatModule
# ============================================================
cat > src/modules/ai-chat/ai-chat.module.ts << 'TS_EOF'
import { Module } from "@nestjs/common";
import { AiChatController } from "./ai-chat.controller";
import { AiChatService } from "./ai-chat.service";
import { ConversationsStoreService } from "./conversations-store.service";

@Module({
  controllers: [AiChatController],
  providers: [AiChatService, ConversationsStoreService],
})
export class AiChatModule {}
TS_EOF

echo "✅ AiChatModule criado"

# ============================================================
# 7. Atualizar AppModule (adicionar AiChatModule)
# ============================================================
APP_MODULE="src/app.module.ts"
if grep -q "AiChatModule" "$APP_MODULE"; then
  echo "⏭️  AiChatModule já está no AppModule"
else
  # Adiciona import
  sed -i '/^import.*Module/a import { AiChatModule } from "./modules/ai-chat/ai-chat.module";' "$APP_MODULE"
  # Adiciona ao array imports
  sed -i 's/imports: \[/imports: [AiChatModule, /' "$APP_MODULE"
  echo "✅ AppModule atualizado"
fi

# ============================================================
# 8. Frontend HTML completo
# ============================================================
cat > public/chat.html << 'HTML_EOF'
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<title>🧪 Lab Chat IA — Suporte Amei</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root {
  --bg: #0f172a;
  --surface: #1e293b;
  --surface-2: #334155;
  --border: #475569;
  --text: #f1f5f9;
  --text-dim: #94a3b8;
  --accent: #3b82f6;
  --user: #3b82f6;
  --ai: #1e293b;
  --intent-image: #3b82f6;
  --intent-operator: #10b981;
  --intent-close: #6b7280;
}
* { box-sizing: border-box; margin: 0; padding: 0; }
body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
  background: var(--bg);
  color: var(--text);
  height: 100vh;
  overflow: hidden;
}
.app {
  display: grid;
  grid-template-columns: 280px 1fr;
  height: 100vh;
}

/* SIDEBAR */
.sidebar {
  background: var(--surface);
  border-right: 1px solid var(--border);
  display: flex;
  flex-direction: column;
  overflow: hidden;
}
.sidebar-header {
  padding: 16px;
  border-bottom: 1px solid var(--border);
}
.sidebar-header h1 {
  font-size: 16px;
  margin-bottom: 4px;
}
.sidebar-header p {
  font-size: 11px;
  color: var(--text-dim);
}
.btn-new {
  margin: 12px;
  padding: 10px;
  background: var(--accent);
  color: white;
  border: none;
  border-radius: 6px;
  cursor: pointer;
  font-size: 14px;
  font-weight: 500;
}
.btn-new:hover { opacity: 0.9; }
.conv-list {
  flex: 1;
  overflow-y: auto;
  padding: 0 8px;
}
.conv-item {
  padding: 10px 12px;
  margin-bottom: 4px;
  border-radius: 6px;
  cursor: pointer;
  font-size: 13px;
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 8px;
}
.conv-item:hover { background: var(--surface-2); }
.conv-item.active { background: var(--accent); }
.conv-item .title {
  flex: 1;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.conv-item .badge-status {
  font-size: 10px;
  padding: 2px 6px;
  border-radius: 4px;
  background: rgba(255,255,255,0.15);
}
.conv-item .badge-status.transferred { background: var(--intent-operator); }
.conv-item .badge-status.closed { background: var(--intent-close); }
.conv-item .btn-del {
  background: none;
  border: none;
  color: var(--text-dim);
  cursor: pointer;
  font-size: 14px;
  padding: 0 4px;
}
.conv-item .btn-del:hover { color: #ef4444; }
.sidebar-footer {
  padding: 12px;
  font-size: 11px;
  color: var(--text-dim);
  border-top: 1px solid var(--border);
}

/* CHAT */
.chat {
  display: flex;
  flex-direction: column;
  background: var(--bg);
  height: 100vh;
  overflow: hidden;
}
.chat-header {
  padding: 14px 20px;
  background: var(--surface);
  border-bottom: 1px solid var(--border);
  display: flex;
  justify-content: space-between;
  align-items: center;
}
.chat-header h2 {
  font-size: 15px;
  margin-bottom: 2px;
}
.chat-header p {
  font-size: 11px;
  color: var(--text-dim);
}
.status-pill {
  font-size: 11px;
  padding: 4px 8px;
  border-radius: 12px;
  background: var(--surface-2);
}
.status-pill.transferred { background: var(--intent-operator); }
.status-pill.closed { background: var(--intent-close); }

.messages {
  flex: 1;
  overflow-y: auto;
  padding: 20px;
  display: flex;
  flex-direction: column;
  gap: 12px;
}
.empty-state {
  margin: auto;
  text-align: center;
  color: var(--text-dim);
}
.empty-state h3 { margin-bottom: 8px; }

.msg {
  max-width: 75%;
  padding: 10px 14px;
  border-radius: 12px;
  font-size: 14px;
  line-height: 1.5;
  white-space: pre-wrap;
  word-wrap: break-word;
}
.msg.user {
  background: var(--user);
  color: white;
  align-self: flex-end;
  border-bottom-right-radius: 4px;
}
.msg.assistant {
  background: var(--ai);
  color: var(--text);
  align-self: flex-start;
  border-bottom-left-radius: 4px;
  border: 1px solid var(--border);
}
.msg-meta {
  font-size: 10px;
  color: var(--text-dim);
  margin-top: 4px;
  font-family: monospace;
  cursor: pointer;
}
.msg-meta:hover { color: var(--accent); }

.intent-badge {
  display: inline-block;
  padding: 6px 12px;
  border-radius: 8px;
  font-size: 13px;
  font-weight: 600;
  font-family: monospace;
  text-transform: uppercase;
  letter-spacing: 0.5px;
}
.intent-badge.imagem { background: var(--intent-image); color: white; }
.intent-badge.operador { background: var(--intent-operator); color: white; }
.intent-badge.encerrar { background: var(--intent-close); color: white; }

.system-banner {
  align-self: center;
  background: var(--surface);
  border: 1px solid var(--border);
  padding: 10px 16px;
  border-radius: 20px;
  font-size: 12px;
  color: var(--text-dim);
}

.input-area {
  padding: 16px 20px;
  background: var(--surface);
  border-top: 1px solid var(--border);
  display: flex;
  gap: 10px;
}
.input-area input {
  flex: 1;
  padding: 12px 14px;
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: 8px;
  color: var(--text);
  font-size: 14px;
}
.input-area input:focus {
  outline: none;
  border-color: var(--accent);
}
.input-area input:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}
.input-area button {
  padding: 12px 22px;
  background: var(--accent);
  color: white;
  border: none;
  border-radius: 8px;
  cursor: pointer;
  font-weight: 500;
}
.input-area button:hover { opacity: 0.9; }
.input-area button:disabled { opacity: 0.4; cursor: not-allowed; }

.loading {
  align-self: flex-start;
  color: var(--text-dim);
  font-style: italic;
  padding: 10px 14px;
}
.loading::after {
  content: '';
  animation: dots 1.5s infinite;
}
@keyframes dots {
  0%, 20% { content: '.'; }
  40% { content: '..'; }
  60%, 100% { content: '...'; }
}
</style>
</head>
<body>
<div class="app">
  <!-- SIDEBAR -->
  <aside class="sidebar">
    <div class="sidebar-header">
      <h1>🧪 Lab IA Amei</h1>
      <p>Teste contexto + intenções</p>
    </div>
    <button class="btn-new" onclick="newConversation()">+ Nova Conversa</button>
    <div class="conv-list" id="convList"></div>
    <div class="sidebar-footer">
      <div id="storeInfo">Carregando...</div>
    </div>
  </aside>

  <!-- CHAT -->
  <main class="chat">
    <div class="chat-header">
      <div>
        <h2 id="chatTitle">Selecione ou crie uma conversa</h2>
        <p id="chatSub">⬅ Use o botão "Nova Conversa" pra começar</p>
      </div>
      <div id="statusPill"></div>
    </div>
    <div class="messages" id="messages">
      <div class="empty-state">
        <h3>👋 Bem-vindo</h3>
        <p>Crie uma nova conversa pra começar a testar</p>
      </div>
    </div>
    <div class="input-area">
      <input type="text" id="messageInput" placeholder="Digite sua mensagem..." disabled
             onkeypress="if(event.key==='Enter') sendMessage()">
      <button id="sendBtn" onclick="sendMessage()" disabled>Enviar</button>
    </div>
  </main>
</div>

<script>
const API = ''; // mesma origem
let currentConv = null;
let conversations = [];

async function loadConversations() {
  try {
    const res = await fetch(API + '/ai/conversations');
    conversations = await res.json();
    renderList();
  } catch (e) {
    console.error(e);
  }
}

async function loadHealth() {
  try {
    const res = await fetch(API + '/rag/confluence/health');
    const data = await res.json();
    document.getElementById('storeInfo').innerHTML =
      `Vector Store: ${data.vectorStoreConfigured ? '✅' : '❌'}<br>` +
      `Páginas indexadas: ${data.registeredPages || 0}`;
  } catch (e) {
    document.getElementById('storeInfo').textContent = '❌ API offline';
  }
}

function renderList() {
  const list = document.getElementById('convList');
  if (conversations.length === 0) {
    list.innerHTML = '<div style="padding:12px;color:var(--text-dim);font-size:12px;text-align:center;">Nenhuma conversa ainda</div>';
    return;
  }
  list.innerHTML = conversations.map(c => `
    <div class="conv-item ${currentConv?.id === c.id ? 'active' : ''}" onclick="selectConv('${c.id}')">
      <span class="title">${escapeHtml(c.title)}</span>
      ${c.status !== 'active' ? `<span class="badge-status ${c.status}">${c.status === 'transferred' ? '👤' : '✓'}</span>` : ''}
      <button class="btn-del" onclick="event.stopPropagation();delConv('${c.id}')" title="Apagar">✕</button>
    </div>
  `).join('');
}

async function selectConv(id) {
  try {
    const res = await fetch(API + '/ai/conversations/' + id);
    currentConv = await res.json();
    renderChat();
    renderList();
  } catch (e) {
    alert('Erro ao carregar conversa');
  }
}

function renderChat() {
  if (!currentConv) return;
  document.getElementById('chatTitle').textContent = currentConv.title;
  document.getElementById('chatSub').textContent = `ID: ${currentConv.id}`;

  const status = currentConv.status;
  const pill = document.getElementById('statusPill');
  if (status === 'active') {
    pill.innerHTML = '<span class="status-pill">🟢 Ativa</span>';
  } else if (status === 'transferred') {
    pill.innerHTML = '<span class="status-pill transferred">👤 Transferida</span>';
  } else {
    pill.innerHTML = '<span class="status-pill closed">✓ Encerrada</span>';
  }

  const msgsEl = document.getElementById('messages');
  if (currentConv.messages.length === 0) {
    msgsEl.innerHTML = '<div class="empty-state"><h3>💬 Conversa vazia</h3><p>Digite uma mensagem pra começar</p></div>';
  } else {
    msgsEl.innerHTML = currentConv.messages.map(m => renderMessage(m)).join('');
  }

  // Banner de status final
  if (status === 'transferred') {
    msgsEl.innerHTML += '<div class="system-banner">👤 Conversa transferida pra equipe humana</div>';
  } else if (status === 'closed') {
    msgsEl.innerHTML += '<div class="system-banner">✓ Conversa encerrada pelo usuário</div>';
  }

  msgsEl.scrollTop = msgsEl.scrollHeight;

  const isActive = status === 'active';
  document.getElementById('messageInput').disabled = !isActive;
  document.getElementById('sendBtn').disabled = !isActive;
  if (isActive) document.getElementById('messageInput').focus();
}

function renderMessage(m) {
  if (m.role === 'user') {
    return `<div class="msg user">${escapeHtml(m.content)}</div>`;
  }
  // Assistant
  if (m.intent) {
    const cls = m.intent === 'intencao_imagem' ? 'imagem'
              : m.intent === 'intencao-operador' ? 'operador'
              : 'encerrar';
    const icon = m.intent === 'intencao_imagem' ? '📸'
               : m.intent === 'intencao-operador' ? '👤'
               : '✓';
    return `
      <div class="msg assistant">
        <span class="intent-badge ${cls}">${icon} ${m.intent}</span>
        <div class="msg-meta" onclick="copyId('${m.response_id}')" title="Clique pra copiar">📋 ${m.response_id || 'sem id'}</div>
      </div>`;
  }
  return `
    <div class="msg assistant">
      ${escapeHtml(m.content)}
      <div class="msg-meta" onclick="copyId('${m.response_id}')" title="Clique pra copiar">📋 ${m.response_id || 'sem id'}</div>
    </div>`;
}

async function sendMessage() {
  const input = document.getElementById('messageInput');
  const text = input.value.trim();
  if (!text || !currentConv) return;

  input.value = '';
  input.disabled = true;
  document.getElementById('sendBtn').disabled = true;

  // Adiciona user msg na UI
  const msgsEl = document.getElementById('messages');
  msgsEl.innerHTML += `<div class="msg user">${escapeHtml(text)}</div>`;
  msgsEl.innerHTML += '<div class="loading" id="loading">IA pensando</div>';
  msgsEl.scrollTop = msgsEl.scrollHeight;

  try {
    const res = await fetch(API + '/ai/chat', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ conversation_id: currentConv.id, message: text })
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.message || 'Erro');

    // Recarrega conversa completa pra ter tudo certinho
    await selectConv(currentConv.id);
    await loadConversations();
  } catch (e) {
    document.getElementById('loading')?.remove();
    msgsEl.innerHTML += `<div class="msg assistant" style="color:#ef4444">❌ Erro: ${escapeHtml(e.message)}</div>`;
    msgsEl.scrollTop = msgsEl.scrollHeight;
    input.disabled = false;
    document.getElementById('sendBtn').disabled = false;
  }
}

async function newConversation() {
  try {
    const res = await fetch(API + '/ai/conversations', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({})
    });
    const conv = await res.json();
    await loadConversations();
    selectConv(conv.id);
  } catch (e) {
    alert('Erro ao criar conversa');
  }
}

async function delConv(id) {
  if (!confirm('Apagar esta conversa?')) return;
  await fetch(API + '/ai/conversations/' + id, { method: 'DELETE' });
  if (currentConv?.id === id) {
    currentConv = null;
    document.getElementById('messages').innerHTML = '<div class="empty-state"><h3>👋</h3><p>Selecione uma conversa</p></div>';
    document.getElementById('chatTitle').textContent = 'Selecione uma conversa';
    document.getElementById('chatSub').textContent = '';
    document.getElementById('statusPill').innerHTML = '';
    document.getElementById('messageInput').disabled = true;
    document.getElementById('sendBtn').disabled = true;
  }
  await loadConversations();
}

function copyId(id) {
  if (!id) return;
  navigator.clipboard.writeText(id);
  alert('ID copiado: ' + id);
}

function escapeHtml(s) {
  if (!s) return '';
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

loadConversations();
loadHealth();
setInterval(loadHealth, 30000);
</script>
</body>
</html>
HTML_EOF

echo "✅ Frontend chat.html criado"

# ============================================================
# 9. .gitignore — não comitar conversations.json
# ============================================================
if ! grep -q "conversations.json" .gitignore 2>/dev/null; then
  echo "data/conversations.json" >> .gitignore
  echo "✅ .gitignore atualizado"
fi

echo ""
echo "🎉 PRONTO! Próximos passos:"
echo ""
echo "1. Para o Nest se estiver rodando (Ctrl+C no terminal dele)"
echo "2. Reinicia:  npm run start:dev"
echo "3. Aguarda aparecer 'Nest application successfully started'"
echo "4. Abre no navegador: https://SUA_URL_CODESPACES/chat.html"
echo "5. Clica em '+ Nova Conversa' e começa a testar"
echo ""
echo "📝 Endpoints novos:"
echo "  POST   /ai/conversations           — criar conversa"
echo "  GET    /ai/conversations           — listar conversas"
echo "  GET    /ai/conversations/:id       — ver conversa"
echo "  DELETE /ai/conversations/:id       — apagar conversa"
echo "  POST   /ai/chat                    — enviar mensagem"
echo ""
echo "💡 Dica: cada conversa nova = previous_response_id zerado"
echo "         Use isso pra testar contexto isolado!"
