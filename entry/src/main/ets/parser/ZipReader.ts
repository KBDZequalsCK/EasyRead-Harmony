import { Bytes, TextCodec } from './Bytes';
import { inflateRaw } from './Inflate';

export class ZipEntry {
  name: string = '';
  method: number = 0;
  flags: number = 0;
  compressedSize: number = 0;
  uncompressedSize: number = 0;
  localHeaderOffset: number = 0;
  isDirectory: boolean = false;
}

/**
 * In-process ZIP reader for EPUB, DOCX and CBZ. It reads the central
 * directory once and inflates entries on demand, so a 300 MB comic costs a few
 * milliseconds to open instead of extracting every page to disk.
 */
export class ZipArchive {
  private data: Uint8Array;
  readonly entries: ZipEntry[] = [];
  private byName: Map<string, ZipEntry> = new Map<string, ZipEntry>();

  private constructor(data: Uint8Array) {
    this.data = data;
  }

  static open(data: Uint8Array): ZipArchive {
    const archive = new ZipArchive(data);
    archive.readCentralDirectory();
    return archive;
  }

  private readCentralDirectory(): void {
    const eocdSignature = [0x50, 0x4B, 0x05, 0x06];
    const minimum = Math.max(0, this.data.length - 66000);
    let eocd = -1;
    for (let i = this.data.length - 22; i >= minimum; i--) {
      if (this.data[i] === 0x50 && this.data[i + 1] === 0x4B &&
        this.data[i + 2] === 0x05 && this.data[i + 3] === 0x06) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) {
      throw new Error('不是有效的 ZIP 文件');
    }
    let count = Bytes.readU16LE(this.data, eocd + 10);
    let directorySize = Bytes.readU32LE(this.data, eocd + 12);
    let directoryOffset = Bytes.readU32LE(this.data, eocd + 16);

    if (count === 0xFFFF || directorySize === 0xFFFFFFFF || directoryOffset === 0xFFFFFFFF) {
      const locator = eocd - 20;
      if (locator >= 0 && Bytes.readU32LE(this.data, locator) === 0x07064B50) {
        const zip64Offset = Bytes.readI64LE(this.data, locator + 8);
        if (zip64Offset >= 0 && zip64Offset + 56 <= this.data.length &&
          Bytes.readU32LE(this.data, zip64Offset) === 0x06064B50) {
          count = Bytes.readI64LE(this.data, zip64Offset + 32);
          directorySize = Bytes.readI64LE(this.data, zip64Offset + 40);
          directoryOffset = Bytes.readI64LE(this.data, zip64Offset + 48);
        }
      }
    }

    let cursor = directoryOffset;
    for (let index = 0; index < count; index++) {
      if (cursor + 46 > this.data.length) {
        break;
      }
      if (Bytes.readU32LE(this.data, cursor) !== 0x02014B50) {
        break;
      }
      const entry = new ZipEntry();
      entry.flags = Bytes.readU16LE(this.data, cursor + 8);
      entry.method = Bytes.readU16LE(this.data, cursor + 10);
      entry.compressedSize = Bytes.readU32LE(this.data, cursor + 20);
      entry.uncompressedSize = Bytes.readU32LE(this.data, cursor + 24);
      const nameLength = Bytes.readU16LE(this.data, cursor + 28);
      const extraLength = Bytes.readU16LE(this.data, cursor + 30);
      const commentLength = Bytes.readU16LE(this.data, cursor + 32);
      entry.localHeaderOffset = Bytes.readU32LE(this.data, cursor + 42);

      const nameBytes = this.data.subarray(cursor + 46, cursor + 46 + nameLength);
      entry.name = ZipArchive.decodeName(nameBytes);

      if (entry.compressedSize === 0xFFFFFFFF || entry.uncompressedSize === 0xFFFFFFFF ||
        entry.localHeaderOffset === 0xFFFFFFFF) {
        this.applyZip64Extra(entry, cursor + 46 + nameLength, extraLength);
      }
      entry.isDirectory = entry.name.endsWith('/');
      this.entries.push(entry);
      if (!entry.isDirectory) {
        this.byName.set(entry.name, entry);
        const lower = entry.name.toLowerCase();
        if (!this.byName.has(lower)) {
          this.byName.set(lower, entry);
        }
      }
      cursor += 46 + nameLength + extraLength + commentLength;
    }
  }

