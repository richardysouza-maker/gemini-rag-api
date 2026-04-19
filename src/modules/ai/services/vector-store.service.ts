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
