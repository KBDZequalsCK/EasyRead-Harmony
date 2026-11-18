import { ReaderSettings, SyncConfig, SyncNamespace } from '../model/LibraryModels';
import { JsonCodec, JsonNode } from '../parser/ZenJson';
import { AppPaths, FileService } from './FileService';
import { util } from '@kit.ArkTS';

export class SettingsStore {
  /** Bump this when the in-app privacy policy changes materially. */
  static readonly PRIVACY_VERSION: number = 3;

  private static instance: SettingsStore | null = null;
  reader: ReaderSettings = new ReaderSettings();
  sync: SyncConfig = new SyncConfig();
  privacyAcceptedVersion: number = 0;

  static shared(): SettingsStore {
    if (SettingsStore.instance === null) {
      SettingsStore.instance = new SettingsStore();
    }
    return SettingsStore.instance;
  }

  /** Reads only the consent marker; no book, account or settings data. */
  loadPrivacy(): void {
    this.privacyAcceptedVersion = 0;
    if (!FileService.exists(AppPaths.privacyFile())) {
      return;
    }
    try {
      const root = JsonCodec.parse(FileService.readText(AppPaths.privacyFile()));
      this.privacyAcceptedVersion = SettingsStore.number(root, 'version', 0);
    } catch (error) {
      // A damaged consent file shows the policy again instead of skipping it.
    }
  }

  acceptPrivacy(): void {
    this.privacyAcceptedVersion = SettingsStore.PRIVACY_VERSION;
    const root = JsonNode.object();
    root.set('version', JsonNode.number(this.privacyAcceptedVersion));
    root.set('acceptedAt', JsonNode.number(Date.now()));
    FileService.writeTextAtomic(AppPaths.privacyFile(), JsonCodec.stringify(root, false, true, false));
  }

  load(): void {
    this.reader = new ReaderSettings();
    this.sync = new SyncConfig();
    if (FileService.exists(AppPaths.settingsFile())) {
      try {
        const root = JsonCodec.parse(FileService.readText(AppPaths.settingsFile()));
        this.reader.fontSize = SettingsStore.number(root, 'fontSize', this.reader.fontSize);
        this.reader.lineHeight = SettingsStore.number(root, 'lineHeight', this.reader.lineHeight);
        this.reader.margin = SettingsStore.number(root, 'margin', this.reader.margin);
        this.reader.theme = SettingsStore.string(root, 'theme', this.reader.theme);
        this.reader.pageMode = SettingsStore.string(root, 'pageMode', this.reader.pageMode);
        this.reader.columns = SettingsStore.string(root, 'columns', this.reader.columns);
        this.reader.publisherStyles = SettingsStore.bool(root, 'publisherStyles', false);
        this.reader.fontFamily = SettingsStore.string(root, 'fontFamily', this.reader.fontFamily);
        this.reader.showProgress = SettingsStore.bool(root, 'showProgress', true);
        this.reader.shelfLayout = SettingsStore.string(root, 'shelfLayout', this.reader.shelfLayout);
        this.reader.shelfVisible = SettingsStore.bool(root, 'shelfVisible', this.reader.shelfVisible);
      } catch (error) {
        // Keep defaults when the settings file is damaged.
      }
    }
    if (FileService.exists(AppPaths.syncFile())) {
      try {
        const root = JsonCodec.parse(FileService.readText(AppPaths.syncFile()));
        this.sync.provider = SettingsStore.string(root, 'provider', this.sync.provider);
        this.sync.server = SettingsStore.string(root, 'server', this.sync.server);
        this.sync.username = SettingsStore.string(root, 'username', '');
        this.sync.autoSync = SettingsStore.bool(root, 'autoSync', true);
        this.sync.lastSyncAt = SettingsStore.number(root, 'lastSyncAt', 0);
        this.sync.deviceId = SettingsStore.string(root, 'deviceId', '');
        const encoded = SettingsStore.string(root, 'password', '');
        if (encoded.length > 0) {
          this.sync.password = SettingsStore.decodePassword(encoded);
        }
        this.sync.remoteFolder = SettingsStore.migrateNamespace(
          SettingsStore.string(root, 'namespace', ''), this.sync.server,
          this.sync.username.trim().length > 0 || this.sync.password.length > 0 ||
            this.sync.lastSyncAt > 0
        );
      } catch (error) {
        // Keep defaults when the sync file is damaged.
      }
    }
  }

