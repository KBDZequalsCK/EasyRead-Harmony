import { display, promptAction } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { picker } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { pdfService, pdfViewManager, PdfView } from '@kit.PDFKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { TextModel } from '../parser/BookTypes';
import { LibraryBook, BookmarkItem, ReaderChapter, ReaderSettings, ReaderProgress } from '../model/LibraryModels';
import { BookSource, SyncProvider, SyncNamespace } from '../model/LibraryModels';
import { LibraryStore } from '../service/LibraryStore';
import { FolderService } from '../service/FolderService';
import { SettingsStore } from '../service/SettingsStore';
import { BookmarkStore } from '../service/BookmarkStore';
import { BookService, PreparedBook } from '../service/BookService';
import { ReaderDocument } from '../service/ReaderDocument';
import { ZenSyncService } from '../service/ZenSyncService';
import { ZenTextLocator } from '../service/ZenTextLocator';
import { WebDavClient } from '../service/WebDavClient';
import { AppContext, AppPaths, FileService } from '../service/FileService';
import { TextSupport } from '../service/TextSupport';
import { JsonCodec, JsonNode } from '../parser/ZenJson';
import { Theme } from '../components/Theme';
import { BookCover, BookRow } from '../components/BookCover';
import { ToolButton, OptionChip, LibraryChip, PanelTab, SettingCaption } from '../components/Controls';
import { PrivacyPolicyContent } from '../components/PrivacyPolicy';

class ReaderBridge {
  onMessage: (message: string) => void = (message: string): void => {};
  configJson: string = '';

  postMessage(message: string): void {
    this.onMessage(message);
  }

  /** Called synchronously by the cached reader page while it boots. */
  getConfig(): string {
    return this.configJson;
  }
}

class TocRow {
  chapterIndex: number = 0;
  title: string = '';
  locator: string = '';
  percent: string = '';
  depth: number = 0;
  hasChildren: boolean = false;
  expanded: boolean = false;
  active: boolean = false;
}

@Entry
@Component
struct Index {
  @State books: LibraryBook[] = [];
  @State localBookCount: number = 0;
  @State cloudBookCount: number = 0;
  @State activeSource: string = BookSource.LOCAL;
  @State shelfQuery: string = '';
  @State shelfLayout: string = 'grid';
  @State shelfVisible: boolean = true;
  @State currentBookId: string = '';
  @State readerKind: string = 'none';
  @State webUrl: string = '';
  @State @Watch('onChaptersChanged') chapters: ReaderChapter[] = [];
  @State tocRows: TocRow[] = [];
  @State bookmarks: BookmarkItem[] = [];
  @State currentPage: number = 1;
  @State totalPages: number = 0;
  @State progress: number = 0;
  /** Shown percentage: ZenReader's metric for WebDAV books, local otherwise. */
  @State shownProgress: number = 0;
  @State currentSnippet: string = '';
  @State loading: boolean = false;
  @State errorMessage: string = '';
  @State isWide: boolean = true;
  @State screenWidth: number = 1200;
  @State panel: string = '';
  @State panelTab: string = 'toc';
  @State searchOpen: boolean = false;
  @State searchQuery: string = '';
  @State searchCount: number = 0;
  @State searchIndex: number = 0;
  @State immersive: boolean = false;
  @State themeName: string = 'paper';
  @State fontSize: number = 20;
  @State lineHeight: number = 1.8;
  @State marginValue: number = 0.08;
  @State fontFamily: string = 'serif';
  @State pageMode: string = 'paged';
  @State columns: string = 'auto';
  @State publisherStyles: boolean = false;
  @State showProgress: boolean = true;
  @State syncBusy: boolean = false;
  @State shelfRefreshing: boolean = false;
  @State syncStatus: string = '';
  @State syncProvider: string = SyncProvider.JIANGUOYUN;
  @State syncServer: string = '';
  @State syncUser: string = '';
  @State syncPassword: string = '';
  @State syncAuto: boolean = true;
  @State syncNamespace: string = SyncNamespace.EASYREAD;
  @State lastSyncText: string = '';
  @State localFolderName: string = '';
  @State folderBusy: boolean = false;
  @State folderStatus: string = '';
  @State comicPaths: string[] = [];
  @State comicLabel: string = '';
  @State comicTwoPage: boolean = false;
  @State newNoteText: string = '';
  @State editingBookmarkId: string = '';
  @State editingNoteText: string = '';
  @State pdfCount: number = 0;
  @State privacyAccepted: boolean = false;
  @State privacyDeclined: boolean = false;
  @State privacyChecked: boolean = false;
  /**
   * A window snapshot of the last reading screen, shown from the very first
   * frame after a cold start until the cached page has re-typeset itself.
   * The WebView still has to lay the text out once per process; this covers
   * that unavoidable pause with the exact page the reader left behind.
   */
  @State resumeCover: boolean = false;

  private currentBook: LibraryBook | null = null;
  private tocScroller: Scroller = new Scroller();
  private tocDepths: number[] = [];
  private tocHasChildren: boolean[] = [];
  private tocCollapsed: Map<number, boolean> = new Map<number, boolean>();
  private tocActiveIndex: number = -1;
  private tocActiveRow: number = -1;
  private webController: webview.WebviewController = new webview.WebviewController();
  private pdfController: pdfViewManager.PdfController = new pdfViewManager.PdfController();
  private bridge: ReaderBridge = new ReaderBridge();
  private searchTimer: number = -1;
  private pdfReady: boolean = false;
  private pdfLoaded: boolean = false;
  private pdfBookId: string = '';
  /** PDF outline (bookmarks) are loaded once per opened document. */
  private pdfOutlineBookId: string = '';
  private pdfOutlineRequested: boolean = false;
  /** Cached once per opened text book; avoids file stats on every position. */
  private zenModel: TextModel | null = null;
  private comicIndex: number = 0;
  private comicPageCount: number = 0;
  private lastProgressWrite: number = 0;
  private autoSyncTimer: number = -1;
  private suppressFlushOnce: boolean = false;
  private lastRecordedProgress: number = -1;
  private pdfListenersRegistered: boolean = false;
  private openGuardTimer: number = -1;
  private comicAreaWidth: number = 0;
  private readerPaneHeight: number = 0;
  private windowBase: number = 0;
  private windowSpan: number = 1;
  private windowStartOffset: number = 0;
  private windowEndOffset: number = 0;
  private windowBusy: boolean = false;
  /**
   * Which book the mounted HTML reader currently holds. Returning to the
   * shelf leaves that page alive behind it; reopening the same book reuses
   * the already-typeset window instead of rebuilding and re-flowing it.
   */
  private webBookId: string = '';
  private resumeImage: string = '';
  private resumeBookId: string = '';
  private resumeTimer: number = -1;
  private initialized: boolean = false;
  /** Last handled back gesture; a second one within 2s leaves the app. */
  private backExitAt: number = 0;

  /**
   * Consent is checked before any book, bookmark, sync credential or reading
   * position is loaded. The full app state starts only after agreement.
   */
  aboutToAppear(): void {
    FileService.ensureBaseDirs();
    TextSupport.install();
    SettingsStore.shared().loadPrivacy();
    this.privacyAccepted =
      SettingsStore.shared().privacyAcceptedVersion >= SettingsStore.PRIVACY_VERSION;
    if (this.privacyAccepted) {
      this.initializeAfterConsent();
    }
  }

  private initializeAfterConsent(): void {
    if (this.initialized) {
      return;
    }
    this.initialized = true;
    LibraryStore.shared().load();
    SettingsStore.shared().load();
    BookmarkStore.shared().load();
    this.activeSource = LibraryStore.shared().activeSource;
    const stored = SettingsStore.shared().reader;
    this.themeName = stored.theme;
    this.fontSize = stored.fontSize;
    this.lineHeight = stored.lineHeight;
    this.marginValue = stored.margin;
    this.fontFamily = stored.fontFamily;
    this.pageMode = stored.pageMode;
    this.columns = stored.columns;
    this.publisherStyles = stored.publisherStyles;
    this.showProgress = stored.showProgress;
    this.shelfLayout = stored.shelfLayout === 'list' ? 'list' : 'grid';
    this.shelfVisible = stored.shelfVisible;
    const sync = SettingsStore.shared().sync;
    this.syncProvider = sync.provider;
    this.syncServer = sync.server;
    this.syncUser = sync.username;
    this.syncPassword = sync.password;
    this.syncAuto = sync.autoSync;
    this.syncNamespace = sync.remoteFolder;
    this.lastSyncText = sync.lastSyncAt > 0 ? '上次同步 ' + this.timeText(sync.lastSyncAt) : '尚未同步';
    this.localFolderName = LibraryStore.shared().localFolderName;
    if (LibraryStore.shared().localFolderUri.length > 0) {
      FolderService.activate(LibraryStore.shared().localFolderUri);
    }
    this.bridge.onMessage = (message: string): void => {
      this.handleReaderMessage(message);
    };
    this.registerPdfListeners();
    this.applySystemBars();
    this.refreshBooks();
    this.prepareResumeCover();
    this.restoreLastBook();
    this.maybeAutoSync();
    if (this.autoSyncTimer >= 0) {
      clearInterval(this.autoSyncTimer);
    }
    this.autoSyncTimer = setInterval((): void => {
      this.maybeAutoSync();
    }, 5 * 60 * 1000);
  }

  aboutToDisappear(): void {
    if (this.autoSyncTimer >= 0) {
      clearInterval(this.autoSyncTimer);
      this.autoSyncTimer = -1;
    }
    if (this.resumeTimer >= 0) {
      clearTimeout(this.resumeTimer);
      this.resumeTimer = -1;
    }
    this.flushPosition();
  }

  /**
   * Called when the app goes to the background. The window is still on screen
   * here, so this is the reliable moment to keep a copy of the reading page
   * for the next cold start.
   */
  onPageHide(): void {
    if (!this.initialized) {
      return;
    }
    this.captureResumeCover();
    this.flushPosition();
  }

  /**
   * System back / edge swipe never drops straight out of the reader. Panels
   * and search close first, then the reader returns to the shelf. Leaving the
   * app itself always needs a second back gesture.
   */
  onBackPress(): boolean {
    console.info('[ER] back panel=' + this.panel + ' book=' + this.currentBookId +
      ' armed=' + this.backExitAt);
    if (!this.privacyAccepted) {
      return false;
    }
    if (this.panel.length > 0) {
      this.panel = '';
      this.backExitAt = 0;
      return true;
    }
    if (this.searchOpen) {
      this.closeSearch();
      this.backExitAt = 0;
      return true;
    }
    if (this.currentBookId.length > 0) {
      this.closeReader();
      // The next back gesture from the shelf exits immediately, matching the
      // “reader -> shelf -> leave app” expectation.
      this.backExitAt = Date.now();
      return true;
    }
    const now = Date.now();
    if (this.backExitAt > 0 && now - this.backExitAt <= 2000) {
      console.info('[ER] back exit');
      this.backExitAt = 0;
      this.exitApp();
      return true;
    }
    this.backExitAt = now;
    console.info('[ER] back arm');
    promptAction.showToast({ message: '再滑一次退出应用' });
    return true;
  }

  private agreePrivacy(): void {
    SettingsStore.shared().acceptPrivacy();
    this.privacyAccepted = true;
    this.privacyDeclined = false;
    this.privacyChecked = false;
    this.initializeAfterConsent();
  }

  private declinePrivacy(): void {
    this.privacyDeclined = true;
    this.privacyChecked = false;
  }

  private exitApp(): void {
    // Persist the last surface before terminating; closeReader may have been
    // only moments ago and its debounced save would never run.
    try {
      LibraryStore.shared().flush();
    } catch (error) {
    }
    try {
      AppContext.abilityContext().terminateSelf();
    } catch (error) {
    }
  }

  private resumeMetaPath(bookId: string): string {
    return AppPaths.readerCache() + '/' + bookId + '/resume.meta';
  }

  private resumeImagePath(bookId: string): string {
    return AppPaths.readerCache() + '/' + bookId + '/resume.jpg';
  }

  private isLandscapeScreen(): boolean {
    try {
      const info = display.getDefaultDisplaySync();
      return info.width > info.height;
    } catch (error) {
      return this.screenWidth >= 720;
    }
  }

  /**
   * Shows last session's page before the WebView has finished its one-time
   * re-typeset. The text engine still runs once per process; this only hides
   * that pause behind the page the reader actually left on.
   */
  private prepareResumeCover(): void {
    const lastId = LibraryStore.shared().lastOpenedId;
    if (lastId.length === 0 || !LibraryStore.shared().resumeReaderOnLaunch) {
      return;
    }
    const book = LibraryStore.shared().find(lastId);
    if (book === null || book.format === 'PDF' || book.format === 'CBZ') {
      return;
    }
    const metaPath = this.resumeMetaPath(lastId);
    if (!FileService.exists(metaPath) || !FileService.exists(this.resumeImagePath(lastId))) {
      return;
    }
    const parts = FileService.readText(metaPath).split('|');
    if (parts.length < 11 || parts[0] !== lastId) {
      return;
    }
    const settings = this.currentSettings();
    // Any typography change makes the old page shape wrong, not just stale.
    if (parts[2] !== '' + settings.fontSize || parts[3] !== '' + settings.lineHeight ||
      parts[4] !== '' + settings.margin || parts[5] !== settings.fontFamily ||
      parts[6] !== settings.theme || parts[7] !== settings.pageMode ||
      parts[8] !== settings.columns) {
      return;
    }
    const progress = Number(parts[1]);
    const shotWidth = Number(parts[9]);
    const shotHeight = Number(parts[10]);
    if (isNaN(progress) || isNaN(shotWidth) || isNaN(shotHeight)) {
      return;
    }
    // The snapshot is only a faithful preview for the same page in the same
    // orientation; a sync or a rotation happened in between, skip it.
    if (Math.abs(progress - book.syncedPosition()) > 0.002 ||
      (shotWidth > shotHeight) !== this.isLandscapeScreen()) {
      return;
    }
    this.resumeImage = 'file://' + this.resumeImagePath(lastId);
    this.resumeBookId = lastId;
    this.resumeCover = true;
    console.info('[ER] resume cover p=' + progress.toFixed(4));
    if (this.resumeTimer >= 0) {
      clearTimeout(this.resumeTimer);
    }
    this.resumeTimer = setTimeout((): void => {
      this.resumeTimer = -1;
      this.resumeCover = false;
    }, 2500);
  }

  private hideResumeCover(): void {
    if (this.resumeTimer >= 0) {
      clearTimeout(this.resumeTimer);
      this.resumeTimer = -1;
    }
    if (this.resumeCover) {
      this.resumeCover = false;
    }
    this.resumeBookId = '';
  }

  /** Keeps a compressed window screenshot next to the book's render cache. */
  private captureResumeCover(): void {
    if (this.readerKind !== 'html' || this.currentBook === null ||
      this.currentBookId.length === 0 || this.loading || this.windowBusy) {
      return;
    }
    // A panel or the search sheet covers the page; capturing now would make
    // the next cold start show a stale settings sheet instead of the book.
    if (this.panel.length > 0 || this.searchOpen) {
      return;
    }
    const mainWindow = AppContext.mainWindow();
    if (mainWindow === null) {
      return;
    }
    const book = this.currentBook;
    const progress = this.progress;
    const settings = this.currentSettings();
    const rect = mainWindow.getWindowProperties().windowRect;
    const started = Date.now();
    mainWindow.snapshot().then((pixelMap: image.PixelMap): void => {
      const packer = image.createImagePacker();
      packer.packToData(pixelMap, { format: 'image/jpeg', quality: 62 })
        .then((buffer: ArrayBuffer): void => {
          const dir = AppPaths.readerCache() + '/' + book.id;
          FileService.ensureDir(dir);
          FileService.writeBytes(dir + '/resume.jpg', new Uint8Array(buffer));
          FileService.writeTextAtomic(dir + '/resume.meta',
            book.id + '|' + progress.toFixed(6) + '|' + settings.fontSize + '|' +
            settings.lineHeight + '|' + settings.margin + '|' + settings.fontFamily + '|' +
            settings.theme + '|' + settings.pageMode + '|' + settings.columns + '|' +
            rect.width + '|' + rect.height + '|' + Date.now());
          console.info('[ER] resume shot ' + book.id + ' ' + buffer.byteLength + 'B ' +
            (Date.now() - started) + 'ms');
          packer.release();
          pixelMap.release();
        })
        .catch((error: BusinessError): void => {
          console.error('[ER] resume pack failed ' + error.code);
          packer.release();
          pixelMap.release();
        });
    }).catch((error: BusinessError): void => {
      console.error('[ER] resume snapshot failed ' + error.code);
    });
  }

  private registerPdfListeners(): void {
    if (this.pdfListenersRegistered) {
      return;
    }
    this.pdfListenersRegistered = true;
    this.pdfController.registerPageCountChangedListener((count: number): void => {
      if (count <= 0 || this.pdfBookId.length === 0 || this.pdfBookId !== this.currentBookId) {
        return;
      }
      this.pdfCount = count;
      this.totalPages = count;
      if (this.currentBook !== null) {
        BookService.shared().setPdfPageCount(this.currentBook.id, count);
      }
      if (this.pdfOutlineBookId !== this.pdfBookId) {
        this.buildPdfChapters();
      }
      this.requestPdfOutline();
      if (!this.pdfReady) {
        this.restorePdfPosition();
      }
    });
    this.pdfController.registerPageChangedListener((index: number): void => {
      if (!this.pdfReady || this.readerKind !== 'pdf' ||
        this.pdfBookId.length === 0 || this.pdfBookId !== this.currentBookId) {
        return;
      }
      const page = index + 1;
      this.currentPage = page;
      this.totalPages = Math.max(this.pdfCount, this.totalPages);
      const progress = this.pdfCount > 1 ? index / (this.pdfCount - 1) : 0;
      this.recordPosition(progress, page, this.pdfCount, '第 ' + page + ' 页');
    });
  }

