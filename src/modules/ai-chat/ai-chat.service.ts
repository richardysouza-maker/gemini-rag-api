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
    const promptPath = path.resolve(__dirname, "prompts", "suporte-amei-v5.2.md");
    if (!fs.existsSync(promptPath)) {
      // Fallback caso esteja rodando do dist/
      const altPath = path.resolve(process.cwd(), "src/modules/ai-chat/prompts/suporte-amei-v5.2.md");
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
