import { RenderedBook } from '../parser/BookTypes';
import { LibraryBook, ReaderSettings } from '../model/LibraryModels';
import { FileService } from './FileService';
import { ZipArchive } from '../parser/ZipReader';
import { TextCodec } from '../parser/Bytes';
import { renderTXT } from '../parser/TxtParser';
import { renderEPUB as renderEpubBook } from '../parser/EpubParser';
import { renderMarkdown } from '../parser/MarkdownRenderer';
import { renderFB2 } from '../parser/FB2Renderer';
import { renderRTF } from '../parser/RTFRenderer';
import { renderDOCX } from '../parser/DOCXRenderer';
import { renderMOBI } from '../parser/MobiParser';

export class RenderService {
  static render(book: LibraryBook, settings: ReaderSettings,
    imageLoader: ((relativePath: string) => Uint8Array | null) | null): RenderedBook {
    const format = book.format.toUpperCase();
    let rendered: RenderedBook;
    if (format === 'TXT') {
      rendered = renderTXT(FileService.readBytes(book.path), '');
    } else if (format === 'EPUB') {
      const zip = ZipArchive.open(FileService.readBytes(book.path));
      rendered = renderEpubBook(zip, settings.publisherStyles);
    } else if (format === 'MD') {
      const bytes = FileService.readBytes(book.path);
      rendered = renderMarkdown(TextCodec.decode(bytes), imageLoader);
    } else if (format === 'FB2') {
      const bytes = FileService.readBytes(book.path);
      rendered = renderFB2(TextCodec.decode(bytes));
    } else if (format === 'RTF') {
      rendered = renderRTF(FileService.readBytes(book.path));
    } else if (format === 'DOCX') {
      const zip = ZipArchive.open(FileService.readBytes(book.path));
      rendered = renderDOCX(zip);
    } else if (format === 'MOBI' || format === 'AZW' || format === 'AZW3') {
      rendered = renderMOBI(FileService.readBytes(book.path));
    } else {
      rendered = new RenderedBook();
      rendered.error = '暂不支持的格式：' + book.format;
      return rendered;
    }
    if (rendered.title.length === 0) {
      rendered.title = book.title;
    }
    return rendered;
  }

  static renderEPUB(zip: ZipArchive, publisherStyles: boolean): RenderedBook {
    return renderEpubBook(zip, publisherStyles);
  }
}
