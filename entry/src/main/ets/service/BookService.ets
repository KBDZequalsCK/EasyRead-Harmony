import { ChapterLink, RenderedBook, RenderedComic, TextModel } from '../parser/BookTypes';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BookFormats, LibraryStore } from './LibraryStore';
import { LibraryBook, ReaderChapter, ReaderSettings } from '../model/LibraryModels';
import { AppPaths, FileService } from './FileService';
import { RenderService } from './RenderService';
import { ReaderDocument } from './ReaderDocument';
import { ZipArchive } from '../parser/ZipReader';
import { JsonCodec, JsonKind, JsonNode } from '../parser/ZenJson';
import { renderCBZ, comicChapters, imageSize } from '../parser/CbzParser';
import { HtmlText } from '../parser/HtmlText';

export class PreparedBook {
  kind: string = 'html';
  url: string = '';
  filePath: string = '';
  chapters: ReaderChapter[] = [];
  comic: RenderedComic | null = null;
  error: string = '';
  pageCount: number = 0;
  /** Fresh session settings handed to the cached reader page via the bridge. */
  configJson: string = '';
  /** Global progress range covered by the generated page. */
  windowBase: number = 0;
  windowSpan: number = 1;
  /** Offsets of the slice inside the cached body, for seamless window turns. */
  windowStart: number = 0;
  windowEnd: number = 0;
  /** True when the page document from the previous session was reused. */
  windowReused: boolean = false;
}

/**
 * A page document that contains only a slice of a long book. Laying out a
 * whole 3 MB novel as one multi-column page takes tens of seconds on the
 * tablet, so the reader asks for a window of roughly WINDOW_CHARS text
 * characters and only that slice is handed to the WebView.
 */
export class WindowDocument {
  url: string = '';
  configJson: string = '';
  windowBase: number = 0;
  windowSpan: number = 1;
  windowStart: number = 0;
  windowEnd: number = 0;
  error: string = '';
}

class RenderCacheMeta {
  key: string = '';
  title: string = '';
  author: string = '';
  /** Approximate number of body characters, used to size reader windows. */
  chars: number = 0;
  chapters: ReaderChapter[] = [];
}

class ComicSession {
  zip: ZipArchive;
  comic: RenderedComic;

  constructor(zip: ZipArchive, comic: RenderedComic) {
    this.zip = zip;
    this.comic = comic;
  }
}

export class ComicPageData {
  path: string = '';
  width: number = 0;
  height: number = 0;
  index: number = 0;
}

class CachedTextModel {
  key: string = '';
  model: TextModel | null = null;
}

class ImportCandidate {
  uri: string = '';
  fileName: string = '';
  format: string = '';
  size: number = 0;
  stem: string = '';
}

export class BookService {
  private static instance: BookService | null = null;
  /**
   * The text budget of one reader window. Big enough that a fast reader
   * crosses a window only every couple of dozen page turns, small enough
   * that switching between scrolling and paging re-lays out quickly on the
   * tablet's Chromium web view.
   */
  private static readonly WINDOW_CHARS: number = 14000;
  private comicSessions: Map<string, ComicSession> = new Map<string, ComicSession>();
  private modelCache: Map<string, CachedTextModel> = new Map<string, CachedTextModel>();
  private pdfPages: Map<string, number> = new Map<string, number>();
  private bodyBookId: string = '';
  private bodyHtml: string = '';
  private bodyCss: string = '';
  private bodyChars: number = 0;
  private bodyChapters: ReaderChapter[] = [];
  private bodyTagStarts: number[] = [];
  private bodyChapterEnds: number[] = [];
  private bodyChapterText: number[] = [];
  private bodyWindowable: boolean = false;

  static shared(): BookService {
    if (BookService.instance === null) {
      BookService.instance = new BookService();
    }
    return BookService.instance;
  }

