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
