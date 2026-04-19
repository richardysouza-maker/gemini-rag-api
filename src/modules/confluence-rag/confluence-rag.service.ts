// src/modules/confluence-rag/confluence-rag.service.ts
import { Injectable, Logger } from '@nestjs/common';
import OpenAI, { toFile } from 'openai';
import { ConfluenceService, ConfluencePageRaw } from './confluence.service';
import { ConfluenceCleanerService, CleanedPage } from './confluence-cleaner.service';
import { VectorStoreService } from '../ai/services/vector-store.service';
import { IndexedPagesStore, IndexedPageEntry } from './indexed-pages-store.service';

export type SyncEventType = 'created' | 'updated' | 'removed';
export type PageSyncStatus =
  | 'new'
  | 'updated'
  | 'unchanged'
  | 'removed'
  | 'skipped'
  | 'failed';

export interface PageSyncResult {
  pageId: string;
  title?: string;
  status: PageSyncStatus;
  reason?: string;
  vectorStoreFileId?: string;
}

export interface SpaceSyncResult {
  spaceId: string;
  vectorStoreId: string;
  new: number;
  updated: number;
  unchanged: number;
  removed: number;
  skipped: number;
  failed: number;
  durationMs: number;
  results: PageSyncResult[];
}

@Injectable()
export class ConfluenceRagService {
  private readonly logger = new Logger(ConfluenceRagService.name);
  private readonly openai: OpenAI;

  constructor(
    private readonly confluence: ConfluenceService,
    private readonly cleaner: ConfluenceCleanerService,
    private readonly vectorStore: VectorStoreService,
    private readonly store: IndexedPagesStore,
  ) {
    this.openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
  }

  // ==========================================================================
  // Endpoints públicos
  // ==========================================================================

  /**
   * (Legado) Indexa uma página do zero, ignorando registro.
   * Prefira syncPage pra uso em produção.
   */
  async ingestPage(pageId: string) {
    const result = await this.syncPage(pageId, 'updated');
    if (result.status === 'failed') {
      throw new Error(result.reason ?? 'Falha na indexação');
    }
    return result;
  }

  /**
   * (Legado) Indexa o espaço inteiro do zero.
   * Prefira syncSpace pra uso em produção.
   */
  async ingestSpace(spaceId: string) {
    return this.syncSpace(spaceId);
  }

  /**
   * Sincroniza UMA página. Chamado pelo webhook da CustomApps.
   *
   * - eventType = 'removed': deleta do vector store e do registro
   * - eventType = 'created' | 'updated': upsert inteligente
   *     - nunca indexada → NEW
   *     - hash inalterado → UNCHANGED (economiza API calls)
   *     - hash diferente → UPDATED (deleta arquivo antigo, sobe novo)
   */
  async syncPage(
    pageId: string,
    eventType: SyncEventType = 'updated',
  ): Promise<PageSyncResult> {
    try {
      if (eventType === 'removed') {
        return await this.handleRemove(pageId);
      }

      const page = await this.confluence.getPage(pageId);

      if (page.status !== 'current') {
        // Página arquivada/deletada no Confluence → trata como remove
        return await this.handleRemove(pageId);
      }

      return await this.handleUpsert(page);
    } catch (err: any) {
      const reason = err?.message ?? String(err);
      this.logger.error(`[Sync] Falha em ${pageId}: ${reason}`);
      return { pageId, status: 'failed', reason };
    }
  }

  /**
   * Sincroniza o ESPAÇO INTEIRO. Chamado pelo cron de reconciliação
   * (1x por dia, pra pegar o que o webhook porventura perdeu).
   */
  async syncSpace(spaceId: string): Promise<SpaceSyncResult> {
    const startedAt = Date.now();
    const vectorStoreId = await this.resolveVectorStoreId();

    const pages = await this.confluence.listPagesInSpace(spaceId, {
      status: 'current',
    });

    this.logger.log(
      `[Sync-Space] ${pages.length} páginas encontradas no Confluence`,
    );

    const results: PageSyncResult[] = [];
    let newCount = 0;
    let updatedCount = 0;
    let unchangedCount = 0;
    let skipped = 0;
    let failed = 0;

    // IDs vindos do Confluence AGORA
    const currentIds = new Set<string>();

    // 1) Processa cada página que veio do Confluence
    for (let i = 0; i < pages.length; i++) {
      const page = pages[i];
      currentIds.add(page.id);

      try {
        const result = await this.handleUpsert(page);
        results.push(result);

        switch (result.status) {
          case 'new':
            newCount++;
            break;
          case 'updated':
            updatedCount++;
            break;
          case 'unchanged':
            unchangedCount++;
            break;
          case 'skipped':
            skipped++;
            break;
          case 'failed':
            failed++;
            break;
        }

        this.logger.log(
          `[Sync-Space] [${i + 1}/${pages.length}] ${result.status.toUpperCase()}: "${page.title}"`,
        );
      } catch (err: any) {
        failed++;
        const reason = err?.message ?? String(err);
        results.push({
          pageId: page.id,
          title: page.title,
          status: 'failed',
          reason,
        });
        this.logger.error(`[Sync-Space] FAILED: "${page.title}" — ${reason}`);
      }

      await new Promise((r) => setTimeout(r, 200));
    }

    // 2) Detecta órfãos: páginas no registro do espaço que não voltaram do Confluence
    const registered = this.store.listBySpace(spaceId);
    const orphans = registered.filter((e) => !currentIds.has(e.pageId));

    let removed = 0;
    for (const orphan of orphans) {
      try {
        const r = await this.handleRemove(orphan.pageId);
        results.push(r);
        if (r.status === 'removed') removed++;
        this.logger.log(`[Sync-Space] REMOVED (orphan): "${orphan.title}"`);
      } catch (err: any) {
        failed++;
        this.logger.error(
          `[Sync-Space] Falha ao remover órfão ${orphan.pageId}: ${err.message}`,
        );
      }
    }

    const durationMs = Date.now() - startedAt;

    this.logger.log(
      `[Sync-Space] ✅ Concluído em ${(durationMs / 1000).toFixed(1)}s — ` +
        `new=${newCount} updated=${updatedCount} unchanged=${unchangedCount} ` +
        `removed=${removed} skipped=${skipped} failed=${failed}`,
    );

    return {
      spaceId,
      vectorStoreId,
      new: newCount,
      updated: updatedCount,
      unchanged: unchangedCount,
      removed,
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
        'CONFLUENCE_VECTOR_STORE_ID não configurado — rode o sync primeiro.',
      );
    }