  private restoreLastBook(): void {
    const store = LibraryStore.shared();
    if (!store.resumeReaderOnLaunch || store.lastOpenedId.length === 0) {
      return;
    }
    const book = store.find(store.lastOpenedId);
    if (book === null) {
      return;
    }
    setTimeout((): void => {
      if (this.currentBookId.length === 0) {
        this.openBook(book);
      }
    }, 500);
  }

  private maybeAutoSync(): void {
    if (!this.privacyAccepted) {
      return;
    }
    const config = SettingsStore.shared().sync;
    if (!config.autoSync || config.username.length === 0 || config.password.length === 0) {
      return;
    }
    if (Date.now() - config.lastSyncAt < 5 * 60 * 1000) {
      return;
    }
    setTimeout((): void => {
      this.runSync('both');
    }, 2000);
  }

  private timeText(timestamp: number): string {
    const date = new Date(timestamp);
    const pad = (value: number): string => value < 10 ? '0' + value : '' + value;
    return pad(date.getHours()) + ':' + pad(date.getMinutes());
  }

  private dateTimeText(timestamp: number): string {
    const date = new Date(timestamp);
    const pad = (value: number): string => value < 10 ? '0' + value : '' + value;
    return (date.getMonth() + 1) + '月' + date.getDate() + '日 ' +
      pad(date.getHours()) + ':' + pad(date.getMinutes());
  }

  private refreshBooks(): void {
    const list = LibraryStore.shared().bySource(this.activeSource);
    const lastOpened = LibraryStore.shared().lastOpenedId;
    // Recently read books first, with the book that is open right now pinned
    // to the top even before its first page turn updates progressUpdatedAt.
    list.sort((a: LibraryBook, b: LibraryBook): number => {
      const aRecent = a.id === lastOpened ? 9007199254740991 :
        Math.max(a.progressUpdatedAt, a.addedAt);
      const bRecent = b.id === lastOpened ? 9007199254740991 :
        Math.max(b.progressUpdatedAt, b.addedAt);
      if (bRecent !== aRecent) {
        return bRecent - aRecent;
      }
      if (a.title === b.title) {
        return 0;
      }
      return a.title < b.title ? -1 : 1;
    });
    this.books = list;
    this.localBookCount = this.sourceCount(BookSource.LOCAL);
    this.cloudBookCount = this.sourceCount(BookSource.WEBDAV);
    this.refreshBookmarks();
  }

  private toggleShelfLayout(): void {
    this.shelfLayout = this.shelfLayout === 'grid' ? 'list' : 'grid';
    this.persistSettings();
  }

  private toggleShelf(): void {
    this.shelfVisible = !this.shelfVisible;
    this.persistSettings();
    setTimeout((): void => {
      this.reflowReader();
    }, 90);
  }

  private toggleChrome(): void {
    if (this.currentBookId.length === 0) {
      return;
    }
    this.immersive = !this.immersive;
  }

  private handleReaderTap(): void {
    if (this.searchOpen) {
      this.closeSearch();
      return;
    }
    this.toggleChrome();
  }

  private togglePageMode(): void {
    if (this.readerKind !== 'html') {
      return;
    }
    this.pageMode = this.pageMode === 'paged' ? 'scroll' : 'paged';
    this.applyMode();
  }

  private reflowReader(): void {
    if (this.readerKind !== 'html' || this.webUrl.length === 0) {
      return;
    }
    this.runJs('window.easyreadPager && window.easyreadPager.reflow(' + this.progress + ')');
  }

  /**
   * Loads a new chapter window around `progress`. Used when a page turn runs
   * past the edge of the current window and when a TOC/bookmark target lives
   * outside it. The WebView reloads a small document instead of the whole book.
   */
  private loadWindow(progress: number, direction: string, locator: string): void {
    if (this.currentBook === null || this.readerKind !== 'html' || this.windowBusy) {
      return;
    }
    this.windowBusy = true;
    this.loading = true;
    const started = Date.now();
    const doc = BookService.shared().buildWindow(this.currentBook, this.currentSettings(),
      progress, direction, locator);
    console.info('[ER] window dir=' + direction + ' p=' + progress.toFixed(4) +
      ' base=' + doc.windowBase.toFixed(4) + ' span=' + doc.windowSpan.toFixed(4) +
      ' ' + (Date.now() - started) + 'ms' + (doc.error.length > 0 ? ' error=' + doc.error : ''));
    if (doc.error.length > 0) {
      this.windowBusy = false;
      this.loading = false;
      promptAction.showToast({ message: doc.error });
      return;
    }
    this.windowBase = doc.windowBase;
    this.windowSpan = doc.windowSpan;
    this.windowStartOffset = doc.windowStart;
    this.windowEndOffset = doc.windowEnd;
    this.bridge.configJson = doc.configJson;
    this.webUrl = doc.url;
    // A mounted Web component ignores changes to `src` on this device build,
    // so navigate explicitly while it stays alive behind the loading veil.
    this.webController.loadUrl(doc.url);
    this.armOpenGuard(this.currentBook.id);
  }

  /**
   * Re-opens the window at an exact body offset. Page turns at a window edge
   * use this so the new document begins where the old one ended; resolving
   * the handover through global progress alone can repeat a page.
   */
  private loadWindowAtOffset(offset: number, direction: string): void {
    if (this.currentBook === null || this.readerKind !== 'html' || this.windowBusy) {
      return;
    }
    this.windowBusy = true;
    this.loading = true;
    const started = Date.now();
    const doc = BookService.shared().buildWindowAtOffset(this.currentBook,
      this.currentSettings(), offset, direction, '');
    console.info('[ER] window dir=' + direction + ' at=' + offset +
      ' base=' + doc.windowBase.toFixed(4) + ' span=' + doc.windowSpan.toFixed(4) +
      ' ' + (Date.now() - started) + 'ms' + (doc.error.length > 0 ? ' error=' + doc.error : ''));
    if (doc.error.length > 0) {
      this.windowBusy = false;
      this.loading = false;
      promptAction.showToast({ message: doc.error });
      return;
    }
    this.windowBase = doc.windowBase;
    this.windowSpan = doc.windowSpan;
    this.windowStartOffset = doc.windowStart;
    this.windowEndOffset = doc.windowEnd;
    this.bridge.configJson = doc.configJson;
    this.webUrl = doc.url;
    this.webController.loadUrl(doc.url);
    this.armOpenGuard(this.currentBook.id);
  }

  private jumpInsideWindow(progress: number): boolean {
    return progress >= this.windowBase - 0.000001 &&
      progress <= this.windowBase + this.windowSpan + 0.000001;
  }

  private armOpenGuard(bookId: string): void {
    if (this.openGuardTimer >= 0) {
      clearTimeout(this.openGuardTimer);
      this.openGuardTimer = -1;
    }
    this.openGuardTimer = setTimeout((): void => {
      this.openGuardTimer = -1;
      if (this.currentBookId === bookId && this.loading) {
        this.loading = false;
      }
    }, 6000);
  }

  private clearOpenGuard(): void {
    if (this.openGuardTimer >= 0) {
      clearTimeout(this.openGuardTimer);
      this.openGuardTimer = -1;
    }
  }

  private refreshBookmarks(): void {
    if (this.currentBook !== null) {
      this.bookmarks = BookmarkStore.shared().forBook(this.currentBook.id);
    } else {
      this.bookmarks = [];
    }
  }

  private visibleBooks(): LibraryBook[] {
    const query = this.shelfQuery.trim().toLowerCase();
    if (query.length === 0) {
      return this.books;
    }
    const result: LibraryBook[] = [];
    for (let i = 0; i < this.books.length; i++) {
      const book = this.books[i];
      if (book.title.toLowerCase().indexOf(query) >= 0 ||
        book.author.toLowerCase().indexOf(query) >= 0) {
        result.push(book);
      }
    }
    return result;
  }

  private sourceCount(source: string): number {
    let count = 0;
    const all = LibraryStore.shared().books;
    for (let i = 0; i < all.length; i++) {
      if (all[i].source === source) {
        count += 1;
      }
    }
    return count;
  }

  private currentSettings(): ReaderSettings {
    const settings = new ReaderSettings();
    settings.fontSize = this.fontSize;
    settings.lineHeight = this.lineHeight;
    settings.margin = this.marginValue;
    settings.theme = this.themeName;
    settings.pageMode = this.pageMode;
    settings.columns = this.columns;
    settings.publisherStyles = this.publisherStyles;
    settings.fontFamily = this.fontFamily;
    settings.showProgress = this.showProgress;
    settings.shelfLayout = this.shelfLayout;
    settings.shelfVisible = this.shelfVisible;
    return settings;
  }

  private persistSettings(): void {
    const stored = SettingsStore.shared();
    stored.reader = this.currentSettings();
    stored.saveReader();
  }

  private async importBooks(): Promise<void> {
    try {
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 20;
      options.fileSuffixFilters = [
        '.txt', '.md', '.markdown', '.epub', '.pdf', '.mobi', '.azw', '.azw3',
        '.fb2', '.cbz', '.rtf', '.docx'
      ];
      const documentPicker = new picker.DocumentViewPicker(getContext(this));
      const uris = await documentPicker.select(options);
      if (uris.length === 0) {
        return;
      }
      const imported = BookService.shared().importBooks(uris, this.activeSource);
      this.refreshBooks();
      if (imported.length === 0) {
        promptAction.showToast({ message: '没有导入新书（可能已在书架中）' });
      } else {
        promptAction.showToast({ message: '已导入 ' + imported.length + ' 本书' });
      }
    } catch (error) {
      promptAction.showToast({ message: '导入失败：' + this.errorText(error) });
    }
  }

  private openBook(selectedBook: LibraryBook): void {
    const stored = LibraryStore.shared().find(selectedBook.id);
    const book = stored !== null ? stored : selectedBook;
    const openStarted = Date.now();
    this.backExitAt = 0;
    this.flushPosition();
    if (this.resumeBookId.length > 0 && this.resumeBookId !== book.id) {
      this.hideResumeCover();
    }
    const warm = this.canWarmOpen(book);
    console.info('[ER] open ' + book.id + ' ' + book.format + (warm ? ' warm' : ''));
    this.pdfReady = false;
    this.pdfBookId = '';
    this.pdfOutlineBookId = '';
    this.pdfOutlineRequested = false;
    this.zenModel = null;
    if (this.readerKind === 'pdf' && this.pdfLoaded) {
      this.pdfController.releaseDocument();
      this.pdfLoaded = false;
    }
    if (this.currentBook !== null) {
      BookService.shared().closeComic(this.currentBook.id);
    }
    this.currentBook = book;
    this.currentBookId = book.id;
    this.immersive = false;
    if (!warm) {
      this.windowBase = 0;
      this.windowSpan = 1;
      this.windowStartOffset = 0;
      this.windowEndOffset = 0;
    }
    this.windowBusy = false;
    this.clearOpenGuard();
    this.loading = !warm;
    this.errorMessage = '';
    if (!warm) {
      this.chapters = [];
      this.currentPage = 1;
      this.totalPages = 0;
    }
    this.bookmarks = BookmarkStore.shared().forBook(book.id);
    this.searchOpen = false;
    this.searchCount = 0;
    this.searchQuery = '';
    this.panel = '';
    this.progress = book.syncedPosition();
    this.shownProgress = book.displayProgress();
    this.lastRecordedProgress = this.progress;
    this.currentSnippet = '';
    this.pdfReady = false;
    this.pdfCount = 0;
    LibraryStore.shared().lastOpenedId = book.id;
    LibraryStore.shared().resumeReaderOnLaunch = true;
    LibraryStore.shared().scheduleSave();
    if (warm) {
      // The page behind the shelf is still laid out exactly where it was
      // flushed when the reader closed. Nothing has to be parsed or re-flowed;
      // only an out-of-window progress change (for example a sync) needs work,
      // and goToProgress asks the host for a new window when that happens.
      if (book.source === BookSource.WEBDAV) {
        this.zenModel = BookService.shared().peekTextModel(book);
      }
      this.books = this.books.slice();
      setTimeout((): void => {
        if (this.currentBookId !== book.id) {
          return;
        }
        console.info('[ER] warm resume ' + book.id + ' p=' + this.progress.toFixed(4) +
          ' ' + (Date.now() - openStarted) + 'ms');
        this.runJs('window.easyreadPager && window.easyreadPager.goToProgress(' +
          this.progress + ')');
      }, 0);
      return;
    }
    const settings = this.currentSettings();
    setTimeout((): void => {
      if (this.currentBookId !== book.id) {
        return;
      }
      const prepareStarted = Date.now();
      const prepared = BookService.shared().prepare(book, settings);
      console.info('[ER] prepare ' + (Date.now() - prepareStarted) + 'ms kind=' + prepared.kind);
      if (prepared.error.length > 0) {
        this.errorMessage = prepared.error;
        this.loading = false;
        return;
      }
      this.chapters = prepared.chapters;
      this.readerKind = prepared.kind;
      if (book.source === BookSource.WEBDAV && prepared.kind === 'html') {
        this.zenModel = BookService.shared().peekTextModel(book);
      }
      this.books = this.books.slice();
      if (prepared.kind === 'html') {
        this.webBookId = book.id;
        this.windowBase = prepared.windowBase;
        this.windowSpan = prepared.windowSpan;
        this.windowStartOffset = prepared.windowStart;
        this.windowEndOffset = prepared.windowEnd;
        this.bridge.configJson = prepared.configJson;
        const hadWeb = this.webUrl.length > 0;
        this.webUrl = prepared.url;
        if (hadWeb) {
          this.webController.loadUrl(prepared.url);
        }
        // The loading veil stays until the cached page has restored the saved
        // position and reports 'ready', so page one is never flashed.
        this.armOpenGuard(book.id);
      } else if (prepared.kind === 'pdf') {
        this.webBookId = '';
        this.webUrl = '';
        this.loading = true;
        setTimeout((): void => {
          this.loadPdf(book);
        }, 80);
      } else if (prepared.kind === 'comic') {
        this.webBookId = '';
        this.webUrl = '';
        this.openComic(book, prepared);
        this.loading = false;
      } else {
        this.webBookId = '';
        this.webUrl = '';
        this.loading = false;
      }
    }, 40);
  }

  /**
   * True when the mounted HTML page already belongs to this book and is idle.
   * Reusing it turns a reopen into a single JavaScript jump: no cache read,
   * no window rebuild and no WebView re-typeset.
   */
  private canWarmOpen(book: LibraryBook): boolean {
    return this.readerKind === 'html' && this.webUrl.length > 0 &&
      this.webBookId === book.id && this.errorMessage.length === 0 &&
      !this.loading && !this.windowBusy;
  }

  private async loadPdf(book: LibraryBook): Promise<void> {
    try {
      if (this.pdfLoaded) {
        this.pdfController.releaseDocument();
        this.pdfLoaded = false;
      }
      this.pdfReady = false;
      this.pdfCount = 0;
      this.pdfBookId = book.id;
      this.pdfOutlineBookId = '';
      this.pdfOutlineRequested = false;
      const result = await this.pdfController.loadDocument(book.path);
      if (this.currentBookId !== book.id) {
        this.pdfController.releaseDocument();
        this.pdfLoaded = false;
        return;
      }
      if (result !== pdfService.ParseResult.PARSE_SUCCESS) {
        this.errorMessage = 'PDF 打开失败，文件可能已损坏或加密';
        this.loading = false;
        return;
      }
      this.pdfLoaded = true;
      this.pdfCount = this.pdfController.getPageCount();
      this.totalPages = this.pdfCount;
      BookService.shared().setPdfPageCount(book.id, this.pdfCount);
      this.buildPdfChapters();
      this.requestPdfOutline();
      this.restorePdfPosition();
      this.loading = false;
    } catch (error) {
      this.errorMessage = 'PDF 打开失败：' + this.errorText(error);
      this.loading = false;
    }
  }

  private restorePdfPosition(): void {
    if (this.pdfCount <= 0) {
      return;
    }
    const target = Math.min(
      Math.max(Math.round(this.progress * Math.max(0, this.pdfCount - 1)), 0),
      this.pdfCount - 1
    );
    this.pdfController.goToPage(target);
    this.currentPage = target + 1;
    this.totalPages = this.pdfCount;
    this.pdfReady = true;
  }

  private buildPdfChapters(): void {
    if (this.readerKind !== 'pdf' || this.pdfCount <= 0) {
      return;
    }
    const chapters: ReaderChapter[] = [];
    for (let i = 0; i < this.pdfCount; i++) {
      const chapter = new ReaderChapter();
      chapter.title = '第 ' + (i + 1) + ' 页';
      chapter.pageIndex = i;
      chapter.progress = this.pdfCount > 1 ? i / (this.pdfCount - 1) : 0;
      chapters.push(chapter);
    }
    this.chapters = chapters;
  }

  /**
   * PDFs with a bookmark outline get the publisher's real TOC (with levels,
   * so contained books can collapse); PDFs without one keep the page list.
   */
  private requestPdfOutline(): void {
    if (this.pdfOutlineRequested || this.currentBook === null ||
      this.readerKind !== 'pdf' || this.pdfCount <= 0) {
      return;
    }
    const book = this.currentBook;
    this.pdfOutlineRequested = true;
    setTimeout((): void => {
      this.loadPdfOutline(book);
    }, 80);
  }

