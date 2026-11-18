import { BookFormats, LibraryStore } from './LibraryStore';
import { BookService } from './BookService';
import { BookmarkStore } from './BookmarkStore';
import { SettingsStore } from './SettingsStore';
import { WebDavClient, SnapshotInfo, WebDavError } from './WebDavClient';
import { HashService } from './HashService';
import { LibraryBook, SyncResult, ZenPositionPayload } from '../model/LibraryModels';
import { JsonCodec, JsonKind, JsonNode } from '../parser/ZenJson';
import { TextModel } from '../parser/BookTypes';
import { ZenTextLocator } from './ZenTextLocator';
import { AppPaths, FileService } from './FileService';

class MatchCandidate {
  index: number = -1;
  score: number = 0;
  removed: boolean = false;
  updatedAt: number = 0;
}

class PendingDownload {
  index: number = 0;
  objectID: string = '';
  displayName: string = '';
  fileType: string = '';
  remotePath: string = '';
  localPath: string = '';
  expectedSize: number = 0;
  exists: boolean = false;
}

class PendingUpload {
  book: LibraryBook;
  bytes: Uint8Array;
  digest: string = '';
  remoteName: string = '';
  objectID: string = '';

  constructor(book: LibraryBook, bytes: Uint8Array) {
    this.book = book;
    this.bytes = bytes;
  }
}

export class ZenSyncService {
  private static instance: ZenSyncService | null = null;

  static shared(): ZenSyncService {
    if (ZenSyncService.instance === null) {
      ZenSyncService.instance = new ZenSyncService();
    }
    return ZenSyncService.instance;
  }

  private static str(node: JsonNode | null | undefined, key: string, fallback: string): string {
    if (node === null || node === undefined) {
      return fallback;
    }
    const value = node.get(key);
    return value !== null ? value.asString(fallback) : fallback;
  }

  private static num(node: JsonNode | null | undefined, key: string, fallback: number): number {
    if (node === null || node === undefined) {
      return fallback;
    }
    const value = node.get(key);
    return value !== null ? value.asNumber(fallback) : fallback;
  }

  private static int(node: JsonNode | null | undefined, key: string, fallback: number): number {
    return Math.trunc(ZenSyncService.num(node, key, fallback));
  }

  private static set(node: JsonNode, key: string, value: JsonNode): void {
    node.set(key, value);
  }

  private static remove(node: JsonNode, key: string): void {
    node.remove(key);
  }

  private static uuid(): string {
    let result = '';
    const template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx';
    for (let i = 0; i < template.length; i++) {
      const ch = template.charAt(i);
      if (ch === 'x' || ch === 'y') {
        const random = Math.floor(Math.random() * 16);
        const value = ch === 'x' ? random : ((random & 0x3) | 0x8);
        result += value.toString(16);
      } else {
        result += ch;
      }
    }
    return result;
  }

  private static pad(value: number, length: number): string {
    let text = Math.trunc(value).toString();
    while (text.length < length) {
      text = '0' + text;
    }
    return text;
  }

  private static snapshotName(date: Date): string {
    return '' + date.getFullYear() + ZenSyncService.pad(date.getMonth() + 1, 2) +
      ZenSyncService.pad(date.getDate(), 2) + '-' +
      ZenSyncService.pad(date.getHours(), 2) + ZenSyncService.pad(date.getMinutes(), 2) +
      ZenSyncService.pad(date.getSeconds(), 2) + '-' + ZenSyncService.pad(date.getMilliseconds(), 3);
  }