  prepare(book: LibraryBook, settings: ReaderSettings): PreparedBook {
    const prepared = new PreparedBook();
    if (!FileService.exists(book.path)) {
      prepared.error = '书籍文件已不存在：' + book.path;
      return prepared;
    }
    const format = book.format.toUpperCase();
    if (format === 'PDF') {
      prepared.kind = 'pdf';
      prepared.filePath = book.path;
      return prepared;
    }
    if (format === 'CBZ') {
      try {
        const zip = ZipArchive.open(FileService.readBytes(book.path));
        const comic = renderCBZ(zip, book.title);
        if (comic.error.length > 0) {
          prepared.error = comic.error;
          return prepared;
        }
        this.comicSessions.set(book.id, new ComicSession(zip, comic));
        prepared.kind = 'comic';
        prepared.comic = comic;
        prepared.chapters = BookService.toReaderChapters(comicChapters(comic));
        prepared.pageCount = comic.pages.length;
        this.writeComicCover(book);
        return prepared;
      } catch (error) {
        prepared.error = '漫画打开失败：' + BookService.errorText(error);
        return prepared;
      }
    }

    const cached = this.loadRenderCache(book, settings);
    console.info('[ER] cache ' + (cached === null ? 'miss' : 'hit'));
    if (cached !== null) {
      const body = this.readCachedText(book.id + '/body.html');
      const css = this.readCachedText(book.id + '/style.css');
      console.info('[ER] cache body=' + body.length + ' css=' + css.length);
      if (body.length > 0) {
        prepared.kind = 'html';
        prepared.chapters = cached.chapters;
        if (cached.title.length > 0) {
          book.title = cached.title;
        }
        if (cached.author.length > 0) {
          book.author = cached.author;
        }
        this.useBody(book.id, body, css, cached.chapters, cached.chars);
        // After a cold start the app has no WebView to carry the laid-out
        // page over. Reopening the exact window that was on screen before
        // shutdown keeps the pagination identical, so the reader lands on the
        // same page as the saved screenshot instead of a window whose start
        // was recomputed from an approximate progress value.
        let window = this.reuseWindow(book, settings);
        if (window !== null) {
          prepared.windowReused = true;
          console.info('[ER] window reuse base=' + window.windowBase.toFixed(6) +
            ' span=' + window.windowSpan.toFixed(6));
        } else {
          window = this.buildWindow(book, settings, book.syncedPosition(), 'start',
            book.locatorText);
        }
        if (window.error.length === 0) {
          prepared.configJson = window.configJson;
          prepared.url = window.url;
          prepared.windowBase = window.windowBase;
          prepared.windowSpan = window.windowSpan;
          prepared.windowStart = window.windowStart;
          prepared.windowEnd = window.windowEnd;
          LibraryStore.shared().scheduleSave();
          return prepared;
        }
        console.info('[ER] cache window error=' + window.error);
      }
    }

    let rendered: RenderedBook;
    try {
      rendered = this.render(book, settings);
    } catch (error) {
      prepared.error = '解析失败：' + BookService.errorText(error);
      return prepared;
    }
    if (rendered.error.length > 0) {
      prepared.error = rendered.error;
      return prepared;
    }
    // Formats without a native heading hierarchy still need collapsible book
    // groups when the file is a collection; this only touches flat tables
    // that contain volume dividers or repeated per-book contents pages.
    HtmlText.normalizeChapterLevels(rendered.chapters,
      rendered.title.length > 0 ? rendered.title : book.title);
    if (rendered.html.trim().length === 0) {
      prepared.error = '这本书没有可显示的正文';
      return prepared;
    }
    prepared.kind = 'html';

    if (rendered.title.length > 0) {
      book.title = rendered.title;
    }
    if (rendered.author.length > 0) {
      book.author = rendered.author;
    }
    LibraryStore.shared().scheduleSave();

    const directory = AppPaths.readerCache() + '/' + book.id;
    FileService.ensureDir(directory);
    for (let i = 0; i < rendered.assets.length; i++) {
      const asset = rendered.assets[i];
      FileService.writeBytes(directory + '/' + asset.path, asset.bytes);
    }
    const bodyCss = rendered.css ? rendered.css : '';
    console.info('[ER] render html=' + rendered.html.length + ' css=' + bodyCss.length +
      ' chapters=' + rendered.chapters.length);
    FileService.writeTextAtomic(directory + '/body.html', rendered.html);
    FileService.writeTextAtomic(directory + '/style.css', bodyCss);
    const chars = rendered.textModel !== null ? rendered.textModel.totalLength : rendered.html.length;
    this.writeRenderCache(book, settings, rendered.chapters, chars);
    this.useBody(book.id, rendered.html, bodyCss,
      BookService.toReaderChapters(rendered.chapters), chars);

    prepared.chapters = BookService.toReaderChapters(rendered.chapters);
    const window = this.buildWindow(book, settings, book.syncedPosition(), 'start',
      book.locatorText);
    if (window.error.length > 0) {
      prepared.error = window.error;
      return prepared;
    }
    prepared.configJson = window.configJson;
    prepared.url = window.url;
    prepared.windowBase = window.windowBase;
    prepared.windowSpan = window.windowSpan;
    prepared.windowStart = window.windowStart;
    prepared.windowEnd = window.windowEnd;

    if (rendered.coverPath.length > 0) {
      this.writeCoverFromAssets(book, rendered);
    }
    this.storeModel(book, rendered.textModel);
    return prepared;
  }

  private static cacheKey(book: LibraryBook, settings: ReaderSettings): string {
    return ReaderDocument.CACHE_VERSION + '|' + book.format + '|' + book.size + '|' +
      FileService.mtimeMs(book.path) + '|' + (settings.publisherStyles ? '1' : '0');
  }

  /**
   * Reopens the exact HTML that was produced the last time this file was
   * parsed. Parsing an EPUB or MOBI takes far longer than reading a few files
   * from the app cache, so this is what makes reopening a book immediate.
   * Position, theme and typography are NOT part of the key; they are read from
   * the bridge when the page boots, so changing them never invalidates it.
   */
  private loadRenderCache(book: LibraryBook, settings: ReaderSettings): RenderCacheMeta | null {
    const directory = AppPaths.readerCache() + '/' + book.id;
    const bodyPath = directory + '/body.html';
    const metaPath = directory + '/meta.json';
    if (!FileService.exists(bodyPath) || !FileService.exists(metaPath)) {
      console.info('[ER] cache files body=' + FileService.exists(bodyPath) +
        ' meta=' + FileService.exists(metaPath));
      return null;
    }
    try {
      const root = JsonCodec.parse(FileService.readText(metaPath));
      const keyNode = root.get('key');
      const expected = BookService.cacheKey(book, settings);
      if (keyNode === null || keyNode.asString() !== expected) {
        console.info('[ER] cache key expected=' + expected + ' actual=' +
          (keyNode !== null ? keyNode.asString() : 'null'));
        return null;
      }
      const meta = new RenderCacheMeta();
      meta.key = expected;
      const titleNode = root.get('title');
      meta.title = titleNode !== null ? titleNode.asString() : '';
      const authorNode = root.get('author');
      meta.author = authorNode !== null ? authorNode.asString() : '';
      const charsNode = root.get('chars');
      meta.chars = charsNode !== null ? charsNode.asNumber(0) : 0;
      const list = root.get('chapters');
      if (list !== null && list.kind === JsonKind.ARRAY) {
        for (let i = 0; i < list.arrayValue.length; i++) {
          const node = list.arrayValue[i];
          const chapter = new ReaderChapter();
          const title = node.get('title');
          chapter.title = title !== null ? title.asString() : '';
          const progress = node.get('progress');
          chapter.progress = progress !== null ? progress.asNumber(0) : 0;
          const anchor = node.get('anchorId');
          chapter.anchorId = anchor !== null ? anchor.asString() : '';
          const locator = node.get('locatorText');
          chapter.locatorText = locator !== null ? locator.asString() : '';
          const level = node.get('level');
          chapter.level = level !== null ? level.asInt(0) : 0;
          const page = node.get('pageIndex');
          chapter.pageIndex = page !== null ? page.asInt(-1) : -1;
          meta.chapters.push(chapter);
        }
      }
      return meta;
    } catch (error) {
      console.info('[ER] cache read failed ' + BookService.errorText(error));
      return null;
    }
  }

