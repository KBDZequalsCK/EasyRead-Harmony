export class BookSource {
  static readonly LOCAL: string = 'local';
  /** Kept as 'jianguoyun' so existing libraries keep their WebDAV shelf. */
  static readonly WEBDAV: string = 'jianguoyun';
  static readonly JIANGUOYUN: string = 'jianguoyun';
}

export class SyncProvider {
  static readonly JIANGUOYUN: string = 'jianguoyun';
  static readonly NEXTCLOUD: string = 'nextcloud';
  static readonly CUSTOM: string = 'custom';
}

export class SyncNamespace {
  /** New installations use their own folder instead of the ZenReader one. */
  static readonly EASYREAD: string = 'easyread';
  /** Compatibility with 极简阅读 / ZenReader, which stores data here. */
  static readonly ZENREADER: string = 'zenreader';
}

export class LibraryBook {
  id: string = '';
  title: string = '';
  author: string = '';
  format: string = '';
  path: string = '';
  size: number = 0;
  source: string = BookSource.LOCAL;
  addedAt: number = 0;
  /** Rendered scroll fraction (0..1), used for the shelf and scroll mode. */
  progress: number = 0;
  /** Character fraction of the extracted book text, the phone's metric. */
  textProgress: number = 0;
  progressUpdatedAt: number = 0;
  locatorText: string = '';
  locatorProgress: number = -1;
  coverPath: string = '';
  pageCount: number = 0;
  /**
   * ZenReader's own chapter-weighted percentage (0..1) for WebDAV books.
   * The local progress above stays a character/page fraction for reopening;
   * the shelf and reader label show this value so they match the iPhone/iPad
   * and the Mac after a sync. -1 means it has not been computed yet.
   */
  zenProgress: number = -1;

  syncedPosition(): number {
    if (this.textProgress > 0.000001) {
      return this.textProgress;
    }
    return this.progress;
  }

  /** The same position the reader resumes from, so shelf and reader agree. */
  displayProgress(): number {
    const value = this.source === BookSource.WEBDAV && this.zenProgress >= 0
      ? this.zenProgress
      : this.syncedPosition();
    return Math.min(Math.max(value, 0), 1);
  }
}

export class ReaderSettings {
  fontSize: number = 20;
  lineHeight: number = 1.8;
  /** Side margin as a fraction of the reading pane width. */
  margin: number = 0.08;
  theme: string = 'paper';
  pageMode: string = 'paged';
  /** auto / one / two */
  columns: string = 'auto';
  publisherStyles: boolean = false;
  fontFamily: string = 'serif';
  showProgress: boolean = true;
  /** Shelf presentation: grid or list. */
  shelfLayout: string = 'grid';
  /** Whether the wide-screen shelf panel is shown beside the reader. */
  shelfVisible: boolean = true;
}

export class SyncConfig {
  provider: string = SyncProvider.JIANGUOYUN;
  server: string = 'https://dav.jianguoyun.com/dav/';
  username: string = '';
  password: string = '';
  autoSync: boolean = true;
  lastSyncAt: number = 0;
  deviceId: string = '';
  /** Remote folder layout: easyread (default) or zenreader (compatibility). */
  remoteFolder: string = SyncNamespace.EASYREAD;
}

export class BookmarkItem {
  id: string = '';
  bookId: string = '';
  progress: number = 0;
  textProgress: number = 0;
  pageIndex: number = -1;
  snippet: string = '';
  note: string = '';
  createdAt: number = 0;
}

export class SyncResult {
  remoteSnapshot: string = '';
  totalRemoteBooks: number = 0;
  matched: number = 0;
  pulled: number = 0;
  pushed: number = 0;
  downloadedBooks: number = 0;
  uploadedBooks: number = 0;
  transferSkipped: number = 0;
  failures: string[] = [];
  removedBookIds: string[] = [];
  uploadedSnapshot: string = '';
  manifestWarning: string = '';
}

export class ZenPositionPayload {
  percent: number = 0;
  readPage: number = 0;
  readChapter: number = 0;
  readText: string = '';
}

export class ProgressUpdate {
  bookId: string = '';
  progress: number = 0;
  textProgress: number = 0;
  updatedAt: number = 0;
  locatorText: string = '';
  fromCloud: boolean = true;
}

export class ReaderChapter {
  title: string = '';
  progress: number = 0;
  anchorId: string = '';
  locatorText: string = '';
  level: number = 0;
  pageIndex: number = -1;
}

/**
 * Converts between the local character fraction and the chapter-weighted
 * percentage that ZenReader stores in its WebDAV snapshot. Both directions are
 * deterministic for the same chapter table, so a book shows the same number
 * on every device that syncs with the same account.
 */
export class ReaderProgress {
  static percent(progress: number, chapters: ReaderChapter[]): number {
    const clamped = Math.min(Math.max(isNaN(progress) ? 0 : progress, 0), 1);
    if (chapters.length === 0) {
      return clamped;
    }
    let index = 0;
    for (let i = 1; i < chapters.length; i++) {
      if (chapters[i].progress <= clamped + 0.0000001) {
        index = i;
      }
    }
    const start = chapters[index].progress;
    const end = index + 1 < chapters.length ? chapters[index + 1].progress : 1;
    const fraction = end > start ? Math.min(Math.max((clamped - start) / (end - start), 0), 1) : 0;
    return Math.min(Math.max((index + fraction) / chapters.length, 0), 1);
  }

  static characterProgress(percent: number, chapters: ReaderChapter[]): number {
    const clamped = Math.min(Math.max(isNaN(percent) ? 0 : percent, 0), 1);
    if (chapters.length === 0) {
      return clamped;
    }
    const position = clamped * chapters.length;
    let index = Math.floor(position);
    if (index >= chapters.length) {
      index = chapters.length - 1;
    }
    const fraction = Math.min(Math.max(position - index, 0), 1);
    const start = chapters[index].progress;
    const end = index + 1 < chapters.length ? chapters[index + 1].progress : 1;
    if (end <= start) {
      return Math.min(Math.max(start, 0), 1);
    }
    return Math.min(Math.max(start + fraction * (end - start), 0), 1);
  }
}
