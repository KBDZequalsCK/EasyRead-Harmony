import { LibraryBook } from '../model/LibraryModels';
import { JsonCodec, JsonKind, JsonNode } from '../parser/ZenJson';
import { AppPaths, FileService } from './FileService';

export class BookFormats {
  static fromExtension(extension: string): string {
    const lower = extension.toLowerCase();
    if (lower === 'md' || lower === 'markdown') {
      return 'MD';
    }
    if (['txt', 'epub', 'pdf', 'mobi', 'azw', 'azw3', 'fb2', 'cbz', 'rtf', 'docx'].indexOf(lower) >= 0) {
      return lower.toUpperCase();
    }
    return '';
  }

  static isSupported(extension: string): boolean {
    return BookFormats.fromExtension(extension).length > 0;
  }

  static isComic(format: string): boolean {
    return format === 'CBZ';
  }

  static isPdf(format: string): boolean {
    return format === 'PDF';
  }

  static isPhoneSyncable(format: string): boolean {
    return ['TXT', 'EPUB', 'PDF', 'MOBI', 'AZW', 'AZW3'].indexOf(format) >= 0;
  }
}

export class LibraryStore {
  private static instance: LibraryStore | null = null;
  books: LibraryBook[] = [];
  lastOpenedId: string = '';
  /**
   * Whether the reader was the last visible surface. A cold start restores
   * the last book only when the app went away while reading; after the reader
   * has been closed back to the shelf, launching again shows the shelf.
   */
  resumeReaderOnLaunch: boolean = false;
  activeSource: string = 'local';
  /** Picker URI of the folder linked to the local shelf, if any. */
  localFolderUri: string = '';
  localFolderName: string = '';
  private loaded: boolean = false;
  private saveTimer: number = -1;

  static shared(): LibraryStore {
    if (LibraryStore.instance === null) {
      LibraryStore.instance = new LibraryStore();
    }
    return LibraryStore.instance;
  }

  load(): void {
    this.books = [];
    this.lastOpenedId = '';
    this.resumeReaderOnLaunch = false;
    this.activeSource = 'local';
    this.localFolderUri = '';
    this.localFolderName = '';
    this.loaded = true;
    if (!FileService.exists(AppPaths.libraryFile())) {
      return;
    }
    let raw = '';
    try {
      raw = FileService.readText(AppPaths.libraryFile());
      const root = JsonCodec.parse(raw);
      const last = root.get('lastOpenedId');
      this.lastOpenedId = last !== null ? last.asString() : '';
      const resume = root.get('resumeReaderOnLaunch');
      this.resumeReaderOnLaunch = resume !== null ? resume.asBool(false) : false;
      const source = root.get('activeSource');
      if (source !== null) {
        this.activeSource = source.asString('local');
      }
      const folderUri = root.get('localFolderUri');
      this.localFolderUri = folderUri !== null ? folderUri.asString() : '';
      const folderName = root.get('localFolderName');
      this.localFolderName = folderName !== null ? folderName.asString() : '';
      const list = root.get('books');
      if (list === null || list.kind !== JsonKind.ARRAY) {
        return;
      }
      for (let i = 0; i < list.arrayValue.length; i++) {
        const book = LibraryStore.bookFromJson(list.arrayValue[i]);
        if (book !== null) {
          this.books.push(book);
        }
      }
    } catch (error) {
      // A damaged library file must not stop the app from starting; the
      // original is kept beside the fresh one so it can be inspected.
      try {
        if (raw.length > 0) {
          FileService.writeText(AppPaths.libraryFile() + '.broken', raw);
        }
      } catch (inner) {
      }
    }
  }

  private static bookFromJson(node: JsonNode): LibraryBook | null {
    const path = node.get('path');
    if (path === null || path.asString().length === 0) {
      return null;
    }
    const book = new LibraryBook();
    book.id = LibraryStore.stringField(node, 'id');
    if (book.id.length === 0) {
      book.id = LibraryStore.makeId();
    }
    book.title = LibraryStore.stringField(node, 'title');
    book.author = LibraryStore.stringField(node, 'author');
    book.format = LibraryStore.stringField(node, 'format');
    book.path = path.asString();
    book.size = LibraryStore.numberField(node, 'size', 0);
    book.source = LibraryStore.stringField(node, 'source');
    if (book.source.length === 0) {
      book.source = 'local';
    }
    book.addedAt = LibraryStore.numberField(node, 'addedAt', 0);
    book.progress = LibraryStore.numberField(node, 'progress', 0);
    book.textProgress = LibraryStore.numberField(node, 'textProgress', 0);
    book.progressUpdatedAt = LibraryStore.numberField(node, 'progressUpdatedAt', 0);
    book.locatorText = LibraryStore.stringField(node, 'locatorText');
    book.locatorProgress = LibraryStore.numberField(node, 'locatorProgress', -1);
    book.coverPath = LibraryStore.stringField(node, 'coverPath');
    book.pageCount = LibraryStore.numberField(node, 'pageCount', 0);
    book.zenProgress = LibraryStore.numberField(node, 'zenProgress', -1);
    if (book.title.length === 0) {
      const name = FileService.fileName(book.path);
      const dot = name.lastIndexOf('.');
      book.title = dot > 0 ? name.substring(0, dot) : name;
    }
    return book;
  }

  private static stringField(node: JsonNode, key: string): string {
    const value = node.get(key);
    return value !== null ? value.asString() : '';
  }

