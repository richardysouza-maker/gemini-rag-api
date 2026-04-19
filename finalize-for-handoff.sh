#!/bin/bash
# finalize-for-handoff.sh — adiciona sync inteligente, auth e documentação
# Uso: bash finalize-for-handoff.sh

set -e

echo "📁 Criando pasta data (para JSON de registro)..."
mkdir -p data
touch data/.gitkeep

echo "🔧 Adicionando 'data/' ao .gitignore..."
if ! grep -q "^data/$" .gitignore 2>/dev/null; then
  echo "" >> .gitignore
  echo "# Estado runtime (registro de páginas indexadas)" >> .gitignore
  echo "data/*.json" >> .gitignore
fi

echo "📄 Criando IndexedPagesStoreService..."
cat > src/modules/confluence-rag/indexed-pages-store.service.ts << 'ARQUIVO_FIM'
// src/modules/confluence-rag/indexed-pages-store.service.ts
import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import * as fs from 'fs';
import * as path from 'path';

export interface IndexedPageEntry {
  pageId: string;
  title: string;
  spaceId: string;
  version: number;
  contentHash: string;
  vectorStoreFileId: string;
  openaiFileId?: string;
  indexedAt: string;
  url: string;
}

/**
 * Guarda o registro das páginas já indexadas em data/indexed-pages.json.
 * Serve como "memória" pra detectar mudanças (novo / atualizado / deletado).
 */
@Injectable()
export class IndexedPagesStore implements OnModuleInit {
  private readonly logger = new Logger(IndexedPagesStore.name);
  private readonly filePath = path.resolve('data', 'indexed-pages.json');
  private cache: Record<string, IndexedPageEntry> = {};

  async onModuleInit() {
    await this.loadFromDisk();
  }

  private async loadFromDisk(): Promise<void> {
    try {
      if (!fs.existsSync(this.filePath)) {
        fs.mkdirSync(path.dirname(this.filePath), { recursive: true });
        fs.writeFileSync(this.filePath, '{}', 'utf-8');
      }
      const raw = fs.readFileSync(this.filePath, 'utf-8');
      this.cache = raw ? JSON.parse(raw) : {};
      this.logger.log(
        `[Store] Carregadas ${Object.keys(this.cache).length} páginas do registro`,
      );
    } catch (err: any) {
      this.logger.error(`[Store] Falha ao carregar registro: ${err.message}`);
      this.cache = {};
    }
  }

  private async saveToDisk(): Promise<void> {
    try {
      fs.writeFileSync(
        this.filePath,
        JSON.stringify(this.cache, null, 2),
        'utf-8',
      );
    } catch (err: any) {
      this.logger.error(`[Store] Falha ao salvar: ${err.message}`);
    }
  }

  get(pageId: string): IndexedPageEntry | null {
    return this.cache[pageId] ?? null;
  }

  async upsert(entry: IndexedPageEntry): Promise<void> {
    this.cache[entry.pageId] = entry;
    await this.saveToDisk();
  }

  async delete(pageId: string): Promise<IndexedPageEntry | null> {
    const removed = this.cache[pageId] ?? null;
    delete this.cache[pageId];
    await this.saveToDisk();
    return removed;
  }

  listAll(): IndexedPageEntry[] {
    return Object.values(this.cache);
  }

  listBySpace(spaceId: string): IndexedPageEntry[] {
    return Object.values(this.cache).filter((e) => e.spaceId === spaceId);
  }

  size(): number {
    return Object.keys(this.cache).length;
  }
}
ARQUIVO_FIM

echo "📄 Criando Guard de autenticação por token..."
cat > src/modules/confluence-rag/api-token.guard.ts << 'ARQUIVO_FIM'
// src/modules/confluence-rag/api-token.guard.ts
import {
  CanActivate,
  ExecutionContext,
  Injectable,
  Logger,
  UnauthorizedException,
} from '@nestjs/common';

/**
 * Guard simples pra proteger endpoints que só devem ser chamados pela
 * CustomApps/automation. Valida header:
 *
 *   Authorization: Bearer <API_TOKEN>
 *
 * O token vem do env var API_TOKEN.
 *
 * Se API_TOKEN não estiver setado no .env, o guard DEIXA PASSAR (útil em dev).
 * Em produção SEMPRE configure API_TOKEN.
 */
@Injectable()
export class ApiTokenGuard implements CanActivate {
  private readonly logger = new Logger(ApiTokenGuard.name);

