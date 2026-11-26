import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { JsonCodec, JsonNode } from '../parser/ZenJson';
import { SyncNamespace } from '../model/LibraryModels';
import { HashService } from './HashService';
import { normalizeWebDavRoots, WebDavUrlError, webDavUrl } from './WebDavUrl';

export class WebDavError extends Error {
  status: number = 0;

  constructor(message: string, status: number = 0) {
    super(message);
    this.status = status;
  }
}

class HttpResult {
  status: number = 0;
  bytes: Uint8Array = new Uint8Array(0);

  text(): string {
    return new util.TextDecoder('utf-8').decodeWithStream(this.bytes);
  }
}

/**
 * `customMethod` is the official WebDAV hook from API 23. Declaring it locally
 * keeps the project buildable with an API 12 SDK while still passing it on
 * newer devices; older runtimes fall back to the method string itself.
 */
interface WebDavHttpOptions extends http.HttpRequestOptions {
  customMethod?: string;
}

export class SnapshotInfo {
  name: string = '';
  bytes: Uint8Array = new Uint8Array(0);
  node: JsonNode = JsonNode.object();
}

export class WebDavClient {
  /** The account root the user typed, e.g. https://dav.jianguoyun.com/dav/ */
  private accountUrl: string = '';
  /** accountUrl + EasyRead or ZenReader/v1; used for every file request. */
  private rootUrl: string = '';
  private namespaceCollection: string = 'EasyRead';
  private username: string = '';
  private password: string = '';
  private ensured: Map<string, boolean> = new Map<string, boolean>();

  constructor(server: string, username: string, password: string,
    namespace: string = SyncNamespace.EASYREAD) {
    this.username = username.trim();
    this.password = password;
    const collection = namespace === SyncNamespace.ZENREADER ? 'ZenReader/v1' : 'EasyRead';
    try {
      const roots = normalizeWebDavRoots(server, collection);
      this.accountUrl = roots.accountUrl;
      this.rootUrl = roots.rootUrl;
      this.namespaceCollection = roots.collection;
    } catch (error) {
      if (error instanceof WebDavUrlError) {
        throw new WebDavError(error.message);
      }
      throw new WebDavError('服务器地址无效');
    }
  }

  get root(): string {
    return this.rootUrl;
  }

  private authHeader(): string {
    return 'Basic ' + HashService.base64Utf8(this.username + ':' + this.password);
  }

  private async execute(baseUrl: string, method: string, relativePath: string, depth: string,
    contentType: string, body: ArrayBuffer | null): Promise<HttpResult> {
    const client = http.createHttp();
    try {
      const headers: Record<string, string> = {
        'Authorization': this.authHeader(),
        'User-Agent': 'EasyRead-Harmony/1.0'
      };
      if (depth.length > 0) {
        headers['Depth'] = depth;
      }
      if (contentType.length > 0) {
        headers['Content-Type'] = contentType;
      }
      // RequestMethod is a string enum; WebDAV's PROPFIND/MKCOL methods are
      // passed through as-is. customMethod (API 23+) has higher priority when
      // the runtime understands it.
      const options: WebDavHttpOptions = {
        method: method as http.RequestMethod,
        header: headers,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 30000,
        readTimeout: 900000,
        usingCache: false,
        maxLimit: 512 * 1024 * 1024
      };
      if (method === 'PROPFIND' || method === 'MKCOL') {
        options.customMethod = method;
      }
      if (body !== null) {
        options.extraData = body;
      }
      const response = await client.request(webDavUrl(baseUrl, relativePath), options);
      const result = new HttpResult();
      result.status = response.responseCode;
      if (response.result instanceof ArrayBuffer) {
        result.bytes = new Uint8Array(response.result);
      } else if (typeof response.result === 'string') {
        result.bytes = new util.TextEncoder().encodeInto(response.result);
      }
      if (result.status === 401) {
        throw new WebDavError('账号或应用密码不正确', 401);
      }
      if (result.status === 403) {
        throw new WebDavError('服务器拒绝访问', 403);
      }
      return result;
    } catch (error) {
      if (error instanceof WebDavError) {
        throw error;
      }
      throw new WebDavError('网络请求失败：' + WebDavClient.errorText(error), 0);
    } finally {
      client.destroy();
    }
  }

