import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import BuildProfile from 'entry/BuildProfile';
import { JsonCodec, JsonNode } from '../parser/ZenJson';
import { AppPaths, FileService } from './FileService';

/**
 * Offline WebDAV unlock with 爱发电 license codes.
 *
 * The code is an Ed25519-signed payload in the same format as the macOS
 * EasyRead app (ERPRO1 prefix, easyread.pro.webdav product). Verification
 * happens entirely on the device with the public key embedded below; there
 * is no license server and no account. The private key is kept outside every
 * repository (default: ~/.easyread-license/private.key).
 */
export class LicenseService {
  static readonly PRODUCT_ID: string = 'easyread.pro.webdav';
  static readonly PRODUCT_NAME: string = 'EasyRead WebDAV 书库永久解锁';
  static readonly PRICE_DISPLAY: string = '¥8';
  static readonly PRICE_TEXT: string = '¥8.00';
  static readonly PURCHASE_URL: string = 'https://ifdian.net/item/433d9ac0e31111f181f552540025c377';
  static readonly SUPPORT_URL: string = 'https://ifdian.net/a/easyread';
  static readonly SOURCE_LICENSE: string = 'license';
  static readonly SOURCE_DEBUG: string = 'debug';

  private static readonly LICENSE_PREFIX: string = 'ERPRO1';
  /** Raw 32-byte Ed25519 public key, matching the macOS app. */
  private static readonly PUBLIC_KEY_BASE64: string = 'dLfepSvGfcOIPUuBiTjaoWeCcEl4kFCjYh13zZBFWbQ=';
  /**
   * X.509 SubjectPublicKeyInfo prefix for Ed25519:
   * 30 2a 30 05 06 03 2b 65 70 03 21 00. cryptoFramework's convertKeySync
   * expects standard DER key material for Ed25519.
   */
  private static readonly SPKI_PREFIX_HEX: string = '302a300506032b6570032100';

  private static instance: LicenseService | null = null;

  private unlocked: boolean = false;
  private code: string = '';
  private licenseId: string = '';
  private orderId: string = '';
  private issuedAt: number = 0;
  private expiresAt: number = 0;
  private activatedAt: number = 0;
  private deviceBinding: string = '';
  private source: string = '';
  private didRemoveMismatchedLicense: boolean = false;

  static shared(): LicenseService {
    if (LicenseService.instance === null) {
      LicenseService.instance = new LicenseService();
    }
    return LicenseService.instance;
  }

  isUnlocked(): boolean {
    return this.unlocked;
  }

  priceText(): string {
    return LicenseService.PRICE_TEXT;
  }

  /** Short uppercase license ID for the unlock panel, or '' when unlicensed. */
  licenseIDDescription(): string {
    if (this.licenseId.length === 0) {
      return '';
    }
    return this.licenseId.substring(0, 8).toUpperCase();
  }

  orderText(): string {
    return this.orderId;
  }

  /** True when the active license was bound to an ODID. */
  isDeviceBound(): boolean {
    return this.deviceBinding.length > 0;
  }

  isDebugBuild(): boolean {
    // Compile-time flag: a release build never exposes the simulation.
    return BuildProfile.DEBUG;
  }

  /** True when this device can be identified for local binding. */
  canBindDevice(): boolean {
    return this.currentDeviceBinding().length > 0;
  }

  removedMismatchedLicense(): boolean {
    return this.didRemoveMismatchedLicense;
  }

  /**
   * Loads the cached license and re-verifies its signature. The raw code is
   * kept so the entitlement can be checked offline forever, but a code bound
   * to a different device is removed here.
   */
  loadLocal(): void {
    this.resetInMemory();
    this.didRemoveMismatchedLicense = false;
    if (!FileService.exists(AppPaths.licenseFile())) {
      return;
    }
    try {
      const root = JsonCodec.parse(FileService.readText(AppPaths.licenseFile()));
      const source = LicenseService.string(root, 'source', '');
      if (source === LicenseService.SOURCE_DEBUG && !this.isDebugBuild()) {
        this.clearStoredLicense();
        return;
      }
      if (source === LicenseService.SOURCE_DEBUG) {
        this.unlocked = true;
        this.source = source;
        this.activatedAt = LicenseService.number(root, 'activatedAt', 0);
        return;
      }
      const storedCode = LicenseService.string(root, 'code', '');
      if (storedCode.length === 0) {
        this.clearStoredLicense();
        return;
      }
      const result = LicenseService.verify(storedCode);
      if (!result.ok || result.info === null) {
        this.clearStoredLicense();
        return;
      }
      const storedBinding = LicenseService.string(root, 'deviceBinding', '');
      const currentBinding = this.currentDeviceBinding();
      if (storedBinding.length > 0 && currentBinding.length > 0 &&
        storedBinding !== currentBinding) {
        // The cached entitlement was activated on another device (or this
        // device identity changed). Do not keep it; the user can activate
        // the code here again.
        this.didRemoveMismatchedLicense = true;
        this.clearStoredLicense();
        return;
      }
      this.applyInfo(result.info, storedCode);
      this.activatedAt = LicenseService.number(root, 'activatedAt', Date.now());
      this.deviceBinding = storedBinding;
      if (this.deviceBinding.length === 0 && currentBinding.length > 0) {
        this.deviceBinding = currentBinding;
        this.save();
      }
    } catch (error) {
      this.clearStoredLicense();
    }
  }