  canActivate(context: ExecutionContext): boolean {
    const expected = process.env.API_TOKEN;

    if (!expected) {
      this.logger.warn(
        '⚠️  API_TOKEN não configurado no .env — endpoint está ABERTO (ok em dev, PERIGOSO em prod)',
      );
      return true;
    }

    const req = context.switchToHttp().getRequest();
    const auth = req.headers['authorization'] ?? '';
    const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';

    if (token !== expected) {
      throw new UnauthorizedException(
        'Token inválido ou ausente. Envie header "Authorization: Bearer <token>".',
      );
    }

    return true;
  }
}
ARQUIVO_FIM

echo "🔧 Atualizando confluence-rag.service.ts (adicionando syncPage e syncSpace com upsert)..."
cat > src/modules/confluence-rag/confluence-rag.service.ts << 'ARQUIVO_FIM'
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
ARQUIVO_FIM

echo "🔧 Atualizando confluence-rag.controller.ts (endpoints sync + auth)..."
cat > src/modules/confluence-rag/confluence-rag.controller.ts << 'ARQUIVO_FIM'
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
ARQUIVO_FIM

echo "🔧 Atualizando confluence-rag.module.ts..."
cat > src/modules/confluence-rag/confluence-rag.module.ts << 'ARQUIVO_FIM'
// src/modules/confluence-rag/confluence-rag.module.ts
import { Module } from '@nestjs/common';
import { ConfluenceService } from './confluence.service';
import { ConfluenceCleanerService } from './confluence-cleaner.service';
import { ConfluenceRagService } from './confluence-rag.service';
import { ConfluenceRagController } from './confluence-rag.controller';
import { IndexedPagesStore } from './indexed-pages-store.service';
import { VectorStoreService } from '../ai/services/vector-store.service';

@Module({
  controllers: [ConfluenceRagController],
  providers: [
    ConfluenceService,
    ConfluenceCleanerService,
    ConfluenceRagService,
    IndexedPagesStore,
    VectorStoreService,
  ],
  exports: [ConfluenceRagService],
})
export class ConfluenceRagModule {}
ARQUIVO_FIM

echo "📝 Criando HANDOFF.md (documento pro time de CustomApps)..."
cat > HANDOFF.md << 'ARQUIVO_FIM'
# HANDOFF — RAG Confluence para CustomApps

> **Contexto:** este documento é destinado ao time de CustomApps.
> Ele explica o que precisa ser feito para colocar a solução em produção
> e automatizar a sincronização com o Confluence.

## 🎯 O que este projeto faz

É uma API em Node.js/NestJS que:

1. Busca páginas do Confluence Cloud (espaço IGF atualmente)
2. Limpa o HTML/storage format e converte para markdown
3. Indexa na OpenAI como vector store (RAG)
4. Responde perguntas via `file_search` usando GPT-4o-mini

A interface de perguntas já existe (HTML simples na raiz `/`).

---

## ✅ O que PRECISA ser feito (trabalho do time de CustomApps)

### 1. Deploy da aplicação Node.js

É uma app NestJS padrão. Qualquer plataforma que rode Node.js 20+ serve:
- Servidor interno Node.js / PM2
- Container Docker
- Kubernetes
- Railway / Fly.io / Render / AWS ECS / etc

**Requisitos de runtime:**
- Node.js 20 LTS ou superior
- Saída HTTP para:
  - `https://amorsaudesuporte.atlassian.net` (API do Confluence)
  - `https://api.openai.com` (OpenAI)
- Escrita em disco para a pasta `data/` (registro de páginas indexadas em JSON)
- Porta de entrada HTTP (padrão 3000) exposta publicamente ou via gateway interno

**Como rodar:**
```bash
npm ci
npm run build
npm run start:prod
```

### 2. Variáveis de ambiente necessárias

| Variável | Descrição | Obrigatória |
|---|---|---|
| `CONFLUENCE_BASE_URL` | URL base do Confluence (ex.: `https://amorsaudesuporte.atlassian.net`) | ✅ |
| `CONFLUENCE_EMAIL` | Email da conta de serviço Atlassian | ✅ |
| `CONFLUENCE_API_TOKEN` | API token do Atlassian | ✅ |
| `OPENAI_API_KEY` | Chave da OpenAI (conta da empresa) | ✅ |
| `CONFLUENCE_VECTOR_STORE_ID` | ID do vector store já criado | ✅ (após primeiro sync) |
| `API_TOKEN` | Token compartilhado pra autenticar chamadas automatizadas (gerem um token forte tipo UUID) | ✅ (obrigatório em prod) |
| `PORT` | Porta HTTP (default 3000) | ❌ |

⚠️ **Sem `API_TOKEN` os endpoints de sync ficam abertos.** Não subir em produção sem isso.

### 3. Configurar webhook no Confluence Cloud