  private applyZip64Extra(entry: ZipEntry, start: number, length: number): void {
    let cursor = start;
    const end = start + length;
    while (cursor + 4 <= end) {
      const headerId = Bytes.readU16LE(this.data, cursor);
      const size = Bytes.readU16LE(this.data, cursor + 2);
      if (headerId === 0x0001) {
        let field = cursor + 4;
        if (entry.uncompressedSize === 0xFFFFFFFF && field + 8 <= end) {
          entry.uncompressedSize = Bytes.readI64LE(this.data, field);
          field += 8;
        }
        if (entry.compressedSize === 0xFFFFFFFF && field + 8 <= end) {
          entry.compressedSize = Bytes.readI64LE(this.data, field);
          field += 8;
        }
        if (entry.localHeaderOffset === 0xFFFFFFFF && field + 8 <= end) {
          entry.localHeaderOffset = Bytes.readI64LE(this.data, field);
        }
        return;
      }
      cursor += 4 + size;
    }
  }

  private static decodeName(bytes: Uint8Array): string {
    if (TextCodec.looksLikeUtf8(bytes)) {
      return TextCodec.decodeUtf8(bytes);
    }
    if (TextCodec.externalDecoder !== null) {
      return TextCodec.externalDecoder(bytes, 'gbk');
    }
    return TextCodec.decodeLatin1(bytes);
  }

  get count(): number {
    return this.entries.length;
  }

  find(name: string): ZipEntry | null {
    const direct = this.byName.get(name);
    if (direct !== undefined) {
      return direct;
    }
    const lower = this.byName.get(name.toLowerCase());
    return lower !== undefined ? lower : null;
  }

  has(name: string): boolean {
    return this.find(name) !== null;
  }

  /** Inflates one entry. Stored and deflated entries are both supported. */
  readEntry(entry: ZipEntry): Uint8Array {
    if ((entry.flags & 0x0001) !== 0) {
      throw new Error('加密的 ZIP 条目暂不支持');
    }
    let offset = entry.localHeaderOffset;
    if (offset + 30 > this.data.length || Bytes.readU32LE(this.data, offset) !== 0x04034B50) {
      throw new Error('ZIP 本地文件头损坏');
    }
    const nameLength = Bytes.readU16LE(this.data, offset + 26);
    const extraLength = Bytes.readU16LE(this.data, offset + 28);
    const dataStart = offset + 30 + nameLength + extraLength;
    const dataEnd = dataStart + entry.compressedSize;
    if (dataEnd > this.data.length) {
      throw new Error('ZIP 条目超出文件范围');
    }
    const payload = this.data.subarray(dataStart, dataEnd);
    if (entry.method === 0) {
      return payload.slice();
    }
    if (entry.method === 8) {
      const inflated = inflateRaw(payload);
      if (entry.uncompressedSize > 0 && inflated.length !== entry.uncompressedSize) {
        // Some writers leave the size as zero in the central directory. Keep
        // the inflated bytes; a real mismatch is still caught by later parsing.
        if (inflated.length < entry.uncompressedSize) {
          throw new Error('ZIP 解压长度不一致');
        }
      }
      return inflated;
    }
    throw new Error('不支持的 ZIP 压缩方式：' + entry.method);
  }

  read(name: string): Uint8Array | null {
    const entry = this.find(name);
    if (entry === null) {
      return null;
    }
    return this.readEntry(entry);
  }

  readText(name: string): string | null {
    const bytes = this.read(name);
    if (bytes === null) {
      return null;
    }
    return TextCodec.decode(bytes);
  }

  names(): string[] {
    const result: string[] = [];
    for (let i = 0; i < this.entries.length; i++) {
      if (!this.entries[i].isDirectory) {
        result.push(this.entries[i].name);
      }
    }
    return result;
  }
}

/** Natural, case-insensitive ordering: page2 < page10. */
export function naturalCompare(a: string, b: string): number {
  const left = a.toLowerCase();
  const right = b.toLowerCase();
  let i = 0;
  let j = 0;
  while (i < left.length && j < right.length) {
    const ca = left.charCodeAt(i);
    const cb = right.charCodeAt(j);
    if (ca >= 48 && ca <= 57 && cb >= 48 && cb <= 57) {
      let startA = i;
      let startB = j;
      while (i < left.length && left.charCodeAt(i) >= 48 && left.charCodeAt(i) <= 57) {
        i++;
      }
      while (j < right.length && right.charCodeAt(j) >= 48 && right.charCodeAt(j) <= 57) {
        j++;
      }
      const na = parseInt(left.substring(startA, i), 10);
      const nb = parseInt(right.substring(startB, j), 10);
      if (na !== nb) {
        return na - nb;
      }
      continue;
    }
    if (ca !== cb) {
      return ca - cb;
    }
    i++;
    j++;
  }
  return left.length - right.length;
}
