import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

export class AppContext {
  private static context: common.UIAbilityContext | null = null;
  private static window: window.Window | null = null;

  static init(context: common.UIAbilityContext, mainWindow: window.Window): void {
    AppContext.context = context;
    AppContext.window = mainWindow;
  }

  static abilityContext(): common.UIAbilityContext {
    if (AppContext.context === null) {
      throw new Error('应用上下文尚未初始化');
    }
    return AppContext.context;
  }

  static mainWindow(): window.Window | null {
    return AppContext.window;
  }

  static filesDir(): string {
    return AppContext.abilityContext().filesDir;
  }

  static cacheDir(): string {
    return AppContext.abilityContext().cacheDir;
  }
}

export class AppPaths {
  static root(): string {
    return AppContext.filesDir() + '/EasyRead';
  }

  static localBooks(): string {
    return AppPaths.root() + '/Books';
  }

  static cloudBooks(): string {
    return AppPaths.root() + '/ZenReaderBooks';
  }

  static libraryFile(): string {
    return AppPaths.root() + '/library.json';
  }

  static settingsFile(): string {
    return AppPaths.root() + '/settings.json';
  }

  static bookmarksFile(): string {
    return AppPaths.root() + '/bookmarks.json';
  }

  static syncFile(): string {
    return AppPaths.root() + '/sync.json';
  }

  static privacyFile(): string {
    return AppPaths.root() + '/privacy.json';
  }

  static cacheRoot(): string {
    return AppContext.cacheDir() + '/EasyRead';
  }

  static readerCache(): string {
    return AppPaths.cacheRoot() + '/Reader';
  }

  static coverCache(): string {
    return AppPaths.cacheRoot() + '/Covers';
  }

  static comicCache(): string {
    return AppPaths.cacheRoot() + '/Comic';
  }
}

export class FileService {
  static ensureBaseDirs(): void {
    const dirs: string[] = [
      AppPaths.root(), AppPaths.localBooks(), AppPaths.cloudBooks(),
      AppPaths.cacheRoot(), AppPaths.readerCache(), AppPaths.coverCache(), AppPaths.comicCache()
    ];
    for (let i = 0; i < dirs.length; i++) {
      FileService.ensureDir(dirs[i]);
    }
  }

  static ensureDir(path: string): void {
    if (!fs.accessSync(path)) {
      fs.mkdirSync(path, true);
    }
  }

  static exists(path: string): boolean {
    if (path.length === 0) {
      return false;
    }
    return fs.accessSync(path);
  }

  static size(path: string): number {
    try {
      return fs.statSync(path).size;
    } catch (error) {
      return 0;
    }
  }

  static mtimeMs(path: string): number {
    try {
      return Math.round(fs.statSync(path).mtime * 1000);
    } catch (error) {
      return 0;
    }
  }

