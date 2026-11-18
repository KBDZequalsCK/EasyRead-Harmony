import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

export class HashService {
  static async sha256(bytes: Uint8Array): Promise<string> {
    const md = cryptoFramework.createMd('SHA256');
    const chunkSize = 1024 * 1024;
    let offset = 0;
    while (offset < bytes.length) {
      const end = Math.min(bytes.length, offset + chunkSize);
      const blob: cryptoFramework.DataBlob = { data: bytes.subarray(offset, end) };
      await md.update(blob);
      offset = end;
    }
    if (bytes.length === 0) {
      const empty: cryptoFramework.DataBlob = { data: new Uint8Array(0) };
      await md.update(empty);
    }
    const digest = await md.digest();
    return HashService.toHex(digest.data);
  }

  static async sha256Text(text: string): Promise<string> {
    return HashService.sha256(new util.TextEncoder().encodeInto(text));
  }

  static toHex(bytes: Uint8Array): string {
    let result = '';
    for (let i = 0; i < bytes.length; i++) {
      const value = bytes[i].toString(16);
      result += value.length === 1 ? '0' + value : value;
    }
    return result;
  }

  static base64Utf8(text: string): string {
    const encoder = new util.TextEncoder();
    const helper = new util.Base64Helper();
    return helper.encodeToStringSync(encoder.encodeInto(text));
  }

  static utf8(text: string): Uint8Array {
    return new util.TextEncoder().encodeInto(text);
  }

  static utf8Length(text: string): number {
    return new util.TextEncoder().encodeInto(text).length;
  }
}
