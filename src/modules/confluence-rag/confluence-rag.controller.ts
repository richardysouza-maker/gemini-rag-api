// src/modules/confluence-rag/confluence-rag.controller.ts
import { Body, Controller, Get, Param, Post } from '@nestjs/common';
import { ConfluenceRagService } from './confluence-rag.service';

@Controller('rag/confluence')
export class ConfluenceRagController {
  constructor(private readonly ragService: ConfluenceRagService) {}

  @Get('health')
  health() {
    return {
      ok: true,
      vectorStoreConfigured: !!process.env.CONFLUENCE_VECTOR_STORE_ID,
    };
  }

  @Post('ingest/:pageId')
  async ingest(@Param('pageId') pageId: string) {
    return this.ragService.ingestPage(pageId);
  }

  @Post('ingest-space/:spaceId')
  async ingestSpace(@Param('spaceId') spaceId: string) {
    return this.ragService.ingestSpace(spaceId);
  }

  @Post('ask')
  async ask(@Body() body: { question: string }) {
    const answer = await this.ragService.ask(body.question);
    return { question: body.question, answer };
  }
}