  private loadPdfOutline(book: LibraryBook): void {
    if (this.currentBookId !== book.id || this.readerKind !== 'pdf' || this.pdfCount <= 0) {
      return;
    }
    let document: pdfService.PdfDocument | null = null;
    try {
      document = new pdfService.PdfDocument();
      const parsed = document.loadDocument(book.path);
      if (parsed !== pdfService.ParseResult.PARSE_SUCCESS) {
        return;
      }
      const roots = document.getRootBookmarks();
      if (roots === undefined || roots === null || roots.length === 0) {
        return;
      }
      const total = this.pdfCount > 0 ? this.pdfCount : document.getPageCount();
      if (total <= 0) {
        return;
      }
      const chapters: ReaderChapter[] = [];
      this.collectPdfOutline(roots, 0, total, chapters);
      if (chapters.length === 0 || this.currentBookId !== book.id || this.readerKind !== 'pdf') {
        return;
      }
      this.chapters = chapters;
      this.pdfOutlineBookId = book.id;
      console.info('[ER] pdf outline chapters=' + chapters.length + ' book=' + book.id);
    } catch (error) {
      console.info('[ER] pdf outline unavailable: ' + this.errorText(error));
    } finally {
      if (document !== null) {
        try {
          document.releaseDocument();
        } catch (error) {
        }
      }
    }
  }

  private collectPdfOutline(bookmarks: pdfService.Bookmark[], level: number,
    total: number, chapters: ReaderChapter[]): number {
    let firstPage = -1;
    for (let i = 0; i < bookmarks.length; i++) {
      const bookmark = bookmarks[i];
      let title = '';
      let pageIndex = -1;
      try {
        title = bookmark.getBookmarkInfo().title.replace(/\s+/g, ' ').trim();
        pageIndex = bookmark.getDestInfo().pageIndex;
      } catch (error) {
        pageIndex = -1;
      }
      let children: pdfService.Bookmark[] = [];
      try {
        if (bookmark.hasChild()) {
          children = bookmark.getChildren();
        }
      } catch (error) {
        children = [];
      }
      const childChapters: ReaderChapter[] = [];
      const childFirst = (children !== undefined && children !== null && children.length > 0)
        ? this.collectPdfOutline(children, level + 1, total, childChapters)
        : -1;
      const jumpPage = pageIndex >= 0 && pageIndex < total ? pageIndex : childFirst;
      if (jumpPage < 0) {
        // A heading with neither a destination nor a reachable child is not
        // useful in the table, so it and its empty subtree are dropped.
        continue;
      }
      if (firstPage < 0) {
        firstPage = jumpPage;
      }
      const chapter = new ReaderChapter();
      chapter.title = title.length > 0 ? title : '第 ' + (jumpPage + 1) + ' 页';
      chapter.pageIndex = jumpPage;
      chapter.level = level;
      chapter.progress = total > 1 ? jumpPage / (total - 1) : 0;
      chapters.push(chapter);
      for (let c = 0; c < childChapters.length; c++) {
        chapters.push(childChapters[c]);
      }
    }
    return firstPage;
  }

  private openComic(book: LibraryBook, prepared: PreparedBook): void {
    if (prepared.comic === null) {
      return;
    }
    this.comicPageCount = prepared.comic.pages.length;
    this.comicTwoPage = this.isWide && this.comicPageCount > 1;
    let index = Math.round(this.progress * Math.max(0, this.comicPageCount - 1));
    if (this.comicTwoPage && index % 2 === 1) {
      index -= 1;
    }
    this.showComicPage(index);
  }

  private showComicPage(index: number): void {
    if (this.currentBook === null || this.comicPageCount <= 0) {
      return;
    }
    let start = Math.min(Math.max(index, 0), this.comicPageCount - 1);
    if (this.comicTwoPage) {
      start = Math.floor(start / 2) * 2;
    }
    const paths: string[] = [];
    try {
      const first = BookService.shared().comicPage(this.currentBook, start);
      if (first !== null) {
        paths.push('file://' + first.path);
      }
      if (this.comicTwoPage && start + 1 < this.comicPageCount) {
        const second = BookService.shared().comicPage(this.currentBook, start + 1);
        if (second !== null) {
          paths.push('file://' + second.path);
        }
      }
    } catch (error) {
      this.errorMessage = '漫画页面读取失败：' + this.errorText(error);
      return;
    }
    if (paths.length === 0) {
      this.errorMessage = '漫画页面读取失败';
      return;
    }
    this.comicPaths = paths;
    this.comicIndex = start;
    this.currentPage = start + 1;
    this.totalPages = this.comicPageCount;
    if (this.comicTwoPage && start + 1 < this.comicPageCount) {
      this.comicLabel = '' + (start + 1) + '–' + (start + 2) + ' / ' + this.comicPageCount;
    } else {
      this.comicLabel = '' + (start + 1) + ' / ' + this.comicPageCount;
    }
    const progress = this.comicPageCount > 1 ? start / (this.comicPageCount - 1) : 1;
    this.recordPosition(progress, start + 1, this.comicPageCount, this.comicLabel);
  }

  private comicNext(): void {
    const step = this.comicTwoPage ? 2 : 1;
    if (this.comicIndex + step < this.comicPageCount) {
      this.showComicPage(this.comicIndex + step);
    }
  }

  private comicPrevious(): void {
    const step = this.comicTwoPage ? 2 : 1;
    if (this.comicIndex - step >= 0) {
      this.showComicPage(this.comicIndex - step);
    }
  }

  private toggleComicSpread(): void {
    this.comicTwoPage = !this.comicTwoPage;
    this.showComicPage(this.comicIndex);
  }

  private closeReader(): void {
    console.info('[ER] close ' + this.currentBookId);
    // The shelf becomes the last visible surface, so an explicit exit from
    // here must reopen on the shelf rather than restoring the reader.
    LibraryStore.shared().resumeReaderOnLaunch = false;
    this.clearOpenGuard();
    this.hideResumeCover();
    this.pdfReady = false;
    this.pdfBookId = '';
    this.pdfOutlineBookId = '';
    this.pdfOutlineRequested = false;
    this.zenModel = null;
    this.flushPosition();
    if (this.readerKind === 'pdf' && this.pdfLoaded) {
      this.pdfController.releaseDocument();
      this.pdfLoaded = false;
    }
    if (this.currentBook !== null) {
      BookService.shared().closeComic(this.currentBook.id);
    }
    // Keep the typeset HTML page alive behind the shelf so reopening the same
    // book can skip parsing, window generation and WebView layout entirely.
    const keepWarm = this.readerKind === 'html' && this.webUrl.length > 0 &&
      this.webBookId.length > 0 && this.errorMessage.length === 0 &&
      !this.loading && !this.windowBusy;
    this.currentBook = null;
    this.currentBookId = '';
    this.immersive = false;
    this.loading = false;
    if (!keepWarm) {
      this.readerKind = 'none';
      this.webUrl = '';
      this.webBookId = '';
      this.windowBusy = false;
      this.chapters = [];
    }
    this.panel = '';
    this.searchOpen = false;
    this.comicPaths = [];
    this.refreshBooks();
  }

  private flushPosition(): void {
    if (this.suppressFlushOnce) {
      this.suppressFlushOnce = false;
      LibraryStore.shared().flush();
      return;
    }
    if (this.currentBook !== null) {
      const anchor = this.readerKind === 'html' ? this.currentSnippet : '';
      const changed = Math.abs(this.progress - this.currentBook.syncedPosition()) > 0.0001 ||
        (anchor.length > 0 && anchor !== this.currentBook.locatorText);
      if (changed) {
        const zen = this.currentBook.source === BookSource.WEBDAV ? this.shownProgress : -1;
        LibraryStore.shared().updateProgress(this.currentBook.id, this.progress,
          this.progress, anchor, this.progress, true, zen);
      }
      LibraryStore.shared().flush();
    }
  }

  /**
 * The number shown to the reader. WebDAV books use the chapter-weighted
 * percentage ZenReader itself displays, so the same passage reports the same
 * number on the tablet, the Mac and the iPhone/iPad. Local books keep the
 * character/page fraction because they never leave this device.
 */
  private canonicalPercent(characterProgress: number, locator: string = ''): number {
    const clamped = Math.min(Math.max(characterProgress, 0), 1);
    const book = this.currentBook;
    if (book === null || book.source !== BookSource.WEBDAV) {
      return clamped;
    }
    if (this.readerKind === 'pdf' && this.pdfCount > 0) {
      return Math.min(Math.max(this.currentPage / this.pdfCount, 0), 1);
    }
    if (this.readerKind !== 'html') {
      return clamped;
    }
    return this.zenPercentAt(clamped, locator);
  }

  /**
   * Same conversion the Mac uses (ZenTextLocator): chapter index plus the
   * offset inside that chapter, over the extracted text model. The locator
   * snippet wins when it can be found, so both devices agree exactly for the
   * same passage instead of merely landing in the same chapter.
   */
  private zenPercentAt(characterProgress: number, locator: string): number {
    const clamped = Math.min(Math.max(characterProgress, 0), 1);
    const model = this.zenModel;
    if (model !== null) {
      if (locator.length > 0) {
        const anchored = ZenTextLocator.locateByText(locator, clamped, model);
        if (anchored !== null) {
          return Math.min(Math.max(anchored.percent / 100, 0), 1);
        }
      }
      const payload = ZenTextLocator.locate(clamped, model);
      if (payload !== null) {
        return Math.min(Math.max(payload.percent / 100, 0), 1);
      }
    }
    return ReaderProgress.percent(clamped, this.chapters);
  }

  private recordPosition(progress: number, page: number, pages: number, locator: string): void {
    if (this.currentBook === null) {
      return;
    }
    const clamped = Math.min(Math.max(progress, 0), 1);
    this.progress = clamped;
    this.currentPage = page;
    this.totalPages = pages;
    if (locator.length > 0) {
      this.currentSnippet = locator;
    }
    const shown = this.canonicalPercent(clamped, locator);
    this.shownProgress = shown;
    const book = this.currentBook;
    let zenChanged = false;
    if (book.source === BookSource.WEBDAV && Math.abs(book.zenProgress - shown) > 0.0000001) {
      book.zenProgress = shown;
      zenChanged = true;
    }
    const changed = Math.abs(clamped - this.lastRecordedProgress) > 0.0001;
    this.lastRecordedProgress = clamped;
    // Keep the config the page reads on boot in sync with the live position.
    // A display rotation can recreate the WebView; it then reloads the same
    // window and must restore this position instead of the one from open time.
    this.refreshBridgeConfig();
    if (!changed) {
      if (zenChanged) {
        LibraryStore.shared().scheduleSave();
      }
      return;
    }
    this.suppressFlushOnce = false;
    book.progress = clamped;
    book.textProgress = clamped;
    const anchor = this.readerKind === 'html' ? locator : '';
    if (anchor.length > 0) {
      book.locatorText = anchor;
      book.locatorProgress = clamped;
    }
    const zen = book.source === BookSource.WEBDAV ? shown : -1;
    LibraryStore.shared().updateProgress(book.id, clamped, clamped, anchor, clamped, true, zen);
    const now = Date.now();
    if (now - this.lastProgressWrite > 5000) {
      this.lastProgressWrite = now;
      this.books = this.books.slice();
    }
  }

  private handleReaderMessage(raw: string): void {
    let node: JsonNode;
    try {
      node = JsonCodec.parse(raw);
    } catch (error) {
      return;
    }
    const typeNode = node.get('type');
    const type = typeNode !== null ? typeNode.asString() : '';
    if (type === 'ready') {
      console.info('[ER] ready html=' + (this.readerKind === 'html') + ' id=' + this.currentBookId);
      this.clearOpenGuard();
      this.windowBusy = false;
      if (this.readerKind === 'html' && this.currentBookId.length > 0) {
        this.loading = false;
        this.hideResumeCover();
      }
    } else if (type === 'window') {
      const progressNode = node.get('progress');
      const directionNode = node.get('direction');
      const direction = directionNode !== null ? directionNode.asString() : 'next';
      if (direction === 'next' && this.windowEndOffset > 0) {
        this.loadWindowAtOffset(this.windowEndOffset, 'next');
      } else if (direction === 'prev' && this.windowStartOffset > 0) {
        this.loadWindowAtOffset(this.windowStartOffset, 'prev');
      } else {
        this.loadWindow(
          progressNode !== null ? progressNode.asNumber(this.progress) : this.progress,
          direction,
          ''
        );
      }
    } else if (type === 'tap') {
      this.handleReaderTap();
    } else if (type === 'diag') {
      const diagNode = node.get('message');
      console.info('[ER] diag ' + (diagNode !== null ? diagNode.asString() : ''));
    } else if (type === 'error') {
      const messageNode = node.get('message');
      console.error('[ER] reader error ' + (messageNode !== null ? messageNode.asString() : ''));
      this.windowBusy = false;
      this.loading = false;
      this.hideResumeCover();
    } else if (type === 'position') {
      const progressNode = node.get('progress');
      const pageNode = node.get('page');
      const pagesNode = node.get('pages');
      const locatorNode = node.get('locator');
      this.recordPosition(
        progressNode !== null ? progressNode.asNumber(0) : this.progress,
        pageNode !== null ? pageNode.asInt(1) : this.currentPage,
        pagesNode !== null ? pagesNode.asInt(1) : this.totalPages,
        locatorNode !== null ? locatorNode.asString() : ''
      );
      const snippetNode = node.get('snippet');
      if (snippetNode !== null && snippetNode.asString().length > 0) {
        this.currentSnippet = snippetNode.asString();
      }
    } else if (type === 'layout') {
      const pageNode = node.get('page');
      const pagesNode = node.get('pages');
      this.currentPage = pageNode !== null ? pageNode.asInt(1) : this.currentPage;
      this.totalPages = pagesNode !== null ? pagesNode.asInt(1) : this.totalPages;
    } else if (type === 'search') {
      const countNode = node.get('count');
      const indexNode = node.get('index');
      this.searchCount = countNode !== null ? countNode.asInt(0) : 0;
      this.searchIndex = indexNode !== null ? indexNode.asInt(0) : 0;
    }
  }

  private runJs(script: string): void {
    if (this.readerKind !== 'html' || this.webUrl.length === 0) {
      return;
    }
    this.webController.runJavaScript(script).catch((error: BusinessError): void => {
    });
  }

  private applyTypography(): void {
    this.persistSettings();
    this.applySystemBars();
    this.refreshBridgeConfig();
    this.runJs('window.easyreadPager && window.easyreadPager.setTypography(' +
      this.fontSize + ',' + this.lineHeight + ',' + this.marginValue + ',\'' +
      this.themeName + '\',\'' + this.fontFamily + '\')');
  }

  /** Rebuilds the boot config so a recreated WebView restores live state. */
  private refreshBridgeConfig(): void {
    if (this.currentBook === null || this.readerKind !== 'html') {
      return;
    }
    const locator = this.currentSnippet.length > 0 ? this.currentSnippet : this.currentBook.locatorText;
    this.bridge.configJson = ReaderDocument.configJson(this.currentBook, this.currentSettings(),
      this.windowBase, this.windowSpan, this.progress, locator);
  }

  private applySystemBars(): void {
    const mainWindow = AppContext.mainWindow();
    if (mainWindow === null) {
      return;
    }
    mainWindow.setWindowSystemBarProperties({
      statusBarColor: Theme.bg(this.themeName),
      navigationBarColor: Theme.bg(this.themeName),
      statusBarContentColor: Theme.fg(this.themeName),
      navigationBarContentColor: Theme.fg(this.themeName)
    }).catch((): void => {
    });
  }

  private applyMode(): void {
    this.persistSettings();
    this.refreshBridgeConfig();
    this.runJs('window.easyreadPager && window.easyreadPager.setMode(\'' +
      (this.pageMode === 'scroll' ? 'scroll' : 'paged') + '\',\'' + this.columns + '\')');
  }

  private applyColumns(): void {
    this.persistSettings();
    this.refreshBridgeConfig();
    this.runJs('window.easyreadPager && window.easyreadPager.setColumns(\'' + this.columns + '\')');
  }

  private onChaptersChanged(): void {
    if (this.panel === 'reader' && this.panelTab === 'toc') {
      this.prepareToc();
      this.scrollTocToActive();
    }
  }

  private showTocPanel(): void {
    this.prepareToc();
    this.panelTab = 'toc';
    this.panel = 'reader';
  }

  private showTocTab(): void {
    if (this.panelTab === 'toc') {
      return;
    }
    this.prepareToc();
    this.panelTab = 'toc';
  }

  /**
   * Builds one indented tree from the heading levels. Groups that do not
   * contain the reading position start collapsed, so an omnibus opens on the
   * book currently being read instead of several hundred sibling chapters.
   */
  private prepareToc(): void {
    const count = this.chapters.length;
    this.tocDepths = [];
    this.tocHasChildren = [];
    this.tocCollapsed.clear();
    this.tocActiveRow = -1;
    if (count === 0) {
      this.tocActiveIndex = -1;
      this.tocRows = [];
      return;
    }

    const parents: number[] = [];
    const depths: number[] = [];
    const hasChildren: boolean[] = [];
    const stack: number[] = [];
    for (let i = 0; i < count; i++) {
      hasChildren.push(false);
    }
    for (let i = 0; i < count; i++) {
      const level = this.chapters[i].level;
      while (stack.length > 0) {
        const top = stack[stack.length - 1];
        if (this.chapters[top].level < level) {
          break;
        }
        stack.pop();
      }
      const parent = stack.length > 0 ? stack[stack.length - 1] : -1;
      parents.push(parent);
      depths.push(parent >= 0 ? depths[parent] + 1 : 0);
      if (parent >= 0) {
        hasChildren[parent] = true;
      }
      stack.push(i);
    }
    this.tocDepths = depths;
    this.tocHasChildren = hasChildren;

    const active = this.currentChapterIndex();
    this.tocActiveIndex = active;
    const keepOpen: Map<number, boolean> = new Map<number, boolean>();
    let cursor = active;
    while (cursor >= 0 && cursor < count) {
      keepOpen.set(cursor, true);
      cursor = parents[cursor];
    }
    for (let i = 0; i < count; i++) {
      if (hasChildren[i] && keepOpen.get(i) !== true) {
        this.tocCollapsed.set(i, true);
      }
    }
    this.buildTocRows();
  }

