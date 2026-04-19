#!/bin/bash
# setup-rag.sh — cria toda a estrutura do módulo Confluence RAG
# Uso: bash setup-rag.sh

set -e

echo "🔧 Criando pastas..."
mkdir -p src/modules/confluence-rag
mkdir -p src/modules/ai/services

echo "📄 Criando vector-store.service.ts..."
cat > src/modules/ai/services/vector-store.service.ts << 'ARQUIVO_FIM'
// src/modules/ai/services/vector-store.service.ts
import { Injectable, Logger } from '@nestjs/common';
import OpenAI, { toFile } from 'openai';

@Injectable()
export class VectorStoreService {
  private openai: OpenAI;
  private readonly logger = new Logger(VectorStoreService.name);

  private readonly MAX_RETRIES = 3;
  private readonly INITIAL_RETRY_DELAY = 500;

  constructor() {
    this.openai = new OpenAI({
      apiKey: process.env.OPENAI_API_KEY,
    });
  }

  async deleteVectorStore(vectorStoreId: string) {
    await this.openai.vectorStores.delete(vectorStoreId);
  }

  async createVectorStore(name?: string): Promise<string> {
    const vectorStore = await this.openai.vectorStores.create({
      name: name || `knowledge_${Date.now()}`,
    });
    return vectorStore.id;
  }

  async waitForVectorStoreReady(vectorStoreId: string): Promise<void> {
    const pollInterval = 1000;
    const maxAttempts = 300;

    this.logger.debug(`Aguardando vector store ${vectorStoreId} ficar pronto`);

    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      const store: any = await this.openai.vectorStores.retrieve(vectorStoreId);
      const processing = store.file_counts?.processing ?? 0;
      const failed = store.file_counts?.failed ?? 0;

      if (processing === 0) {
        this.logger.debug(`Vector store pronto. Failed files: ${failed}`);
        return;
      }

      await new Promise((r) => setTimeout(r, pollInterval));
    }

    throw new Error('Timeout esperando vector store ficar pronto');
  }

  async uploadText(vectorStoreId: string, text: string): Promise<string> {
    const buffer = Buffer.from(text, 'utf-8');
    return this.uploadBuffer(vectorStoreId, buffer, `text_${Date.now()}.txt`);
  }

  private async uploadBuffer(
    vectorStoreId: string,
    buffer: Buffer,
    filename: string,
  ): Promise<string> {
    const file = await this.openai.files.create({
      file: await toFile(buffer, filename),
      purpose: 'assistants',
    });

    await new Promise((r) => setTimeout(r, 500));

    const vectorFile = await this.addFileToVectorStoreWithRetry(
      vectorStoreId,
      file.id,
    );

    this.logger.log(`[VectorStore] Upload concluído file=${file.id}`);
    return vectorFile.id;
  }

  private async addFileToVectorStoreWithRetry(
    vectorStoreId: string,
    fileId: string,
    attempt = 1,
  ): Promise<any> {
    try {
      return await this.openai.vectorStores.files.create(vectorStoreId, {
        file_id: fileId,
      });
    } catch (error: any) {
      if (attempt < this.MAX_RETRIES && error?.status === 404) {
        const delayMs = this.INITIAL_RETRY_DELAY * Math.pow(2, attempt - 1);
        this.logger.warn(`Arquivo ${fileId} ainda não pronto. Retry ${attempt}`);
        await new Promise((r) => setTimeout(r, delayMs));
        return this.addFileToVectorStoreWithRetry(vectorStoreId, fileId, attempt + 1);
      }
      throw error;
    }
  }
}
ARQUIVO_FIM

