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
