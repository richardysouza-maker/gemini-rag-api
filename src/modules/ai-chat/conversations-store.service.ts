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
