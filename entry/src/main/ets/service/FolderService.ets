import { fileIo as fs, fileShare, fileUri } from '@kit.CoreFileKit';
import { BookFormats } from './LibraryStore';

export class FolderScanResult {
  files: string[] = [];
  error: string = '';
  skipped: number = 0;
}

/**
 * Scans a folder picked through DocumentViewPicker and returns the supported
 * book files inside it. The picker hands back a `file://docs/...` URI; recent
 * system builds accept it directly in the file APIs, older ones only accept
 * the plain path, so both are tried before a folder is reported unreadable.
 */
export class FolderService {
  private static readonly AUTHORIZE_CAPABILITY: string =
    'SystemCapability.FileManagement.AppFileService.FolderAuthorization';
  static readonly PICKER_CAPABILITY: string =
    'SystemCapability.FileManagement.UserFileService.FolderSelection';

  static canPickFolder(): boolean {
    try {
      return canIUse(FolderService.PICKER_CAPABILITY);
    } catch (error) {
      return false;
    }
  }

  static folderName(uri: string): string {
    if (uri.length === 0) {
      return '';
    }
    try {
      const name = new fileUri.FileUri(uri).name;
      if (name.length > 0) {
        try {
          return decodeURIComponent(name);
        } catch (error) {
          return name;
        }
      }
    } catch (error) {
    }
    return '本地文件夹';
  }

  /** Keeps the picker grant across app restarts when the device allows it. */
  static async persist(uri: string): Promise<boolean> {
    if (uri.length === 0 || !FolderService.canAuthorize()) {
      return false;
    }
    try {
      const policy: fileShare.PolicyInfo = {
        uri: uri,
        operationMode: fileShare.OperationMode.READ_MODE
      };
      await fileShare.persistPermission([policy]);
      return true;
    } catch (error) {
      return false;
    }
  }

  /** Re-enables a permission stored in a previous session. */
  static async activate(uri: string): Promise<boolean> {
    if (uri.length === 0 || !FolderService.canAuthorize()) {
      return false;
    }
    try {
      const policy: fileShare.PolicyInfo = {
        uri: uri,
        operationMode: fileShare.OperationMode.READ_MODE
      };
      await fileShare.activatePermission([policy]);
      return true;
    } catch (error) {
      return false;
    }
  }

  private static canAuthorize(): boolean {
    try {
      return canIUse(FolderService.AUTHORIZE_CAPABILITY);
    } catch (error) {
      return false;
    }
  }

  static async scanAsync(uri: string): Promise<FolderScanResult> {
    const result = new FolderScanResult();
    if (uri.length === 0) {
      result.error = '还没有关联文件夹';
      return result;
    }
    let path = '';
    try {
      path = new fileUri.FileUri(uri).path;
    } catch (error) {
      path = '';
    }
    let names: string[] = [];
    let base = '';
    let listError = false;
    try {
      names = await fs.listFile(uri, { recursion: true });
      base = uri;
    } catch (error) {
      listError = true;
    }
    if (listError && path.length > 0 && path !== uri) {
      try {
        names = await fs.listFile(path, { recursion: true });
        base = path;
        listError = false;
      } catch (error) {
        listError = true;
      }
    }
    if (base.length === 0) {
      result.error = '无法读取文件夹，请重新选择';
      return result;
    }
    for (let i = 0; i < names.length; i++) {
      let relative = names[i];
      while (relative.startsWith('/')) {
        relative = relative.substring(1);
      }
      if (relative.length === 0) {
        continue;
      }
      const extension = relative.lastIndexOf('.') > 0
        ? relative.substring(relative.lastIndexOf('.') + 1)
        : '';
      if (!BookFormats.isSupported(extension)) {
        result.skipped += 1;
        continue;
      }
      const candidate = base + '/' + relative;
      if (FolderService.readable(candidate)) {
        result.files.push(candidate);
        continue;
      }
      if (path.length > 0 && base !== path) {
        const fallback = path + '/' + relative;
        if (FolderService.readable(fallback)) {
          result.files.push(fallback);
          continue;
        }
      }
      result.skipped += 1;
    }
    if (result.files.length === 0 && result.skipped === 0 && listError) {
      result.error = '无法读取文件夹，请重新选择';
    }
    return result;
  }

  private static readable(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (error) {
      return false;
    }
  }
}