  private buildTocRows(): void {
    const rows: TocRow[] = [];
    this.tocActiveRow = -1;
    let hiddenDepth = -1;
    for (let i = 0; i < this.chapters.length; i++) {
      const depth = this.tocDepths[i];
      if (hiddenDepth >= 0) {
        if (depth > hiddenDepth) {
          continue;
        }
        hiddenDepth = -1;
      }
      const chapter = this.chapters[i];
      const hasChildren = this.tocHasChildren[i];
      const collapsed = hasChildren && this.tocCollapsed.get(i) === true;
      const row = new TocRow();
      row.chapterIndex = i;
      row.title = chapter.title;
      row.locator = chapter.locatorText;
      row.percent = this.tocPercent(chapter);
      row.depth = depth;
      row.hasChildren = hasChildren;
      row.expanded = hasChildren && !collapsed;
      row.active = i === this.tocActiveIndex;
      rows.push(row);
      if (row.active) {
        this.tocActiveRow = rows.length - 1;
      }
      if (collapsed) {
        hiddenDepth = depth;
      }
    }
    this.tocRows = rows;
  }

  private tocPercent(chapter: ReaderChapter): string {
    let value = chapter.progress;
    if (this.currentBook !== null && this.currentBook.source === BookSource.WEBDAV) {
      if (this.readerKind === 'pdf' && this.pdfCount > 0 && chapter.pageIndex >= 0) {
        value = (chapter.pageIndex + 1) / this.pdfCount;
      } else if (this.readerKind === 'html') {
        value = this.zenPercentAt(chapter.progress, '');
      }
    }
    return Math.round(Math.min(Math.max(value, 0), 1) * 100) + '%';
  }

  private toggleTocGroup(row: TocRow): void {
    if (!row.hasChildren) {
      return;
    }
    if (this.tocCollapsed.get(row.chapterIndex) === true) {
      this.tocCollapsed.delete(row.chapterIndex);
    } else {
      this.tocCollapsed.set(row.chapterIndex, true);
    }
    this.buildTocRows();
  }

  private currentChapterIndex(): number {
    if (this.chapters.length === 0) {
      return -1;
    }
    if (this.readerKind === 'pdf' || this.readerKind === 'comic') {
      const page = this.readerKind === 'pdf' ? this.currentPage - 1 : this.comicIndex;
      let found = -1;
      for (let i = 0; i < this.chapters.length; i++) {
        const chapterPage = this.chapters[i].pageIndex;
        if (chapterPage >= 0 && chapterPage <= page) {
          found = i;
        }
      }
      if (found >= 0) {
        return found;
      }
    }
    let result = -1;
    for (let i = 0; i < this.chapters.length; i++) {
      if (this.chapters[i].progress <= this.progress + 0.000001) {
        result = i;
      }
    }
    return result;
  }

  private scrollTocToActive(): void {
    const target = this.tocActiveRow;
    if (target < 0) {
      return;
    }
    setTimeout((): void => {
      if (target >= this.tocRows.length) {
        return;
      }
      try {
        this.tocScroller.scrollToIndex(target, false, ScrollAlign.CENTER);
      } catch (error) {
      }
    }, 40);
  }

  private jumpToChapter(chapter: ReaderChapter): void {
    if (this.readerKind === 'html') {
      if (this.jumpInsideWindow(chapter.progress)) {
        this.runJs('window.easyreadPager && window.easyreadPager.goToAnchor(' +
          JSON.stringify(chapter.anchorId) + ',' + JSON.stringify(chapter.locatorText) + ',' +
          chapter.progress + ')');
      } else {
        this.loadWindow(chapter.progress, 'start', chapter.locatorText);
      }
    } else if (this.readerKind === 'pdf' && chapter.pageIndex >= 0) {
      this.pdfController.goToPage(chapter.pageIndex);
      this.currentPage = chapter.pageIndex + 1;
      this.progress = this.pdfCount > 1 ? chapter.pageIndex / (this.pdfCount - 1) : 0;
      this.recordPosition(this.progress, this.currentPage, this.pdfCount, '第 ' + this.currentPage + ' 页');
    } else if (this.readerKind === 'comic') {
      this.showComicPage(chapter.pageIndex);
    }
    this.panel = '';
  }

  private jumpToBookmark(item: BookmarkItem): void {
    if (this.readerKind === 'html') {
      if (this.jumpInsideWindow(item.progress)) {
        this.runJs('window.easyreadPager && window.easyreadPager.goToAnchor(\'\',' + 
          JSON.stringify(item.snippet) + ',' + item.progress + ')');
      } else {
        this.loadWindow(item.progress, 'start', item.snippet);
      }
    } else if (this.readerKind === 'pdf' && item.pageIndex >= 0) {
      this.pdfController.goToPage(item.pageIndex);
      this.currentPage = item.pageIndex + 1;
    } else if (this.readerKind === 'comic' && item.pageIndex >= 0) {
      this.showComicPage(item.pageIndex);
    }
    this.panel = '';
  }

  private addBookmark(): void {
    if (this.currentBook === null) {
      return;
    }
    const item = new BookmarkItem();
    item.bookId = this.currentBook.id;
    item.progress = this.progress;
    item.textProgress = this.progress;
    item.pageIndex = this.readerKind === 'pdf' || this.readerKind === 'comic'
      ? this.currentPage - 1 : -1;
    item.snippet = this.currentSnippet.length > 0 ? this.currentSnippet : this.positionLabel();
    if (this.readerKind === 'html') {
      this.webController.runJavaScript('window.easyreadPager ? window.easyreadPager.selectionText() : \'\'')
        .then((value: string): void => {
          if (value.length > 0) {
            item.snippet = value.substring(0, 120);
          }
          BookmarkStore.shared().add(item);
          this.refreshBookmarks();
          promptAction.showToast({ message: '已添加书签' });
        }).catch((error: BusinessError): void => {
          BookmarkStore.shared().add(item);
          this.refreshBookmarks();
        });
    } else {
      BookmarkStore.shared().add(item);
      this.refreshBookmarks();
      promptAction.showToast({ message: '已添加书签' });
    }
  }

  private addNote(): void {
    if (this.currentBook === null || this.newNoteText.trim().length === 0) {
      return;
    }
    const item = new BookmarkItem();
    item.bookId = this.currentBook.id;
    item.progress = this.progress;
    item.textProgress = this.progress;
    item.pageIndex = this.readerKind === 'pdf' || this.readerKind === 'comic'
      ? this.currentPage - 1 : -1;
    item.snippet = this.currentSnippet;
    item.note = this.newNoteText.trim();
    const finish = (): void => {
      BookmarkStore.shared().add(item);
      this.newNoteText = '';
      this.refreshBookmarks();
      promptAction.showToast({ message: '笔记已保存' });
    };
    if (this.readerKind === 'html') {
      this.webController.runJavaScript('window.easyreadPager ? window.easyreadPager.selectionText() : \'\'')
        .then((value: string): void => {
          if (value !== null && value !== undefined && value.length > 0) {
            item.snippet = value.substring(0, 120);
          }
          finish();
        }).catch((error: BusinessError): void => {
          finish();
        });
    } else {
      finish();
    }
  }

  private saveEditedNote(): void {
    if (this.editingBookmarkId.length === 0) {
      return;
    }
    if (this.editingNoteText.trim().length === 0) {
      promptAction.showToast({ message: '笔记内容不能为空' });
      return;
    }
    BookmarkStore.shared().updateNote(this.editingBookmarkId, this.editingNoteText.trim(), '');
    this.editingBookmarkId = '';
    this.editingNoteText = '';
    this.refreshBookmarks();
    promptAction.showToast({ message: '笔记已更新' });
  }

  private deleteBookmark(item: BookmarkItem): void {
    BookmarkStore.shared().remove(item.id);
    this.refreshBookmarks();
  }

  private positionLabel(): string {
    if (this.readerKind === 'pdf') {
      return '第 ' + this.currentPage + ' 页';
    }
    if (this.readerKind === 'comic') {
      return this.comicLabel;
    }
    return '第 ' + this.currentPage + ' / ' + Math.max(1, this.totalPages) + ' 页 · ' +
      Math.round(this.shownProgress * 100) + '%';
  }

  private openSearch(): void {
    if (this.readerKind === 'comic') {
      return;
    }
    this.searchOpen = true;
  }

  private runSearch(query: string): void {
    this.searchQuery = query;
    if (query.trim().length === 0) {
      this.searchCount = 0;
      if (this.readerKind === 'html') {
        this.runJs('window.easyreadPager && window.easyreadPager.clearMarks()');
      } else if (this.readerKind === 'pdf') {
        this.pdfController.clearSearch();
      }
      return;
    }
    if (this.readerKind === 'html') {
      this.runJs('window.easyreadPager && window.easyreadPager.find(' + JSON.stringify(query) + ')');
    } else if (this.readerKind === 'pdf') {
      if (!this.pdfLoaded) {
        return;
      }
      this.pdfController.searchKey(query, (count: number): void => {
        this.searchCount = count;
        this.searchIndex = count > 0 ? 1 : 0;
        if (count > 0) {
          this.pdfController.setSearchIndex(0);
        }
      });
    }
  }

  private searchNext(): void {
    if (this.searchCount <= 0) {
      return;
    }
    if (this.readerKind === 'html') {
      this.runJs('window.easyreadPager && window.easyreadPager.findNext()');
    } else if (this.readerKind === 'pdf') {
      if (!this.pdfLoaded) {
        return;
      }
      this.searchIndex = this.searchIndex >= this.searchCount ? 1 : this.searchIndex + 1;
      this.pdfController.setSearchIndex(this.searchIndex - 1);
    }
  }

  private searchPrevious(): void {
    if (this.searchCount <= 0) {
      return;
    }
    if (this.readerKind === 'html') {
      this.runJs('window.easyreadPager && window.easyreadPager.findPrevious()');
    } else if (this.readerKind === 'pdf') {
      if (!this.pdfLoaded) {
        return;
      }
      this.searchIndex = this.searchIndex <= 1 ? this.searchCount : this.searchIndex - 1;
      this.pdfController.setSearchIndex(this.searchIndex - 1);
    }
  }

  private closeSearch(): void {
    this.searchOpen = false;
    if (this.readerKind === 'html') {
      this.runJs('window.easyreadPager && window.easyreadPager.clearMarks()');
    } else if (this.readerKind === 'pdf') {
      this.pdfController.clearSearch();
    }
    this.searchCount = 0;
    this.searchQuery = '';
  }

  private async showBookMenu(book: LibraryBook): Promise<void> {
    try {
      const buttons: [
        promptAction.Button,
        promptAction.Button?,
        promptAction.Button?,
        promptAction.Button?,
        promptAction.Button?,
        promptAction.Button?
      ] = [{ text: '打开', color: Theme.accent(this.themeName) }];
      const actions: string[] = ['open'];
      if (book.source === BookSource.JIANGUOYUN) {
        buttons[1] = { text: '删除本地副本', color: Theme.muted(this.themeName) };
        actions.push('delete-local');
        buttons[2] = { text: '从云端删除并移出书架', color: '#B04A3A' };
        actions.push('delete-cloud');
      } else {
        buttons[1] = { text: '移出书架', color: Theme.muted(this.themeName) };
        actions.push('remove');
        buttons[2] = { text: '删除本地文件', color: '#B04A3A' };
        actions.push('delete-local');
      }
      const response = await this.getUIContext().getPromptAction().showActionMenu({
        title: book.title,
        buttons: buttons
      });
      const action = response.index >= 0 && response.index < actions.length ? actions[response.index] : '';
      if (action === 'open') {
        this.openBook(book);
      } else if (action === 'remove') {
        BookmarkStore.shared().removeForBook(book.id);
        LibraryStore.shared().remove(book.id);
        this.refreshBooks();
        if (book.id === this.currentBookId) {
          this.closeReader();
        }
        promptAction.showToast({ message: '已移出书架，文件仍保留' });
      } else if (action === 'delete-local') {
        BookService.shared().deleteBookData(book);
        BookmarkStore.shared().removeForBook(book.id);
        LibraryStore.shared().remove(book.id);
        this.refreshBooks();
        if (book.id === this.currentBookId) {
          this.closeReader();
        }
        promptAction.showToast({
          message: book.source === BookSource.JIANGUOYUN ? '已删除本地副本，下次同步会重新下载' : '已删除本地文件'
        });
      } else if (action === 'delete-cloud') {
        if (this.syncBusy) {
          promptAction.showToast({ message: '同步进行中，请稍后再试' });
          return;
        }
        this.syncBusy = true;
        this.syncStatus = '正在写入云端删除快照…';
        try {
          const snapshot = await ZenSyncService.shared().deleteCloudBook(book);
          BookService.shared().deleteBookData(book);
          BookmarkStore.shared().removeForBook(book.id);
          LibraryStore.shared().remove(book.id);
          this.refreshBooks();
          if (book.id === this.currentBookId) {
            this.closeReader();
          }
          promptAction.showToast({
            message: snapshot !== null ? '已从云端删除，并移出书架' : '云端未找到这本书，已移出本机书架'
          });
          this.syncStatus = '已写入云端删除快照';
          this.lastSyncText = '上次同步 ' + this.timeText(Date.now());
        } catch (error) {
          this.syncStatus = '删除失败：' + this.errorText(error);
          promptAction.showToast({ message: this.syncStatus });
        } finally {
          this.syncBusy = false;
        }
      }
    } catch (error) {
    }
  }

  private switchSource(source: string): void {
    this.activeSource = source;
    LibraryStore.shared().activeSource = source;
    LibraryStore.shared().scheduleSave();
    this.refreshBooks();
  }

  private openSyncPanel(): void {
    const config = SettingsStore.shared().sync;
    this.syncProvider = config.provider;
    this.syncServer = config.server;
    this.syncUser = config.username;
    this.syncPassword = config.password;
    this.syncAuto = config.autoSync;
    this.syncNamespace = config.remoteFolder;
    this.panel = 'sync';
  }

  /**
   * Pull-to-refresh on the shelf: merge cloud progress for the WebDAV shelf,
   * rescan the linked folder for the local shelf.
   */
  private async refreshShelf(): Promise<void> {
    try {
      if (this.activeSource === BookSource.WEBDAV) {
        const config = SettingsStore.shared().sync;
        if (config.username.trim().length === 0 || config.password.length === 0) {
          promptAction.showToast({ message: '请先填写 WebDAV 账号和应用密码' });
          this.openSyncPanel();
          return;
        }
        await this.runSync('both');
      } else if (LibraryStore.shared().localFolderUri.length > 0) {
        if (!this.folderBusy) {
          await this.scanLocalFolder();
        }
      } else {
        this.refreshBooks();
      }
    } finally {
      this.shelfRefreshing = false;
    }
  }

  private async runSync(mode: string): Promise<void> {
    if (!this.privacyAccepted || this.syncBusy) {
      return;
    }
    const config = SettingsStore.shared().sync;
    config.provider = this.syncProvider;
    config.server = this.syncServer;
    config.username = this.syncUser;
    config.password = this.syncPassword;
    config.autoSync = this.syncAuto;
    config.remoteFolder = this.syncNamespace;
    SettingsStore.shared().saveSync();
    if (config.username.trim().length === 0 || config.password.length === 0) {
      promptAction.showToast({ message: '请先填写 WebDAV 账号和应用密码' });
      return;
    }
    this.syncBusy = true;
    this.syncStatus = '准备同步…';
    const openBookId = this.currentBookId;
    const openProgress = this.progress;
    try {
      const result = await ZenSyncService.shared().sync(
        LibraryStore.shared().books, mode,
        (stage: string, done: number, total: number): void => {
          this.syncStatus = total > 0 ? stage + ' ' + done + '/' + total : stage;
        }
      );
      this.refreshBooks();
      if (this.currentBookId.length > 0 && LibraryStore.shared().find(this.currentBookId) === null) {
        this.closeReader();
      } else if (this.currentBookId.length === 0 && this.webBookId.length > 0 &&
        LibraryStore.shared().find(this.webBookId) === null) {
        // The book whose page is kept warm behind the shelf no longer exists.
        this.webBookId = '';
        this.webUrl = '';
        this.readerKind = 'none';
        this.chapters = [];
      } else if (openBookId.length > 0 && openBookId === this.currentBookId &&
        this.currentBook !== null) {
        const cloudPosition = this.currentBook.syncedPosition();
        if (Math.abs(cloudPosition - openProgress) > 0.001 &&
          Math.abs(this.progress - openProgress) < 0.001) {
          // The cloud moved this book while it was open and the reader has not
          // turned a page since. Do not write the stale on-screen position
          // back over the newer cloud one when the reader closes.
          this.suppressFlushOnce = true;
        }
      }
      const parts: string[] = [];
      if (result.downloadedBooks > 0) {
        parts.push('下载 ' + result.downloadedBooks + ' 本');
      }
      if (result.uploadedBooks > 0) {
        parts.push('上传 ' + result.uploadedBooks + ' 本');
      }
      if (result.pulled > 0) {
        parts.push('更新 ' + result.pulled + ' 本进度');
      }
      if (result.pushed > 0) {
        parts.push('上传 ' + result.pushed + ' 本进度');
      }
      if (result.removedBookIds.length > 0) {
        parts.push('移除 ' + result.removedBookIds.length + ' 本');
      }
      if (result.failures.length > 0) {
        parts.push(result.failures.length + ' 本失败');
      }
      this.syncStatus = parts.length > 0 ? '同步完成 · ' + parts.join('，') : '书籍与进度已是最新';
      this.lastSyncText = '上次同步 ' + this.timeText(Date.now());
      if (result.manifestWarning.length > 0) {
        this.syncStatus += '（' + result.manifestWarning + '）';
      }
      if (this.currentBook !== null) {
        this.refreshBookmarks();
      }
      promptAction.showToast({ message: this.syncStatus });
    } catch (error) {
      this.syncStatus = '同步失败：' + this.errorText(error);
      promptAction.showToast({ message: this.syncStatus });
    } finally {
      this.syncBusy = false;
    }
  }