echo "📄 Criando confluence.service.ts..."
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

  async getPage(pageId: string): Promise<ConfluencePageRaw> {
    const url = `${this.baseUrl}/wiki/api/v2/pages/${pageId}?body-format=storage`;
    this.logger.log(`[Confluence] GET ${url}`);

    const auth = Buffer.from(`${this.email}:${this.apiToken}`).toString('base64');

    const res = await fetch(url, {
      method: 'GET',
      headers: {
        Authorization: `Basic ${auth}`,
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
}
ARQUIVO_FIM

echo "📄 Criando confluence-cleaner.service.ts..."
cat > src/modules/confluence-rag/confluence-cleaner.service.ts << 'ARQUIVO_FIM'
// src/modules/confluence-rag/confluence-cleaner.service.ts
import { Injectable, Logger } from '@nestjs/common';
import * as cheerio from 'cheerio';
import TurndownService from 'turndown';
import * as he from 'he';
import { createHash } from 'crypto';
import { ConfluencePageRaw } from './confluence.service';

export interface CleanedPage {
  id: string;
  title: string;
  spaceId: string;
  version: number;
  updatedAt: string;
  url: string;
  markdown: string;
  indexableText: string;
  contentHash: string;
}

@Injectable()
export class ConfluenceCleanerService {
  private readonly logger = new Logger(ConfluenceCleanerService.name);
  private readonly turndown: TurndownService;

  private readonly DROP_MACROS = new Set([
    'livesearch', 'toc', 'pagetree', 'children', 'attachments',
    'recently-updated', 'contentbylabel', 'gallery', 'profile', 'profile-picture',
  ]);

  private readonly UNWRAP_MACROS = new Set([
    'panel', 'info', 'note', 'warning', 'tip', 'expand',
    'details', 'column', 'section',
  ]);

  constructor() {
    this.turndown = new TurndownService({
      headingStyle: 'atx',
      codeBlockStyle: 'fenced',
      bulletListMarker: '-',
      emDelimiter: '_',
    });

    this.turndown.addRule('stripAtlassianNamespaces', {
      filter: (node) => {
        const name = node.nodeName.toLowerCase();
        return name.startsWith('ac:') || name.startsWith('ri:');
      },
      replacement: (content) => content,
    });
  }

  clean(page: ConfluencePageRaw): CleanedPage {
    const rawHtml = page?.body?.storage?.value ?? '';
    const markdown = this.storageToMarkdown(rawHtml);

    const base = page._links?.base ?? '';
    const webui = page._links?.webui ?? '';
    const url = base && webui ? `${base}${webui}` : webui || '';

    const indexableText =
      `# ${page.title}\n\n` +
      `> Fonte: ${url}\n` +
      `> Página ID: ${page.id} | Versão: ${page.version.number} | Atualizado em: ${page.version.createdAt}\n\n` +
      markdown.trim();

    const contentHash = createHash('sha256').update(indexableText).digest('hex');

    return {
      id: page.id,
      title: page.title,
      spaceId: page.spaceId,
      version: page.version.number,
      updatedAt: page.version.createdAt,
      url,
      markdown,
      indexableText,
      contentHash,
    };
  }

  private storageToMarkdown(storageHtml: string): string {
    if (!storageHtml) return '';

    const $ = cheerio.load(storageHtml, { xmlMode: true, decodeEntities: false });

    $('ac\\:structured-macro').each((_, el) => {
      const name = $(el).attr('ac:name') ?? '';
      if (this.DROP_MACROS.has(name)) {
        $(el).remove();
      }
    });

    $('ac\\:structured-macro').each((_, el) => {
      const name = $(el).attr('ac:name') ?? '';
      if (this.UNWRAP_MACROS.has(name)) {
        const body = $(el).find('ac\\:rich-text-body').first();
        const inner = body.length ? (body.html() ?? '') : '';
        const label =
          name === 'info' || name === 'note' || name === 'warning' || name === 'tip'
            ? `**[${name.toUpperCase()}]** `
            : '';
        $(el).replaceWith(`<div>${label}${inner}</div>`);
      }
    });

    $('ac\\:structured-macro').each((_, el) => {
      const body = $(el).find('ac\\:rich-text-body').first();
      const inner = body.length ? (body.html() ?? '') : $(el).text();
      $(el).replaceWith(`<div>${inner}</div>`);
    });

    $('ac\\:layout, ac\\:layout-section, ac\\:layout-cell').each((_, el) => {
      $(el).replaceWith(`<div>${$(el).html() ?? ''}</div>`);
    });

    $('ac\\:link').each((_, el) => {
      const pageRef = $(el).find('ri\\:page').attr('ri:content-title');
      const linkBody = $(el).find('ac\\:link-body').text().trim();
      const label = linkBody || pageRef || 'link';
      $(el).replaceWith(`<span>[${label}]</span>`);
    });

    $('ac\\:parameter').remove();

    $('ac\\:image').each((_, el) => {
      const alt = $(el).attr('ac:alt') ?? '';
      $(el).replaceWith(alt ? `[imagem: ${alt}]` : '');
    });

    $('*').each((_, el) => {
      if (el.type !== 'tag') return;
      const attrs = (el as any).attribs ?? {};
      for (const attr of Object.keys(attrs)) {
        if (
          attr === 'local-id' ||
          attr.startsWith('ac:') ||
          attr.startsWith('ri:') ||
          attr === 'data-layout' ||
          attr === 'data-local-id'
        ) {
          $(el).removeAttr(attr);
        }
      }
    });

    const cleanedHtml = he.decode($.html());
    const markdown = this.turndown.turndown(cleanedHtml);

    return markdown
      .replace(/\n{3,}/g, '\n\n')
      .replace(/[ \t]+\n/g, '\n')
      .trim();
  }
}
ARQUIVO_FIM

echo "📄 Criando confluence-rag.service.ts..."
cat > src/modules/confluence-rag/confluence-rag.service.ts << 'ARQUIVO_FIM'
// src/modules/confluence-rag/confluence-rag.service.ts
import { Injectable, Logger } from '@nestjs/common';
import OpenAI, { toFile } from 'openai';
import { ConfluenceService } from './confluence.service';
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

  async ingestPage(pageId: string): Promise<IngestResult> {
    const page = await this.confluence.getPage(pageId);

    if (page.status !== 'current') {
      throw new Error(
        `Página ${pageId} tem status "${page.status}" — só indexamos "current".`,
      );
    }

    const cleaned = this.cleaner.clean(page);

    if (cleaned.markdown.length < 50) {
      throw new Error(
        `Página ${pageId} tem conteúdo muito curto (${cleaned.markdown.length} chars) — não vale indexar.`,
      );
    }

    this.logger.log(
      `[RAG] Página "${cleaned.title}" limpa. Markdown: ${cleaned.markdown.length} chars, hash=${cleaned.contentHash.substring(0, 8)}`,
    );

    let vectorStoreId = process.env.CONFLUENCE_VECTOR_STORE_ID;

    if (!vectorStoreId) {
      vectorStoreId = await this.vectorStore.createVectorStore('confluence-amei');
      this.logger.warn(
        `⚠️  Criado novo vector store. COLE ESTE ID NO SEU .env:\n\nCONFLUENCE_VECTOR_STORE_ID=${vectorStoreId}\n`,
      );
    }

    const vectorStoreFileId = await this.uploadPageAsFile(
      vectorStoreId,
      cleaned.indexableText,
      `confluence_${cleaned.id}_v${cleaned.version}.md`,
    );

    await this.vectorStore.waitForVectorStoreReady(vectorStoreId);

    this.logger.log(
      `[RAG] ✅ Página ${pageId} indexada. file=${vectorStoreFileId} vectorStore=${vectorStoreId}`,
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

echo "📄 Criando confluence-rag.controller.ts..."
cat > src/modules/confluence-rag/confluence-rag.controller.ts << 'ARQUIVO_FIM'
// src/modules/confluence-rag/confluence-rag.controller.ts
import { Body, Controller, Param, Post } from '@nestjs/common';
import { ConfluenceRagService } from './confluence-rag.service';

@Controller('rag/confluence')
export class ConfluenceRagController {
  constructor(private readonly ragService: ConfluenceRagService) {}

  @Post('ingest/:pageId')
  async ingest(@Param('pageId') pageId: string) {
    return this.ragService.ingestPage(pageId);
  }

  @Post('ask')
  async ask(@Body() body: { question: string }) {
    const answer = await this.ragService.ask(body.question);
    return { question: body.question, answer };
  }
}
ARQUIVO_FIM

echo "📄 Criando confluence-rag.module.ts..."
cat > src/modules/confluence-rag/confluence-rag.module.ts << 'ARQUIVO_FIM'
// src/modules/confluence-rag/confluence-rag.module.ts
import { Module } from '@nestjs/common';
import { ConfluenceService } from './confluence.service';
import { ConfluenceCleanerService } from './confluence-cleaner.service';
import { ConfluenceRagService } from './confluence-rag.service';
import { ConfluenceRagController } from './confluence-rag.controller';
import { VectorStoreService } from '../ai/services/vector-store.service';

@Module({
  controllers: [ConfluenceRagController],
  providers: [
    ConfluenceService,
    ConfluenceCleanerService,
    ConfluenceRagService,
    VectorStoreService,
  ],
  exports: [ConfluenceRagService],
})
export class ConfluenceRagModule {}
ARQUIVO_FIM

echo "📄 Atualizando app.module.ts..."
cat > src/app.module.ts << 'ARQUIVO_FIM'
import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { AppController } from './app.controller';
import { AppService } from './app.service';
import { ConfluenceRagModule } from './modules/confluence-rag/confluence-rag.module';

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true }),
    ConfluenceRagModule,
  ],
  controllers: [AppController],
  providers: [AppService],
})
export class AppModule {}
ARQUIVO_FIM

echo "📄 Criando .env de exemplo..."
if [ ! -f .env ]; then
  cat > .env << 'ARQUIVO_FIM'
CONFLUENCE_BASE_URL=https://amorsaudesuporte.atlassian.net
CONFLUENCE_EMAIL=seu-email@amorsaude.com.br
CONFLUENCE_API_TOKEN=cole-seu-token-aqui
OPENAI_API_KEY=sk-...
CONFLUENCE_VECTOR_STORE_ID=
ARQUIVO_FIM
  echo "   ✅ .env criado — LEMBRE DE PREENCHER SUAS CREDENCIAIS"
else
  echo "   ⏭️  .env já existe, não vou sobrescrever"
fi

echo "📄 Garantindo .env no .gitignore..."
if ! grep -q "^\.env$" .gitignore 2>/dev/null; then
  echo ".env" >> .gitignore
fi

echo ""
echo "✅ Setup concluído!"
echo ""
echo "Próximos passos:"
echo "1. Preencha o arquivo .env com suas credenciais"
echo "2. Rode: npm run start:dev"
echo "3. Em outro terminal: curl -X POST http://localhost:3000/rag/confluence/ingest/1202913561"