  private static errorText(error: Object): string {
    if (error instanceof Error) {
      return error.message;
    }
    return String(error);
  }

  private async requestWithRetry(baseUrl: string, method: string, relativePath: string, depth: string,
    contentType: string, body: ArrayBuffer | null): Promise<HttpResult> {
    try {
      return await this.execute(baseUrl, method, relativePath, depth, contentType, body);
    } catch (error) {
      if (error instanceof WebDavError && error.status !== 0) {
        throw error;
      }
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 350);
      });
      return await this.execute(baseUrl, method, relativePath, depth, contentType, body);
    }
  }

  private static hrefs(xml: string): string[] {
    const result: string[] = [];
    const pattern = /href\s*>\s*([^<]+?)\s*<\/[^>]*href/gi;
    let match = pattern.exec(xml);
    while (match !== null) {
      let value = match[1];
      value = value.split('&amp;').join('&');
      try {
        value = decodeURIComponent(value);
      } catch (error) {
      }
      result.push(value);
      match = pattern.exec(xml);
    }
    return result;
  }

  async snapshotNames(): Promise<string[]> {
    const xmlBody = '<?xml version="1.0" encoding="utf-8"?>' +
      '<D:propfind xmlns:D="DAV:"><D:prop><D:resourcetype/></D:prop></D:propfind>';
    const result = await this.requestWithRetry(
      this.rootUrl, 'PROPFIND', 'snapshots/', '1', 'application/xml; charset=utf-8',
      new util.TextEncoder().encodeInto(xmlBody).buffer as ArrayBuffer
    );
    if (result.status === 404) {
      return [];
    }
    if (result.status !== 207 && result.status !== 200) {
      throw new WebDavError('无法读取云端快照目录（HTTP ' + result.status + '）', result.status);
    }
    const names: string[] = [];
    const seen: Map<string, boolean> = new Map<string, boolean>();
    const hrefs = WebDavClient.hrefs(result.text());
    for (let i = 0; i < hrefs.length; i++) {
      let href = hrefs[i];
      while (href.endsWith('/')) {
        href = href.substring(0, href.length - 1);
      }
      const slash = href.lastIndexOf('/');
      const name = slash >= 0 ? href.substring(slash + 1) : href;
      if (/^\d{8}-\d{6}-\d{3}$/.test(name) && seen.get(name) === undefined) {
        seen.set(name, true);
        names.push(name);
      }
    }
    names.sort();
    names.reverse();
    return names;
  }

  async fileNames(folder: string): Promise<string[]> {
    const xmlBody = '<?xml version="1.0" encoding="utf-8"?>' +
      '<D:propfind xmlns:D="DAV:"><D:prop><D:resourcetype/></D:prop></D:propfind>';
    const result = await this.requestWithRetry(
      this.rootUrl, 'PROPFIND', folder + '/', '1', 'application/xml; charset=utf-8',
      new util.TextEncoder().encodeInto(xmlBody).buffer as ArrayBuffer
    );
    if (result.status === 404) {
      return [];
    }
    if (result.status !== 207 && result.status !== 200) {
      throw new WebDavError('无法列出云端书籍（HTTP ' + result.status + '）', result.status);
    }
    const names: string[] = [];
    const hrefs = WebDavClient.hrefs(result.text());
    for (let i = 0; i < hrefs.length; i++) {
      let href = hrefs[i];
      const isFolder = href.endsWith('/');
      while (href.endsWith('/')) {
        href = href.substring(0, href.length - 1);
      }
      const slash = href.lastIndexOf('/');
      const name = slash >= 0 ? href.substring(slash + 1) : href;
      if (name.length > 0 && name !== folder && !isFolder) {
        names.push(name);
      }
    }
    return names;
  }

  async get(relativePath: string): Promise<Uint8Array | null> {
    const result = await this.requestWithRetry(this.rootUrl, 'GET', relativePath, '', '', null);
    if (result.status === 404) {
      return null;
    }
    if (result.status !== 200 && result.status !== 206) {
      throw new WebDavError('下载失败（HTTP ' + result.status + '）', result.status);
    }
    return result.bytes;
  }

  private static propfindBody(): string {
    return '<?xml version="1.0" encoding="utf-8"?>' +
      '<D:propfind xmlns:D="DAV:"><D:prop><D:resourcetype/></D:prop></D:propfind>';
  }

  private async collectionExistsAt(baseUrl: string, relativePath: string): Promise<boolean> {
    const result = await this.requestWithRetry(
      baseUrl, 'PROPFIND', relativePath + '/', '0', 'application/xml; charset=utf-8',
      new util.TextEncoder().encodeInto(WebDavClient.propfindBody()).buffer as ArrayBuffer
    );
    return result.status === 207 || result.status === 200;
  }

  /** Creates a folder below the selected layout root (EasyRead / ZenReader/v1). */
  async ensureCollection(relativePath: string): Promise<void> {
    await this.ensureCollectionAt(this.rootUrl, relativePath);
  }

  private async ensureCollectionAt(baseUrl: string, relativePath: string): Promise<void> {
    const cacheKey = baseUrl + '\n' + relativePath;
    const cached = this.ensured.get(cacheKey);
    if (cached !== undefined) {
      return;
    }
    const result = await this.requestWithRetry(baseUrl, 'MKCOL', relativePath + '/', '', '', null);
    if (result.status === 201 || result.status === 200 || result.status === 405) {
      this.ensured.set(cacheKey, true);
      return;
    }
    if (result.status === 409) {
      // Most servers use 405 for an existing collection, but some WebDAV
      // implementations answer 409 either for "already here" or for a missing
      // parent. Check before treating it as a missing parent.
      if (await this.collectionExistsAt(baseUrl, relativePath)) {
        this.ensured.set(cacheKey, true);
        return;
      }
      const slash = relativePath.lastIndexOf('/');
      if (slash > 0) {
        await this.ensureCollectionAt(baseUrl, relativePath.substring(0, slash));
        const retry = await this.requestWithRetry(baseUrl, 'MKCOL', relativePath + '/', '', '', null);
        let created = retry.status === 201 || retry.status === 200 || retry.status === 405;
        if (!created && retry.status === 409) {
          created = await this.collectionExistsAt(baseUrl, relativePath);
        }
        if (created) {
          this.ensured.set(cacheKey, true);
          return;
        }
        throw new WebDavError('无法创建云端目录（HTTP ' + retry.status + '）', retry.status);
      }
      throw new WebDavError('无法创建同步目录，请确认服务器地址中的目录已存在', 409);
    }
    throw new WebDavError('无法创建云端目录（HTTP ' + result.status + '）', result.status);
  }

  /**
   * Creates EasyRead (or ZenReader/v1) below the account root. This must use
   * accountUrl, not rootUrl: rootUrl already ends with the layout folder.
   */
  async ensureRoot(): Promise<void> {
    await this.ensureCollectionAt(this.accountUrl, this.namespaceCollection);
  }

  async ensureParent(relativePath: string): Promise<void> {
    const segments = relativePath.split('/');
    let path = '';
    for (let i = 0; i < segments.length - 1; i++) {
      if (segments[i].length === 0) {
        continue;
      }
      path = path.length === 0 ? segments[i] : path + '/' + segments[i];
      await this.ensureCollection(path);
    }
  }

  async putObject(relativePath: string, bytes: Uint8Array, contentType: string): Promise<void> {
    await this.ensureParent(relativePath);
    const body = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
    const result = await this.requestWithRetry(this.rootUrl, 'PUT', relativePath, '', contentType, body);
    if (result.status !== 200 && result.status !== 201 && result.status !== 204) {
      throw new WebDavError('上传失败（HTTP ' + result.status + '）', result.status);
    }
  }

  async createSnapshot(name: string, bytes: Uint8Array): Promise<boolean> {
    const path = 'snapshots/' + name + '/readerzen.json';
    await this.ensureParent(path);
    const body = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
    const result = await this.requestWithRetry(this.rootUrl, 'PUT', path, '', 'application/json; charset=utf-8', body);
    if (result.status === 200 || result.status === 201 || result.status === 204) {
      return true;
    }
    if (result.status === 409 || result.status === 412) {
      return false;
    }
    throw new WebDavError('写入云端快照失败（HTTP ' + result.status + '）', result.status);
  }

  async rootManifest(): Promise<JsonNode | null> {
    const bytes = await this.get('manifest.json');
    if (bytes === null) {
      return null;
    }
    try {
      return JsonCodec.parse(new util.TextDecoder('utf-8').decodeWithStream(bytes));
    } catch (error) {
      return null;
    }
  }

  /**
   * Reads the newest snapshot, or null when the selected remote folder has no
   * sync data yet. Creating the folder here means a fresh EasyRead folder works
   * without any manual setup in the WebDAV provider.
   */
  async latestSnapshotOrNull(): Promise<SnapshotInfo | null> {
    await this.ensureRoot();
    let preferredName = '';
    let preferredPath = '';
    try {
      const manifest = await this.rootManifest();
      if (manifest !== null) {
        const dataPath = manifest.get('dataPath');
        if (dataPath !== null) {
          preferredPath = dataPath.asString();
        }
        const snapshotRoot = manifest.get('snapshotRoot');
        if (snapshotRoot !== null) {
          const root = snapshotRoot.asString();
          const slash = root.lastIndexOf('/');
          preferredName = slash >= 0 ? root.substring(slash + 1) : root;
        }
      }
    } catch (error) {
      // A stale or unreadable root manifest is not fatal; fall back to the
      // newest snapshot folder below.
    }

    if (preferredPath.length > 0) {
      const bytes = await this.get(preferredPath);
      if (bytes !== null) {
        const info = new SnapshotInfo();
        info.name = preferredName;
        info.bytes = bytes;
        let parsed = false;
        try {
          info.node = JsonCodec.parse(new util.TextDecoder('utf-8').decodeWithStream(bytes));
          parsed = info.node.get('files') !== null;
        } catch (error) {
          parsed = false;
        }
        if (parsed) {
          return info;
        }
      }
    }

    const names = await this.snapshotNames();
    if (names.length === 0) {
      return null;
    }
    const limit = Math.min(names.length, 12);
    for (let i = 0; i < limit; i++) {
      const path = 'snapshots/' + names[i] + '/readerzen.json';
      const bytes = await this.get(path);
      if (bytes === null) {
        continue;
      }
      const info = new SnapshotInfo();
      info.name = names[i];
      info.bytes = bytes;
      try {
        info.node = JsonCodec.parse(new util.TextDecoder('utf-8').decodeWithStream(bytes));
      } catch (error) {
        continue;
      }
      return info;
    }
    throw new WebDavError('无法读取最新的云端快照');
  }

  async latestSnapshot(): Promise<SnapshotInfo> {
    const info = await this.latestSnapshotOrNull();
    if (info === null) {
      throw new WebDavError('云端还没有同步快照，请先上传一次');
    }
    return info;
  }

  async testConnection(): Promise<number> {
    await this.ensureRoot();
    return (await this.snapshotNames()).length;
  }

  async download(relativePath: string): Promise<Uint8Array> {
    const bytes = await this.get(relativePath);
    if (bytes === null) {
      throw new WebDavError('云端文件不存在：' + relativePath, 404);
    }
    return bytes;
  }
}