  private writeRenderCache(book: LibraryBook, settings: ReaderSettings,
    chapters: ChapterLink[], chars: number): void {
    try {
      const root = JsonNode.object();
      root.set('key', JsonNode.string(BookService.cacheKey(book, settings)));
      root.set('title', JsonNode.string(book.title));
      root.set('author', JsonNode.string(book.author));
      root.set('chars', JsonNode.number(chars));
      const list = JsonNode.array();
      for (let i = 0; i < chapters.length; i++) {
        const node = JsonNode.object();
        node.set('title', JsonNode.string(chapters[i].title));
        node.set('progress', JsonNode.number(chapters[i].progress));
        node.set('anchorId', JsonNode.string(chapters[i].anchorId));
        node.set('locatorText', JsonNode.string(chapters[i].locatorText));
        node.set('level', JsonNode.number(chapters[i].level));
        node.set('pageIndex', JsonNode.number(chapters[i].pageIndex));
        list.arrayValue.push(node);
      }
      root.set('chapters', list);
      FileService.writeTextAtomic(AppPaths.readerCache() + '/' + book.id + '/meta.json',
        JsonCodec.stringify(root, false, false, false));
    } catch (error) {
      // A cache that cannot be written only costs a re-render next time.
    }
  }

  private render(book: LibraryBook, settings: ReaderSettings): RenderedBook {
    return RenderService.render(book, settings, (relativePath: string): Uint8Array | null => {
      const resolved = FileService.parent(book.path) + '/' + relativePath;
      if (!FileService.exists(resolved)) {
        return null;
      }
      return FileService.readBytes(resolved);
    });
  }

  private readCachedText(relative: string): string {
    const path = AppPaths.readerCache() + '/' + relative;
    if (!FileService.exists(path)) {
      return '';
    }
    try {
      // Read on this device build can hand back undefined for an empty file
      // (a MOBI without publisher CSS), so never pass it on unchecked.
      const text = FileService.readText(path);
      return text ? text : '';
    } catch (error) {
      return '';
    }
  }

  private useBody(bookId: string, body: string, css: string, chapters: ReaderChapter[],
    chars: number): void {
    this.bodyBookId = bookId;
    this.bodyHtml = body;
    this.bodyCss = css;
    this.bodyChars = chars > 0 ? chars : body.length;
    this.bodyChapters = chapters;
    this.bodyTagStarts = this.indexChapterTags(body, chapters);
    this.bodyWindowable = chapters.length > 0 && this.bodyTagStarts.length === chapters.length;
    this.bodyChapterEnds = [];
    this.bodyChapterText = [];
    if (this.bodyWindowable) {
      for (let i = 0; i < chapters.length; i++) {
        const start = this.bodyTagStarts[i];
        const end = i + 1 < chapters.length ? this.bodyTagStarts[i + 1] : body.length;
        this.bodyChapterEnds.push(end);
        this.bodyChapterText.push(BookService.textLength(body, start, end));
      }
    }
  }

  /**
   * Counts the characters a browser would render between two offsets of the
   * cached XHTML, skipping tags and collapsing entities to a single character.
   * It lets a window boundary fall inside a chapter while its share of the
   * whole-book progress is still interpolated exactly.
   */
  private static textLength(html: string, from: number, to: number): number {
    const end = Math.min(to, html.length);
    let count = 0;
    let inTag = false;
    for (let i = Math.max(0, from); i < end; i++) {
      const code = html.charCodeAt(i);
      if (inTag) {
        if (code === 62) {
          inTag = false;
        }
        continue;
      }
      if (code === 60) {
        inTag = true;
        continue;
      }
      if (code === 38) {
        const semi = html.indexOf(';', i + 1);
        if (semi > i && semi <= i + 10) {
          i = semi;
        }
      }
      count++;
    }
    return count;
  }

  /**
   * Finds the opening tag of every chapter so a window can be cut out of the
   * cached body without re-parsing the source format. If any anchor is missing
   * the call returns an empty list and the reader falls back to the whole book.
   */
  private indexChapterTags(body: string, chapters: ReaderChapter[]): number[] {
    const starts: number[] = [];
    let cursor = 0;
    for (let i = 0; i < chapters.length; i++) {
      const anchor = chapters[i].anchorId;
      if (anchor.length === 0) {
        return [];
      }
      const idAt = body.indexOf('id="' + anchor + '"', cursor);
      if (idAt < 0) {
        return [];
      }
      const tagAt = body.lastIndexOf('<', idAt);
      if (tagAt < cursor) {
        return [];
      }
      starts.push(tagAt);
      cursor = tagAt + 1;
    }
    return starts;
  }