  private async testSyncConnection(): Promise<void> {
    if (!this.privacyAccepted) {
      return;
    }
    try {
      const client = new WebDavClient(this.syncServer, this.syncUser, this.syncPassword,
        this.syncNamespace);
      const count = await client.testConnection();
      const folder = this.syncNamespace === SyncNamespace.ZENREADER ? 'ZenReader/v1' : 'EasyRead';
      promptAction.showToast({
        message: count > 0 ?
          '连接成功，' + folder + ' 有 ' + count + ' 份快照' :
          '连接成功，已准备 ' + folder + '（云端暂无快照）'
      });
    } catch (error) {
      promptAction.showToast({ message: '连接失败：' + this.errorText(error) });
    }
  }

  private saveSyncSettings(): void {
    const config = SettingsStore.shared().sync;
    config.provider = this.syncProvider;
    config.server = this.syncServer;
    config.username = this.syncUser;
    config.password = this.syncPassword;
    config.autoSync = this.syncAuto;
    config.remoteFolder = this.syncNamespace;
    SettingsStore.shared().saveSync();
    this.lastSyncText = config.lastSyncAt > 0 ? '上次同步 ' + this.timeText(config.lastSyncAt) : '尚未同步';
    promptAction.showToast({ message: 'WebDAV 设置已保存' });
  }

  private providerLabel(): string {
    if (this.syncProvider === SyncProvider.NEXTCLOUD) {
      return 'Nextcloud';
    }
    if (this.syncProvider === SyncProvider.CUSTOM) {
      return '自定义 WebDAV';
    }
    return '坚果云';
  }

  private providerServerPlaceholder(): string {
    if (this.syncProvider === SyncProvider.NEXTCLOUD) {
      return 'https://cloud.example.com/remote.php/dav/files/用户名/';
    }
    if (this.syncProvider === SyncProvider.CUSTOM) {
      return 'https://example.com/dav/';
    }
    return 'https://dav.jianguoyun.com/dav/';
  }

  private providerAccountLabel(): string {
    return this.syncProvider === SyncProvider.JIANGUOYUN ? '账号（邮箱）' : '账号';
  }

  private providerAccountPlaceholder(): string {
    return this.syncProvider === SyncProvider.JIANGUOYUN ? '坚果云账号邮箱' : 'WebDAV 账号';
  }

  private providerPasswordHint(): string {
    if (this.syncProvider === SyncProvider.JIANGUOYUN) {
      return '请在坚果云「账户信息 → 安全选项」中生成「第三方应用密码」，不要使用登录密码。密码只保存在应用私有目录中。';
    }
    return '填写 WebDAV 的应用密码或访问令牌，不要使用账户主密码。密码只保存在应用私有目录中。';
  }

  private selectSyncProvider(provider: string): void {
    this.syncProvider = provider;
    const jianguoyun = 'https://dav.jianguoyun.com/dav/';
    const current = this.syncServer.trim();
    if (provider === SyncProvider.JIANGUOYUN) {
      if (current.length === 0 || current === 'https://dav.jianguoyun.com/dav') {
        this.syncServer = jianguoyun;
      }
    } else if (current === jianguoyun || current === 'https://dav.jianguoyun.com/dav') {
      this.syncServer = '';
    }
  }