No admin Atlassian (quem for admin do site):

**Eventos a escutar:**
- `page_created`
- `page_updated`
- `page_removed` (ou `page_restored` + `page_trashed`, depende da versão)

**Filtro recomendado:** só páginas do espaço **IGF** (spaceId: `1202913290`)

**Endpoint do webhook (NÃO é sua API direto — é a CustomApps):**
A CustomApps recebe o webhook primeiro, filtra/enriquece, e chama a API:

```
POST https://<URL_DA_API_EM_PRODUCAO>/rag/confluence/sync-page

Headers:
  Authorization: Bearer <API_TOKEN>
  Content-Type: application/json

Body:
  {
    "pageId": "<ID_DA_PAGINA_DO_EVENTO>",
    "eventType": "updated"  // ou "created" ou "removed"
  }
```

**Resposta (sucesso):**
```json
{
  "pageId": "1202913561",
  "title": "Núcleo de IA",
  "status": "updated",         // "new" | "updated" | "unchanged" | "removed" | "skipped" | "failed"
  "vectorStoreFileId": "file-..."
}
```

**Resposta (erro):**
HTTP 4xx/5xx com JSON de erro padrão NestJS.

### 4. Configurar job de reconciliação diário

Webhook pode falhar (API fora do ar, evento perdido, etc). Precisa de um job que "varre" o espaço inteiro 1x por dia e pega o que escapou.

**Agendamento sugerido:** todo dia às 03:00 BRT (hora de baixo tráfego).

**Chamada:**
```
POST https://<URL_DA_API_EM_PRODUCAO>/rag/confluence/sync-space/1202913290

Headers:
  Authorization: Bearer <API_TOKEN>
```

**Resposta:**
```json
{
  "spaceId": "1202913290",
  "vectorStoreId": "vs_...",
  "new": 2,
  "updated": 5,
  "unchanged": 40,
  "removed": 1,
  "skipped": 0,
  "failed": 0,
  "durationMs": 45000,
  "results": [...]
}
```

O job pode levar **vários minutos** dependendo do volume. Configurem timeout de pelo menos 10min.

---

## 🔐 Segurança

- **Token compartilhado**: gerem um `API_TOKEN` forte (UUID/random 32+ chars) e configurem nos dois lados (CustomApps e nas env vars da API).
- **HTTPS obrigatório** em produção — o token trafega no header.
- **Nunca loguem o valor do token** em logs de auditoria.
- **Rotação**: recomendado rotacionar a cada 6 meses ou se houver suspeita de vazamento.

---

## 🧪 Como testar depois do deploy

1. Testar saúde:
```bash
curl https://<URL>/rag/confluence/health
# → { "ok": true, "vectorStoreConfigured": true, "registeredPages": 4, "authProtected": true }
```

2. Testar auth (deve falhar sem token):
```bash
curl -X POST https://<URL>/rag/confluence/sync-page \
  -H "Content-Type: application/json" \
  -d '{"pageId":"1202913561"}'
# → 401 Unauthorized
```

3. Testar auth (deve funcionar com token):
```bash
curl -X POST https://<URL>/rag/confluence/sync-page \
  -H "Authorization: Bearer SEU_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"pageId":"1202913561","eventType":"updated"}'
# → { "status": "unchanged", ... }
```

4. Testar a pergunta (público):
```bash
curl -X POST https://<URL>/rag/confluence/ask \
  -H "Content-Type: application/json" \
  -d '{"question":"o que é o Núcleo de IA?"}'
# → resposta do RAG
```

---

## 📋 Endpoints — referência rápida

| Método | Rota | Auth | Descrição |
|---|---|---|---|
| GET | `/rag/confluence/health` | ❌ | Saúde do serviço |
| POST | `/rag/confluence/ask` | ❌ | Faz pergunta ao RAG |
| POST | `/rag/confluence/sync-page` | ✅ | Sincroniza uma página (webhook) |
| POST | `/rag/confluence/sync-space/:spaceId` | ✅ | Sincroniza espaço inteiro (cron) |
| POST | `/rag/confluence/ingest/:pageId` | ✅ | (Legado) Força reindex |
| POST | `/rag/confluence/ingest-space/:spaceId` | ✅ | (Legado) Força reindex do espaço |

---

## 💾 Persistência de estado

A aplicação grava em `data/indexed-pages.json` um registro das páginas já indexadas
(ID, version, hash do conteúdo, ID do arquivo na OpenAI). Isso permite detectar
mudanças sem chamar a OpenAI desnecessariamente.

**Importante:**
- Em deploys com disk efêmero (container recriado a cada deploy), **usar volume
  persistente** pra `data/` OU migrar pra banco de dados.