  /**
   * Before the folder choice existed every configuration wrote to
   * ZenReader/v1. Preserve that for existing WebDAV accounts so their cloud
   * books do not appear to vanish; new or empty configurations start in the
   * app's own EasyRead folder.
   */
  private static migrateNamespace(saved: string, server: string, configured: boolean): string {
    const value = saved.trim().toLowerCase();
    if (value === SyncNamespace.EASYREAD || value === SyncNamespace.ZENREADER) {
      return value;
    }
    const lowerServer = server.toLowerCase();
    if (lowerServer.indexOf('/zenreader/v1') >= 0 || lowerServer.endsWith('/zenreader')) {
      return SyncNamespace.ZENREADER;
    }
    if (lowerServer.indexOf('/easyread/v1') >= 0 || lowerServer.endsWith('/easyread')) {
      return SyncNamespace.EASYREAD;
    }
    return configured ? SyncNamespace.ZENREADER : SyncNamespace.EASYREAD;
  }

  private static string(node: JsonNode, key: string, fallback: string): string {
    const value = node.get(key);
    return value !== null ? value.asString(fallback) : fallback;
  }

  private static number(node: JsonNode, key: string, fallback: number): number {
    const value = node.get(key);
    return value !== null ? value.asNumber(fallback) : fallback;
  }

  private static bool(node: JsonNode, key: string, fallback: boolean): boolean {
    const value = node.get(key);
    return value !== null ? value.asBool(fallback) : fallback;
  }

  saveReader(): void {
    const root = JsonNode.object();
    root.set('fontSize', JsonNode.number(this.reader.fontSize));
    root.set('lineHeight', JsonNode.number(this.reader.lineHeight));
    root.set('margin', JsonNode.number(this.reader.margin));
    root.set('theme', JsonNode.string(this.reader.theme));
    root.set('pageMode', JsonNode.string(this.reader.pageMode));
    root.set('columns', JsonNode.string(this.reader.columns));
    root.set('publisherStyles', JsonNode.bool(this.reader.publisherStyles));
    root.set('fontFamily', JsonNode.string(this.reader.fontFamily));
    root.set('showProgress', JsonNode.bool(this.reader.showProgress));
    root.set('shelfLayout', JsonNode.string(this.reader.shelfLayout));
    root.set('shelfVisible', JsonNode.bool(this.reader.shelfVisible));
    FileService.writeTextAtomic(AppPaths.settingsFile(), JsonCodec.stringify(root, false, true, false));
  }

  saveSync(): void {
    const root = JsonNode.object();
    root.set('provider', JsonNode.string(this.sync.provider));
    root.set('server', JsonNode.string(this.sync.server));
    root.set('username', JsonNode.string(this.sync.username));
    root.set('password', JsonNode.string(SettingsStore.encodePassword(this.sync.password)));
    root.set('autoSync', JsonNode.bool(this.sync.autoSync));
    root.set('lastSyncAt', JsonNode.number(this.sync.lastSyncAt));
    root.set('deviceId', JsonNode.string(this.sync.deviceId));
    root.set('namespace', JsonNode.string(this.sync.remoteFolder));
    FileService.writeTextAtomic(AppPaths.syncFile(), JsonCodec.stringify(root, false, true, false));
  }

  /**
   * A Jianguoyun app password is revocable and only grants WebDAV access to
   * its own folder; it is obfuscated here, not treated as a system secret.
   */
  private static encodePassword(value: string): string {
    const helper = new util.Base64Helper();
    return helper.encodeToStringSync(new util.TextEncoder().encodeInto(value));
  }

  private static decodePassword(value: string): string {
    try {
      const helper = new util.Base64Helper();
      return new util.TextDecoder('utf-8').decodeWithStream(helper.decodeSync(value));
    } catch (error) {
      return '';
    }
  }
}