  private clearSyncSettings(): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '清除 WebDAV 配置',
      message: '将清除服务器地址、账号和应用密码，不会删除书架里的书与阅读进度。',
      buttons: [
        { text: '取消', color: Theme.muted(this.themeName) },
        { text: '清除', color: '#B04A3A' }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): void => {
      if (result.index !== 1) {
        return;
      }
      const config = SettingsStore.shared().sync;
      config.provider = SyncProvider.JIANGUOYUN;
      config.server = 'https://dav.jianguoyun.com/dav/';
      config.username = '';
      config.password = '';
      config.lastSyncAt = 0;
      config.remoteFolder = SyncNamespace.EASYREAD;
      SettingsStore.shared().saveSync();
      this.syncProvider = config.provider;
      this.syncServer = config.server;
      this.syncUser = '';
      this.syncPassword = '';
      this.syncNamespace = config.remoteFolder;
      this.syncStatus = '';
      this.lastSyncText = '尚未同步';
      promptAction.showToast({ message: '已清除 WebDAV 配置' });
    }).catch((error: BusinessError): void => {
    });
  }

  private async chooseLocalFolder(): Promise<void> {
    if (!FolderService.canPickFolder()) {
      promptAction.showToast({ message: '当前设备不支持选择文件夹，请改选多本文件' });
      this.importBooks();
      return;
    }
    try {
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.selectMode = picker.DocumentSelectMode.FOLDER;
      const documentPicker = new picker.DocumentViewPicker(getContext(this));
      const uris = await documentPicker.select(options);
      if (uris.length === 0) {
        return;
      }
      const uri = uris[0];
      const name = FolderService.folderName(uri);
      const store = LibraryStore.shared();
      store.localFolderUri = uri;
      store.localFolderName = name;
      store.scheduleSave();
      this.localFolderName = name;
      this.folderStatus = '';
      await FolderService.persist(uri);
      await this.scanLocalFolder();
    } catch (error) {
      promptAction.showToast({ message: '选择文件夹失败：' + this.errorText(error) });
    }
  }

  private async scanLocalFolder(): Promise<void> {
    const store = LibraryStore.shared();
    if (store.localFolderUri.length === 0) {
      // Refresh must stay a refresh even when no folder is linked. Opening the
      // folder picker here made the refresh button look like a second import
      // entry; directory import already has its own folder button.
      this.refreshBooks();
      promptAction.showToast({ message: '书架已刷新；整目录导入请点击左侧文件夹按钮' });
      return;
    }
    this.folderBusy = true;
    this.folderStatus = '正在扫描「' + this.localFolderName + '」…';
    try {
      await FolderService.activate(store.localFolderUri);
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 30);
      });
      const scan = await FolderService.scanAsync(store.localFolderUri);
      if (scan.error.length > 0) {
        this.folderStatus = '';
        promptAction.showToast({ message: scan.error });
        return;
      }
      this.folderStatus = '正在核对 ' + scan.files.length + ' 本书…';
      const imported = await BookService.shared().importBooksAsync(scan.files, BookSource.LOCAL,
        (done: number, total: number, name: string): void => {
          if (done < total) {
            this.folderStatus = '正在核对 ' + (done + 1) + '/' + total + ' · ' + name;
          }
        });
      if (this.activeSource !== BookSource.LOCAL) {
        this.switchSource(BookSource.LOCAL);
      } else {
        this.refreshBooks();
      }
      if (imported.length > 0) {
        this.folderStatus = '已从文件夹导入 ' + imported.length + ' 本书';
      } else if (scan.files.length > 0) {
        this.folderStatus = '文件夹里的书都已在书架中';
      } else {
        this.folderStatus = '文件夹里没有可导入的书';
      }
      promptAction.showToast({ message: this.folderStatus });
    } catch (error) {
      this.folderStatus = '扫描失败：' + this.errorText(error);
      promptAction.showToast({ message: this.folderStatus });
    } finally {
      this.folderBusy = false;
    }
  }

  private errorText(error: Object): string {
    if (error instanceof Error) {
      return error.message;
    }
    return String(error);
  }

  @Builder
  shelfPanel() {
    Column() {
      Row({ space: this.isWide ? 4 : 10 }) {
        Column({ space: 2 }) {
          Text('EasyRead')
            .fontSize(this.isWide ? 22 : 28)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.fg(this.themeName))
            .fontFamily('serif')
            .maxLines(1)
          Text('Tablet Reader')
            .fontSize(10)
            .fontColor(Theme.muted(this.themeName))
            .letterSpacing(1.2)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        ToolButton({
          icon: 'plus',
          iconSize: 21,
          color: Theme.accent(this.themeName),
          buttonWidth: this.isWide ? 34 : 40,
          onTap: (): void => {
            this.importBooks();
          }
        })
        ToolButton({
          icon: this.shelfLayout === 'grid' ? 'list' : 'grid',
          iconSize: 19,
          color: Theme.muted(this.themeName),
          buttonWidth: this.isWide ? 34 : 40,
          onTap: (): void => {
            this.toggleShelfLayout();
          }
        })
        ToolButton({
          label: '隐私',
          fontSize: 11,
          color: Theme.muted(this.themeName),
          buttonWidth: this.isWide ? 38 : 40,
          onTap: (): void => {
            this.panel = 'privacy';
          }
        })
        if (this.isWide) {
          ToolButton({
            icon: 'sidebar-close',
            iconSize: 18,
            color: Theme.muted(this.themeName),
            buttonWidth: 34,
            onTap: (): void => {
              this.toggleShelf();
            }
          })
        }
      }
      .width('100%')
      .padding({ left: 20, right: 16, top: 18 })

      Row({ space: 4 }) {
        Row({ space: 6 }) {
          LibraryChip({
            label: '本地书库',
            count: this.localBookCount,
            selected: this.activeSource === BookSource.LOCAL,
            themeName: this.themeName,
            onTap: (): void => {
              this.switchSource(BookSource.LOCAL);
            }
          })
          LibraryChip({
            label: 'WebDAV书库',
            count: this.cloudBookCount,
            selected: this.activeSource === BookSource.WEBDAV,
            themeName: this.themeName,
            onTap: (): void => {
              this.switchSource(BookSource.WEBDAV);
            }
          })
        }
        .height(40)
        .alignItems(VerticalAlign.Center)

        if (this.activeSource === BookSource.LOCAL) {
          ToolButton({
            icon: 'folder',
            iconSize: 18,
            color: Theme.accent(this.themeName),
            buttonWidth: this.isWide ? 34 : 40,
            onTap: (): void => {
              this.chooseLocalFolder();
            }
          })
          ToolButton({
            icon: 'refresh',
            iconSize: 18,
            color: Theme.muted(this.themeName),
            buttonWidth: this.isWide ? 34 : 40,
            onTap: (): void => {
              if (!this.folderBusy) {
                this.scanLocalFolder();
              }
            }
          })
        } else {
          ToolButton({
            icon: 'gear',
            iconSize: 18,
            color: Theme.muted(this.themeName),
            buttonWidth: this.isWide ? 34 : 40,
            onTap: (): void => {
              this.openSyncPanel();
            }
          })
          ToolButton({
            icon: 'sync',
            iconSize: 18,
            color: this.syncBusy ? Theme.muted(this.themeName) : Theme.accent(this.themeName),
            buttonWidth: this.isWide ? 34 : 40,
            onTap: (): void => {
              if (!this.syncBusy) {
                this.runSync('both');
              }
            }
          })
        }
        Blank()
      }
      .width('100%')
      .padding({ left: 20, right: 12, top: 14 })

      if (this.folderBusy || this.syncBusy) {
        Row({ space: 8 }) {
          LoadingProgress().width(14).height(14).color(Theme.accent(this.themeName))
          Text(this.folderBusy ? this.folderStatus : this.syncStatus)
            .fontSize(11)
            .fontColor(Theme.muted(this.themeName))
            .maxLines(2)
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 8 })
      } else if (this.activeSource === BookSource.LOCAL) {
        Text(this.localFolderName.length > 0
          ? '本地文件夹 · ' + this.localFolderName +
            (this.folderStatus.length > 0 ? ' · ' + this.folderStatus : '')
          : '未关联文件夹，可用书库标签旁的文件夹按钮整目录导入')
          .fontSize(11)
          .fontColor(Theme.muted(this.themeName))
          .maxLines(2)
          .width('100%')
          .padding({ left: 20, right: 20, top: 8 })
      } else if (this.syncStatus.length > 0) {
        Text(this.syncStatus)
          .fontSize(11)
          .fontColor(Theme.muted(this.themeName))
          .maxLines(2)
          .width('100%')
          .padding({ left: 20, right: 20, top: 8 })
      } else if (this.lastSyncText.length > 0) {
        Text(this.lastSyncText + (this.activeSource === BookSource.WEBDAV ? ' · 下拉可同步' : ''))
          .fontSize(11)
          .fontColor(Theme.muted(this.themeName))
          .maxLines(1)
          .width('100%')
          .padding({ left: 20, right: 20, top: 8 })
      }

      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(16)
          .fontColor([Theme.muted(this.themeName)])
        TextInput({ text: this.shelfQuery, placeholder: '搜索书名或作者' })
          .fontSize(13)
          .fontColor(Theme.fg(this.themeName))
          .placeholderColor(Theme.muted(this.themeName))
          .backgroundColor('#00000000')
          .padding(0)
          .layoutWeight(1)
          .onChange((value: string): void => {
            this.shelfQuery = value;
          })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .backgroundColor(Theme.surface(this.themeName))
      .borderRadius(12)
      .margin({ left: 20, right: 20, top: 10 })

      if (this.visibleBooks().length === 0) {
        Column({ space: 10 }) {
          Blank()
          Text(this.shelfQuery.length > 0 ? '没有匹配的书' : '书架还是空的')
            .fontSize(16)
            .fontColor(Theme.fg(this.themeName))
          Text(this.shelfQuery.length > 0
            ? '换个关键词试试'
            : (this.activeSource === BookSource.WEBDAV
              ? '下拉刷新或点书库标签旁的同步按钮，从 WebDAV 云端拉取书籍与进度'
              : '从文件导入，或选择整个文件夹批量导入'))
            .fontSize(12)
            .fontColor(Theme.muted(this.themeName))
            .textAlign(TextAlign.Center)
          if (this.shelfQuery.length === 0) {
            Row({ space: 8 }) {
              Button('从文件导入')
                .fontSize(13)
                .fontColor(this.activeSource === BookSource.LOCAL
                  ? Theme.bg(this.themeName) : Theme.fg(this.themeName))
                .backgroundColor(this.activeSource === BookSource.LOCAL
                  ? Theme.accent(this.themeName) : Theme.surface(this.themeName))
                .borderRadius(18)
                .height(36)
                .onClick((): void => {
                  this.importBooks();
                })
              if (this.activeSource === BookSource.LOCAL) {
                Button('选择文件夹')
                  .fontSize(13)
                  .fontColor(Theme.fg(this.themeName))
                  .backgroundColor(Theme.surface(this.themeName))
                  .borderRadius(18)
                  .height(36)
                  .onClick((): void => {
                    this.chooseLocalFolder();
                  })
              } else {
                Button('立即同步')
                  .fontSize(13)
                  .fontColor(Theme.fg(this.themeName))
                  .backgroundColor(Theme.surface(this.themeName))
                  .borderRadius(18)
                  .height(36)
                  .enabled(!this.syncBusy)
                  .onClick((): void => {
                    this.runSync('both');
                  })
              }
            }
            .margin({ top: 6 })
          }
          Blank()
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.shelfLayout === 'list') {
        Refresh({
          refreshing: $$this.shelfRefreshing,
          promptText: this.activeSource === BookSource.WEBDAV
            ? '下拉同步云端进度' : '下拉刷新书架'
        }) {
          List({ space: 8 }) {
            ForEach(this.visibleBooks(), (book: LibraryBook): void => {
              ListItem() {
                BookRow({
                  book: book,
                  themeName: this.themeName,
                  onOpen: (selected: LibraryBook): void => {
                    this.openBook(selected);
                  },
                  onMenu: (selected: LibraryBook): void => {
                    this.showBookMenu(selected);
                  }
                })
              }
            }, (book: LibraryBook): string => book.id + ':' +
              Math.round(book.displayProgress() * 100) + ':' + book.progressUpdatedAt)
          }
          .width('100%')
          .height('100%')
          .padding({ left: 20, right: 20, top: 12, bottom: 24 })
          .scrollBar(BarState.Off)
        }
        .width('100%')
        .layoutWeight(1)
        .onRefreshing((): void => {
          this.refreshShelf();
        })
      } else {
        Refresh({
          refreshing: $$this.shelfRefreshing,
          promptText: this.activeSource === BookSource.WEBDAV
            ? '下拉同步云端进度' : '下拉刷新书架'
        }) {
          Grid() {
            ForEach(this.visibleBooks(), (book: LibraryBook): void => {
              GridItem() {
                BookCover({
                  book: book,
                  themeName: this.themeName,
                  onOpen: (selected: LibraryBook): void => {
                    this.openBook(selected);
                  },
                  onMenu: (selected: LibraryBook): void => {
                    this.showBookMenu(selected);
                  }
                })
              }
            }, (book: LibraryBook): string => book.id + ':' +
              Math.round(book.displayProgress() * 100) + ':' +
              (book.coverPath.length > 0 ? 'c' : '') + ':' + book.title.length)
          }
          .columnsTemplate(this.isWide ? '1fr 1fr' : '1fr 1fr 1fr')
          .columnsGap(14)
          .rowsGap(18)
          .width('100%')
          .height('100%')
          .padding({ left: 20, right: 20, top: 18, bottom: 24 })
          .scrollBar(BarState.Off)
        }
        .width('100%')
        .layoutWeight(1)
        .onRefreshing((): void => {
          this.refreshShelf();
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.themeName))
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  welcomePanel() {
    Column({ space: 18 }) {
      Blank()
      Text('EasyRead')
        .fontSize(46)
        .fontFamily('serif')
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.fg(this.themeName))
      Text('为平板而做的本地阅读器')
        .fontSize(14)
        .fontColor(Theme.muted(this.themeName))
        .letterSpacing(2)
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
        ForEach(['TXT', 'MD', 'EPUB', 'PDF', 'MOBI', 'CBZ', 'FB2', 'DOCX'], (format: string): void => {
          Text(format)
            .fontSize(10)
            .fontColor(Theme.muted(this.themeName))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .borderRadius(6)
            .backgroundColor(Theme.surface(this.themeName))
            .margin(4)
        }, (format: string): string => format)
      }
      .width('100%')
      .constraintSize({ maxWidth: 520 })
      Text('双栏排版 · 目录搜索 · 书签笔记 · WebDAV 同步')
        .fontSize(12)
        .fontColor(Theme.muted(this.themeName))
        .margin({ top: 4 })
      Button('选择一本书开始')
        .fontSize(14)
        .fontColor(Theme.bg(this.themeName))
        .backgroundColor(Theme.accent(this.themeName))
        .borderRadius(22)
        .height(44)
        .padding({ left: 26, right: 26 })
        .margin({ top: 10 })
        .onClick((): void => {
          const list = this.visibleBooks();
          if (list.length > 0) {
            this.openBook(list[0]);
          } else {
            this.importBooks();
          }
        })
      Blank()
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(Theme.bg(this.themeName))
  }

  @Builder
  readerToolbar() {
    Row({ space: 2 }) {
      if (!this.isWide) {
        ToolButton({
          icon: 'back',
          iconSize: 22,
          color: Theme.fg(this.themeName),
          onTap: (): void => {
            this.closeReader();
          }
        })
      } else {
        ToolButton({
          icon: this.shelfVisible ? 'sidebar-close' : 'sidebar-open',
          iconSize: 19,
          color: Theme.muted(this.themeName),
          onTap: (): void => {
            this.toggleShelf();
          }
        })
      }
      Column({ space: 2 }) {
        Text(this.currentBook !== null ? this.currentBook.title : '')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.fg(this.themeName))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.currentBook !== null && this.currentBook.author.length > 0
          ? this.currentBook.author
          : (this.readerKind === 'html' && this.pageMode === 'scroll'
            ? Math.round(this.shownProgress * 100) + '%'
            : this.positionLabel()))
          .fontSize(10)
          .fontColor(Theme.muted(this.themeName))
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .padding({ left: 6 })

      if (this.readerKind === 'html') {
        Text(this.pageMode === 'paged' ? '⇆ 翻页' : '↕ 滚动')
          .fontSize(11)
          .fontColor(this.pageMode === 'paged' ? Theme.accent(this.themeName) : Theme.muted(this.themeName))
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .backgroundColor(Theme.surface(this.themeName))
          .borderRadius(12)
          .margin({ right: 4 })
          .onClick((): void => {
            this.togglePageMode();
          })
      }
      ToolButton({
        icon: 'toc',
        iconSize: 19,
        color: Theme.fg(this.themeName),
        onTap: (): void => {
          this.showTocPanel();
        }
      })
      if (this.readerKind !== 'comic') {
        ToolButton({
          icon: 'search',
          iconSize: 19,
          color: Theme.fg(this.themeName),
          onTap: (): void => {
            this.openSearch();
          }
        })
      }
      ToolButton({
        icon: 'bookmark',
        iconSize: 19,
        color: Theme.fg(this.themeName),
        onTap: (): void => {
          this.panelTab = 'marks';
          this.panel = 'reader';
        }
      })
      if (this.readerKind === 'html' || this.readerKind === 'pdf') {
        ToolButton({
          icon: 'note',
          iconSize: 19,
          color: Theme.fg(this.themeName),
          onTap: (): void => {
            this.panelTab = 'notes';
            this.panel = 'reader';
          }
        })
      }
      ToolButton({
        icon: 'textformat',
        iconSize: 19,
        color: Theme.fg(this.themeName),
        onTap: (): void => {
          this.panel = 'settings';
        }
      })
      if (this.isWide) {
        ToolButton({
          icon: 'close',
          iconSize: 18,
          color: Theme.muted(this.themeName),
          onTap: (): void => {
            this.closeReader();
          }
        })
      }
    }
    .width('100%')
    .height(52)
    .padding({ left: this.isWide ? 10 : 2, right: 8 })
    .backgroundColor(Theme.bg(this.themeName))
    .border({ width: { bottom: 1 }, color: Theme.line(this.themeName) })
  }

  @Builder
  readerContent() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.readerKind === 'pdf') {
        PdfView({
          controller: this.pdfController,
          pageFit: pdfService.PageFit.FIT_WIDTH,
          showScroll: true
        })
          .width('100%')
          .height('100%')
          .backgroundColor(Theme.bg(this.themeName))
        Row()
          .width('100%')
          .height('100%')
          .hitTestBehavior(HitTestMode.Transparent)
          .onClick((event: ClickEvent): void => {
            if (event.y < 110 || event.y > this.readerPaneHeight - 60) {
              return;
            }
            this.toggleChrome();
          })
      }
      if (this.errorMessage.length > 0) {
        Column({ space: 12 }) {
          Text('无法打开这本书')
            .fontSize(16)
            .fontColor(Theme.fg(this.themeName))
          Text(this.errorMessage)
            .fontSize(12)
            .fontColor(Theme.muted(this.themeName))
            .textAlign(TextAlign.Center)
            .maxLines(5)
          Button('返回书架')
            .fontSize(13)
            .fontColor(Theme.bg(this.themeName))
            .backgroundColor(Theme.accent(this.themeName))
            .borderRadius(18)
            .onClick((): void => {
              this.closeReader();
            })
        }
        .width('100%')
        .height('100%')
        .padding(28)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Theme.bg(this.themeName))
      } else if (this.readerKind === 'html' && this.webUrl.length > 0) {
        Web({ src: this.webUrl, controller: this.webController })
          .javaScriptAccess(true)
          .fileAccess(true)
          .domStorageAccess(true)
          .imageAccess(true)
          .zoomAccess(false)
          .horizontalScrollBarAccess(false)
          .verticalScrollBarAccess(false)
          .javaScriptProxy({
            object: this.bridge,
            name: 'easyread',
            methodList: ['postMessage', 'getConfig'],
            controller: this.webController
          })
          .width('100%')
          .height('100%')
          .backgroundColor(Theme.bg(this.themeName))
      } else if (this.readerKind === 'comic') {
        Column() {
          Stack({ alignContent: Alignment.Center }) {
            if (this.comicPaths.length === 2) {
              Row({ space: 2 }) {
                Image(this.comicPaths[0]).height('100%').layoutWeight(1).objectFit(ImageFit.Contain)
                Image(this.comicPaths[1]).height('100%').layoutWeight(1).objectFit(ImageFit.Contain)
              }
              .width('100%')
              .height('100%')
            } else if (this.comicPaths.length === 1) {
              Image(this.comicPaths[0])
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Contain)
            } else {
              LoadingProgress().width(30).height(30).color('#FFFFFF')
            }
            Row() {
              Text('‹')
                .fontSize(26)
                .fontColor('#AAFFFFFF')
                .width(48)
                .height(72)
                .textAlign(TextAlign.Center)
                .backgroundColor('#44000000')
                .borderRadius(12)
                .onClick((): void => {
                  this.comicPrevious();
                })
              Blank()
              Text('›')
                .fontSize(26)
                .fontColor('#AAFFFFFF')
                .width(48)
                .height(72)
                .textAlign(TextAlign.Center)
                .backgroundColor('#44000000')
                .borderRadius(12)
                .onClick((): void => {
                  this.comicNext();
                })
            }
            .width('100%')
            .padding({ left: 8, right: 8 })
          }
          .width('100%')
          .layoutWeight(1)
          .backgroundColor('#0B0C0D')
          .onAreaChange((oldArea: Area, newArea: Area): void => {
            const width = Number(newArea.width);
            if (!isNaN(width) && width > 0) {
              this.comicAreaWidth = width;
            }
          })
          .onClick((event: ClickEvent): void => {
            const width = this.comicAreaWidth > 0 ? this.comicAreaWidth : this.screenWidth;
            if (event.x < 70 || event.x > width - 70 ||
              event.y < 110 || event.y > this.readerPaneHeight - 90) {
              return;
            }
            this.toggleChrome();
          })
          .gesture(PanGesture({ direction: PanDirection.Horizontal, distance: 10 })
            .onActionEnd((event: GestureEvent): void => {
              if (event.offsetX < -40) {
                this.comicNext();
              } else if (event.offsetX > 40) {
                this.comicPrevious();
              }
            }))
          Row({ space: 12 }) {
            Text(this.comicLabel)
              .fontSize(11)
              .fontColor(Theme.muted(this.themeName))
            Blank()
            Text(this.comicTwoPage ? '双页' : '单页')
              .fontSize(11)
              .fontColor(Theme.accent(this.themeName))
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .borderRadius(10)
              .backgroundColor(Theme.surface(this.themeName))
              .onClick((): void => {
                this.toggleComicSpread();
              })
          }
          .width('100%')
          .height(36)
          .padding({ left: 16, right: 16 })
          .backgroundColor(Theme.bg(this.themeName))
        }
        .width('100%')
        .height('100%')
      }
      // The veil sits on top of the live reader instead of replacing it: if it
      // were part of the same condition, every window switch would tear down
      // and recreate the WebView, costing several seconds per reload.
      if (this.loading) {
        Column({ space: 12 }) {
          LoadingProgress().width(34).height(34).color(Theme.accent(this.themeName))
          Text(this.readerKind === 'pdf' ? '正在打开 PDF…' : '正在排版…')
            .fontSize(12)
            .fontColor(Theme.muted(this.themeName))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Theme.bg(this.themeName))
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((oldArea: Area, newArea: Area): void => {
      const height = Number(newArea.height);
      if (!isNaN(height) && height > 0) {
        this.readerPaneHeight = height;
      }
    })
  }

  @Builder
  readerBottom() {
    if (this.showProgress && !this.loading && this.errorMessage.length === 0) {
      Row({ space: 12 }) {
        Text(this.readerKind === 'comic'
          ? this.comicLabel
          : (this.readerKind === 'html'
            ? (this.pageMode === 'paged'
              ? this.currentPage + ' / ' + Math.max(1, this.totalPages) + ' · ' +
                Math.round(this.shownProgress * 100) + '%'
              : Math.round(this.shownProgress * 100) + '%')
            : this.currentPage + ' / ' + Math.max(1, this.totalPages)))
          .fontSize(11)
          .fontColor(Theme.muted(this.themeName))
          .width(this.readerKind === 'html' && this.pageMode === 'paged' ? 104 : 72)
        Slider({
          value: this.readerKind === 'comic' ? this.comicIndex :
            (this.readerKind === 'html'
              ? Math.round(this.shownProgress * 1000)
              : Math.max(0, this.currentPage - 1)),
          min: 0,
          max: this.readerKind === 'comic' ? Math.max(1, this.comicPageCount - 1) :
            (this.readerKind === 'html'
              ? 1000
              : Math.max(1, this.totalPages - 1)),
          step: 1,
          style: SliderStyle.OutSet
        })
          .layoutWeight(1)
          .blockColor(Theme.accent(this.themeName))
          .selectedColor(Theme.accent(this.themeName))
          .trackColor(Theme.line(this.themeName))
          .onChange((value: number, mode: SliderChangeMode): void => {
            if (mode !== SliderChangeMode.End) {
              return;
            }
            if (this.readerKind === 'html') {
              // The slider follows the whole book; the page engine loads the
              // matching window when the target lies outside the current one.
              // Its value is the ZenReader percentage shown in the label, so
              // convert it back to the local character fraction for the page.
              const percent = Math.min(Math.max(value / 1000, 0), 1);
              let target = percent;
              if (this.currentBook !== null && this.currentBook.source === BookSource.WEBDAV) {
                const model = this.zenModel;
                const converted = model !== null
                  ? ZenTextLocator.progressFromPercent(percent * 100, '', false, model)
                  : null;
                if (converted !== null) {
                  target = converted;
                } else if (this.chapters.length > 0) {
                  target = ReaderProgress.characterProgress(percent, this.chapters);
                }
              }
              this.runJs('window.easyreadPager && window.easyreadPager.goToProgress(' + target + ')');
            } else if (this.readerKind === 'pdf') {
              if (!this.pdfLoaded) {
                return;
              }
              this.pdfController.goToPage(Math.round(value));
            } else if (this.readerKind === 'comic') {
              this.showComicPage(Math.round(value));
            }
          })
        Text(Math.round(this.shownProgress * 100) + '%')
          .fontSize(11)
          .fontColor(Theme.muted(this.themeName))
          .width(42)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .height(40)
      .padding({ left: 16, right: 16 })
      .backgroundColor(Theme.bg(this.themeName))
      .border({ width: { top: 1 }, color: Theme.line(this.themeName) })
    }
  }

  @Builder
  searchBar() {
    Row({ space: 8 }) {
      Text('⌕')
        .fontSize(15)
        .fontColor(Theme.muted(this.themeName))
      TextInput({ text: this.searchQuery, placeholder: '在书中查找…' })
        .fontSize(13)
        .fontColor(Theme.fg(this.themeName))
        .placeholderColor(Theme.muted(this.themeName))
        .backgroundColor('#00000000')
        .padding(0)
        .layoutWeight(1)
        .onChange((value: string): void => {
          this.searchQuery = value;
          if (this.searchTimer >= 0) {
            clearTimeout(this.searchTimer);
          }
          this.searchTimer = setTimeout((): void => {
            this.runSearch(this.searchQuery);
          }, 260);
        })
        .onSubmit((): void => {
          this.runSearch(this.searchQuery);
        })
      Text(this.searchCount > 0 ? this.searchIndex + ' / ' + this.searchCount : '无结果')
        .fontSize(11)
        .fontColor(Theme.muted(this.themeName))
      Text('‹')
        .fontSize(18)
        .fontColor(Theme.fg(this.themeName))
        .padding({ left: 6, right: 6 })
        .onClick((): void => {
          this.searchPrevious();
        })
      Text('›')
        .fontSize(18)
        .fontColor(Theme.fg(this.themeName))
        .padding({ left: 6, right: 6 })
        .onClick((): void => {
          this.searchNext();
        })
      Text('×')
        .fontSize(17)
        .fontColor(Theme.muted(this.themeName))
        .padding({ left: 6, right: 2 })
        .onClick((): void => {
          this.closeSearch();
        })
    }
    .width('100%')
    .height(46)
    .padding({ left: 16, right: 12 })
    .backgroundColor(Theme.surface(this.themeName))
    .border({ width: { bottom: 1 }, color: Theme.line(this.themeName) })
  }

  @Builder
  readerArea() {
    Stack({ alignContent: Alignment.TopStart }) {
      // The HTML page stays mounted even when no book is open: the shelf or
      // welcome panel is drawn on top, and reopening the same book reveals the
      // already-typeset page instead of rebuilding it.
      if (this.readerKind === 'html' && this.webUrl.length > 0) {
        this.readerContent()
      } else if (this.currentBookId.length > 0) {
        this.readerContent()
      }
      if (this.currentBookId.length === 0) {
        this.welcomePanel()
      } else if (!this.immersive) {
        Column() {
          this.readerToolbar()
          if (this.searchOpen) {
            this.searchBar()
          }
          Blank()
          this.readerBottom()
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.themeName))
  }

  @Builder
  readerPanel() {
    Column() {
      Row({ space: 4 }) {
        PanelTab({
          label: '目录',
          selected: this.panelTab === 'toc',
          themeName: this.themeName,
          onTap: (): void => {
            this.showTocTab();
          }
        })
        PanelTab({
          label: '书签',
          selected: this.panelTab === 'marks',
          themeName: this.themeName,
          onTap: (): void => {
            this.panelTab = 'marks';
          }
        })
        PanelTab({
          label: '笔记',
          selected: this.panelTab === 'notes',
          themeName: this.themeName,
          onTap: (): void => {
            this.panelTab = 'notes';
          }
        })
        Blank()
        Text('×')
          .fontSize(20)
          .fontColor(Theme.muted(this.themeName))
          .width(36)
          .height(36)
          .textAlign(TextAlign.Center)
          .onClick((): void => {
            this.panel = '';
          })
      }
      .width('100%')
      .height(50)
      .padding({ left: 12, right: 8 })

      if (this.panelTab === 'toc') {
        if (this.chapters.length === 0) {
          Column({ space: 8 }) {
            Blank()
            Text(this.readerKind === 'pdf' ? 'PDF 加载后会列出每一页' : '这本书没有目录')
              .fontSize(12)
              .fontColor(Theme.muted(this.themeName))
            Blank()
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 2, scroller: this.tocScroller }) {
            ForEach(this.tocRows, (row: TocRow): void => {
              ListItem() {
                Row({ space: 2 }) {
                  if (row.hasChildren) {
                    Row() {
                      Text(row.expanded ? '▾' : '▸')
                        .fontSize(19)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(row.active ? Theme.accent(this.themeName) : Theme.muted(this.themeName))
                    }
                    .width(40)
                    .height(48)
                    .justifyContent(FlexAlign.Center)
                    .onClick((): void => {
                      this.toggleTocGroup(row);
                    })
                  } else {
                    Row() {
                    }
                    .width(38)
                  }
                  Row({ space: 8 }) {
                    Column({ space: 3 }) {
                      Text(row.title)
                        .fontSize(13)
                        .fontWeight(row.active ? FontWeight.Medium : FontWeight.Normal)
                        .fontColor(row.active ? Theme.accent(this.themeName) : Theme.fg(this.themeName))
                        .maxLines(2)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      if (row.locator.length > 0) {
                        Text(row.locator)
                          .fontSize(10)
                          .fontColor(Theme.muted(this.themeName))
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                      }
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                    Text(row.percent)
                      .fontSize(10)
                      .fontColor(row.active ? Theme.accent(this.themeName) : Theme.muted(this.themeName))
                  }
                  .layoutWeight(1)
                  .padding({ top: 8, bottom: 8 })
                  .onClick((): void => {
                    if (row.chapterIndex >= 0 && row.chapterIndex < this.chapters.length) {
                      this.jumpToChapter(this.chapters[row.chapterIndex]);
                    }
                  })
                }
                .width('100%')
                .padding({ left: 8 + row.depth * 14, right: 12 })
                .backgroundColor(row.active ? Theme.accentSoft(this.themeName) : '#00000000')
                .borderRadius(8)
              }
            }, (row: TocRow): string => row.chapterIndex + ':' +
              (row.expanded ? '1' : '0') + ':' + (row.active ? '1' : '0'))
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .onAppear((): void => {
            this.scrollTocToActive();
          })
        }
      } else if (this.panelTab === 'marks') {
        Column() {
          List({ space: 6 }) {
            ForEach(this.bookmarks, (item: BookmarkItem): void => {
              ListItem() {
                Column({ space: 6 }) {
                  Row() {
                    Text(this.dateTimeText(item.createdAt))
                      .fontSize(10)
                      .fontColor(Theme.muted(this.themeName))
                    Blank()
                    Text(this.bookmarkLocation(item))
                      .fontSize(10)
                      .fontColor(Theme.accent(this.themeName))
                  }
                  .width('100%')
                  if (item.snippet.length > 0) {
                    Text(item.snippet)
                      .fontSize(12)
                      .fontColor(Theme.fg(this.themeName))
                      .maxLines(3)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                  }
                  if (item.note.length > 0) {
                    Text(item.note)
                      .fontSize(12)
                      .fontColor(Theme.muted(this.themeName))
                      .padding(8)
                      .width('100%')
                      .backgroundColor(Theme.surface(this.themeName))
                      .borderRadius(8)
                  }
                  Row({ space: 8 }) {
                    Text('打开')
                      .fontSize(11)
                      .fontColor(Theme.accent(this.themeName))
                      .onClick((): void => {
                        this.jumpToBookmark(item);
                      })
                    if (item.note.length === 0) {
                      Text('补写笔记')
                        .fontSize(11)
                        .fontColor(Theme.muted(this.themeName))
                        .onClick((): void => {
                          this.editingBookmarkId = item.id;
                          this.editingNoteText = '';
                          this.panelTab = 'notes';
                        })
                    }
                    Blank()
                    Text('删除')
                      .fontSize(11)
                      .fontColor('#B04A3A')
                      .onClick((): void => {
                        this.deleteBookmark(item);
                      })
                  }
                  .width('100%')
                }
                .width('100%')
                .padding(12)
                .backgroundColor(Theme.card(this.themeName))
                .borderRadius(10)
              }
            }, (item: BookmarkItem): string => item.id)
          }
          .layoutWeight(1)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .scrollBar(BarState.Off)
          Button('在当前位置加书签')
            .fontSize(12)
            .fontColor(Theme.bg(this.themeName))
            .backgroundColor(Theme.accent(this.themeName))
            .borderRadius(16)
            .height(34)
            .margin({ left: 12, right: 12, bottom: 12 })
            .onClick((): void => {
              this.addBookmark();
            })
        }
        .layoutWeight(1)
        .width('100%')
      } else {
        Column() {
          if (this.editingBookmarkId.length > 0) {
            Column({ space: 8 }) {
              Text('编辑笔记')
                .fontSize(12)
                .fontColor(Theme.muted(this.themeName))
                .width('100%')
              TextArea({ text: this.editingNoteText, placeholder: '写下想法…' })
                .fontSize(13)
                .height(110)
                .backgroundColor(Theme.surface(this.themeName))
                .borderRadius(10)
                .onChange((value: string): void => {
                  this.editingNoteText = value;
                })
              Row({ space: 10 }) {
                Button('取消')
                  .fontSize(12)
                  .fontColor(Theme.muted(this.themeName))
                  .backgroundColor(Theme.surface(this.themeName))
                  .borderRadius(16)
                  .height(32)
                  .onClick((): void => {
                    this.editingBookmarkId = '';
                    this.editingNoteText = '';
                  })
                Button('保存')
                  .fontSize(12)
                  .fontColor(Theme.bg(this.themeName))
                  .backgroundColor(Theme.accent(this.themeName))
                  .borderRadius(16)
                  .height(32)
                  .onClick((): void => {
                    this.saveEditedNote();
                  })
              }
              .width('100%')
            }
            .width('100%')
            .padding(12)
          }
          List({ space: 6 }) {
            ForEach(this.notesOnly(), (item: BookmarkItem): void => {
              ListItem() {
                Column({ space: 6 }) {
                  Row() {
                    Text(this.dateTimeText(item.createdAt))
                      .fontSize(10)
                      .fontColor(Theme.muted(this.themeName))
                    Blank()
                    Text(this.bookmarkLocation(item))
                      .fontSize(10)
                      .fontColor(Theme.accent(this.themeName))
                  }
                  .width('100%')
                  if (item.snippet.length > 0) {
                    Text(item.snippet)
                      .fontSize(11)
                      .fontColor(Theme.muted(this.themeName))
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  Text(item.note)
                    .fontSize(12)
                    .fontColor(Theme.fg(this.themeName))
                    .width('100%')
                  Row({ space: 10 }) {
                    Text('打开')
                      .fontSize(11)
                      .fontColor(Theme.accent(this.themeName))
                      .onClick((): void => {
                        this.jumpToBookmark(item);
                      })
                    Text('编辑')
                      .fontSize(11)
                      .fontColor(Theme.muted(this.themeName))
                      .onClick((): void => {
                        this.editingBookmarkId = item.id;
                        this.editingNoteText = item.note;
                      })
                    Blank()
                    Text('删除')
                      .fontSize(11)
                      .fontColor('#B04A3A')
                      .onClick((): void => {
                        this.deleteBookmark(item);
                      })
                  }
                  .width('100%')
                }
                .width('100%')
                .padding(12)
                .backgroundColor(Theme.card(this.themeName))
                .borderRadius(10)
              }
            }, (item: BookmarkItem): string => item.id)
          }
          .layoutWeight(1)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .scrollBar(BarState.Off)
          TextArea({ text: this.newNoteText, placeholder: '写下这一刻的想法…' })
            .fontSize(13)
            .height(84)
            .margin({ left: 12, right: 12, top: 4 })
            .backgroundColor(Theme.surface(this.themeName))
            .borderRadius(10)
            .onChange((value: string): void => {
              this.newNoteText = value;
            })
          Button('保存笔记')
            .fontSize(12)
            .fontColor(Theme.bg(this.themeName))
            .backgroundColor(Theme.accent(this.themeName))
            .borderRadius(16)
            .height(34)
            .margin({ left: 12, right: 12, top: 8, bottom: 12 })
            .onClick((): void => {
              this.addNote();
            })
        }
        .layoutWeight(1)
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.surface(this.themeName))
  }

  private notesOnly(): BookmarkItem[] {
    const result: BookmarkItem[] = [];
    for (let i = 0; i < this.bookmarks.length; i++) {
      if (this.bookmarks[i].note.length > 0) {
        result.push(this.bookmarks[i]);
      }
    }
    return result;
  }

  private bookmarkLocation(item: BookmarkItem): string {
    if (item.pageIndex >= 0) {
      return '第 ' + (item.pageIndex + 1) + ' 页';
    }
    return Math.round(item.progress * 100) + '%';
  }

  private themeLabel(theme: string): string {
    if (theme === 'paper') {
      return '纸白';
    }
    if (theme === 'sepia') {
      return '米黄';
    }
    if (theme === 'green') {
      return '浅绿';
    }
    return '夜间';
  }

  private fontLabel(): string {
    if (this.fontFamily === 'serif') {
      return '宋体';
    }
    if (this.fontFamily === 'sans') {
      return '黑体';
    }
    if (this.fontFamily === 'kai') {
      return '楷体';
    }
    return '系统';
  }

  @Builder
  settingsPanel() {
    Column() {
      Row() {
        Column({ space: 3 }) {
          Text('阅读设置')
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.fg(this.themeName))
            .fontFamily('serif')
          Text('排版、主题与翻页方式')
            .fontSize(11)
            .fontColor(Theme.muted(this.themeName))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text('×')
          .fontSize(18)
          .fontColor(Theme.muted(this.themeName))
          .width(32)
          .height(32)
          .textAlign(TextAlign.Center)
          .backgroundColor(Theme.card(this.themeName))
          .borderRadius(16)
          .onClick((): void => {
            this.panel = '';
          })
      }
      .width('100%')
      .padding({ left: 20, right: 14, top: 18, bottom: 10 })

      Scroll() {
        Column({ space: 14 }) {
          Column({ space: 14 }) {
            SettingCaption({
              label: '主题',
              value: this.themeLabel(this.themeName),
              themeName: this.themeName
            })
            Row() {
              ForEach(['paper', 'sepia', 'green', 'night'], (theme: string): void => {
                Column({ space: 7 }) {
                  Stack() {
                    if (this.themeName === theme) {
                      Text('✓')
                        .fontSize(14)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(Theme.fg(theme))
                    }
                  }
                  .width(44)
                  .height(44)
                  .borderRadius(22)
                  .backgroundColor(Theme.bg(theme))
                  .border({
                    width: this.themeName === theme ? 2 : 1,
                    color: this.themeName === theme ? Theme.accent(theme) : Theme.line(theme)
                  })
                  Text(this.themeLabel(theme))
                    .fontSize(10)
                    .fontColor(this.themeName === theme ? Theme.fg(this.themeName) : Theme.muted(this.themeName))
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Center)
                .onClick((): void => {
                  this.themeName = theme;
                  this.applyTypography();
                })
              }, (theme: string): string => theme)
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .alignItems(HorizontalAlign.Start)
          .backgroundColor(Theme.card(this.themeName))
          .borderRadius(16)
          .border({ width: 1, color: Theme.line(this.themeName) })

          Column({ space: 16 }) {
            SettingCaption({
              label: '字体',
              value: this.fontLabel(),
              themeName: this.themeName
            })
            Row({ space: 8 }) {
              OptionChip({
                label: '宋体',
                selected: this.fontFamily === 'serif',
                themeName: this.themeName,
                onTap: (): void => {
                  this.fontFamily = 'serif';
                  this.applyTypography();
                }
              })
              OptionChip({
                label: '黑体',
                selected: this.fontFamily === 'sans',
                themeName: this.themeName,
                onTap: (): void => {
                  this.fontFamily = 'sans';
                  this.applyTypography();
                }
              })
              OptionChip({
                label: '楷体',
                selected: this.fontFamily === 'kai',
                themeName: this.themeName,
                onTap: (): void => {
                  this.fontFamily = 'kai';
                  this.applyTypography();
                }
              })
              OptionChip({
                label: '系统',
                selected: this.fontFamily === 'system',
                themeName: this.themeName,
                onTap: (): void => {
                  this.fontFamily = 'system';
                  this.applyTypography();
                }
              })
            }
            .width('100%')

            Divider()
              .width('100%')
              .color(Theme.line(this.themeName))
              .strokeWidth(1)

            Column({ space: 4 }) {
              SettingCaption({
                label: '字号',
                value: Math.round(this.fontSize) + ' px',
                themeName: this.themeName
              })
              Slider({ value: this.fontSize, min: 15, max: 30, step: 1, style: SliderStyle.OutSet })
                .blockColor(Theme.accent(this.themeName))
                .selectedColor(Theme.accent(this.themeName))
                .trackColor(Theme.line(this.themeName))
                .onChange((value: number, mode: SliderChangeMode): void => {
                  this.fontSize = value;
                  if (mode === SliderChangeMode.End) {
                    this.applyTypography();
                  }
                })
            }
            .width('100%')

            Column({ space: 4 }) {
              SettingCaption({
                label: '行距',
                value: this.lineHeight.toFixed(1) + ' ×',
                themeName: this.themeName
              })
              Slider({ value: this.lineHeight, min: 1.35, max: 2.2, step: 0.05, style: SliderStyle.OutSet })
                .blockColor(Theme.accent(this.themeName))
                .selectedColor(Theme.accent(this.themeName))
                .trackColor(Theme.line(this.themeName))
                .onChange((value: number, mode: SliderChangeMode): void => {
                  this.lineHeight = value;
                  if (mode === SliderChangeMode.End) {
                    this.applyTypography();
                  }
                })
            }
            .width('100%')

            Column({ space: 4 }) {
              SettingCaption({
                label: '页边距',
                value: Math.round(this.marginValue * 100) + '%',
                themeName: this.themeName
              })
              Slider({ value: this.marginValue, min: 0.03, max: 0.16, step: 0.01, style: SliderStyle.OutSet })
                .blockColor(Theme.accent(this.themeName))
                .selectedColor(Theme.accent(this.themeName))
                .trackColor(Theme.line(this.themeName))
                .onChange((value: number, mode: SliderChangeMode): void => {
                  this.marginValue = value;
                  if (mode === SliderChangeMode.End) {
                    this.applyTypography();
                  }
                })
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .alignItems(HorizontalAlign.Start)
          .backgroundColor(Theme.card(this.themeName))
          .borderRadius(16)
          .border({ width: 1, color: Theme.line(this.themeName) })

          Column({ space: 16 }) {
            Column({ space: 8 }) {
              SettingCaption({
                label: '翻页方式',
                value: this.pageMode === 'paged' ? '左右分页' : '上下滚动',
                themeName: this.themeName
              })
              Row({ space: 8 }) {
                OptionChip({
                  label: '左右分页',
                  selected: this.pageMode === 'paged',
                  themeName: this.themeName,
                  onTap: (): void => {
                    this.pageMode = 'paged';
                    this.applyMode();
                  }
                })
                OptionChip({
                  label: '上下滚动',
                  selected: this.pageMode === 'scroll',
                  themeName: this.themeName,
                  onTap: (): void => {
                    this.pageMode = 'scroll';
                    this.applyMode();
                  }
                })
              }
              .width('100%')
            }
            .width('100%')

            Divider()
              .width('100%')
              .color(Theme.line(this.themeName))
              .strokeWidth(1)

            Column({ space: 8 }) {
              SettingCaption({
                label: '分栏',
                value: this.columns === 'auto' ? '自动' : (this.columns === 'one' ? '单栏' : '双栏'),
                themeName: this.themeName
              })
              Row({ space: 8 }) {
                OptionChip({
                  label: '自动',
                  selected: this.columns === 'auto',
                  themeName: this.themeName,
                  onTap: (): void => {
                    this.columns = 'auto';
                    this.applyColumns();
                  }
                })
                OptionChip({
                  label: '单栏',
                  selected: this.columns === 'one',
                  themeName: this.themeName,
                  onTap: (): void => {
                    this.columns = 'one';
                    this.applyColumns();
                  }
                })
                OptionChip({
                  label: '双栏',
                  selected: this.columns === 'two',
                  themeName: this.themeName,
                  onTap: (): void => {
                    this.columns = 'two';
                    this.applyColumns();
                  }
                })
              }
              .width('100%')
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .alignItems(HorizontalAlign.Start)
          .backgroundColor(Theme.card(this.themeName))
          .borderRadius(16)
          .border({ width: 1, color: Theme.line(this.themeName) })

          Column({ space: 14 }) {
            Row() {
              Column({ space: 3 }) {
                Text('显示底部进度')
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.fg(this.themeName))
                Text('在页脚显示百分比与页码')
                  .fontSize(10)
                  .fontColor(Theme.muted(this.themeName))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.showProgress })
                .selectedColor(Theme.accent(this.themeName))
                .onChange((isOn: boolean): void => {
                  this.showProgress = isOn;
                  this.persistSettings();
                })
            }
            .width('100%')

            if (this.currentBook !== null && this.currentBook.format === 'EPUB') {
              Divider()
                .width('100%')
                .color(Theme.line(this.themeName))
                .strokeWidth(1)

              Row() {
                Column({ space: 3 }) {
                  Text('使用出版方排版')
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Theme.fg(this.themeName))
                  Text('保留书籍自带的 CSS 与字体')
                    .fontSize(10)
                    .fontColor(Theme.muted(this.themeName))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.publisherStyles })
                  .selectedColor(Theme.accent(this.themeName))
                  .onChange((isOn: boolean): void => {
                    this.publisherStyles = isOn;
                    this.persistSettings();
                    const book = this.currentBook;
                    if (book !== null) {
                      this.openBook(book);
                    }
                  })
              }
              .width('100%')
            }
          }
          .width('100%')
          .padding(16)
          .alignItems(HorizontalAlign.Start)
          .backgroundColor(Theme.card(this.themeName))
          .borderRadius(16)
          .border({ width: 1, color: Theme.line(this.themeName) })

          Blank().height(8)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 16, right: 16, top: 4, bottom: 24 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.surface(this.themeName))
  }

  @Builder
  syncPanel() {
    Column() {
      Row() {
        Column({ space: 3 }) {
          Text('WebDAV 同步')
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.fg(this.themeName))
            .fontFamily('serif')
          Text('与手机共用一套书籍与阅读位置')
            .fontSize(11)
            .fontColor(Theme.muted(this.themeName))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text('×')
          .fontSize(18)
          .fontColor(Theme.muted(this.themeName))
          .width(32)
          .height(32)
          .textAlign(TextAlign.Center)
          .backgroundColor(Theme.card(this.themeName))
          .borderRadius(16)
          .onClick((): void => {
            this.panel = '';
          })
      }
      .width('100%')
      .padding({ left: 20, right: 14, top: 18, bottom: 10 })

      Scroll() {
        Column({ space: 14 }) {
          Text('在手机或其他设备上用 EasyRead 同步后，这里填写同一个 WebDAV 账号，即可共用书籍与阅读位置。')
            .fontSize(11)
            .fontColor(Theme.muted(this.themeName))
            .lineHeight(17)
            .width('100%')

          Column({ space: 12 }) {
            SettingCaption({
              label: '账户',
              value: this.syncUser.length > 0 ? '已填写' : '未填写',
              themeName: this.themeName
            })

            Column({ space: 8 }) {
              Text('服务商')
                .fontSize(10)
                .fontColor(Theme.muted(this.themeName))
                .letterSpacing(0.5)
              Row({ space: 6 }) {
                OptionChip({
                  label: '坚果云',
                  selected: this.syncProvider === SyncProvider.JIANGUOYUN,
                  themeName: this.themeName,
                  onTap: (): void => {
                    this.selectSyncProvider(SyncProvider.JIANGUOYUN);
                  }
                })
                OptionChip({
                  label: 'Nextcloud',
                  selected: this.syncProvider === SyncProvider.NEXTCLOUD,
                  themeName: this.themeName,
                  onTap: (): void => {
                    this.selectSyncProvider(SyncProvider.NEXTCLOUD);
                  }
                })
                OptionChip({
                  label: '自定义 WebDAV',
                  selected: this.syncProvider === SyncProvider.CUSTOM,
                  themeName: this.themeName,
                  onTap: (): void => {
                    this.selectSyncProvider(SyncProvider.CUSTOM);
                  }
                })
              }
              .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            Column({ space: 6 }) {
              Text('服务器地址')
                .fontSize(10)
                .fontColor(Theme.muted(this.themeName))
                .letterSpacing(0.5)
              TextInput({ text: this.syncServer, placeholder: this.providerServerPlaceholder() })
                .fontSize(13)
                .fontColor(Theme.fg(this.themeName))
                .placeholderColor(Theme.muted(this.themeName))
                .height(40)
                .padding({ left: 12, right: 12 })
                .backgroundColor(Theme.surface(this.themeName))
                .borderRadius(10)
                .onChange((value: string): void => {
                  this.syncServer = value;
                })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            Column({ space: 6 }) {
              Text(this.providerAccountLabel())
                .fontSize(10)
                .fontColor(Theme.muted(this.themeName))
                .letterSpacing(0.5)
              TextInput({ text: this.syncUser, placeholder: this.providerAccountPlaceholder() })
                .fontSize(13)
                .fontColor(Theme.fg(this.themeName))
                .placeholderColor(Theme.muted(this.themeName))
                .height(40)
                .padding({ left: 12, right: 12 })
                .backgroundColor(Theme.surface(this.themeName))
                .borderRadius(10)
                .onChange((value: string): void => {
                  this.syncUser = value;
                })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            Column({ space: 6 }) {
              Text('应用密码')
                .fontSize(10)
                .fontColor(Theme.muted(this.themeName))
                .letterSpacing(0.5)
              TextInput({ text: this.syncPassword, placeholder: '应用密码或访问令牌' })
                .type(InputType.Password)
                .fontSize(13)
                .fontColor(Theme.fg(this.themeName))
                .placeholderColor(Theme.muted(this.themeName))
                .height(40)
                .padding({ left: 12, right: 12 })
                .backgroundColor(Theme.surface(this.themeName))
                .borderRadius(10)
                .onChange((value: string): void => {
                  this.syncPassword = value;
                })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            Text(this.providerPasswordHint())
              .fontSize(10)
              .fontColor(Theme.muted(this.themeName))
              .lineHeight(15)
              .width('100%')

            Column({ space: 8 }) {
              Text('同步目录')
                .fontSize(10)
                .fontColor(Theme.muted(this.themeName))
                .letterSpacing(0.5)
              Row({ space: 6 }) {
                OptionChip({
                  label: 'EasyRead（默认）',
                  selected: this.syncNamespace === SyncNamespace.EASYREAD,
                  themeName: this.themeName,
                  onTap: (): void => {
                    this.syncNamespace = SyncNamespace.EASYREAD;
                  }
                })
                OptionChip({
                  label: 'ZenReader（兼容）',
                  selected: this.syncNamespace === SyncNamespace.ZENREADER,
                  themeName: this.themeName,
                  onTap: (): void => {
                    this.syncNamespace = SyncNamespace.ZENREADER;
                  }
                })
              }
              .width('100%')
              Row({ space: 8 }) {
                Text(this.syncNamespace === SyncNamespace.ZENREADER ? 'ZenReader/v1' : 'EasyRead')
                  .fontSize(12)
                  .fontColor(Theme.fg(this.themeName))
                Blank()
                Text('不存在时自动创建')
                  .fontSize(9)
                  .fontColor(Theme.muted(this.themeName))
                  .padding({ left: 7, right: 7, top: 2, bottom: 2 })
                  .backgroundColor(Theme.card(this.themeName))
                  .borderRadius(6)
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 10, bottom: 10 })
              .backgroundColor(Theme.surface(this.themeName))
              .borderRadius(10)
              Text(this.syncNamespace === SyncNamespace.ZENREADER ?
                '兼容极简阅读的 ZenReader/v1，原有云端书籍可继续同步；目录会在首次连接或同步时自动创建。' :
                '默认使用 EasyRead 目录，适合只使用 EasyRead 的设备；目录会在首次连接或同步时自动创建。')
                .fontSize(10)
                .fontColor(Theme.muted(this.themeName))
                .lineHeight(15)
                .width('100%')
              Text('服务器地址只需填写到账号根目录，应用会自动拼接同步目录。切换目录只影响之后的同步，不会移动或删除另一个目录里已有的文件。')
                .fontSize(10)
                .fontColor(Theme.muted(this.themeName))
                .lineHeight(15)
                .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            Row({ space: 8 }) {
              Button('测试连接')
                .fontSize(12)
                .fontColor(Theme.fg(this.themeName))
                .backgroundColor(Theme.surface(this.themeName))
                .borderRadius(12)
                .height(38)
                .layoutWeight(1)
                .onClick((): void => {
                  this.testSyncConnection();
                })
              Button('保存配置')
                .fontSize(12)
                .fontColor(Theme.bg(this.themeName))
                .backgroundColor(Theme.accent(this.themeName))
                .borderRadius(12)
                .height(38)
                .layoutWeight(1)
                .onClick((): void => {
                  this.saveSyncSettings();
                })
              Button('清除配置')
                .fontSize(12)
                .fontColor('#B04A3A')
                .backgroundColor(Theme.surface(this.themeName))
                .borderRadius(12)
                .height(38)
                .layoutWeight(1)
                .onClick((): void => {
                  this.clearSyncSettings();
                })
            }
            .width('100%')
            .padding({ top: 2 })
          }
          .width('100%')
          .padding(16)
          .alignItems(HorizontalAlign.Start)
          .backgroundColor(Theme.card(this.themeName))
          .borderRadius(16)
          .border({ width: 1, color: Theme.line(this.themeName) })

          Column({ space: 12 }) {
            Row() {
              Column({ space: 3 }) {
                Text('启动时自动同步')
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.fg(this.themeName))
                Text('检查云端新书与阅读位置')
                  .fontSize(10)
                  .fontColor(Theme.muted(this.themeName))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.syncAuto })
                .selectedColor(Theme.accent(this.themeName))
                .onChange((isOn: boolean): void => {
                  this.syncAuto = isOn;
                })
            }
            .width('100%')

            Divider()
              .width('100%')
              .color(Theme.line(this.themeName))
              .strokeWidth(1)

            Text(this.lastSyncText)
              .fontSize(11)
              .fontColor(Theme.muted(this.themeName))
              .width('100%')
          }
          .width('100%')
          .padding(16)
          .alignItems(HorizontalAlign.Start)
          .backgroundColor(Theme.card(this.themeName))
          .borderRadius(16)
          .border({ width: 1, color: Theme.line(this.themeName) })

          Column({ space: 12 }) {
            SettingCaption({
              label: '立即同步',
              value: '',
              themeName: this.themeName
            })
            Text('双向同步会把两端的书籍与阅读进度合并：每本书以最后阅读时间较新的一方为准，时间相同时保留进度更大的一方。')
              .fontSize(10)
              .fontColor(Theme.muted(this.themeName))
              .lineHeight(16)
              .width('100%')

            Button('双向同步（推荐）')
              .fontSize(12)
              .fontColor(Theme.bg(this.themeName))
              .backgroundColor(Theme.accent(this.themeName))
              .borderRadius(12)
              .height(40)
              .width('100%')
              .enabled(!this.syncBusy)
              .onClick((): void => {
                this.runSync('both');
              })

            Row({ space: 10 }) {
              Button('上传覆盖云端')
                .fontSize(12)
                .fontColor(Theme.fg(this.themeName))
                .backgroundColor(Theme.surface(this.themeName))
                .borderRadius(12)
                .height(38)
                .layoutWeight(1)
                .enabled(!this.syncBusy)
                .onClick((): void => {
                  this.runSync('upload');
                })
              Button('下载覆盖本机')
                .fontSize(12)
                .fontColor(Theme.fg(this.themeName))
                .backgroundColor(Theme.surface(this.themeName))
                .borderRadius(12)
                .height(38)
                .layoutWeight(1)
                .enabled(!this.syncBusy)
                .onClick((): void => {
                  this.runSync('download');
                })
            }
            .width('100%')

            Text('上传和下载是单向覆盖，会用选定的一侧替换另一侧的阅读进度，仅在确定以某一端为准时使用。')
              .fontSize(10)
              .fontColor(Theme.muted(this.themeName))
              .lineHeight(16)
              .width('100%')

            if (this.syncBusy || this.syncStatus.length > 0) {
              Row({ space: 8 }) {
                if (this.syncBusy) {
                  LoadingProgress().width(14).height(14).color(Theme.accent(this.themeName))
                }
                Text(this.syncStatus)
                  .fontSize(11)
                  .fontColor(this.syncStatus.indexOf('失败') >= 0 ? '#B04A3A' : Theme.muted(this.themeName))
                  .layoutWeight(1)
              }
              .width('100%')
            }
          }
          .width('100%')
          .padding(16)
          .alignItems(HorizontalAlign.Start)
          .backgroundColor(Theme.card(this.themeName))
          .borderRadius(16)
          .border({ width: 1, color: Theme.line(this.themeName) })

          Text('每次同步只新建一份快照，不覆盖旧快照；加密 PDF 与带 DRM 的 Kindle 书无法同步。')
            .fontSize(10)
            .fontColor(Theme.muted(this.themeName))
            .lineHeight(15)
            .width('100%')
            .padding({ left: 2, right: 2 })

          Text('查看隐私政策 · WebDAV 账号与书籍数据如何处理')
            .fontSize(10)
            .fontColor(Theme.accent(this.themeName))
            .width('100%')
            .padding({ left: 2, right: 2 })
            .onClick((): void => {
              this.panel = 'privacy';
            })

          Blank().height(8)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 16, right: 16, top: 4, bottom: 24 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.surface(this.themeName))
  }

  @Builder
  privacyPanel() {
    Column() {
      Row() {
        Column({ space: 3 }) {
          Text('隐私政策')
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.fg(this.themeName))
            .fontFamily('serif')
          Text('书籍、阅读进度与 WebDAV 账号的处理方式')
            .fontSize(11)
            .fontColor(Theme.muted(this.themeName))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text('×')
          .fontSize(18)
          .fontColor(Theme.muted(this.themeName))
          .width(32)
          .height(32)
          .textAlign(TextAlign.Center)
          .backgroundColor(Theme.card(this.themeName))
          .borderRadius(16)
          .onClick((): void => {
            this.panel = '';
          })
      }
      .width('100%')
      .padding({ left: 20, right: 14, top: 18, bottom: 10 })

      Scroll() {
        PrivacyPolicyContent({ themeName: this.themeName })
          .padding({ left: 20, right: 20, top: 4, bottom: 24 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.surface(this.themeName))
  }

  @Builder
  panelOverlay() {
    Row() {
      Blank()
        .layoutWeight(1)
        .height('100%')
        .onClick((): void => {
          this.panel = '';
        })
      Column() {
        if (this.panel === 'reader') {
          this.readerPanel()
        } else if (this.panel === 'settings') {
          this.settingsPanel()
        } else if (this.panel === 'sync') {
          this.syncPanel()
        } else if (this.panel === 'privacy') {
          this.privacyPanel()
        }
      }
      .width(this.isWide ? 400 : '92%')
      .height('100%')
      .backgroundColor(Theme.surface(this.themeName))
      .borderRadius(this.isWide ? 20 : 0)
      .border({ width: this.isWide ? 1 : 0, color: Theme.line(this.themeName) })
      .clip(true)
      .shadow({ radius: 28, color: '#33000000', offsetX: -8, offsetY: 0 })
    }
    .width('100%')
    .height('100%')
    .padding({
      top: this.isWide ? 14 : 0,
      bottom: this.isWide ? 14 : 0,
      right: this.isWide ? 14 : 0
    })
    .backgroundColor('#26000000')
  }

  @Builder
  privacyGate() {
    Column() {
      if (this.privacyDeclined) {
        this.privacyDeclinedCard()
      } else {
        this.privacyConsentCard()
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 16, right: 16, top: 16, bottom: 16 })
    .backgroundColor(Theme.bg(this.themeName))
  }

  @Builder
  privacyConsentCard() {
    Column() {
      Column({ space: 5 }) {
        Text('欢迎使用 EasyRead')
          .fontSize(22)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.fg(this.themeName))
          .fontFamily('serif')
          .width('100%')
        Text('开始前，请阅读并同意下面的隐私政策。')
          .fontSize(11)
          .fontColor(Theme.muted(this.themeName))
          .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 20, right: 20, top: 20, bottom: 14 })

      Divider()
        .width('100%')
        .color(Theme.line(this.themeName))
        .strokeWidth(1)

      Scroll() {
        PrivacyPolicyContent({ themeName: this.themeName })
          .padding({ left: 20, right: 20, top: 14, bottom: 14 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .align(Alignment.Top)

      Divider()
        .width('100%')
        .color(Theme.line(this.themeName))
        .strokeWidth(1)

      Column({ space: 12 }) {
        Row({ space: 8 }) {
          Toggle({ type: ToggleType.Checkbox, isOn: this.privacyChecked })
            .selectedColor(Theme.accent(this.themeName))
            .onChange((isOn: boolean): void => {
              this.privacyChecked = isOn;
            })
          Text('我已阅读并同意《EasyRead 隐私政策》')
            .fontSize(11)
            .fontColor(Theme.fg(this.themeName))
            .layoutWeight(1)
            .onClick((): void => {
              this.privacyChecked = !this.privacyChecked;
            })
        }
        .width('100%')

        Row({ space: 10 }) {
          Button('不同意')
            .fontSize(13)
            .fontColor(Theme.muted(this.themeName))
            .backgroundColor(Theme.card(this.themeName))
            .borderRadius(14)
            .height(42)
            .layoutWeight(1)
            .onClick((): void => {
              this.declinePrivacy();
            })
          Button('同意并继续')
            .fontSize(13)
            .fontColor(Theme.bg(this.themeName))
            .backgroundColor(Theme.accent(this.themeName))
            .borderRadius(14)
            .height(42)
            .layoutWeight(1)
            .enabled(this.privacyChecked)
            .opacity(this.privacyChecked ? 1 : 0.45)
            .onClick((): void => {
              this.agreePrivacy();
            })
        }
        .width('100%')

        Text('不同意将无法使用应用；同意前不会加载书库、阅读进度或 WebDAV 账号。')
          .fontSize(10)
          .fontColor(Theme.muted(this.themeName))
          .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 20, right: 20, top: 14, bottom: 18 })
    }
    .width(this.isWide ? 600 : '92%')
    .height('86%')
    .backgroundColor(Theme.surface(this.themeName))
    .borderRadius(22)
    .border({ width: 1, color: Theme.line(this.themeName) })
    .clip(true)
    .shadow({ radius: 30, color: '#33000000', offsetX: 0, offsetY: 10 })
  }

  @Builder
  privacyDeclinedCard() {
    Column({ space: 14 }) {
      Text('需要同意隐私政策')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.fg(this.themeName))
        .fontFamily('serif')
        .width('100%')
      Text('同意前，EasyRead 不会加载书库、阅读进度或 WebDAV 账号，也不会联网。你可以重新阅读隐私政策，或退出应用。')
        .fontSize(11)
        .lineHeight(18)
        .fontColor(Theme.muted(this.themeName))
        .width('100%')
      Button('重新阅读隐私政策')
        .fontSize(13)
        .fontColor(Theme.bg(this.themeName))
        .backgroundColor(Theme.accent(this.themeName))
        .borderRadius(14)
        .height(42)
        .width('100%')
        .margin({ top: 4 })
        .onClick((): void => {
          this.privacyDeclined = false;
        })
      Button('退出应用')
        .fontSize(13)
        .fontColor(Theme.muted(this.themeName))
        .backgroundColor(Theme.card(this.themeName))
        .borderRadius(14)
        .height(42)
        .width('100%')
        .onClick((): void => {
          this.exitApp();
        })
    }
    .width(this.isWide ? 480 : '88%')
    .padding(24)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Theme.surface(this.themeName))
    .borderRadius(20)
    .border({ width: 1, color: Theme.line(this.themeName) })
    .shadow({ radius: 24, color: '#33000000', offsetX: 0, offsetY: 8 })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row() {
        if (this.isWide && this.shelfVisible) {
          Column() {
            this.shelfPanel()
          }
          .width(this.screenWidth >= 1000 ? 360 : 300)
          .height('100%')
          Divider()
            .vertical(true)
            .height('100%')
            .color(Theme.line(this.themeName))
        }
        if (this.isWide) {
          Column() {
            this.readerArea()
          }
          .layoutWeight(1)
          .height('100%')
        } else {
          // Narrow screens show either the shelf or the reader. Keep the
          // reader mounted underneath the shelf so the typeset page survives
          // a trip back to the library.
          Stack({ alignContent: Alignment.TopStart }) {
            Column() {
              this.readerArea()
            }
            .width('100%')
            .height('100%')
            if (this.currentBookId.length === 0) {
              Column() {
                this.shelfPanel()
              }
              .width('100%')
              .height('100%')
            }
          }
          .layoutWeight(1)
          .height('100%')
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg(this.themeName))

      if (this.panel.length > 0) {
        this.panelOverlay()
      }

      // Cold-start cover: the last reading screen, painted before the WebView
      // exists, so a restarted app opens on the page the reader left rather
      // than on a blank loader while the text engine runs once.
      if (this.resumeCover && this.resumeImage.length > 0) {
        Image(this.resumeImage)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .backgroundColor(Theme.bg(this.themeName))
          .hitTestBehavior(HitTestMode.Transparent)
      }

      // AGC requires the policy to be presented before any personal data is
      // processed; this opaque gate sits above every other surface until then.
      if (!this.privacyAccepted) {
        this.privacyGate()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.themeName))
    .onAreaChange((oldArea: Area, newArea: Area): void => {
      const width = Number(newArea.width);
      if (!isNaN(width) && width > 0) {
        this.screenWidth = width;
        this.isWide = width >= 720;
      }
    })
  }
}
