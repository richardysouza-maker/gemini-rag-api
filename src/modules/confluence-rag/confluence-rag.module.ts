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
