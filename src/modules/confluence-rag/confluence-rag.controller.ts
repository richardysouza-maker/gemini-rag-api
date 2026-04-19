// src/modules/confluence-rag/confluence-rag.controller.ts
import {
  Body,
  Controller,
  Get,
  Param,
  Post,
  UseGuards,
} from '@nestjs/common';
import { ConfluenceRagService, SyncEventType } from './confluence-rag.service';
import { ApiTokenGuard } from './api-token.guard';
import { IndexedPagesStore } from './indexed-pages-store.service';

@Controller('rag/confluence')
export class ConfluenceRagController {
  constructor(
    private readonly ragService: ConfluenceRagService,
    private readonly store: IndexedPagesStore,
  ) {}

  // ---- ROTAS PÚBLICAS (sem auth) ----

  @Get('health')
  health() {
    return {
      ok: true,
      vectorStoreConfigured: !!process.env.CONFLUENCE_VECTOR_STORE_ID,
      registeredPages: this.store.size(),
      authProtected: !!process.env.API_TOKEN,
    };
  }

  @Post('ask')
  async ask(@Body() body: { question: string }) {
    const answer = await this.ragService.ask(body.question);
    return { question: body.question, answer };
  }

  // ---- ROTAS PROTEGIDAS (exigem Authorization: Bearer <API_TOKEN>) ----

  /**
   * Sincroniza UMA página. É o endpoint que a CustomApps vai chamar
   * quando receber um webhook do Confluence.
   *
   * Body: { "pageId": "123", "eventType": "updated" }
   * eventType: "created" | "updated" | "removed"
   */
  @Post('sync-page')
  @UseGuards(ApiTokenGuard)
  async syncPage(
    @Body() body: { pageId: string; eventType?: SyncEventType },
  ) {
    const eventType = body.eventType ?? 'updated';
    return this.ragService.syncPage(body.pageId, eventType);
  }

  /**
   * Sincroniza o ESPAÇO INTEIRO (reconciliação).
   * Deve ser chamado 1x por dia via cron da CustomApps.
   */
  @Post('sync-space/:spaceId')
  @UseGuards(ApiTokenGuard)
  async syncSpace(@Param('spaceId') spaceId: string) {
    return this.ragService.syncSpace(spaceId);
  }

  // ---- ROTAS LEGADAS (mantidas pra compatibilidade do frontend atual) ----

  @Post('ingest/:pageId')
  @UseGuards(ApiTokenGuard)
  async ingest(@Param('pageId') pageId: string) {
    return this.ragService.ingestPage(pageId);
  }

  @Post('ingest-space/:spaceId')
  @UseGuards(ApiTokenGuard)
  async ingestSpace(@Param('spaceId') spaceId: string) {
    return this.ragService.ingestSpace(spaceId);
  }
}
