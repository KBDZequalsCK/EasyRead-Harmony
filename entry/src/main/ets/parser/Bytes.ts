/**
 * Byte-level helpers shared by every format parser.
 * Pure TypeScript so the same code runs in ArkTS and in the Node test harness.
 */
export class Bytes {
  static readU16LE(data: Uint8Array, offset: number): number {
    return data[offset] | (data[offset + 1] << 8);
  }

  static readU16BE(data: Uint8Array, offset: number): number {
    return (data[offset] << 8) | data[offset + 1];
  }

  static readU24LE(data: Uint8Array, offset: number): number {
    return data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16);
  }

  static readU32LE(data: Uint8Array, offset: number): number {
    return (data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | (data[offset + 3] << 24)) >>> 0;
  }

  static readU32BE(data: Uint8Array, offset: number): number {
    return ((data[offset] << 24) | (data[offset + 1] << 16) | (data[offset + 2] << 8) | data[offset + 3]) >>> 0;
  }

  static readI32LE(data: Uint8Array, offset: number): number {
    return data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | (data[offset + 3] << 24);
  }

  static readI64LE(data: Uint8Array, offset: number): number {
    const low = Bytes.readU32LE(data, offset);
    const high = Bytes.readI32LE(data, offset + 4);
    return high * 4294967296 + low;
  }

  static indexOf(data: Uint8Array, signature: number[], from: number, to: number): number {
    const n = signature.length;
    const limit = Math.min(to, data.length) - n;
    for (let i = Math.max(0, from); i <= limit; i++) {
      let match = true;
      for (let j = 0; j < n; j++) {
        if (data[i + j] !== signature[j]) {
          match = false;
          break;
        }
      }
      if (match) {
        return i;
      }
    }
    return -1;
  }

  static concat(parts: Uint8Array[]): Uint8Array {
    let total = 0;
    for (let i = 0; i < parts.length; i++) {
      total += parts[i].length;
    }
    const out = new Uint8Array(total);
    let cursor = 0;
    for (let i = 0; i < parts.length; i++) {
      out.set(parts[i], cursor);
      cursor += parts[i].length;
    }
    return out;
  }

  static slice(data: Uint8Array, start: number, end: number): Uint8Array {
    return data.subarray(start, end);
  }

  static ascii(data: Uint8Array, start: number, length: number): string {
    let text = '';
    const end = Math.min(data.length, start + length);
    for (let i = start; i < end; i++) {
      text += String.fromCharCode(data[i]);
    }
    return text;
  }
}

/**
 * A small, dependency-free UTF-8 / UTF-16 decoder. ArkTS does provide
 * util.TextDecoder, but keeping the fallback here means the parsers stay
 * testable in Node and never depend on platform text APIs for the common case.
 */
export class TextCodec {
  static externalDecoder: ((bytes: Uint8Array, encoding: string) => string) | null = null;

  static decodeUtf8(data: Uint8Array): string {
    const result: string[] = [];
    let i = 0;
    while (i < data.length) {
      const b0 = data[i];
      if (b0 < 0x80) {
        result.push(String.fromCharCode(b0));
        i += 1;
        continue;
      }
      let code = 0xFFFD;
      let step = 1;
      if ((b0 & 0xE0) === 0xC0) {
        if (i + 1 < data.length) {
          code = ((b0 & 0x1F) << 6) | (data[i + 1] & 0x3F);
          step = 2;
        }
      } else if ((b0 & 0xF0) === 0xE0) {
        if (i + 2 < data.length) {
          code = ((b0 & 0x0F) << 12) | ((data[i + 1] & 0x3F) << 6) | (data[i + 2] & 0x3F);
          step = 3;
        }
      } else if ((b0 & 0xF8) === 0xF0) {
        if (i + 3 < data.length) {
          code = ((b0 & 0x07) << 18) | ((data[i + 1] & 0x3F) << 12) |
            ((data[i + 2] & 0x3F) << 6) | (data[i + 3] & 0x3F);
          step = 4;
        }
      }
      if (code > 0x10FFFF) {
        code = 0xFFFD;
      }
      result.push(String.fromCodePoint(code));
      i += step;
    }
    return result.join('');
  }

