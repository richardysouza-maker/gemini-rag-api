// src/modules/confluence-rag/confluence-rag.service.ts
import { Injectable, Logger } from '@nestjs/common';
import OpenAI, { toFile } from 'openai';
import { ConfluenceService, ConfluencePageRaw } from './confluence.service';
import { ConfluenceCleanerService } from './confluence-cleaner.service';
import { VectorStoreService } from '../ai/services/vector-store.service';

export interface IngestResult {
  pageId: string;
  title: string;
  vectorStoreId: string;
  vectorStoreFileId: string;
  markdownPreview: string;
  contentHash: string;
}

export interface PageIngestStatus {
  pageId: string;
  title: string;
  status: 'success' | 'skipped' | 'failed';
  reason?: string;
  vectorStoreFileId?: string;
}

export interface SpaceIngestResult {
  spaceId: string;
  vectorStoreId: string;
  total: number;
  success: number;
  skipped: number;
  failed: number;
  durationMs: number;
  results: PageIngestStatus[];
}

@Injectable()
export class ConfluenceRagService {
  private readonly logger = new Logger(ConfluenceRagService.name);
  private readonly openai: OpenAI;

  constructor(
    private readonly confluence: ConfluenceService,
    private readonly cleaner: ConfluenceCleanerService,
    private readonly vectorStore: VectorStoreService,
  ) {
    this.openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
  }

  /**
   * Indexa UMA página do Confluence pelo ID.
   */
  async ingestPage(pageId: string): Promise<IngestResult> {
    const page = await this.confluence.getPage(pageId);
    const result = await this.ingestFromRaw(page);
    if (!result) {
      throw new Error(
        `Página ${pageId} não foi indexada (muito curta ou status inválido).`,
      );
    }
    return result;
  }

  /**
   * Indexa o espaço INTEIRO do Confluence (todas as páginas "current"),
   * de forma sequencial (uma por vez).
   */
  async ingestSpace(spaceId: string): Promise<SpaceIngestResult> {
    const startedAt = Date.now();

    // 1) Resolver vector store ANTES do loop (evita criar vários se env vazio)
    const vectorStoreId = await this.resolveVectorStoreId();

    // 2) Buscar todas as páginas do espaço de uma vez (com body)
    const pages = await this.confluence.listPagesInSpace(spaceId, {
      status: 'current',
    });

    this.logger.log(
      `[RAG-Space] ${pages.length} páginas encontradas no espaço ${spaceId}`,
    );

    const results: PageIngestStatus[] = [];
    let success = 0;
    let skipped = 0;
    let failed = 0;

    for (let i = 0; i < pages.length; i++) {
      const page = pages[i];
      const progress = `[${i + 1}/${pages.length}]`;

      this.logger.log(
        `[RAG-Space] ${progress} Processando "${page.title}" (${page.id})`,
      );

      try {
        const result = await this.ingestFromRaw(page, vectorStoreId);

        if (!result) {
          skipped++;
          results.push({
            pageId: page.id,
            title: page.title,
            status: 'skipped',
            reason: 'conteúdo vazio ou status != current',
          });
          this.logger.warn(`[RAG-Space] ${progress} ⏭️  Pulada: "${page.title}"`);
        } else {
          success++;
          results.push({
            pageId: page.id,
            title: page.title,
            status: 'success',
            vectorStoreFileId: result.vectorStoreFileId,
          });
          this.logger.log(
            `[RAG-Space] ${progress} ✅ Indexada: "${page.title}"`,
          );
        }
      } catch (err: any) {
        failed++;
        const message = err?.message ?? String(err);
        results.push({
          pageId: page.id,
          title: page.title,
          status: 'failed',
          reason: message,
        });
        this.logger.error(
          `[RAG-Space] ${progress} ❌ Falhou: "${page.title}" — ${message}`,
        );
      }

      // Pequeno delay entre páginas pra não tomar rate limit do Confluence
      await new Promise((r) => setTimeout(r, 300));
    }

    const durationMs = Date.now() - startedAt;

    this.logger.log(
      `[RAG-Space] ✅ Concluído em ${(durationMs / 1000).toFixed(1)}s — ${success} OK, ${skipped} puladas, ${failed} falhas`,
    );

    return {
      spaceId,
      vectorStoreId,
      total: pages.length,
      success,
      skipped,
      failed,
      durationMs,
      results,
    };
  }

  async ask(question: string): Promise<string> {
    const vectorStoreId = process.env.CONFLUENCE_VECTOR_STORE_ID;
    if (!vectorStoreId) {
      throw new Error(
        'CONFLUENCE_VECTOR_STORE_ID não configurado — rode o ingest primeiro.',
      );
    }

    const instructions = `
Você é um assistente que responde APENAS com base nos documentos fornecidos no file_search.
Regras:
- Se a resposta não estiver nos documentos, diga claramente "Não encontrei essa informação na documentação."
- Sempre cite o título da página de onde veio a informação.
- Seja objetivo e técnico.
- Responda em português.
`.trim();

    const response = await this.openai.responses.create({
      model: 'gpt-4o-mini',
      instructions,
      input: question,
      tools: [
        {
          type: 'file_search',
          vector_store_ids: [vectorStoreId],
        },
      ],
    });

    return (response as any).output_text ?? JSON.stringify(response.output);
  }

  // ============ Métodos privados ============

  /**
   * Indexa uma página a partir do objeto bruto do Confluence.
   * Retorna null se a página foi "pulada" (conteúdo vazio, status inválido).
   */
  private async ingestFromRaw(
    page: ConfluencePageRaw,
    vectorStoreIdOverride?: string,
  ): Promise<IngestResult | null> {
    if (page.status !== 'current') {
      return null;
    }

    const cleaned = this.cleaner.clean(page);

    if (cleaned.markdown.length < 50) {
      return null;
    }

    const vectorStoreId = vectorStoreIdOverride ?? (await this.resolveVectorStoreId());

    const vectorStoreFileId = await this.uploadPageAsFile(
      vectorStoreId,
      cleaned.indexableText,
      `confluence_${cleaned.id}_v${cleaned.version}.md`,
    );

    return {
      pageId: cleaned.id,
      title: cleaned.title,
      vectorStoreId,
      vectorStoreFileId,
      markdownPreview: cleaned.markdown.substring(0, 500),
      contentHash: cleaned.contentHash,
    };
  }

  private async resolveVectorStoreId(): Promise<string> {
    let vectorStoreId = process.env.CONFLUENCE_VECTOR_STORE_ID;

    if (!vectorStoreId) {
      vectorStoreId = await this.vectorStore.createVectorStore('confluence-amei');
      this.logger.warn(
        `⚠️  Criado novo vector store. COLE ESTE ID NO SEU .env:\n\nCONFLUENCE_VECTOR_STORE_ID=${vectorStoreId}\n`,
      );
    }

    return vectorStoreId;
  }

  private async uploadPageAsFile(
    vectorStoreId: string,
    text: string,
    filename: string,
  ): Promise<string> {
    const buffer = Buffer.from(text, 'utf-8');

    const file = await this.openai.files.create({
      file: await toFile(buffer, filename),
      purpose: 'assistants',
    });

    await new Promise((r) => setTimeout(r, 500));

    const vectorFile = await this.openai.vectorStores.files.create(
      vectorStoreId,
      { file_id: file.id },
    );

    return vectorFile.id;
  }
}