  static readBytes(path: string): Uint8Array {
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const chunks: Uint8Array[] = [];
      const buffer = new ArrayBuffer(4 * 1024 * 1024);
      let total = 0;
      while (true) {
        const read = fs.readSync(file.fd, buffer);
        if (read <= 0) {
          break;
        }
        chunks.push(new Uint8Array(buffer.slice(0, read)));
        total += read;
        if (read < buffer.byteLength) {
          break;
        }
      }
      const result = new Uint8Array(total);
      let offset = 0;
      for (let i = 0; i < chunks.length; i++) {
        result.set(chunks[i], offset);
        offset += chunks[i].length;
      }
      return result;
    } finally {
      fs.closeSync(file.fd);
    }
  }

  static readText(path: string): string {
    const bytes = FileService.readBytes(path);
    if (bytes.length === 0) {
      return '';
    }
    const text = new util.TextDecoder('utf-8', { ignoreBOM: true }).decodeWithStream(bytes);
    return text ? text : '';
  }

  static writeBytes(path: string, bytes: Uint8Array): void {
    FileService.ensureDir(FileService.parent(path));
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      let offset = 0;
      while (offset < bytes.length) {
        const chunk = bytes.subarray(offset, Math.min(bytes.length, offset + 1024 * 1024));
        const written = fs.writeSync(file.fd, chunk.buffer.slice(chunk.byteOffset, chunk.byteOffset + chunk.length));
        if (written <= 0) {
          break;
        }
        offset += written;
      }
    } finally {
      fs.closeSync(file.fd);
    }
  }

  static writeText(path: string, text: string): void {
    if (!text || text.length === 0) {
      // util.TextEncoder.encodeInto('') is not reliable on every device build;
      // write an explicit empty buffer instead of passing a possibly undefined.
      FileService.writeBytes(path, new Uint8Array(0));
      return;
    }
    const encoder = new util.TextEncoder();
    FileService.writeBytes(path, encoder.encodeInto(text));
  }

  static writeTextAtomic(path: string, text: string): void {
    const temporary = path + '.tmp';
    FileService.writeText(temporary, text);
    if (FileService.exists(path)) {
      fs.unlinkSync(path);
    }
    fs.renameSync(temporary, path);
  }

  static delete(path: string): void {
    if (FileService.exists(path)) {
      fs.unlinkSync(path);
    }
  }

  static list(path: string): string[] {
    try {
      return fs.listFileSync(path);
    } catch (error) {
      return [];
    }
  }

  static parent(path: string): string {
    const index = path.lastIndexOf('/');
    return index > 0 ? path.substring(0, index) : path;
  }

  static fileName(path: string): string {
    const index = path.lastIndexOf('/');
    return index >= 0 ? path.substring(index + 1) : path;
  }

  static extension(path: string): string {
    const name = FileService.fileName(path);
    const dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
  }

  private static uniqueDestination(destinationDir: string, preferredName: string): string {
    let name = preferredName.length > 0 ? preferredName : 'book';
    name = name.replace(/[\/\\:*?"<>|]/g, '_');
    let destination = destinationDir + '/' + name;
    if (FileService.exists(destination)) {
      const dot = name.lastIndexOf('.');
      const stem = dot > 0 ? name.substring(0, dot) : name;
      const suffix = dot > 0 ? name.substring(dot) : '';
      const stamp = Date.now().toString();
      destination = destinationDir + '/' + stem + '-' + stamp + suffix;
    }
    return destination;
  }

  /** Copies a picker URI into the app sandbox and returns the new path. */
  static copyFromUri(uri: string, destinationDir: string, preferredName: string): string {
    FileService.ensureDir(destinationDir);
    const destination = FileService.uniqueDestination(destinationDir, preferredName);
    const source = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    const target = fs.openSync(destination, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      const buffer = new ArrayBuffer(1024 * 1024);
      while (true) {
        const read = fs.readSync(source.fd, buffer);
        if (read <= 0) {
          break;
        }
        let written = 0;
        while (written < read) {
          const slice = buffer.slice(written, read);
          const count = fs.writeSync(target.fd, slice);
          if (count <= 0) {
            break;
          }
          written += count;
        }
        if (read < buffer.byteLength) {
          break;
        }
      }
    } finally {
      fs.closeSync(source.fd);
      fs.closeSync(target.fd);
    }
    return destination;
  }

  /**
   * Asynchronous variant used for folder imports. The native copy runs off the
   * UI thread, so importing a directory with hundreds of megabytes of books
   * does not freeze the shelf the way the synchronous loop above would.
   */
  static async copyFromUriAsync(uri: string, destinationDir: string,
    preferredName: string): Promise<string> {
    FileService.ensureDir(destinationDir);
    const destination = FileService.uniqueDestination(destinationDir, preferredName);
    const source = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      await fs.copyFile(source.fd, destination);
    } finally {
      fs.closeSync(source.fd);
    }
    return destination;
  }

  static uriFileName(uri: string): string {
    const index = uri.lastIndexOf('/');
    const raw = index >= 0 ? uri.substring(index + 1) : uri;
    try {
      return decodeURIComponent(raw);
    } catch (error) {
      return raw;
    }
  }
}