- Se o JSON for perdido, o próximo `sync-space` vai re-indexar tudo (não é
  catastrófico, mas gera custo extra de API da OpenAI).

**Sugestão de upgrade:** migrar pra Postgres/Redis quando volume crescer.

---

## 🆘 Dúvidas

Qualquer dúvida sobre o código, falar com **Richardy Souza**.
ARQUIVO_FIM

echo "📝 Atualizando README.md..."
cat > README.md << 'ARQUIVO_FIM'
# gemini-rag-api

> Sistema RAG (Retrieval-Augmented Generation) sobre o Confluence da Amor Saúde.
> Indexa páginas do Confluence no vector store da OpenAI e responde perguntas
> com base na documentação oficial da empresa.

## ✨ O que faz

- 📥 **Indexa** páginas do Confluence Cloud (espaço IGF)
- 🧹 **Limpa** o HTML/storage format do Confluence (macros, layouts, namespaces)
- 🧠 **Gera** embeddings via OpenAI, guardados em um vector store
- 💬 **Responde** perguntas usando GPT-4o-mini + `file_search`
- 🔄 **Sincroniza** automaticamente via webhook (upsert inteligente por hash)
- 🎨 **UI** pronta (chat HTML acessível na raiz)

## 🧱 Stack

- [NestJS 11](https://nestjs.com/) (Node.js 20+)
- [OpenAI SDK](https://github.com/openai/openai-node) — Responses API + Vector Stores + file_search
- [Confluence Cloud REST API v2](https://developer.atlassian.com/cloud/confluence/rest/v2/)
- [cheerio](https://cheerio.js.org/) + [turndown](https://github.com/mixmark-io/turndown) pra parsing HTML → Markdown

## 🚀 Setup local

### Pré-requisitos
- Node.js 20+ (`node -v`)
- Credenciais:
  - API token do Confluence Cloud
  - API key da OpenAI

### Instalação
```bash
git clone https://github.com/richardysouza-maker/gemini-rag-api.git
cd gemini-rag-api
npm install
```

### Configuração
Copie `.env.example` para `.env` e preencha:

```env
CONFLUENCE_BASE_URL=https://amorsaudesuporte.atlassian.net
CONFLUENCE_EMAIL=seu-email@amorsaude.com.br
CONFLUENCE_API_TOKEN=atatt3x...
OPENAI_API_KEY=sk-...
CONFLUENCE_VECTOR_STORE_ID=     # deixe vazio na primeira execução
API_TOKEN=                       # só obrigatório em produção
```

### Rodar
```bash
npm run start:dev
```

Abra `http://localhost:3000` pra ver o chat.

### Primeiro uso (indexar)
```bash
# Indexa o espaço IGF inteiro
curl -X POST http://localhost:3000/rag/confluence/sync-space/1202913290

# Copie o vectorStoreId do log e cole no .env
# Reinicie o Nest
```

### Perguntar
```bash
curl -X POST http://localhost:3000/rag/confluence/ask \
  -H "Content-Type: application/json" \
  -d '{"question":"como funciona o agendamento de atendimento?"}'
```

## 🗺️ Arquitetura

```
┌─────────────┐   webhook   ┌──────────────┐   HTTP    ┌─────────────────┐
│  Confluence ├────────────▶│  CustomApps  ├──────────▶│ gemini-rag-api  │
│   (Cloud)   │             │ (orquestra)  │  POST     │   (NestJS)      │
└─────────────┘             └──────────────┘ /sync-... └────────┬────────┘
                                                                │
                                                                │ upload + query
                                                                ▼
                                                         ┌────────────────┐
                                                         │  OpenAI API    │
                                                         │  • files       │
                                                         │  • vector_stores│
                                                         │  • responses   │
                                                         └────────────────┘
```

**Fluxo de ingestão:**
1. Alguém edita uma página no Confluence
2. Atlassian dispara webhook → CustomApps recebe
3. CustomApps chama `POST /rag/confluence/sync-page` na nossa API
4. Nossa API busca a página, limpa, detecta se mudou (via hash), faz upsert no vector store
5. Registro local em `data/indexed-pages.json` é atualizado

**Fluxo de consulta:**
1. Usuário faz pergunta no chat web
2. Frontend chama `POST /rag/confluence/ask`
3. OpenAI Responses API + `file_search` buscam contexto relevante no vector store
4. GPT-4o-mini gera resposta fundamentada na documentação

## 📂 Estrutura

```
src/
├── modules/
│   ├── ai/services/
│   │   └── vector-store.service.ts       # integração com OpenAI vector stores
│   └── confluence-rag/
│       ├── confluence.service.ts         # cliente da API do Confluence
│       ├── confluence-cleaner.service.ts # storage format → markdown
│       ├── indexed-pages-store.service.ts # registro JSON local
│       ├── api-token.guard.ts            # auth por Bearer token
│       ├── confluence-rag.service.ts     # orquestrador (sync/upsert/ask)
│       ├── confluence-rag.controller.ts  # rotas HTTP
│       └── confluence-rag.module.ts
├── app.module.ts
└── main.ts

public/
└── index.html                             # frontend chat

data/
└── indexed-pages.json                     # registro runtime (gitignored)
```

## 🔌 API

### Públicos
- `GET  /rag/confluence/health` — status
- `POST /rag/confluence/ask` — pergunta

### Protegidos (Bearer `API_TOKEN`)
- `POST /rag/confluence/sync-page` — sincroniza uma página (chamado pelo webhook)
- `POST /rag/confluence/sync-space/:spaceId` — sincroniza espaço inteiro (reconciliação)
- `POST /rag/confluence/ingest/:pageId` — (legado) força reindex
- `POST /rag/confluence/ingest-space/:spaceId` — (legado) força reindex do espaço

Veja [`HANDOFF.md`](./HANDOFF.md) pra detalhes completos sobre payloads.

## ⚠️ Limitações conhecidas

- Arquivos binários (imagens, PDFs anexados) **não são indexados** (só o texto)
- Tabelas complexas podem perder formatação no markdown
- Páginas com permissões restritas que a conta de serviço não vê **não aparecem**
- JSON local não funciona bem em deploys com múltiplas réplicas (migrar pra banco)

## 🚢 Produção

Ver [`HANDOFF.md`](./HANDOFF.md) — documento direcionado ao time de
CustomApps/DevOps explicando deploy, configuração de webhook e cron.

## 📝 Licença

Projeto interno Amor Saúde.
ARQUIVO_FIM

echo "📝 Atualizando .env.example com API_TOKEN..."
cat > .env.example << 'ARQUIVO_FIM'
# Confluence Cloud
CONFLUENCE_BASE_URL=https://amorsaudesuporte.atlassian.net
CONFLUENCE_EMAIL=seu-email@amorsaude.com.br
CONFLUENCE_API_TOKEN=cole-seu-token-aqui

# OpenAI
OPENAI_API_KEY=sk-...

# Vector Store (deixe vazio na primeira execução)
CONFLUENCE_VECTOR_STORE_ID=

# Token compartilhado com a CustomApps pra autenticar chamadas de sync.
# Gere um valor forte (UUID ou random 32+ chars). Obrigatório em produção.
# Em dev pode deixar vazio.
API_TOKEN=

# Opcional: porta HTTP (default 3000)
# PORT=3000
ARQUIVO_FIM

echo ""
echo "✅ Handoff preparado!"
echo ""
echo "==============================================="
echo "📋 O QUE FOI ADICIONADO"
echo "==============================================="
echo ""
echo "Serviços novos:"
echo "  • IndexedPagesStore   → guarda registro em data/indexed-pages.json"
echo "  • ApiTokenGuard       → protege endpoints com Bearer token"
echo ""
echo "Métodos novos no ConfluenceRagService:"
echo "  • syncPage(pageId, eventType)   → upsert inteligente (new/updated/unchanged/removed)"
echo "  • syncSpace(spaceId)            → reconciliação com detecção de órfãos"
echo ""
echo "Endpoints novos:"
echo "  • POST /rag/confluence/sync-page         (auth)"
echo "  • POST /rag/confluence/sync-space/:id    (auth)"
echo ""
echo "Documentação:"
echo "  • HANDOFF.md  → doc pro time de CustomApps (deploy + webhooks + cron)"
echo "  • README.md   → doc técnica do projeto"
echo ""
echo "==============================================="
echo "🎯 PRÓXIMOS PASSOS"
echo "==============================================="
echo ""
echo "1. Gere um API_TOKEN forte (ex.: openssl rand -hex 32)"
echo "   Cole em API_TOKEN= no .env"
echo ""
echo "2. Aguarde o Nest recompilar (se já estiver rodando)"
echo ""
echo "3. Teste localmente:"
echo "   curl http://localhost:3000/rag/confluence/health"
echo ""
echo "4. Faça commit:"
echo "   git add ."
echo "   git commit -m 'feat: sync-page com upsert + auth + handoff'"
echo "   git push origin main"
echo ""
echo "5. Agende reunião com time de CustomApps e mande o link do repo"
echo "   + aponte pra HANDOFF.md"