  private static numberField(node: JsonNode, key: string, fallback: number): number {
    const value = node.get(key);
    return value !== null ? value.asNumber(fallback) : fallback;
  }

  static makeId(): string {
    return 'b' + Date.now().toString(36) + Math.floor(Math.random() * 100000).toString(36);
  }

  private toJson(): string {
    const root = JsonNode.object();
    root.set('version', JsonNode.number(1));
    root.set('lastOpenedId', JsonNode.string(this.lastOpenedId));
    root.set('resumeReaderOnLaunch', JsonNode.bool(this.resumeReaderOnLaunch));
    root.set('activeSource', JsonNode.string(this.activeSource));
    root.set('localFolderUri', JsonNode.string(this.localFolderUri));
    root.set('localFolderName', JsonNode.string(this.localFolderName));
    const list = JsonNode.array();
    for (let i = 0; i < this.books.length; i++) {
      const book = this.books[i];
      const node = JsonNode.object();
      node.set('id', JsonNode.string(book.id));
      node.set('title', JsonNode.string(book.title));
      node.set('author', JsonNode.string(book.author));
      node.set('format', JsonNode.string(book.format));
      node.set('path', JsonNode.string(book.path));
      node.set('size', JsonNode.number(book.size));
      node.set('source', JsonNode.string(book.source));
      node.set('addedAt', JsonNode.number(book.addedAt));
      node.set('progress', JsonNode.number(book.progress));
      node.set('textProgress', JsonNode.number(book.textProgress));
      node.set('progressUpdatedAt', JsonNode.number(book.progressUpdatedAt));
      node.set('locatorText', JsonNode.string(book.locatorText));
      node.set('locatorProgress', JsonNode.number(book.locatorProgress));
      node.set('coverPath', JsonNode.string(book.coverPath));
      node.set('pageCount', JsonNode.number(book.pageCount));
      node.set('zenProgress', JsonNode.number(book.zenProgress));
      list.arrayValue.push(node);
    }
    root.set('books', list);
    return JsonCodec.stringify(root, false, true, false);
  }

  saveNow(): void {
    if (!this.loaded) {
      return;
    }
    FileService.writeTextAtomic(AppPaths.libraryFile(), this.toJson());
  }

  scheduleSave(): void {
    if (!this.loaded) {
      return;
    }
    if (this.saveTimer >= 0) {
      clearTimeout(this.saveTimer);
    }
    this.saveTimer = setTimeout((): void => {
      this.saveTimer = -1;
      this.saveNow();
    }, 800);
  }

  flush(): void {
    if (this.saveTimer >= 0) {
      clearTimeout(this.saveTimer);
      this.saveTimer = -1;
    }
    this.saveNow();
  }

  find(id: string): LibraryBook | null {
    for (let i = 0; i < this.books.length; i++) {
      if (this.books[i].id === id) {
        return this.books[i];
      }
    }
    return null;
  }

  findByPath(path: string): LibraryBook | null {
    for (let i = 0; i < this.books.length; i++) {
      if (this.books[i].path === path) {
        return this.books[i];
      }
    }
    return null;
  }

  add(book: LibraryBook): void {
    for (let i = 0; i < this.books.length; i++) {
      if (this.books[i].path === book.path) {
        this.books[i] = book;
        this.scheduleSave();
        return;
      }
    }
    this.books.push(book);
    this.scheduleSave();
  }

  remove(id: string): void {
    const next: LibraryBook[] = [];
    for (let i = 0; i < this.books.length; i++) {
      if (this.books[i].id !== id) {
        next.push(this.books[i]);
      }
    }
    this.books = next;
    if (this.lastOpenedId === id) {
      this.lastOpenedId = '';
    }
    this.scheduleSave();
  }

  bySource(source: string): LibraryBook[] {
    const result: LibraryBook[] = [];
    for (let i = 0; i < this.books.length; i++) {
      if (this.books[i].source === source) {
        result.push(this.books[i]);
      }
    }
    result.sort((a: LibraryBook, b: LibraryBook): number => b.addedAt - a.addedAt);
    return result;
  }

  updateProgress(bookId: string, progress: number, textProgress: number,
    locatorText: string, locatorProgress: number, settled: boolean,
    zenProgress: number = -1): void {
    const book = this.find(bookId);
    if (book === null) {
      return;
    }
    book.progress = Math.min(Math.max(progress, 0), 1);
    book.textProgress = Math.min(Math.max(textProgress, 0), 1);
    if (zenProgress >= 0) {
      book.zenProgress = Math.min(Math.max(zenProgress, 0), 1);
    }
    if (locatorText.length > 0) {
      book.locatorText = locatorText;
      book.locatorProgress = locatorProgress;
    }
    book.progressUpdatedAt = Date.now();
    if (settled) {
      this.scheduleSave();
    }
  }

  applyCloudPosition(bookId: string, progress: number, textProgress: number,
    locatorText: string, updatedAt: number, zenProgress: number = -1): void {
    const book = this.find(bookId);
    if (book === null) {
      return;
    }
    book.progress = progress;
    book.textProgress = textProgress;
    book.locatorText = locatorText;
    book.locatorProgress = locatorText.length > 0 ? progress : -1;
    book.progressUpdatedAt = updatedAt;
    if (zenProgress >= 0) {
      book.zenProgress = Math.min(Math.max(zenProgress, 0), 1);
    }
    this.scheduleSave();
  }
}
