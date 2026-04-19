#!/bin/bash
# update-space-ingest.sh — adiciona funcionalidade de indexar espaço inteiro
# Uso: bash update-space-ingest.sh

set -e

echo "🔧 Atualizando confluence.service.ts (adicionando listPagesInSpace)..."
cat > src/modules/confluence-rag/confluence.service.ts << 'ARQUIVO_FIM'
// src/modules/confluence-rag/confluence.service.ts
import { Injectable, Logger } from '@nestjs/common';

export interface ConfluencePageRaw {
  id: string;
  title: string;
  spaceId: string;
  status: string;
  parentId: string | null;
  version: {
    number: number;
    createdAt: string;
    message: string;
  };
  body: {
    storage: {
      representation: 'storage';
      value: string;
    };
  };
  _links: {
    base?: string;
    webui?: string;
  };
}

export interface ListPagesOptions {
  status?: 'current' | 'archived' | 'deleted' | 'draft' | 'trashed';
  limit?: number;
}

@Injectable()
export class ConfluenceService {
  private readonly logger = new Logger(ConfluenceService.name);

  private readonly baseUrl = process.env.CONFLUENCE_BASE_URL!;
  private readonly email = process.env.CONFLUENCE_EMAIL!;
  private readonly apiToken = process.env.CONFLUENCE_API_TOKEN!;

  constructor() {
    if (!this.baseUrl || !this.email || !this.apiToken) {
      this.logger.warn(
        'CONFLUENCE_BASE_URL, CONFLUENCE_EMAIL ou CONFLUENCE_API_TOKEN ausentes no .env',
      );
    }
  }

  private authHeader(): string {
    const auth = Buffer.from(`${this.email}:${this.apiToken}`).toString('base64');
    return `Basic ${auth}`;
  }

  async getPage(pageId: string): Promise<ConfluencePageRaw> {
    const url = `${this.baseUrl}/wiki/api/v2/pages/${pageId}?body-format=storage`;
    this.logger.log(`[Confluence] GET ${url}`);

    const res = await fetch(url, {
      method: 'GET',
      headers: {
        Authorization: this.authHeader(),
        Accept: 'application/json',
      },
    });

    if (!res.ok) {
      const body = await res.text();
      throw new Error(
        `Confluence API falhou: ${res.status} ${res.statusText} — ${body}`,
      );
    }

    const page = (await res.json()) as ConfluencePageRaw;

    this.logger.log(
      `[Confluence] Página "${page.title}" (v${page.version.number}, status=${page.status}) carregada`,
    );

    return page;
  }

  /**
   * Lista todas as páginas de um espaço, com paginação automática.
   * Já traz o body em formato storage — não precisa chamar getPage depois.
   */
  async listPagesInSpace(
    spaceId: string,
    options: ListPagesOptions = {},
  ): Promise<ConfluencePageRaw[]> {
    const status = options.status ?? 'current';
    const limit = options.limit ?? 250;

    const allPages: ConfluencePageRaw[] = [];
    let nextUrl: string | null =
      `${this.baseUrl}/wiki/api/v2/spaces/${spaceId}/pages?body-format=storage&status=${status}&limit=${limit}`;

    let pageCount = 0;

    while (nextUrl) {
      pageCount++;
      this.logger.log(`[Confluence] Listagem página ${pageCount}: GET ${nextUrl}`);

      const res = await fetch(nextUrl, {
        method: 'GET',
        headers: {
          Authorization: this.authHeader(),
          Accept: 'application/json',
        },
      });

      if (!res.ok) {
        const body = await res.text();
        throw new Error(
          `Confluence API falhou (listagem): ${res.status} ${res.statusText} — ${body}`,
        );
      }

      const data = (await res.json()) as {
        results: ConfluencePageRaw[];
        _links?: { next?: string; base?: string };
      };

      allPages.push(...(data.results ?? []));

      // O Confluence v2 retorna `_links.next` como caminho relativo.
      // Ex.: "/wiki/api/v2/spaces/xxx/pages?cursor=yyy&limit=250"
      const nextPath = data._links?.next;
      if (nextPath) {
        // Se já for URL absoluta, usa direto; senão prefixa baseUrl
        nextUrl = nextPath.startsWith('http')
          ? nextPath
          : `${this.baseUrl}${nextPath}`;
      } else {
        nextUrl = null;
      }
    }

    this.logger.log(
      `[Confluence] Listagem concluída: ${allPages.length} páginas no espaço ${spaceId} (status=${status})`,
    );

    return allPages;
  }
}
ARQUIVO_FIM

echo "🔧 Atualizando confluence-rag.service.ts (adicionando ingestSpace)..."
cat > src/modules/confluence-rag/confluence-rag.service.ts << 'ARQUIVO_FIM'
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
ARQUIVO_FIM

echo "🔧 Atualizando confluence-rag.controller.ts (adicionando rota ingest-space)..."
cat > src/modules/confluence-rag/confluence-rag.controller.ts << 'ARQUIVO_FIM'
// src/modules/confluence-rag/confluence-rag.controller.ts
import { Body, Controller, Param, Post } from '@nestjs/common';
import { ConfluenceRagService } from './confluence-rag.service';

@Controller('rag/confluence')
export class ConfluenceRagController {
  constructor(private readonly ragService: ConfluenceRagService) {}

  /**
   * Indexa uma única página.
   * POST /rag/confluence/ingest/:pageId
   */
  @Post('ingest/:pageId')
  async ingest(@Param('pageId') pageId: string) {
    return this.ragService.ingestPage(pageId);
  }

  /**
   * Indexa TODAS as páginas "current" de um espaço.
   * POST /rag/confluence/ingest-space/:spaceId
   */
  @Post('ingest-space/:spaceId')
  async ingestSpace(@Param('spaceId') spaceId: string) {
    return this.ragService.ingestSpace(spaceId);
  }

  /**
   * Faz uma pergunta usando o vector store configurado.
   * POST /rag/confluence/ask  { "question": "..." }
   */
  @Post('ask')
  async ask(@Body() body: { question: string }) {
    const answer = await this.ragService.ask(body.question);
    return { question: body.question, answer };
  }
}
ARQUIVO_FIM

echo ""
echo "✅ Atualização concluída!"
echo ""
echo "Próximos passos:"
echo "1. Se o Nest está rodando (npm run start:dev), ele vai recompilar sozinho."
echo "2. Rode a indexação do espaço IGF:"
echo ""
echo "   curl -X POST --max-time 600 http://localhost:3000/rag/confluence/ingest-space/1202913290"
echo ""
echo "3. Observe o log do Nest — vai mostrar [i/total] Processando \"Título da página\"..."
echo "4. No final, a resposta traz estatísticas: total, success, skipped, failed"