    const instructions = `
Você é um assistente que responde APENAS com base nos documentos fornecidos no file_search.
Regras:
- Se a resposta não estiver nos documentos, diga "Não encontrei essa informação na documentação."
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

  // ==========================================================================
  // Lógica privada de upsert
  // ==========================================================================

  private async handleUpsert(page: ConfluencePageRaw): Promise<PageSyncResult> {
    const cleaned = this.cleaner.clean(page);

    if (cleaned.markdown.length < 50) {
      return {
        pageId: page.id,
        title: page.title,
        status: 'skipped',
        reason: 'conteúdo muito curto',
      };
    }

    const existing = this.store.get(page.id);

    // Nunca indexada → NEW
    if (!existing) {
      const fileId = await this.uploadToVectorStore(cleaned);
      await this.store.upsert({
        pageId: cleaned.id,
        title: cleaned.title,
        spaceId: cleaned.spaceId,
        version: cleaned.version,
        contentHash: cleaned.contentHash,
        vectorStoreFileId: fileId,
        indexedAt: new Date().toISOString(),
        url: cleaned.url,
      });
      return {
        pageId: cleaned.id,
        title: cleaned.title,
        status: 'new',
        vectorStoreFileId: fileId,
      };
    }

    // Hash idêntico → UNCHANGED (sem chamada à OpenAI, de graça)
    if (existing.contentHash === cleaned.contentHash) {
      return {
        pageId: cleaned.id,
        title: cleaned.title,
        status: 'unchanged',
      };
    }

    // Hash diferente → UPDATED: deleta arquivo antigo, sobe novo
    await this.safeDeleteVectorFile(existing.vectorStoreFileId);

    const fileId = await this.uploadToVectorStore(cleaned);
    await this.store.upsert({
      pageId: cleaned.id,
      title: cleaned.title,
      spaceId: cleaned.spaceId,
      version: cleaned.version,
      contentHash: cleaned.contentHash,
      vectorStoreFileId: fileId,
      indexedAt: new Date().toISOString(),
      url: cleaned.url,
    });

    return {
      pageId: cleaned.id,
      title: cleaned.title,
      status: 'updated',
      vectorStoreFileId: fileId,
    };
  }

  private async handleRemove(pageId: string): Promise<PageSyncResult> {
    const existing = this.store.get(pageId);
    if (!existing) {
      return {
        pageId,
        status: 'unchanged',
        reason: 'não estava registrada, nada a remover',
      };
    }

    await this.safeDeleteVectorFile(existing.vectorStoreFileId);
    await this.store.delete(pageId);

    return {
      pageId,
      title: existing.title,
      status: 'removed',
    };
  }

  private async uploadToVectorStore(cleaned: CleanedPage): Promise<string> {
    const vectorStoreId = await this.resolveVectorStoreId();

    const buffer = Buffer.from(cleaned.indexableText, 'utf-8');
    const file = await this.openai.files.create({
      file: await toFile(
        buffer,
        `confluence_${cleaned.id}_v${cleaned.version}.md`,
      ),
      purpose: 'assistants',
    });

    await new Promise((r) => setTimeout(r, 400));

    const vectorFile = await this.openai.vectorStores.files.create(
      vectorStoreId,
      { file_id: file.id },
    );

    return vectorFile.id;
  }

  private async safeDeleteVectorFile(vectorStoreFileId: string): Promise<void> {
    if (!vectorStoreFileId) return;

    const vectorStoreId = process.env.CONFLUENCE_VECTOR_STORE_ID;
    if (!vectorStoreId) return;

    try {
      await this.openai.vectorStores.files.delete(
        vectorStoreFileId,
        { vector_store_id: vectorStoreId } as any,
      );
    } catch (err: any) {
      this.logger.warn(
        `[Sync] Não consegui remover arquivo ${vectorStoreFileId} do vector store: ${err.message}`,
      );
    }
  }

  private async resolveVectorStoreId(): Promise<string> {
    let vectorStoreId = process.env.CONFLUENCE_VECTOR_STORE_ID;
    if (!vectorStoreId) {
      vectorStoreId = await this.vectorStore.createVectorStore('confluence-amei');
      this.logger.warn(
        `⚠️  Criado novo vector store. Cole no .env:\nCONFLUENCE_VECTOR_STORE_ID=${vectorStoreId}`,
      );
    }
    return vectorStoreId;
  }
}
