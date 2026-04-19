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

    const $ = cheerio.load(storageHtml, { xmlMode: true });

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