  /**
   * Verifies and activates a code. Returns an empty string on success and a
   * user-facing message on failure. A valid code binds to this device when
   * an ODID is available; without one, activation still succeeds.
   */
  activate(code: string): string {
    const normalized = LicenseService.normalize(code);
    if (normalized.length === 0) {
      return '请先粘贴授权码。';
    }
    const result = LicenseService.verify(normalized);
    if (!result.ok || result.info === null) {
      return result.error;
    }
    this.unlocked = true;
    this.source = LicenseService.SOURCE_LICENSE;
    this.activatedAt = Date.now();
    this.didRemoveMismatchedLicense = false;
    this.applyInfo(result.info, normalized);
    this.deviceBinding = this.currentDeviceBinding();
    this.save();
    return '';
  }

  /** Debug-package helper so the locked UI can be exercised without a code. */
  debugUnlock(): void {
    if (!this.isDebugBuild()) {
      return;
    }
    this.unlocked = true;
    this.source = LicenseService.SOURCE_DEBUG;
    this.licenseId = 'DEBUG-' + Date.now();
    this.orderId = 'DEBUG';
    this.issuedAt = Date.now();
    this.expiresAt = 0;
    this.activatedAt = Date.now();
    this.deviceBinding = this.currentDeviceBinding();
    this.didRemoveMismatchedLicense = false;
    this.save();
  }

  /** Removes the local cache. Only exposed in debug builds. */
  debugReset(): void {
    if (!this.isDebugBuild()) {
      return;
    }
    this.resetInMemory();
    this.clearStoredLicense();
  }

  /**
   * Verifies an ERPRO1 code against the embedded key. The payload inside the
   * code is signed as raw bytes; it is not re-serialized before checking.
   */
  static verify(code: string): LicenseCheck {
    const normalized = LicenseService.normalize(code);
    const parts = normalized.split('.');
    if (parts.length !== 3 || parts[0] !== LicenseService.LICENSE_PREFIX) {
      return LicenseCheck.failure('授权码格式不正确，请完整粘贴以 ERPRO1. 开头的授权码。');
    }
    let payloadBytes: Uint8Array;
    let signatureBytes: Uint8Array;
    try {
      payloadBytes = LicenseService.base64UrlDecode(parts[1]);
      signatureBytes = LicenseService.base64UrlDecode(parts[2]);
    } catch (error) {
      return LicenseCheck.failure('授权码格式不正确，请完整粘贴以 ERPRO1. 开头的授权码。');
    }
    if (payloadBytes.length === 0 || signatureBytes.length !== 64) {
      return LicenseCheck.failure('授权码格式不正确，请完整粘贴以 ERPRO1. 开头的授权码。');
    }
    try {
      const generator = cryptoFramework.createAsyKeyGenerator('Ed25519');
      const keyPair = generator.convertKeySync(LicenseService.publicKeyBlob(), null);
      const verifier = cryptoFramework.createVerify('Ed25519');
      verifier.initSync(keyPair.pubKey);
      const valid = verifier.verifySync({ data: payloadBytes }, { data: signatureBytes });
      if (!valid) {
        return LicenseCheck.failure('授权码无效或已被修改。');
      }
    } catch (error) {
      return LicenseCheck.failure('无法校验授权码，请确认应用安装完整后重试。');
    }
    let info: LicenseInfo | null = null;
    try {
      const text = new util.TextDecoder('utf-8').decodeWithStream(payloadBytes);
      info = LicenseService.parsePayload(text ? text : '');
    } catch (error) {
      return LicenseCheck.failure('这个授权码不适用于当前版本。');
    }
    if (info === null) {
      return LicenseCheck.failure('这个授权码不适用于当前版本。');
    }
    if (info.expiresAt > 0 && info.expiresAt < Date.now()) {
      return LicenseCheck.failure('授权码已过期。');
    }
    return LicenseCheck.success(info);
  }

  private static parsePayload(text: string): LicenseInfo | null {
    try {
      const root = JsonCodec.parse(text);
      const version = LicenseService.number(root, 'v', 0);
      const product = LicenseService.string(root, 'product', '');
      const kind = LicenseService.string(root, 'kind', '');
      const licenseId = LicenseService.string(root, 'licenseId', '');
      if (version !== 1 || product !== LicenseService.PRODUCT_ID ||
        kind !== 'lifetime' || licenseId.length === 0) {
        return null;
      }
      const info = new LicenseInfo();
      info.licenseId = licenseId;
      info.issuedAt = LicenseService.number(root, 'issuedAt', 0);
      info.orderId = LicenseService.string(root, 'orderId', '');
      info.expiresAt = LicenseService.number(root, 'expiresAt', 0);
      return info;
    } catch (error) {
      return null;
    }
  }