  static decodeUtf16(data: Uint8Array, littleEndian: boolean): string {
    const result: string[] = [];
    for (let i = 0; i + 1 < data.length; i += 2) {
      const value = littleEndian
        ? (data[i] | (data[i + 1] << 8))
        : ((data[i] << 8) | data[i + 1]);
      result.push(String.fromCharCode(value));
    }
    return result.join('');
  }

  static decodeLatin1(data: Uint8Array): string {
    const result: string[] = [];
    const chunk = 8192;
    for (let start = 0; start < data.length; start += chunk) {
      const end = Math.min(data.length, start + chunk);
      let text = '';
      for (let i = start; i < end; i++) {
        text += String.fromCharCode(data[i]);
      }
      result.push(text);
    }
    return result.join('');
  }

  /**
   * Decodes text with BOM detection. `encodingHint` is only consulted when the
   * bytes carry no BOM. GBK/GB18030 goes through the injected platform decoder.
   */
  static decode(data: Uint8Array, encodingHint: string = ''): string {
    if (data.length >= 3 && data[0] === 0xEF && data[1] === 0xBB && data[2] === 0xBF) {
      return TextCodec.decodeUtf8(data.subarray(3));
    }
    if (data.length >= 2 && data[0] === 0xFF && data[1] === 0xFE) {
      return TextCodec.decodeUtf16(data.subarray(2), true);
    }
    if (data.length >= 2 && data[0] === 0xFE && data[1] === 0xFF) {
      return TextCodec.decodeUtf16(data.subarray(2), false);
    }
    const normalized = encodingHint.trim().toLowerCase();
    if (normalized === 'utf-16le') {
      return TextCodec.decodeUtf16(data, true);
    }
    if (normalized === 'utf-16be') {
      return TextCodec.decodeUtf16(data, false);
    }
    if (normalized === 'gbk' || normalized === 'gb18030' || normalized === 'gb2312') {
      if (TextCodec.externalDecoder !== null) {
        return TextCodec.externalDecoder(data, normalized);
      }
      return TextCodec.decodeUtf8(data);
    }
    if (normalized === 'iso-8859-1' || normalized === 'latin1' || normalized === 'windows-1252') {
      return TextCodec.decodeLatin1(data);
    }
    return TextCodec.decodeUtf8(data);
  }

  /** A generous UTF-8 validity probe used to choose a fallback for TXT files. */
  static looksLikeUtf8(data: Uint8Array): boolean {
    let i = 0;
    let suspicious = 0;
    let multibyte = 0;
    while (i < data.length) {
      const b = data[i];
      if (b < 0x80) {
        i += 1;
        continue;
      }
      let need = 0;
      if ((b & 0xE0) === 0xC0) {
        need = 1;
      } else if ((b & 0xF0) === 0xE0) {
        need = 2;
      } else if ((b & 0xF8) === 0xF0) {
        need = 3;
      } else {
        return false;
      }
      if (i + need >= data.length) {
        return false;
      }
      for (let j = 1; j <= need; j++) {
        if ((data[i + j] & 0xC0) !== 0x80) {
          suspicious += 1;
          break;
        }
      }
      multibyte += 1;
      i += need + 1;
    }
    return suspicious * 20 < multibyte + 1;
  }
}

/** Growable byte buffer used by the inflater and by image extraction. */
export class ByteBuffer {
  private data: Uint8Array;
  private length: number = 0;

  constructor(capacity: number = 65536) {
    this.data = new Uint8Array(Math.max(16, capacity));
  }

  private ensure(extra: number): void {
    const needed = this.length + extra;
    if (needed <= this.data.length) {
      return;
    }
    let capacity = this.data.length;
    while (capacity < needed) {
      capacity *= 2;
    }
    const next = new Uint8Array(capacity);
    next.set(this.data.subarray(0, this.length));
    this.data = next;
  }

  push(value: number): void {
    this.ensure(1);
    this.data[this.length] = value;
    this.length += 1;
  }

  pushBytes(bytes: Uint8Array): void {
    this.ensure(bytes.length);
    this.data.set(bytes, this.length);
    this.length += bytes.length;
  }

  byteAtFromEnd(distance: number): number {
    return this.data[this.length - distance];
  }

  get size(): number {
    return this.length;
  }

  toUint8Array(): Uint8Array {
    return this.data.slice(0, this.length);
  }
}