  private static dateFromSnapshot(name: string): number {
    const match = name.match(/^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})-(\d{3})$/);
    if (match === null) {
      return 0;
    }
    return new Date(
      parseInt(match[1], 10), parseInt(match[2], 10) - 1, parseInt(match[3], 10),
      parseInt(match[4], 10), parseInt(match[5], 10), parseInt(match[6], 10),
      parseInt(match[7], 10)
    ).getTime();
  }

  private static dateText(timestamp: number): string {
    const date = new Date(timestamp);
    return '' + date.getFullYear() + '.' + ZenSyncService.pad(date.getMonth() + 1, 2) + '.' +
      ZenSyncService.pad(date.getDate(), 2) + ' ' + ZenSyncService.pad(date.getHours(), 2) + ':' +
      ZenSyncService.pad(date.getMinutes(), 2) + ':' + ZenSyncService.pad(date.getSeconds(), 2);
  }

  private static normalizeName(value: string): string {
    return value
      .split('\u3000').join('')
      .split(' ').join('')
      .split('（').join('(')
      .split('）').join(')')
      .split('：').join(':')
      .toLowerCase();
  }

  private static formatFileSize(bytes: number): string {
    if (bytes <= 0) {
      return '';
    }
    const value = bytes;
    if (value >= 1024 * 1024 * 1024) {
      return (value / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
    }
    if (value >= 1024 * 1024) {
      return (value / (1024 * 1024)).toFixed(2) + ' MB';
    }
    if (value >= 1024) {
      return (value / 1024).toFixed(2) + ' KB';
    }
    return bytes + ' B';
  }

  private static remoteSizeMatches(entry: JsonNode, localBytes: number): boolean {
    if (localBytes <= 0) {
      return false;
    }
    const value = entry.get('fileSize');
    if (value === null) {
      return false;
    }
    if (value.kind === JsonKind.NUMBER) {
      return Math.trunc(value.numberValue) === localBytes;
    }
    const text = value.asString().trim();
    if (text.length === 0) {
      return false;
    }
    const bytes = Number(text);
    if (!isNaN(bytes)) {
      return Math.trunc(bytes) === localBytes;
    }
    return text === ZenSyncService.formatFileSize(localBytes);
  }

  private static nameScore(local: string, remote: string): number {
    const a = ZenSyncService.normalizeName(local);
    const b = ZenSyncService.normalizeName(remote);
    if (b.length === 0) {
      return 0;
    }
    if (a === b) {
      return 60;
    }
    if (b.length >= 4 && (a.indexOf(b) === 0 || b.indexOf(a) === 0)) {
      return 45;
    }
    if (b.length >= 4 && (a.indexOf(b) >= 0 || b.indexOf(a) >= 0)) {
      return 35;
    }
    return 0;
  }

  private static authorMatches(local: string, remote: string): boolean {
    const a = ZenSyncService.normalizeName(local);
    const b = ZenSyncService.normalizeName(remote);
    if (a.length === 0 || b.length === 0) {
      return false;
    }
    return a.indexOf(b) >= 0 || b.indexOf(a) >= 0;
  }

  private static matchIndex(book: LibraryBook, files: JsonNode[], localBytes: number): number {
    const format = book.format.toLowerCase();
    const candidates: MatchCandidate[] = [];
    for (let index = 0; index < files.length; index++) {
      const entry = files[index];
      const rawFormat = ZenSyncService.str(entry, 'fileType', '');
      const entryFormat = BookFormats.fromExtension(rawFormat).toLowerCase();
      if (entryFormat !== format) {
        continue;
      }
      const displayName = ZenSyncService.str(entry, 'displayName', '');
      const score = ZenSyncService.nameScore(book.title, displayName);
      const sizeMatches = ZenSyncService.remoteSizeMatches(entry, localBytes);
      if (score <= 0 && !sizeMatches) {
        continue;
      }
      let total = 10 + score;
      if (sizeMatches) {
        total += 25;
      }
      if (ZenSyncService.authorMatches(book.author, ZenSyncService.str(entry, 'author', ''))) {
        total += 8;
      }
      const candidate = new MatchCandidate();
      candidate.index = index;
      candidate.score = total;
      candidate.removed = ZenSyncService.int(entry, 'isRemove', 0) !== 0;
      candidate.updatedAt = ZenSyncService.int(entry, 'updatedAt', 0);
      candidates.push(candidate);
    }
    if (candidates.length === 0) {
      return -1;
    }
    let bestScore = 0;
    for (let i = 0; i < candidates.length; i++) {
      if (candidates[i].score > bestScore) {
        bestScore = candidates[i].score;
      }
    }
    if (bestScore < 30) {
      return -1;
    }
    let liveBest: MatchCandidate | null = null;
    let anyBest: MatchCandidate | null = null;
    for (let i = 0; i < candidates.length; i++) {
      const candidate = candidates[i];
      if (candidate.score !== bestScore) {
        continue;
      }
      if (anyBest === null || candidate.updatedAt > anyBest.updatedAt) {
        anyBest = candidate;
      }
      if (!candidate.removed) {
        if (liveBest === null || candidate.updatedAt > liveBest.updatedAt) {
          liveBest = candidate;
        }
      }
    }
    if (liveBest !== null) {
      return liveBest.index;
    }
    return anyBest !== null ? anyBest.index : -1;
  }

  private static webdavPath(entry: JsonNode): string {
    const raw = entry.get('extraJSON');
    if (raw === null) {
      return '';
    }
    let extra: JsonNode | null = null;
    if (raw.kind === JsonKind.STRING) {
      try {
        extra = JsonCodec.parse(raw.stringValue);
      } catch (error) {
        return '';
      }
    } else if (raw.kind === JsonKind.OBJECT) {
      extra = raw;
    }
    if (extra === null) {
      return '';
    }
    const webdav = extra.get('webdav');
    if (webdav === null) {
      return '';
    }
    const pathNode = webdav.get('path');
    if (pathNode === null) {
      return '';
    }
    const path = pathNode.asString().trim();
    if (path.indexOf('objects/') !== 0 || path.indexOf('..') >= 0) {
      return '';
    }
    return path;
  }

  private static webdavSha(entry: JsonNode): string {
    const path = ZenSyncService.webdavPath(entry);
    if (path.length === 0) {
      return '';
    }
    const raw = entry.get('extraJSON');
    let extra: JsonNode | null = null;
    if (raw !== null && raw.kind === JsonKind.STRING) {
      try {
        extra = JsonCodec.parse(raw.stringValue);
      } catch (error) {
        return '';
      }
    } else if (raw !== null && raw.kind === JsonKind.OBJECT) {
      extra = raw;
    }
    if (extra === null) {
      return '';
    }
    const webdav = extra.get('webdav');
    if (webdav === null) {
      return '';
    }
    const sha = webdav.get('sha256');
    return sha !== null ? sha.asString().trim().toLowerCase() : '';
  }

  private static zenPercent(entry: JsonNode): number {
    const value = entry.get('progress');
    if (value === null) {
      return -1;
    }
    const number = value.asNumber(-1);
    return number >= 0 ? number : -1;
  }

  private static remotePosition(book: LibraryBook, entry: JsonNode, percent: number): number {
    if (book.format === 'PDF') {
      const page = ZenSyncService.int(entry, 'readPage', -1);
      const count = BookService.shared().pdfPageCount(book.id);
      if (page >= 0 && count > 1) {
        return Math.min(Math.max(page / (count - 1), 0), 1);
      }
      return percent >= 0 ? Math.min(Math.max(percent / 100, 0), 1) : 0;
    }
    if (percent < 0) {
      return 0;
    }
    if (percent <= 0) {
      return 0;
    }
    if (percent >= 100) {
      return 1;
    }
    const model = BookService.shared().textModel(book);
    if (model !== null) {
      const readText = ZenSyncService.str(entry, 'readText', '');
      const neighbor = book.format === 'MOBI' || book.format === 'AZW' || book.format === 'AZW3';
      const converted = ZenTextLocator.progressFromPercent(percent, readText, neighbor, model);
      if (converted !== null) {
        return converted;
      }
    }
    return Math.min(Math.max(percent / 100, 0), 1);
  }

  private static positionPayload(book: LibraryBook, progress: number,
    pdfPages: Map<string, number>): ZenPositionPayload | null {
    if (book.format === 'PDF') {
      let count = BookService.shared().pdfPageCount(book.id);
      if (count <= 1) {
        count = 0;
      }
      if (count <= 1) {
        return null;
      }
      const page = Math.min(Math.max(Math.round(progress * (count - 1)), 0), count - 1);
      const payload = new ZenPositionPayload();
      payload.percent = (page + 1) / count * 100;
      payload.readPage = page;
      payload.readChapter = 0;
      payload.readText = '';
      return ZenSyncService.withShownPercent(book, payload);
    }
    const model = BookService.shared().textModel(book);
    if (model === null) {
      return null;
    }
    const clamped = Math.min(Math.max(progress, 0), 1);
    if (book.locatorText.length > 0 && book.locatorProgress >= 0 &&
      Math.abs(book.locatorProgress - clamped) <= 0.01) {
      const anchored = ZenTextLocator.locateByText(book.locatorText, clamped, model);
      if (anchored !== null) {
        return ZenSyncService.withShownPercent(book, anchored);
      }
    }
    return ZenSyncService.withShownPercent(book, ZenTextLocator.locate(clamped, model));
  }

  /** Keep the uploaded percent identical to the number shown on this device. */
  private static withShownPercent(book: LibraryBook, payload: ZenPositionPayload | null): ZenPositionPayload | null {
    if (payload !== null && book.zenProgress >= 0) {
      payload.percent = Math.min(Math.max(book.zenProgress * 100, 0), 100);
    }
    return payload;
  }

  private static percentString(value: number): string {
    const clamped = Math.min(Math.max(value, 0), 100);
    return String(clamped);
  }

  private static async accountKeyAsync(server: string, username: string): Promise<string> {
    let value = server.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    value += '/';
    return await HashService.sha256Text(value + '|' + username.trim());
  }

  private static cachedBookPath(displayName: string, fileType: string, objectID: string,
    expectedSize: number): string {
    let safeName = displayName.replace(/[\/\\:*?"<>|]/g, '_').trim();
    if (safeName.length === 0) {
      safeName = objectID;
    }
    if (safeName.toLowerCase().endsWith('.' + fileType.toLowerCase())) {
      safeName = safeName.substring(0, safeName.length - fileType.length - 1);
    }
    const primary = AppPaths.cloudBooks() + '/' + safeName + '.' + fileType;
    if (FileService.exists(primary)) {
      if (expectedSize <= 0 || FileService.size(primary) === expectedSize) {
        return primary;
      }
    }
    const fallback = AppPaths.cloudBooks() + '/' + safeName + '-' +
      objectID.substring(0, 8) + '.' + fileType;
    if (FileService.exists(fallback)) {
      return fallback;
    }
    return primary;
  }

  private static emptySnapshot(deviceId: string): JsonNode {
    const root = JsonNode.object();
    root.set('files', JsonNode.array());
    root.set('deviceId', JsonNode.string(deviceId));
    root.set('app', JsonNode.string('readerZen'));
    root.set('formatVersion', JsonNode.number(1));
    return root;
  }

  async sync(books: LibraryBook[], mode: string,
    onProgress: ((stage: string, done: number, total: number) => void) | null): Promise<SyncResult> {
    const config = SettingsStore.shared().sync;
    if (config.username.trim().length === 0 || config.password.length === 0) {
      throw new WebDavError('请先在 WebDAV 设置里填写账号和应用密码');
    }
    if (config.deviceId.length === 0) {
      config.deviceId = ZenSyncService.uuid();
      SettingsStore.shared().saveSync();
    }
    const result = new SyncResult();
    const client = new WebDavClient(config.server, config.username, config.password, config.remoteFolder);
    if (onProgress !== null) {
      onProgress('正在检查云端快照…', 0, 0);
    }
    const latest = await client.latestSnapshotOrNull();
    if (latest === null && mode === 'download') {
      throw new WebDavError('云端还没有同步数据，请先上传一次');
    }
    const root = latest !== null ? latest.node : ZenSyncService.emptySnapshot(config.deviceId);
    const filesNode = root.get('files');
    if (filesNode === null || filesNode.kind !== JsonKind.ARRAY) {
      throw new WebDavError('云端快照缺少书籍列表');
    }
    const files = filesNode.arrayValue;
    result.remoteSnapshot = latest !== null ? latest.name : '';
    result.totalRemoteBooks = files.length;
    const store = LibraryStore.shared();
    const pdfPages: Map<string, number> = new Map<string, number>();
    // First upload into a freshly created EasyRead folder still has to publish an
    // initial snapshot, even when the shelf is empty.
    let dirty = latest === null;

    const uploadMode = mode === 'upload';
    const downloadMode = mode === 'download';
    const transferBooks = !uploadMode;

    if (transferBooks) {
      const downloaded = await this.downloadMissingBooks(client, files, result, onProgress);
      if (downloaded > 0) {
        dirty = false;
      }
    }

    if (onProgress !== null) {
      onProgress('正在整理阅读进度…', 0, 0);
    }

    const removalIds: string[] = [];
    const shelf = store.bySource('jianguoyun');
    for (let i = 0; i < shelf.length; i++) {
      const book = shelf[i];
      const localBytes = FileService.size(book.path);
      const index = ZenSyncService.matchIndex(book, files, localBytes);
      if (index < 0) {
        continue;
      }
      if (ZenSyncService.int(files[index], 'isRemove', 0) !== 0) {
        removalIds.push(book.id);
      }
    }
    if (removalIds.length > 0) {
      for (let i = 0; i < removalIds.length; i++) {
        const book = store.find(removalIds[i]);
        if (book !== null) {
          BookService.shared().deleteBookData(book);
          BookmarkStore.shared().removeForBook(book.id);
          store.remove(book.id);
        }
      }
      result.removedBookIds = removalIds;
      dirty = true;
    }

    const pushDate = latest !== null ?
      Math.max(Date.now(), ZenSyncService.dateFromSnapshot(latest.name) + 2) : Date.now();
    for (let i = 0; i < shelf.length; i++) {
      const book = shelf[i];
      if (removalIds.indexOf(book.id) >= 0) {
        continue;
      }
      const localBytes = FileService.size(book.path);
      const index = ZenSyncService.matchIndex(book, files, localBytes);
      if (index < 0) {
        continue;
      }
      result.matched += 1;
      const entry = files[index];
      const percent = ZenSyncService.zenPercent(entry);
      const local = book.syncedPosition();
      const remote = ZenSyncService.remotePosition(book, entry, percent);
      const remoteDate = ZenSyncService.int(entry, 'updatedAt', 0);
      const remoteText = ZenSyncService.str(entry, 'readText', '').trim();
      let decision = 'none';
      if (uploadMode) {
        // A local progress record wins even when it is 0%, so a deliberate
        // rewind to the first page can still overwrite the cloud. Books that
        // were never read on this device keep the cloud position.
        if (local > 0.0001 || book.progressUpdatedAt > 0) {
          decision = 'push';
        }
      } else if (downloadMode) {
        if (percent >= 0) {
          decision = 'pull';
        }
      } else if (remoteDate > 0 || remote > 0) {
        if (book.progressUpdatedAt > 0) {
          if (remoteDate > book.progressUpdatedAt + 1000) {
            decision = 'pull';
          } else if (book.progressUpdatedAt > remoteDate + 1000) {
            // The local read time is newer, so the local position wins even
            // when the reader moved back to 0% (first page). Comparing the
            // progress values here used to drop that rewind: 0 is never
            // larger than the cloud's 60%, so the sync reported "已是最新".
            decision = 'push';
          } else if (remote > local + 0.0001) {
            decision = 'pull';
          } else if (local > remote + 0.0001) {
            decision = 'push';
          }
        } else if (remote > local + 0.0001) {
          decision = 'pull';
        } else if (local > remote + 0.0001) {
          decision = 'push';
        }
      } else if (local > 0.0001) {
        decision = 'push';
      }

      if (decision === 'pull') {
        if (Math.abs(remote - local) > 0.0001) {
          result.pulled += 1;
        }
        store.applyCloudPosition(book.id, remote, remote, remoteText, remoteDate,
          percent >= 0 ? percent / 100 : -1);
      } else if (decision === 'push') {
        const payload = ZenSyncService.positionPayload(book, local, pdfPages);
        if (payload !== null) {
          book.zenProgress = Math.min(Math.max(payload.percent / 100, 0), 1);
          entry.set('progress', JsonNode.string(ZenSyncService.percentString(payload.percent)));
          if (book.format === 'PDF') {
            entry.set('readPage', JsonNode.number(payload.readPage));
          } else {
            entry.set('readChapter', JsonNode.number(payload.readChapter));
            entry.set('readPage', JsonNode.number(payload.readPage));
            if (payload.readText.length > 0) {
              entry.set('readText', JsonNode.string(payload.readText));
            }
          }
        } else {
          const fallbackPercent = book.zenProgress >= 0 ? book.zenProgress * 100 : local * 100;
          entry.set('progress', JsonNode.string(ZenSyncService.percentString(fallbackPercent)));
        }
        entry.set('updatedAt', JsonNode.number(pushDate));
        entry.set('lastOpenDate', JsonNode.number(pushDate));
        entry.set('isReadOver', JsonNode.number(local >= 0.995 ? 1 : 0));
        book.progressUpdatedAt = pushDate;
        result.pushed += 1;
        dirty = true;
      }
    }

    if (!downloadMode) {
      const uploaded = await this.uploadMissingBooks(client, files, result, pushDate, onProgress);
      if (uploaded > 0) {
        dirty = true;
      }
    }

    if (dirty) {
      if (onProgress !== null) {
        onProgress('正在写入云端快照…', 0, 0);
      }
      root.set('files', filesNode);
      root.set('deviceId', JsonNode.string(config.deviceId));
      if (root.get('app') === null) {
        root.set('app', JsonNode.string('readerZen'));
      }
      if (root.get('formatVersion') === null) {
        root.set('formatVersion', JsonNode.number(1));
      }
      let uploadDate = pushDate;
      let uploadedName = '';
      for (let attempt = 0; attempt < 6; attempt++) {
        const candidate = ZenSyncService.snapshotName(new Date(uploadDate));
        root.set('createdAt', JsonNode.number(uploadDate));
        const bytes = HashService.utf8(JsonCodec.stringify(root, true, true, true));
        if (await client.createSnapshot(candidate, bytes)) {
          uploadedName = candidate;
          break;
        }
        uploadDate += 10;
      }
      if (uploadedName.length === 0) {
        throw new WebDavError('无法写入新的云端快照，请稍后重试');
      }
      result.uploadedSnapshot = uploadedName;
      try {
        await this.publishManifest(client, root, uploadedName, uploadDate,
          latest !== null ? latest.name : '');
      } catch (error) {
        result.manifestWarning = '云端清单未更新：' + ZenSyncService.errorText(error);
      }
    }

    config.lastSyncAt = Date.now();
    SettingsStore.shared().saveSync();
    store.flush();
    return result;
  }

  async deleteCloudBook(book: LibraryBook): Promise<string | null> {
    const config = SettingsStore.shared().sync;
    if (config.username.trim().length === 0 || config.password.length === 0) {
      throw new WebDavError('请先在 WebDAV 设置里填写账号和应用密码');
    }
    if (config.deviceId.length === 0) {
      config.deviceId = ZenSyncService.uuid();
      SettingsStore.shared().saveSync();
    }
    const client = new WebDavClient(config.server, config.username, config.password, config.remoteFolder);
    const latest = await client.latestSnapshot();
    const root = latest.node;
    const filesNode = root.get('files');
    if (filesNode === null || filesNode.kind !== JsonKind.ARRAY) {
      throw new WebDavError('云端快照缺少书籍列表');
    }
    const files = filesNode.arrayValue;
    const index = ZenSyncService.matchIndex(book, files, FileService.size(book.path));
    if (index < 0) {
      return null;
    }
    const entry = files[index];
    const objectID = ZenSyncService.str(entry, 'objectID', '').trim();
    const now = Date.now();
    entry.set('isRemove', JsonNode.number(1));
    entry.set('deleteDate', JsonNode.number(now));
    entry.set('updatedAt', JsonNode.number(now));
    if (objectID.length > 0) {
      let tombstones = root.get('tombstones');
      if (tombstones === null || tombstones.kind !== JsonKind.ARRAY) {
        tombstones = JsonNode.array();
        root.set('tombstones', tombstones);
      }
      let exists = false;
      for (let i = 0; i < tombstones.arrayValue.length; i++) {
        const tombstone = tombstones.arrayValue[i];
        if (ZenSyncService.str(tombstone, 'entity', '') === 'file' &&
          ZenSyncService.str(tombstone, 'objectID', '') === objectID) {
          exists = true;
          break;
        }
      }
      if (!exists) {
        const tombstone = JsonNode.object();
        tombstone.set('deletedAt', JsonNode.number(now));
        tombstone.set('entity', JsonNode.string('file'));
        tombstone.set('objectID', JsonNode.string(objectID));
        tombstones.arrayValue.push(tombstone);
      }
    }
    root.set('files', filesNode);
    root.set('deviceId', JsonNode.string(config.deviceId.length > 0 ? config.deviceId : ZenSyncService.uuid()));
    if (root.get('app') === null) {
      root.set('app', JsonNode.string('readerZen'));
    }
    if (root.get('formatVersion') === null) {
      root.set('formatVersion', JsonNode.number(1));
    }
    const latestDate = ZenSyncService.dateFromSnapshot(latest.name);
    let uploadDate = Math.max(now, latestDate + 2);
    let uploadedName = '';
    for (let attempt = 0; attempt < 6; attempt++) {
      const candidate = ZenSyncService.snapshotName(new Date(uploadDate));
      root.set('createdAt', JsonNode.number(uploadDate));
      const bytes = HashService.utf8(JsonCodec.stringify(root, true, true, true));
      if (await client.createSnapshot(candidate, bytes)) {
        uploadedName = candidate;
        break;
      }
      uploadDate += 10;
    }
    if (uploadedName.length === 0) {
      throw new WebDavError('无法写入删除快照');
    }
    try {
      await this.publishManifest(client, root, uploadedName, uploadDate, latest.name);
    } catch (error) {
      // The deletion snapshot is already safe; only the pointer update failed.
    }
    config.lastSyncAt = Date.now();
    SettingsStore.shared().saveSync();
    return uploadedName;
  }

  private async downloadMissingBooks(client: WebDavClient, files: JsonNode[],
    result: SyncResult,
    onProgress: ((stage: string, done: number, total: number) => void) | null): Promise<number> {
    const store = LibraryStore.shared();
    const matched: number[] = [];
    const shelf = store.bySource('jianguoyun');
    for (let i = 0; i < shelf.length; i++) {
      const index = ZenSyncService.matchIndex(shelf[i], files, FileService.size(shelf[i].path));
      if (index >= 0) {
        matched.push(index);
      }
    }
    const supported: string[] = ['txt', 'epub', 'pdf', 'mobi', 'azw', 'azw3', 'md', 'markdown'];
    const seen: Map<string, boolean> = new Map<string, boolean>();
    const pending: PendingDownload[] = [];
    for (let index = 0; index < files.length; index++) {
      if (matched.indexOf(index) >= 0) {
        continue;
      }
      const entry = files[index];
      if (ZenSyncService.int(entry, 'isRemove', 0) !== 0) {
        continue;
      }
      const objectID = ZenSyncService.str(entry, 'objectID', '').trim();
      if (objectID.length === 0 || seen.get(objectID) !== undefined) {
        continue;
      }
      seen.set(objectID, true);
      const fileType = ZenSyncService.str(entry, 'fileType', '').toLowerCase();
      if (supported.indexOf(fileType) < 0) {
        result.transferSkipped += 1;
        continue;
      }
      const displayName = ZenSyncService.str(entry, 'displayName', objectID);
      const expectedSize = ZenSyncService.int(entry, 'fileSize', 0);
      const localPath = ZenSyncService.cachedBookPath(displayName, fileType, objectID, expectedSize);
      const item = new PendingDownload();
      item.index = index;
      item.objectID = objectID;
      item.displayName = displayName;
      item.fileType = fileType;
      item.remotePath = ZenSyncService.webdavPath(entry);
      item.localPath = localPath;
      item.expectedSize = expectedSize;
      item.exists = FileService.exists(localPath) &&
        (expectedSize <= 0 || FileService.size(localPath) === expectedSize);
      pending.push(item);
    }
    const downloads: PendingDownload[] = [];
    for (let i = 0; i < pending.length; i++) {
      if (!pending[i].exists) {
        downloads.push(pending[i]);
      }
    }
    if (downloads.length > 0 && onProgress !== null) {
      onProgress('正在下载云端书籍…', 0, downloads.length);
    }
    let completed = 0;
    for (let i = 0; i < downloads.length; i++) {
      const item = downloads[i];
      try {
        let remotePath = item.remotePath;
        if (remotePath.length === 0) {
          remotePath = 'objects/books/' + item.objectID + '.' + item.fileType;
        }
        const bytes = await client.download(remotePath);
        FileService.writeBytes(item.localPath, bytes);
        item.exists = true;
      } catch (error) {
        result.failures.push(item.displayName + '：' + ZenSyncService.errorText(error));
      }
      completed += 1;
      if (onProgress !== null) {
        onProgress('正在下载云端书籍…', completed, downloads.length);
      }
    }
    let downloaded = 0;
    for (let i = 0; i < pending.length; i++) {
      const item = pending[i];
      if (!item.exists) {
        continue;
      }
      if (store.findByPath(item.localPath) !== null) {
        continue;
      }
      const entry = files[item.index];
      const book = new LibraryBook();
      book.id = LibraryStore.makeId();
      book.title = item.displayName;
      book.author = ZenSyncService.str(entry, 'author', '');
      book.format = BookFormats.fromExtension(item.fileType);
      if (book.format.length === 0) {
        continue;
      }
      book.path = item.localPath;
      book.size = FileService.size(item.localPath);
      book.source = 'jianguoyun';
      book.addedAt = ZenSyncService.int(entry, 'createDate', Date.now());
      const percent = ZenSyncService.zenPercent(entry);
      if (book.format === 'PDF') {
        const readPage = ZenSyncService.int(entry, 'readPage', -1);
        if (readPage >= 0 && percent > 0) {
          book.pageCount = Math.round((readPage + 1) * 100 / percent);
        }
      }
      const remote = ZenSyncService.remotePosition(book, entry, percent);
      book.progress = remote;
      book.textProgress = remote;
      book.locatorText = ZenSyncService.str(entry, 'readText', '');
      book.locatorProgress = book.locatorText.length > 0 ? remote : -1;
      book.zenProgress = percent >= 0 ? Math.min(Math.max(percent / 100, 0), 1) : -1;
      book.progressUpdatedAt = ZenSyncService.int(entry, 'updatedAt', 0);
      store.add(book);
      result.downloadedBooks += 1;
      downloaded += 1;
    }
    store.flush();
    return downloaded;
  }

  private async uploadMissingBooks(client: WebDavClient, files: JsonNode[],
    result: SyncResult, pushDate: number,
    onProgress: ((stage: string, done: number, total: number) => void) | null): Promise<number> {
    const store = LibraryStore.shared();
    const candidates: LibraryBook[] = [];
    const shelf = store.bySource('jianguoyun');
    for (let i = 0; i < shelf.length; i++) {
      const book = shelf[i];
      if (!BookFormats.isPhoneSyncable(book.format)) {
        continue;
      }
      if (!FileService.exists(book.path)) {
        continue;
      }
      const size = FileService.size(book.path);
      if (size <= 0) {
        continue;
      }
      if (ZenSyncService.matchIndex(book, files, size) >= 0) {
        continue;
      }
      candidates.push(book);
    }
    if (candidates.length === 0) {
      return 0;
    }
    if (onProgress !== null) {
      onProgress('正在检查云端书籍…', 0, candidates.length);
    }
    let existing: string[] = [];
    try {
      existing = await client.fileNames('objects/books');
    } catch (error) {
      try {
        await client.ensureCollection('objects/books');
      } catch (inner) {
      }
      existing = [];
    }
    const prepared: PendingUpload[] = [];
    for (let i = 0; i < candidates.length; i++) {
      const book = candidates[i];
      try {
        const bytes = FileService.readBytes(book.path);
        const digest = await HashService.sha256(bytes);
        const item = new PendingUpload(book, bytes);
        item.digest = digest;
        item.remoteName = digest + '.' + book.format.toLowerCase();
        item.objectID = ZenSyncService.uuid();
        prepared.push(item);
      } catch (error) {
        result.failures.push(book.title + '：' + ZenSyncService.errorText(error));
      }
    }
    if (prepared.length === 0) {
      return 0;
    }
    let uploaded = 0;
    const accountKey = await ZenSyncService.accountKeyAsync(
      SettingsStore.shared().sync.server, SettingsStore.shared().sync.username
    );
    for (let i = 0; i < prepared.length; i++) {
      const item = prepared[i];
      try {
        if (existing.indexOf(item.remoteName) < 0) {
          await client.putObject('objects/books/' + item.remoteName, item.bytes,
            'application/octet-stream');
          existing.push(item.remoteName);
        }
        const entry = this.uploadedEntry(item, accountKey, pushDate);
        files.push(entry);
        uploaded += 1;
      } catch (error) {
        result.failures.push(item.book.title + '：' + ZenSyncService.errorText(error));
      }
      if (onProgress !== null) {
        onProgress('正在上传云端书籍…', i + 1, prepared.length);
      }
    }
    result.uploadedBooks += uploaded;
    return uploaded;
  }

  private uploadedEntry(item: PendingUpload, accountKey: string, pushDate: number): JsonNode {
    const book = item.book;
    const progress = book.syncedPosition();
    const payload = ZenSyncService.positionPayload(book, progress, new Map<string, number>());
    const percent = payload !== null ? payload.percent :
      (book.zenProgress >= 0 ? book.zenProgress * 100 : progress * 100);
    book.zenProgress = Math.min(Math.max(percent / 100, 0), 1);
    let displayName = book.title;
    if (book.author.length > 0 &&
      ZenSyncService.normalizeName(book.title).indexOf(ZenSyncService.normalizeName(book.author)) < 0) {
      displayName += ' (' + book.author + ')';
    }
    const created = book.addedAt > 0 ? book.addedAt : pushDate;
    const extra = JsonNode.object();
    extra.set('schemaVersion', JsonNode.number(1));
    const webdav = JsonNode.object();
    webdav.set('accountKey', JsonNode.string(accountKey));
    webdav.set('path', JsonNode.string('objects/books/' + item.remoteName));
    webdav.set('sha256', JsonNode.string(item.digest));
    webdav.set('syncedAt', JsonNode.number(pushDate));
    extra.set('webdav', webdav);
    const entry = JsonNode.object();
    entry.set('author', JsonNode.string(book.author));
    entry.set('createDate', JsonNode.number(created));
    entry.set('displayName', JsonNode.string(displayName));
    entry.set('extraJSON', JsonNode.string(JsonCodec.stringify(extra, true, false, true)));
    entry.set('fileSize', JsonNode.string(String(item.bytes.length)));
    entry.set('fileType', JsonNode.string(book.format.toLowerCase()));
    entry.set('fromType', JsonNode.string(''));
    entry.set('isLock', JsonNode.number(0));
    entry.set('isReadOver', JsonNode.number(progress >= 0.995 ? 1 : 0));
    entry.set('isRemove', JsonNode.number(0));
    entry.set('isTop', JsonNode.number(0));
    entry.set('lastOpenDate', JsonNode.number(pushDate));
    entry.set('objectID', JsonNode.string(item.objectID));
    entry.set('parentId', JsonNode.string(''));
    entry.set('picModel', JsonNode.number(0));
    entry.set('pinYinName', JsonNode.string(ZenSyncService.normalizeName(displayName)));
    entry.set('progress', JsonNode.string(ZenSyncService.percentString(percent)));
    entry.set('readChapter', JsonNode.number(payload !== null ? payload.readChapter : 0));
    entry.set('readPage', JsonNode.number(payload !== null ? payload.readPage : 0));
    entry.set('score', JsonNode.number(0));
    entry.set('updatedAt', JsonNode.number(pushDate));
    if (payload !== null && payload.readText.length > 0) {
      entry.set('readText', JsonNode.string(payload.readText));
    }
    return entry;
  }

  private async publishManifest(client: WebDavClient, root: JsonNode,
    snapshotName: string, createdAt: number, previousSnapshotName: string): Promise<void> {
    const payload = root.copy();
    payload.remove('createdAt');
    const canonical = JsonCodec.canonical(payload);
    const dataSize = HashService.utf8Length(canonical);
    const dataSha = await HashService.sha256Text(canonical);

    let previous: JsonNode | null = null;
    try {
      previous = await client.rootManifest();
    } catch (error) {
      previous = null;
    }
    const previousBooks: Map<string, JsonNode> = new Map<string, JsonNode>();
    if (previous !== null) {
      const oldBooks = previous.get('books');
      if (oldBooks !== null && oldBooks.kind === JsonKind.ARRAY) {
        for (let i = 0; i < oldBooks.arrayValue.length; i++) {
          const node = oldBooks.arrayValue[i];
          const objectID = ZenSyncService.str(node, 'objectID', '');
          if (objectID.length > 0) {
            previousBooks.set(objectID, node);
          }
        }
      }
    }

    const files = root.get('files');
    const books = JsonNode.array();
    if (files !== null && files.kind === JsonKind.ARRAY) {
      for (let i = 0; i < files.arrayValue.length; i++) {
        const entry = files.arrayValue[i];
        const path = ZenSyncService.webdavPath(entry);
        const objectID = ZenSyncService.str(entry, 'objectID', '').trim();
        const size = ZenSyncService.int(entry, 'fileSize', 0);
        if (path.length === 0 || objectID.length === 0 || size <= 0) {
          continue;
        }
        const slash = path.lastIndexOf('/');
        const remoteName = slash >= 0 ? path.substring(slash + 1) : path;
        if (remoteName.length === 0) {
          continue;
        }
        let sha = ZenSyncService.webdavSha(entry);
        if (sha.length === 0) {
          const dot = remoteName.lastIndexOf('.');
          sha = (dot > 0 ? remoteName.substring(0, dot) : remoteName).toLowerCase();
        }
        const old = previousBooks.get(objectID);
        let originalName = ZenSyncService.str(old, 'originalName', '').trim();
        if (originalName.length === 0) {
          originalName = ZenSyncService.str(entry, 'originalName', '').trim();
        }
        if (originalName.length === 0) {
          originalName = ZenSyncService.manifestOriginalName(entry, remoteName);
        }
        const book = JsonNode.object();
        book.set('available', JsonNode.bool(true));
        let contentUpdatedAt = ZenSyncService.int(old, 'contentUpdatedAt', 0);
        if (contentUpdatedAt === 0) {
          contentUpdatedAt = ZenSyncService.int(entry, 'contentUpdatedAt', 0);
        }
        if (contentUpdatedAt === 0) {
          contentUpdatedAt = ZenSyncService.int(entry, 'createDate', 0);
        }
        if (contentUpdatedAt === 0) {
          contentUpdatedAt = ZenSyncService.int(entry, 'updatedAt', createdAt);
        }
        book.set('contentUpdatedAt', JsonNode.number(contentUpdatedAt));
        book.set('objectID', JsonNode.string(objectID));
        book.set('originalName', JsonNode.string(originalName));
        book.set('remoteName', JsonNode.string(remoteName));
        book.set('remotePath', JsonNode.string(path));
        book.set('sha256', JsonNode.string(sha));
        book.set('size', JsonNode.number(size));
        books.arrayValue.push(book);
      }
    }

    const snapshotRoot = 'snapshots/' + snapshotName;
    const historyItems: JsonNode[] = [];
    if (previous !== null) {
      const oldHistory = previous.get('snapshots');
      if (oldHistory !== null && oldHistory.kind === JsonKind.ARRAY) {
        for (let i = 0; i < oldHistory.arrayValue.length; i++) {
          historyItems.push(oldHistory.arrayValue[i].copy());
        }
      }
    }
    if (previousSnapshotName.length > 0 && previousSnapshotName !== snapshotName) {
      let exists = false;
      for (let i = 0; i < historyItems.length; i++) {
        if (ZenSyncService.str(historyItems[i], 'snapshotRoot', '') === 'snapshots/' + previousSnapshotName) {
          exists = true;
          break;
        }
      }
      if (!exists) {
        const previousTime = ZenSyncService.dateFromSnapshot(previousSnapshotName);
        historyItems.push(ZenSyncService.historyEntry(
          previousSnapshotName, previousTime > 0 ? previousTime : createdAt - 1
        ));
      }
    }
    historyItems.push(ZenSyncService.historyEntry(snapshotName, createdAt));
    historyItems.sort((a: JsonNode, b: JsonNode): number =>
      ZenSyncService.int(a, 'createdAt', 0) - ZenSyncService.int(b, 'createdAt', 0));
    const byRoot: Map<string, JsonNode> = new Map<string, JsonNode>();
    for (let i = 0; i < historyItems.length; i++) {
      byRoot.set(ZenSyncService.str(historyItems[i], 'snapshotRoot', ''), historyItems[i]);
    }
    const deduped: JsonNode[] = [];
    byRoot.forEach((value: JsonNode, key: string): void => {
      deduped.push(value);
    });
    deduped.sort((a: JsonNode, b: JsonNode): number =>
      ZenSyncService.int(a, 'createdAt', 0) - ZenSyncService.int(b, 'createdAt', 0));
    const history = JsonNode.array();
    const start = Math.max(0, deduped.length - 20);
    for (let i = start; i < deduped.length; i++) {
      history.arrayValue.push(deduped[i]);
    }

    const manifest = previous !== null ? previous.copy() : JsonNode.object();
    manifest.set('app', JsonNode.string(ZenSyncService.str(manifest, 'app', 'readerZen')));
    manifest.set('books', books);
    if (manifest.get('covers') === null) {
      manifest.set('covers', JsonNode.array());
    }
    manifest.set('createdAt', JsonNode.number(createdAt));
    manifest.set('createdAtText', JsonNode.string(ZenSyncService.dateText(createdAt)));
    manifest.set('dataPath', JsonNode.string(snapshotRoot + '/readerzen.json'));
    manifest.set('dataSha256', JsonNode.string(dataSha));
    manifest.set('dataSize', JsonNode.number(dataSize));
    manifest.set('formatVersion', JsonNode.number(3));
    manifest.set('snapshotRoot', JsonNode.string(snapshotRoot));
    manifest.set('snapshots', history);
    const bytes = HashService.utf8(JsonCodec.stringify(manifest, true, true, true));
    await client.putObject(snapshotRoot + '/manifest.json', bytes, 'application/json; charset=utf-8');
    await client.putObject('manifest.json', bytes, 'application/json; charset=utf-8');
  }

  private static historyEntry(snapshotName: string, createdAt: number): JsonNode {
    const node = JsonNode.object();
    node.set('createdAt', JsonNode.number(createdAt));
    node.set('createdAtText', JsonNode.string(ZenSyncService.dateText(createdAt)));
    node.set('manifestPath', JsonNode.string('snapshots/' + snapshotName + '/manifest.json'));
    node.set('snapshotRoot', JsonNode.string('snapshots/' + snapshotName));
    return node;
  }

  private static manifestOriginalName(entry: JsonNode, remoteName: string): string {
    const originalName = ZenSyncService.str(entry, 'originalName', '').trim();
    if (originalName.length > 0) {
      return originalName;
    }
    const display = ZenSyncService.str(entry, 'displayName', '').trim();
    const type = ZenSyncService.str(entry, 'fileType', '').toLowerCase();
    if (display.length === 0) {
      return remoteName;
    }
    if (type.length > 0 && !display.toLowerCase().endsWith('.' + type)) {
      return display + '.' + type;
    }
    return display;
  }

  private static errorText(error: Object): string {
    if (error instanceof Error) {
      return error.message;
    }
    return String(error);
  }
}