  private static publicKeyBlob(): cryptoFramework.DataBlob {
    const raw = new util.Base64Helper().decodeSync(LicenseService.PUBLIC_KEY_BASE64);
    const prefix = LicenseService.hexBytes(LicenseService.SPKI_PREFIX_HEX);
    const spki = new Uint8Array(prefix.length + raw.length);
    spki.set(prefix, 0);
    spki.set(raw, prefix.length);
    return { data: spki };
  }

  /**
   * A stable, non-reversible identifier for this device. ODID is scoped to
   * the signing developer and requires no permission; only its SHA-256 hash
   * is stored. Returns '' when the platform does not expose an ODID.
   */
  private currentDeviceBinding(): string {
    try {
      const odid = deviceInfo.ODID;
      if (odid === undefined || odid === null || odid.length === 0 ||
        odid === '00000000-0000-0000-0000-000000000000') {
        return '';
      }
      const md = cryptoFramework.createMd('SHA256');
      const encoder = new util.TextEncoder();
      md.updateSync({ data: encoder.encodeInto('easyread.pro.webdav|' + odid) });
      const digest = md.digestSync().data;
      return LicenseService.hexString(digest);
    } catch (error) {
      return '';
    }
  }

  private applyInfo(info: LicenseInfo, code: string): void {
    this.code = code;
    this.licenseId = info.licenseId;
    this.orderId = info.orderId;
    this.issuedAt = info.issuedAt;
    this.expiresAt = info.expiresAt;
    this.unlocked = true;
  }

  private save(): void {
    const root = JsonNode.object();
    root.set('version', JsonNode.number(1));
    root.set('source', JsonNode.string(this.source));
    root.set('code', JsonNode.string(this.code));
    root.set('licenseId', JsonNode.string(this.licenseId));
    root.set('orderId', JsonNode.string(this.orderId));
    root.set('issuedAt', JsonNode.number(this.issuedAt));
    root.set('expiresAt', JsonNode.number(this.expiresAt));
    root.set('activatedAt', JsonNode.number(this.activatedAt));
    root.set('deviceBinding', JsonNode.string(this.deviceBinding));
    FileService.writeTextAtomic(AppPaths.licenseFile(), JsonCodec.stringify(root, false, true, false));
  }

  private clearStoredLicense(): void {
    this.resetInMemory();
    FileService.delete(AppPaths.licenseFile());
  }

  private resetInMemory(): void {
    this.unlocked = false;
    this.code = '';
    this.licenseId = '';
    this.orderId = '';
    this.issuedAt = 0;
    this.expiresAt = 0;
    this.activatedAt = 0;
    this.deviceBinding = '';
    this.source = '';
  }

  private static normalize(code: string): string {
    return code.replace(/\s+/g, '');
  }

  private static base64UrlDecode(value: string): Uint8Array {
    let normalized = value.replace(/-/g, '+').replace(/_/g, '/');
    while (normalized.length % 4 !== 0) {
      normalized += '=';
    }
    return new util.Base64Helper().decodeSync(normalized, util.Type.BASIC);
  }

  private static hexBytes(hex: string): Uint8Array {
    const bytes = new Uint8Array(hex.length / 2);
    for (let i = 0; i < bytes.length; i++) {
      bytes[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
    }
    return bytes;
  }

  private static hexString(bytes: Uint8Array): string {
    const digits = '0123456789abcdef';
    let text = '';
    for (let i = 0; i < bytes.length; i++) {
      text += digits.charAt(bytes[i] >> 4);
      text += digits.charAt(bytes[i] & 15);
    }
    return text;
  }

  private static string(node: JsonNode, key: string, fallback: string): string {
    const value = node.get(key);
    return value !== null ? value.asString(fallback) : fallback;
  }

  private static number(node: JsonNode, key: string, fallback: number): number {
    const value = node.get(key);
    return value !== null ? value.asNumber(fallback) : fallback;
  }
}

export class LicenseInfo {
  licenseId: string = '';
  orderId: string = '';
  issuedAt: number = 0;
  expiresAt: number = 0;
}

export class LicenseCheck {
  ok: boolean = false;
  error: string = '';
  info: LicenseInfo | null = null;

  static success(info: LicenseInfo): LicenseCheck {
    const result = new LicenseCheck();
    result.ok = true;
    result.info = info;
    return result;
  }

  static failure(error: string): LicenseCheck {
    const result = new LicenseCheck();
    result.ok = false;
    result.error = error;
    return result;
  }
}
