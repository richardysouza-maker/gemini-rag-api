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