  private chapterIndexAt(progress: number): number {
    const chapters = this.bodyChapters;
    let index = 0;
    for (let i = 0; i < chapters.length; i++) {
      if (chapters[i].progress <= progress + 0.000001) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }

  private chapterProgressEnd(index: number): number {
    return index + 1 < this.bodyChapters.length ? this.bodyChapters[index + 1].progress : 1;
  }

  private chapterIndexForOffset(offset: number): number {
    let index = 0;
    for (let i = 0; i < this.bodyTagStarts.length; i++) {
      if (this.bodyTagStarts[i] <= offset) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }

  /**
   * Whole-book progress of an arbitrary offset inside a chapter. Positions
   * between two chapter anchors are interpolated by visible characters, the
   * same quantity the reader script uses for its local progress, so a window
   * that ends mid-chapter still hands over to the next window seamlessly.
   */
  private progressAtOffset(chapter: number, offset: number): number {
    const chapters = this.bodyChapters;
    if (chapter < 0 || chapter >= chapters.length) {
      return 0;
    }
    const start = this.bodyTagStarts[chapter];
    const end = this.bodyChapterEnds[chapter];
    const total = this.bodyChapterText[chapter];
    const base = chapters[chapter].progress;
    const span = Math.max(0, this.chapterProgressEnd(chapter) - base);
    if (total <= 0 || end <= start) {
      return base;
    }
    const clampAt = Math.min(Math.max(offset, start), end);
    const used = BookService.textLength(this.bodyHtml, start, clampAt);
    return base + span * Math.min(1, used / total);
  }

  private offsetAtChapterFraction(chapter: number, fraction: number): number {
    const start = this.bodyTagStarts[chapter];
    const end = this.bodyChapterEnds[chapter];
    const clamped = Math.min(Math.max(fraction, 0), 1);
    return start + Math.floor((end - start) * clamped);
  }

  private targetOffsetInChapter(chapter: number, target: number): number {
    const base = this.bodyChapters[chapter].progress;
    const span = Math.max(0.000001, this.chapterProgressEnd(chapter) - base);
    return this.offsetAtChapterFraction(chapter, (target - base) / span);
  }

  /**
   * Moves a cut point back to a paragraph boundary (within a small distance)
   * so a window never starts or ends in the middle of a word.
   */
  private paragraphCut(offset: number, floor: number): number {
    const body = this.bodyHtml;
    const lowest = Math.max(floor, offset - 600);
    let cut = body.lastIndexOf('<p', offset);
    if (cut < lowest) {
      cut = body.lastIndexOf('<br', offset);
    }
    if (cut < lowest) {
      cut = body.lastIndexOf('</p', offset);
    }
    return cut >= lowest ? cut : offset;
  }

  /**
   * Walks backwards from `endOffset` until `budget` visible characters are
   * covered, cutting inside a chapter when needed. Returns the start offset.
   */
  private windowStartBefore(endChapter: number, endOffset: number, budget: number): number {
    let chapter = endChapter;
    let limit = endOffset;
    let remaining = budget;
    while (chapter >= 0) {
      const start = chapter === 0 ? 0 : this.bodyTagStarts[chapter];
      const used = BookService.textLength(this.bodyHtml, start, Math.max(start, limit));
      if (used >= remaining) {
        if (used - remaining <= 1) {
          return start;
        }
        const total = this.bodyChapterText[chapter];
        const ratio = (this.bodyChapterEnds[chapter] - start) / Math.max(1, total);
        let cut = start + Math.floor((used - remaining) * ratio);
        cut = this.paragraphCut(cut, start + 1);
        if (chapter === 0 && cut < this.bodyTagStarts[0]) {
          return 0;
        }
        return cut > start && cut < limit ? cut : start;
      }
      remaining -= used;
      chapter -= 1;
      if (chapter >= 0) {
        limit = this.bodyChapterEnds[chapter];
      }
    }
    return 0;
  }

  /**
   * Walks forward from `startOffset` until `budget` visible characters are
   * covered, cutting inside a chapter when needed. Returns the end offset.
   */
  private windowEndAfter(startChapter: number, startOffset: number, budget: number): number {
    const chapters = this.bodyChapters;
    let chapter = startChapter;
    let limit = startOffset;
    let remaining = budget;
    while (chapter < chapters.length) {
      const chapterStart = this.bodyTagStarts[chapter];
      const chapterEnd = this.bodyChapterEnds[chapter];
      const from = Math.max(limit, chapterStart);
      const used = BookService.textLength(this.bodyHtml, from, chapterEnd);
      if (used >= remaining) {
        if (used - remaining <= 1) {
          return chapterEnd;
        }
        const total = this.bodyChapterText[chapter];
        const ratio = (chapterEnd - chapterStart) / Math.max(1, total);
        let cut = from + Math.floor(remaining * ratio);
        cut = Math.min(chapterEnd, Math.max(from + 1, cut));
        cut = this.paragraphCut(cut, from + 1);
        if (cut <= from) {
          cut = Math.min(chapterEnd, from + 1);
        }
        return cut;
      }
      remaining -= used;
      chapter += 1;
      if (chapter < chapters.length) {
        limit = this.bodyTagStarts[chapter];
      }
    }
    return this.bodyHtml.length;
  }

  /**
   * Returns the page document written by the previous session when it still
   * matches the cached body and covers the saved position. A killed process
   * loses the laid-out WebView, so reloading the very same document is the
   * closest possible resume: same slice, same base/span, same page breaks,
   * and no window rebuild before the first frame.
   */
  private reuseWindow(book: LibraryBook, settings: ReaderSettings): WindowDocument | null {
    const directory = AppPaths.readerCache() + '/' + book.id;
    const metaPath = directory + '/window.meta';
    const indexPath = directory + '/index.html';
    if (!FileService.exists(metaPath) || !FileService.exists(indexPath)) {
      return null;
    }
    const parts = FileService.readText(metaPath).split('|');
    if (parts.length < 9 || parts[0] !== ReaderDocument.CACHE_VERSION || parts[1] !== book.id) {
      return null;
    }
    const base = Number(parts[2]);
    const span = Number(parts[3]);
    const start = Number(parts[4]);
    const end = Number(parts[5]);
    const size = Number(parts[6]);
    const bodyLength = Number(parts[7]);
    if (isNaN(base) || isNaN(span) || isNaN(start) || isNaN(end) ||
      isNaN(size) || isNaN(bodyLength)) {
      return null;
    }
    if (span <= 0 || size <= 0 || FileService.size(indexPath) !== size ||
      bodyLength !== this.bodyHtml.length) {
      return null;
    }
    const progress = book.syncedPosition();
    if (progress < base - 0.000001 || progress > base + span + 0.000001) {
      return null;
    }
    const result = new WindowDocument();
    result.url = 'file://' + indexPath + '?v=' + Date.now();
    result.configJson = ReaderDocument.configJson(book, settings, base, span,
      progress, book.locatorText);
    result.windowBase = base;
    result.windowSpan = span;
    result.windowStart = start;
    result.windowEnd = end;
    return result;
  }

  /**
   * Cuts a slice of roughly WINDOW_CHARS out of the cached body and writes it
   * as the page document the WebView will load. The cut may fall inside a
   * chapter, so the reader still opens a full window of pages even in books
   * with very long chapters, and never has to lay out the whole novel.
   */
  buildWindow(book: LibraryBook, settings: ReaderSettings, progress: number,
    direction: string, locator: string): WindowDocument {
    const result = new WindowDocument();
    if (this.bodyBookId !== book.id || this.bodyHtml.length === 0) {
      result.error = '正文缓存已失效，请重新打开这本书';
      return result;
    }
    const target = Math.min(Math.max(progress, 0), 1);
    const chapters = this.bodyChapters;
    if (!this.bodyWindowable || chapters.length === 0 ||
      this.bodyTagStarts.length !== chapters.length) {
      return this.writeSlice(book, settings, 0, this.bodyHtml.length, target, locator);
    }
    const budget = Math.max(4000, BookService.WINDOW_CHARS);
    let start = 0;
    let end = this.bodyHtml.length;
    if (direction === 'prev') {
      // A backward window keeps a little forward margin so the page the
      // reader came from is still there, and reaches back one budget.
      const last = this.chapterIndexAt(target);
      const anchor = this.targetOffsetInChapter(last, target);
      end = this.windowEndAfter(last, anchor, 3000);
      if (end <= this.bodyTagStarts[last]) {
        end = this.bodyChapterEnds[last];
      }
      start = this.windowStartBefore(this.chapterIndexForOffset(end), end, budget);
    } else {
      // Forward windows start exactly at the target paragraph, so a page turn
      // at the edge of a window continues without repeating the previous page.
      const first = this.chapterIndexAt(target);
      if (locator.length > 0 && Math.abs(target - chapters[first].progress) < 0.000001) {
        start = this.bodyTagStarts[first];
      } else {
        const anchor = this.targetOffsetInChapter(first, target);
        start = this.paragraphCut(anchor, first === 0 ? 0 : this.bodyTagStarts[first] + 1);
        if (start < (first === 0 ? 0 : this.bodyTagStarts[first])) {
          start = first === 0 ? 0 : this.bodyTagStarts[first];
        }
      }
      end = this.windowEndAfter(this.chapterIndexForOffset(start), start, budget);
    }
    if (end <= start) {
      const first = this.chapterIndexAt(target);
      start = first === 0 ? 0 : this.bodyTagStarts[first];
      end = this.bodyChapterEnds[first];
    }
    if (end <= start) {
      return this.writeSlice(book, settings, 0, this.bodyHtml.length, target, locator);
    }
    return this.writeSlice(book, settings, start, end, target, locator);
  }

  /**
   * Builds the neighbouring window from exact body offsets instead of a
   * progress value. The reader uses this when a page turn crosses a window
   * edge: the new document starts where the old one ended, so no text is
   * skipped or shown twice even though the char-to-progress mapping is only
   * an approximation.
   */
  buildWindowAtOffset(book: LibraryBook, settings: ReaderSettings, offset: number,
    direction: string, locator: string): WindowDocument {
    const result = new WindowDocument();
    if (this.bodyBookId !== book.id || this.bodyHtml.length === 0) {
      result.error = '正文缓存已失效，请重新打开这本书';
      return result;
    }
    const chapters = this.bodyChapters;
    if (!this.bodyWindowable || chapters.length === 0 ||
      this.bodyTagStarts.length !== chapters.length) {
      return this.writeSlice(book, settings, 0, this.bodyHtml.length, 0, locator);
    }
    const budget = Math.max(4000, BookService.WINDOW_CHARS);
    const edge = Math.min(Math.max(offset, 0), this.bodyHtml.length);
    let start = 0;
    let end = this.bodyHtml.length;
    let target = 0;
    if (direction === 'prev' && edge > 0) {
      end = edge;
      start = this.windowStartBefore(this.chapterIndexForOffset(end), end, budget);
      target = this.progressAtOffset(this.chapterIndexForOffset(end), end);
    } else {
      start = edge;
      end = this.windowEndAfter(this.chapterIndexForOffset(start), start, budget);
      target = this.startProgress(start);
    }
    if (end <= start) {
      return this.writeSlice(book, settings, 0, this.bodyHtml.length, 0, locator);
    }
    return this.writeSlice(book, settings, start, end, target, locator);
  }

  private startProgress(start: number): number {
    const firstChapterStart = this.bodyTagStarts[0];
    return start <= firstChapterStart ? 0 : this.progressAtOffset(this.chapterIndexForOffset(start), start);
  }

  private writeSlice(book: LibraryBook, settings: ReaderSettings, start: number, end: number,
    target: number, locator: string): WindowDocument {
    const base = start <= 0 ? 0 : this.startProgress(start);
    const endChapter = this.chapterIndexForOffset(end);
    const endProgress = end > this.bodyTagStarts[endChapter]
      ? this.progressAtOffset(endChapter, end)
      : this.bodyChapters[endChapter].progress;
    let span = Math.max(0.0001, Math.min(1, endProgress) - base);
    if (base + span > 1) {
      span = Math.max(0.0001, 1 - base);
    }
    const inside = target >= base - 0.000001 && target <= base + span + 0.000001;
    const localTarget = Math.min(Math.max(target, base), base + span);
    const slice = this.bodyHtml.substring(start, end);
    const keepLocator = inside && locator.length > 0 && slice.indexOf(locator) >= 0;
    return this.writeWindow(book, settings, base, span, localTarget,
      keepLocator ? locator : '', slice, start, end);
  }

  private writeWindow(book: LibraryBook, settings: ReaderSettings, base: number, span: number,
    targetProgress: number, targetLocator: string, bodySlice: string, startOffset: number,
    endOffset: number): WindowDocument {
    const result = new WindowDocument();
    try {
      const directory = AppPaths.readerCache() + '/' + book.id;
      FileService.ensureDir(directory);
      const document = ReaderDocument.build(book, bodySlice, this.bodyCss, settings,
        base, span, targetProgress, targetLocator);
      FileService.writeTextAtomic(directory + '/index.html', document);
      result.url = 'file://' + directory + '/index.html?v=' + Date.now();
      result.configJson = ReaderDocument.configJson(book, settings, base, span,
        targetProgress, targetLocator);
      result.windowBase = base;
      result.windowSpan = span;
      result.windowStart = startOffset;
      result.windowEnd = endOffset;
      // Remember which document is on disk. A cold start can then reload it
      // instead of rebuilding a window from an approximate progress value,
      // which used to shift the first page by a few paragraphs.
      FileService.writeTextAtomic(directory + '/window.meta',
        ReaderDocument.CACHE_VERSION + '|' + book.id + '|' + base + '|' + span + '|' +
        startOffset + '|' + endOffset + '|' + FileService.size(directory + '/index.html') + '|' +
        this.bodyHtml.length + '|' + Date.now());
    } catch (error) {
      result.error = '生成阅读页面失败：' + BookService.errorText(error);
    }
    return result;
  }
  private static toReaderChapters(links: ChapterLink[]): ReaderChapter[] {
    const chapters: ReaderChapter[] = [];
    for (let i = 0; i < links.length; i++) {
      const link = links[i];
      const chapter = new ReaderChapter();
      chapter.title = link.title;
      chapter.progress = link.progress;
      chapter.anchorId = link.anchorId;
      chapter.locatorText = link.locatorText;
      chapter.level = link.level;
      chapter.pageIndex = link.pageIndex;
      chapters.push(chapter);
    }
    return chapters;
  }

  private writeCoverFromAssets(book: LibraryBook, rendered: RenderedBook): void {
    for (let i = 0; i < rendered.assets.length; i++) {
      if (rendered.assets[i].path === rendered.coverPath) {
        const extension = BookService.extensionOf(rendered.coverPath);
        this.writeCover(book, rendered.assets[i].bytes, extension);
        return;
      }
    }
  }

  private writeCover(book: LibraryBook, bytes: Uint8Array, extension: string): void {
    if (bytes.length === 0) {
      return;
    }
    FileService.ensureDir(AppPaths.coverCache());
    const path = AppPaths.coverCache() + '/' + book.id + '.' + extension;
    FileService.writeBytes(path, bytes);
    book.coverPath = path;
    LibraryStore.shared().scheduleSave();
  }

  private writeComicCover(book: LibraryBook): void {
    try {
      const page = this.comicPage(book, 0);
      if (page !== null && page.path.length > 0) {
        book.coverPath = page.path;
        LibraryStore.shared().scheduleSave();
      }
    } catch (error) {
      // A missing first page must not stop the comic from opening.
    }
  }

  private static extensionOf(path: string): string {
    const extension = FileService.extension(path);
    return extension.length > 0 ? extension : 'jpg';
  }

  comicPage(book: LibraryBook, index: number): ComicPageData | null {
    const session = this.comicSessions.get(book.id);
    if (session === undefined) {
      return null;
    }
    if (index < 0 || index >= session.comic.pages.length) {
      return null;
    }
    const page = session.comic.pages[index];
    const extension = BookService.extensionOf(page.entryName);
    const directory = AppPaths.comicCache() + '/' + book.id;
    FileService.ensureDir(directory);
    const path = directory + '/' + ('00000' + index).slice(-5) + '.' + extension;
    const result = new ComicPageData();
    result.path = path;
    result.index = index;
    if (FileService.exists(path)) {
      if (page.width <= 0) {
        try {
          const cached = imageSize(FileService.readBytes(path));
          page.width = cached.width;
          page.height = cached.height;
        } catch (error) {
        }
      }
      result.width = page.width;
      result.height = page.height;
      return result;
    }
    const bytes = session.zip.read(page.entryName);
    if (bytes === null) {
      return null;
    }
    FileService.writeBytes(path, bytes);
    const size = imageSize(bytes);
    page.width = size.width;
    page.height = size.height;
    result.width = size.width;
    result.height = size.height;
    return result;
  }

  closeComic(bookId: string): void {
    this.comicSessions.delete(bookId);
  }

  setPdfPageCount(bookId: string, count: number): void {
    if (count > 0) {
      this.pdfPages.set(bookId, count);
      const book = LibraryStore.shared().find(bookId);
      if (book !== null && book.pageCount !== count) {
        book.pageCount = count;
        LibraryStore.shared().scheduleSave();
      }
    }
  }

  pdfPageCount(bookId: string): number {
    const count = this.pdfPages.get(bookId);
    if (count !== undefined) {
      return count;
    }
    const book = LibraryStore.shared().find(bookId);
    return book !== null ? book.pageCount : 0;
  }

  textModel(book: LibraryBook): TextModel | null {
    const key = book.path + '|' + FileService.size(book.path) + '|' + FileService.mtimeMs(book.path);
    const cached = this.modelCache.get(book.path);
    if (cached !== undefined && cached.key === key) {
      return cached.model;
    }
    let model: TextModel | null = null;
    try {
      const rendered = RenderService.render(book, new ReaderSettings(), null);
      model = rendered.textModel;
    } catch (error) {
      model = null;
    }
    const entry = new CachedTextModel();
    entry.key = key;
    entry.model = model;
    this.modelCache.set(book.path, entry);
    return model;
  }

  /**
   * Returns a text model only when this launch already parsed the book.
   * The reader uses it to show ZenReader's percentage without paying for a
   * second full parse just because the HTML body came from the disk cache.
   */
  peekTextModel(book: LibraryBook): TextModel | null {
    const key = book.path + '|' + FileService.size(book.path) + '|' + FileService.mtimeMs(book.path);
    const cached = this.modelCache.get(book.path);
    return cached !== undefined && cached.key === key ? cached.model : null;
  }

  private storeModel(book: LibraryBook, model: TextModel | null): void {
    if (model === null || model.totalLength <= 0) {
      return;
    }
    const key = book.path + '|' + FileService.size(book.path) + '|' + FileService.mtimeMs(book.path);
    const entry = new CachedTextModel();
    entry.key = key;
    entry.model = model;
    this.modelCache.set(book.path, entry);
  }

  importBooks(uris: string[], source: string): LibraryBook[] {
    const store = LibraryStore.shared();
    const imported: LibraryBook[] = [];
    const destinationDir = source === 'jianguoyun' ? AppPaths.cloudBooks() : AppPaths.localBooks();
    for (let i = 0; i < uris.length; i++) {
      const uri = uris[i];
      const fileName = FileService.uriFileName(uri);
      const extension = FileService.extension(fileName);
      const format = BookFormats.fromExtension(extension);
      if (format.length === 0) {
        continue;
      }
      let size = 0;
      try {
        const sourceFile = fs.openSync(uri, fs.OpenMode.READ_ONLY);
        size = fs.statSync(sourceFile.fd).size;
        fs.closeSync(sourceFile.fd);
      } catch (error) {
        size = 0;
      }
      const stem = fileName.lastIndexOf('.') > 0 ? fileName.substring(0, fileName.lastIndexOf('.')) : fileName;
      let duplicate = false;
      for (let b = 0; b < store.books.length; b++) {
        if (store.books[b].source === source && store.books[b].format === format &&
          store.books[b].title === stem && store.books[b].size === size) {
          duplicate = true;
          break;
        }
      }
      if (duplicate) {
        continue;
      }
      try {
        const copied = FileService.copyFromUri(uri, destinationDir, fileName);
        const book = new LibraryBook();
        book.id = LibraryStore.makeId();
        book.title = stem;
        book.format = format;
        book.path = copied;
        book.size = FileService.size(copied);
        book.source = source;
        book.addedAt = Date.now();
        store.add(book);
        imported.push(book);
        if (format === 'EPUB' || format === 'CBZ' || format === 'MOBI' ||
          format === 'AZW' || format === 'AZW3' || format === 'FB2') {
          this.extractCoverQuickly(book);
        }
      } catch (error) {
        // Skip this file; the picker can be used again.
      }
    }
    store.flush();
    return imported;
  }

  /**
   * Folder imports can contain dozens of books and hundreds of megabytes.
   * Copying and parsing them on the UI thread freezes the shelf for long
   * enough that the system kills the app, so this variant copies through the
   * asynchronous native file API and yields to the UI thread between books.
   */
  async importBooksAsync(uris: string[], source: string,
    onProgress: ((done: number, total: number, name: string) => void) | null): Promise<LibraryBook[]> {
    const store = LibraryStore.shared();
    const imported: LibraryBook[] = [];
    const destinationDir = source === 'jianguoyun' ? AppPaths.cloudBooks() : AppPaths.localBooks();
    const pending: ImportCandidate[] = [];
    for (let i = 0; i < uris.length; i++) {
      const candidate = this.prepareImport(uris[i]);
      if (candidate !== null) {
        pending.push(candidate);
      }
    }
    for (let i = 0; i < pending.length; i++) {
      const candidate = pending[i];
      if (onProgress !== null) {
        onProgress(i, pending.length, candidate.stem);
      }
      await BookService.yieldToUi();
      if (BookService.isDuplicate(candidate, source)) {
        continue;
      }
      try {
        const copied = await FileService.copyFromUriAsync(candidate.uri, destinationDir,
          candidate.fileName);
        const book = new LibraryBook();
        book.id = LibraryStore.makeId();
        book.title = candidate.stem;
        book.format = candidate.format;
        book.path = copied;
        book.size = FileService.size(copied);
        book.source = source;
        book.addedAt = Date.now();
        store.add(book);
        imported.push(book);
        await BookService.yieldToUi();
        if (candidate.format === 'EPUB' || candidate.format === 'CBZ' || candidate.format === 'MOBI' ||
          candidate.format === 'AZW' || candidate.format === 'AZW3' || candidate.format === 'FB2') {
          this.extractCoverQuickly(book);
        }
      } catch (error) {
        // Skip this file and keep importing the rest of the folder.
      }
    }
    if (onProgress !== null) {
      onProgress(pending.length, pending.length, '');
    }
    store.flush();
    return imported;
  }

  private prepareImport(uri: string): ImportCandidate | null {
    const fileName = FileService.uriFileName(uri);
    const extension = FileService.extension(fileName);
    const format = BookFormats.fromExtension(extension);
    if (format.length === 0) {
      return null;
    }
    let size = 0;
    try {
      const sourceFile = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      size = fs.statSync(sourceFile.fd).size;
      fs.closeSync(sourceFile.fd);
    } catch (error) {
      size = 0;
    }
    const candidate = new ImportCandidate();
    candidate.uri = uri;
    candidate.fileName = fileName;
    candidate.format = format;
    candidate.size = size;
    candidate.stem = fileName.lastIndexOf('.') > 0
      ? fileName.substring(0, fileName.lastIndexOf('.'))
      : fileName;
    return candidate;
  }

  private static isDuplicate(candidate: ImportCandidate, source: string): boolean {
    const books = LibraryStore.shared().books;
    const dot = candidate.fileName.lastIndexOf('.');
    const stem = dot > 0 ? candidate.fileName.substring(0, dot) : candidate.fileName;
    const suffix = dot > 0 ? candidate.fileName.substring(dot) : '';
    for (let i = 0; i < books.length; i++) {
      const book = books[i];
      if (book.source !== source || book.format !== candidate.format ||
        book.size !== candidate.size) {
        continue;
      }
      // The title is replaced by the embedded metadata after import, so the
      // file name is the stable identity. Timestamped copies from an earlier
      // import are matched as well.
      const existing = FileService.fileName(book.path);
      if (existing === candidate.fileName) {
        return true;
      }
      if (existing.startsWith(stem + '-') && existing.endsWith(suffix)) {
        return true;
      }
    }
    return false;
  }

  private static async yieldToUi(): Promise<void> {
    await new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, 0);
    });
  }

  private extractCoverQuickly(book: LibraryBook): void {
    if (book.size > 120 * 1024 * 1024) {
      // Huge comics/MOBI files get their cover when they are first opened;
      // reading them twice during import would make the picker feel stuck.
      return;
    }
    try {
      if (book.format === 'CBZ') {
        const zip = ZipArchive.open(FileService.readBytes(book.path));
        const comic = renderCBZ(zip, book.title);
        if (comic.pages.length > 0) {
          const bytes = zip.read(comic.pages[0].entryName);
          if (bytes !== null) {
            this.writeCover(book, bytes, BookService.extensionOf(comic.pages[0].entryName));
          }
        }
        LibraryStore.shared().scheduleSave();
        return;
      }
      let rendered: RenderedBook;
      if (book.format === 'MOBI' || book.format === 'AZW' || book.format === 'AZW3' ||
        book.format === 'FB2') {
        rendered = RenderService.render(book, new ReaderSettings(), null);
      } else {
        const zip = ZipArchive.open(FileService.readBytes(book.path));
        rendered = RenderService.renderEPUB(zip, false);
      }
      if (rendered.coverPath.length > 0) {
        for (let i = 0; i < rendered.assets.length; i++) {
          if (rendered.assets[i].path === rendered.coverPath) {
            this.writeCover(book, rendered.assets[i].bytes, BookService.extensionOf(rendered.coverPath));
            break;
          }
        }
      }
      if (rendered.title.length > 0) {
        book.title = rendered.title;
      }
      if (rendered.author.length > 0) {
        book.author = rendered.author;
      }
      LibraryStore.shared().scheduleSave();
    } catch (error) {
      // Cover extraction is optional.
    }
  }

  deleteBookData(book: LibraryBook): void {
    this.closeComic(book.id);
    FileService.delete(book.coverPath);
    if (book.source === 'local' || book.source === 'jianguoyun') {
      FileService.delete(book.path);
    }
  }

  private static errorText(error: Object): string {
    if (error instanceof Error) {
      return error.message;
    }
    return String(error);
  }
}
