import { util } from '@kit.ArkTS';
import { TextCodec } from '../parser/Bytes';

export class TextSupport {
  /**
   * GBK/GB18030 decoding is the only text feature that needs the platform
   * codec; everything else is handled by the pure TypeScript decoder.
   */
  static install(): void {
    TextCodec.externalDecoder = (bytes: Uint8Array, encoding: string): string => {
      try {
        const decoder = new util.TextDecoder(encoding, { ignoreBOM: true });
        return decoder.decodeWithStream(bytes);
      } catch (error) {
        return TextCodec.decodeUtf8(bytes);
      }
    };
  }
}
