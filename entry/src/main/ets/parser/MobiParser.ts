import { AssetBlob, ChapterLink, RenderedBook } from './BookTypes';
import { ByteBuffer, Bytes, TextCodec } from './Bytes';
import { HtmlText } from './HtmlText';

/**
 * 原生 PalmDOC / Mobipocket 6 / KF8 (AZW3) 解码器。
 *
 * 移植自 Mac 版 IntelReader 的 MOBIParser.swift：直接读取 Palm 数据库，
 * 自行完成 PalmDOC 与 HUFF/CDIC 解压、KF8 骨架/片段重组、FDST 文本流和
 * 图片资源抽取，不依赖 Calibre 之类的转换工具。
 */

/** 解析错误，message 直接作为 RenderedBook.error 展示。 */
class MobiError extends Error {
  code: string = '';

  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

function mobiCorrupted(): MobiError {
  return new MobiError('corrupted', 'MOBI 文件已损坏或不完整');
}

/** 记录区间。 */
class RecordRange {
  start: number = 0;
  end: number = 0;

  size(): number {
    return this.end - this.start;
  }
}

/** Palm 数据库：记录表加原始字节。 */
class PalmDatabase {
  private data: Uint8Array;
  private ranges: RecordRange[] = [];

  constructor(data: Uint8Array) {
    this.data = data;
    if (data.length < 78) {
      throw new MobiError('notMOBI', '不是有效的 MOBI/AZW 文件');
    }
    const count = (data[76] << 8) | data[77];
    if (count <= 0) {
      throw new MobiError('notMOBI', '不是有效的 MOBI/AZW 文件');
    }
    const starts: number[] = [];
    for (let index = 0; index < count; index++) {
      const offset = 78 + index * 8;
      if (offset + 4 > data.length) {
        throw mobiCorrupted();
      }
      starts.push(Bytes.readU32BE(data, offset));
    }
    starts.push(data.length);
    let previous = 78;
    for (let index = 0; index < count; index++) {
      const start = starts[index];
      const end = starts[index + 1];
      if (start < previous || start > end || end > data.length) {
        throw mobiCorrupted();
      }
      const range = new RecordRange();
      range.start = start;
      range.end = end;
      this.ranges.push(range);
      previous = start;
    }
  }

  count(): number {
    return this.ranges.length;
  }

  lengthOf(index: number): number {
    if (index < 0 || index >= this.ranges.length) {
      return 0;
    }
    return this.ranges[index].size();
  }

  record(index: number): Uint8Array {
    if (index < 0 || index >= this.ranges.length) {
      return new Uint8Array(0);
    }
    const range = this.ranges[index];
    return this.data.subarray(range.start, range.end);
  }
}

/** MOBI 头（第 0 条记录或 KF8 分段的头记录）。 */
class MOBIHeader {
  recordIndex: number = 0;
  compression: number = 0;
  textLength: number = 0;
  textRecordCount: number = 0;
  cryptoType: number = 0;
  headerLength: number = 0;
  codepage: number = 0;
  version: number = 0;
  minVersion: number = 0;
  firstResource: number = 0;
  huffOffset: number = 0;
  huffCount: number = 0;
  fdst: number = 0;
  fdstCount: number = 0;
  fragIndex: number = 0;
  skelIndex: number = 0;
  trailFlags: number = 0;
  title: string = '';
  author: string = '';
  exth: Map<number, Uint8Array> = new Map<number, Uint8Array>();

  constructor(palm: PalmDatabase, index: number) {
    const record = palm.record(index);
    if (record.length <= 40 || Bytes.ascii(record, 16, 4) !== 'MOBI') {
      throw new MobiError('notMOBI', '不是有效的 MOBI/AZW 文件');
    }
    const u16 = (offset: number): number => {
      if (offset < 0 || offset + 2 > record.length) {
        return 0;
      }
      return (record[offset] << 8) | record[offset + 1];
    };
    const u32 = (offset: number): number => {
      if (offset < 0 || offset + 4 > record.length) {
        return 0;
      }
      return Bytes.readU32BE(record, offset);
    };

    this.recordIndex = index;
    this.compression = u16(0x00);
    this.textLength = u32(0x04);
    this.textRecordCount = u16(0x08);
    this.cryptoType = u16(0x0C);
    this.headerLength = u32(0x14);
    const page = u32(0x1C);
    this.codepage = page;
    this.version = u32(0x24);
    this.minVersion = u32(0x68);
    this.firstResource = u32(0x6C);
    this.huffOffset = u32(0x70);
    this.huffCount = u32(0x74);
    this.fdst = u32(0xC0);
    this.fdstCount = u32(0xC4);
    this.fragIndex = u32(0xF8);
    this.skelIndex = u32(0xFC);
    this.trailFlags = this.headerLength + 16 >= 0xF4 ? u16(0xF2) : 0;

    // EXTH 元数据
    const exthOffset = 16 + this.headerLength;
    if ((u32(0x80) & 0x40) !== 0 &&
      exthOffset + 12 <= record.length &&
      Bytes.ascii(record, exthOffset, 4) === 'EXTH') {
      const count = Bytes.readU32BE(record, exthOffset + 8);
      let position = exthOffset + 12;
      for (let i = 0; i < Math.max(count, 0); i++) {
        if (position + 8 > record.length) {
          break;
        }
        const type = Bytes.readU32BE(record, position);
        const size = Bytes.readU32BE(record, position + 4);
        if (size < 8 || position + size > record.length) {
          break;
        }
        this.exth.set(type, record.subarray(position + 8, position + size));
        position += size;
      }
    }

    const titleOffset = u32(0x54);
    const titleLength = u32(0x58);
    let titleBytes = new Uint8Array(0);
    if (titleOffset > 0 && titleLength > 0 && titleOffset + titleLength <= record.length) {
      titleBytes = record.subarray(titleOffset, titleOffset + titleLength);
    }
    this.title = MobiParser.decode(titleBytes, page).trim();

    const authorBytes = this.exth.get(100);
    if (authorBytes !== undefined) {
      this.author = MobiParser.decode(authorBytes, page).trim();
    }
  }
}

/** 图片资源集合：1 基资源槽位到资源路径的映射，以及待写出的资源。 */
class MobiResources {
  slotNames: Map<number, string> = new Map<number, string>();
  assets: AssetBlob[] = [];
  coverPath: string = '';
}

/** 解析完成、尚未拼装章节的内容。 */
class MobiContent {
  title: string = '';
  author: string = '';
  /** 每章 body 级 HTML，阅读顺序与文本模型一致。 */
  parts: string[] = [];
  /** 与 parts 一一对应的纯文本。 */
  texts: string[] = [];
  assets: AssetBlob[] = [];
  coverPath: string = '';
}

/** Huff/CDIC 解压器，带解压状态（短语缓存），所以不是纯函数。 */
class MobiDecompressor {
  decompress(input: Uint8Array): Uint8Array {
    return input;
  }
}

/** 未压缩文本（compression = 1）。 */
class PassthroughDecompressor extends MobiDecompressor {
  decompress(input: Uint8Array): Uint8Array {
    return input;
  }
}

/** PalmDOC LZ77（compression = 2），几乎所有 MOBI/AZW 在使用。 */
class PalmDOCDecompressor extends MobiDecompressor {
  decompress(input: Uint8Array): Uint8Array {
    const output = new ByteBuffer(Math.max(input.length * 2, 64));
    let position = 0;
    while (position < input.length) {
      const control = input[position];
      position += 1;
      if (control >= 0x01 && control <= 0x08) {
        const count = Math.min(control, input.length - position);
        if (count > 0) {
          output.pushBytes(input.subarray(position, position + count));
        }
        position += count;
      } else if (control === 0x00 || (control >= 0x09 && control <= 0x7F)) {
        output.push(control);
      } else if (control >= 0x80 && control <= 0xBF) {
        if (position < input.length) {
          const pair = (control << 8) | input[position];
          position += 1;
          const distance = (pair >> 3) & 0x07FF;
          const length = (pair & 0x07) + 3;
          if (distance > 0 && distance <= output.size) {
            for (let i = 0; i < length; i++) {
              output.push(output.byteAtFromEnd(distance));
            }
          }
        }
      } else {
        output.push(0x20);
        output.push(control ^ 0x80);
      }
    }
    return output.toUint8Array();
  }
}

class HuffCode {
  length: number = 0;
  terminal: boolean = false;
  maxCode: number = 0;
}

class HuffPhrase {
  bytes: Uint8Array = new Uint8Array(0);
  literal: boolean = false;
}

/** HUFF/CDIC 字典压缩（compression = 17480），早期高压缩 MOBI 在用。 */
class HuffCDICDecompressor extends MobiDecompressor {
  private firstTable: HuffCode[] = [];
  private minCodes: number[] = [];
  private maxCodes: number[] = [];
  private phrases: HuffPhrase[] = [];

  constructor(huff: Uint8Array, cdics: Uint8Array[]) {
    super();
    if (huff.length < 24 || Bytes.ascii(huff, 0, 4) !== 'HUFF') {
      throw mobiCorrupted();
    }
    for (let i = 0; i < 33; i++) {
      this.minCodes.push(0);
      this.maxCodes.push(0);
    }
    const firstOffset = Bytes.readU32BE(huff, 8);
    const secondOffset = Bytes.readU32BE(huff, 12);
    if (firstOffset + 256 * 4 > huff.length || secondOffset + 64 * 4 > huff.length) {
      throw mobiCorrupted();
    }
    for (let index = 0; index < 256; index++) {
      const value = Bytes.readU32BE(huff, firstOffset + index * 4);
      const length = value & 0x1F;
      if (length <= 0 || length > 32) {
        throw mobiCorrupted();
      }
      const code = new HuffCode();
      code.length = length;
      code.terminal = (value & 0x80) !== 0;
      // ((value >> 8) + 1) << (32 - length) - 1，按 32 位截断
      const low = (Math.floor(value / 256) + 1) % Math.pow(2, length);
      const product = low * Math.pow(2, 32 - length);
      code.maxCode = product > 0 ? product - 1 : 4294967295;
      this.firstTable.push(code);
    }
    for (let length = 1; length <= 32; length++) {
      const offset = secondOffset + (length - 1) * 8;
      if (offset + 8 > huff.length) {
        break;
      }
      const minimum = Bytes.readU32BE(huff, offset);
      const maximum = Bytes.readU32BE(huff, offset + 4);
      const minLow = minimum % Math.pow(2, length);
      this.minCodes[length] = minLow * Math.pow(2, 32 - length);
      const maxLow = (maximum + 1) % Math.pow(2, length);
      const maxProduct = maxLow * Math.pow(2, 32 - length);
      this.maxCodes[length] = maxProduct > 0 ? maxProduct - 1 : 4294967295;
    }

    for (let cdicIndex = 0; cdicIndex < cdics.length; cdicIndex++) {
      const cdic = cdics[cdicIndex];
      if (cdic.length < 16 || Bytes.ascii(cdic, 0, 4) !== 'CDIC') {
        throw mobiCorrupted();
      }
      const phraseCount = Bytes.readU32BE(cdic, 8);
      const bits = Bytes.readU32BE(cdic, 12);
      if (bits <= 0 || bits >= 16) {
        throw mobiCorrupted();
      }
      const capacity = Math.min(
        Math.pow(2, bits),
        Math.max(phraseCount - this.phrases.length, 0)
      );
      if (capacity <= 0 || 16 + capacity * 2 > cdic.length) {
        continue;
      }
      for (let index = 0; index < capacity; index++) {
        const offset = 16 + index * 2;
        const phraseOffset = Bytes.readU16BE(cdic, offset);
        const headerPosition = 16 + phraseOffset;
        const phrase = new HuffPhrase();
        if (headerPosition + 2 > cdic.length) {
          this.phrases.push(phrase);
          continue;
        }
        const header = Bytes.readU16BE(cdic, headerPosition);
        const length = header & 0x7FFF;
        const start = headerPosition + 2;
        const end = Math.min(start + length, cdic.length);
        phrase.bytes = start <= end ? cdic.subarray(start, end) : new Uint8Array(0);
        phrase.literal = (header & 0x8000) !== 0;
        this.phrases.push(phrase);
      }
    }
  }

  decompress(input: Uint8Array): Uint8Array {
    return this.unpack(input, 0);
  }

  /** 按位读取 32 位大端窗口；data 末尾已补 8 个 0。 */
  private readBits32(data: Uint8Array, bitOffset: number): number {
    const byteIndex = bitOffset >>> 3;
    const shift = bitOffset & 7;
    let value = ((data[byteIndex] << 24) | (data[byteIndex + 1] << 16) |
      (data[byteIndex + 2] << 8) | data[byteIndex + 3]) >>> 0;
    value = (value << shift) >>> 0;
    if (shift > 0) {
      value = (value | (data[byteIndex + 4] >>> (8 - shift))) >>> 0;
    }
    return value;
  }

  private unpack(input: Uint8Array, depth: number): Uint8Array {
    if (depth >= 32) {
      throw mobiCorrupted();
    }
    const data = new Uint8Array(input.length + 8);
    data.set(input, 0);
    let bitsLeft = input.length * 8;
    const output = new ByteBuffer(Math.max(input.length * 4, 64));
    let cursor = 0;
    while (bitsLeft > 0) {
      const code = this.readBits32(data, cursor);
      let entry = this.firstTable[code >>> 24];
      let length = entry.length;
      let codeMax = entry.maxCode;
      if (!entry.terminal) {
        while (length < 32 && code < this.minCodes[length]) {
          length += 1;
        }
        codeMax = this.maxCodes[length];
      }
      cursor += length;
      bitsLeft -= length;
      if (bitsLeft < 0) {
        break;
      }
      if (length <= 0 || length > 32) {
        break;
      }
      const shift = 32 - length;
      const index = ((codeMax - code) >>> 0) >>> shift;
      if (index < 0 || index >= this.phrases.length) {
        break;
      }
      const phrase = this.phrases[index];
      if (phrase.literal) {
        output.pushBytes(phrase.bytes);
      } else {
        const expanded = this.unpack(phrase.bytes, depth + 1);
        const stored = new HuffPhrase();
        stored.bytes = expanded;
        stored.literal = true;
        this.phrases[index] = stored;
        output.pushBytes(expanded);
      }
    }
    return output.toUint8Array();
  }
}

/** INDX 索引条目。 */
class IndexEntry {
  text: Uint8Array = new Uint8Array(0);
  tags: Map<number, number[]> = new Map<number, number[]>();

  /** 十进制文本值；含非数字时返回 -1。 */
  numericValue(): number {
    let value = 0;
    for (let i = 0; i < this.text.length; i++) {
      const byte = this.text[i];
      if (byte < 0x30 || byte > 0x39) {
        return -1;
      }
      value = value * 10 + (byte - 0x30);
    }
    return value;
  }
}

/** TAGX 标签定义。 */
class TagDefinition {
  tag: number = 0;
  valuesPerEntry: number = 0;
  mask: number = 0;
  endFlag: number = 0;
}

/** parseTags 的中间状态。 */
class PendingTag {
  tag: number = 0;
  count: number = -1;
  byteCount: number = -1;
  perEntry: number = 1;
}

class VarWidth {
  consumed: number = 0;
  value: number = 0;
}

class SkeletonEntry {
  fragmentCount: number = 0;
  start: number = 0;
  length: number = 0;
}

class FragmentEntry {
  insert: number = 0;
  start: number = 0;
  length: number = 0;
}

class MobiHeading {
  title: string = '';
  level: number = 0;
}

export function isMOBI(bytes: Uint8Array): boolean {
  if (bytes.length < 78) {
    return false;
  }
  // Palm 数据库头：type(60..63) = "BOOK"，creator(64..67) = "MOBI"
  return Bytes.ascii(bytes, 60, 4) === 'BOOK' && Bytes.ascii(bytes, 64, 4) === 'MOBI';
}

export function renderMOBI(bytes: Uint8Array): RenderedBook {
  const book = new RenderedBook();
  let content: MobiContent;
  try {
    content = MobiParser.parseContainer(bytes);
  } catch (error) {
    if (error instanceof MobiError) {
      book.error = error.message;
    } else {
      book.error = 'MOBI 文件解析失败';
    }
    return book;
  }

  book.title = content.title;
  book.author = content.author;
  book.assets = content.assets;
  book.coverPath = content.coverPath;

  const sections: string[] = [];
  let totalText = 0;
  for (let i = 0; i < content.parts.length; i++) {
    const anchorId = 'mobi-h-' + i;
    sections.push('<section class="mobi-chapter" id="' + anchorId + '">' +
      content.parts[i] + '</section>');
    totalText += content.texts[i].length;
  }
  book.html = sections.join('\n');
  book.textModel = HtmlText.buildTextModel(content.texts);

  let cursor = 0;
  for (let i = 0; i < content.parts.length; i++) {
    const text = content.texts[i];
    const heading = MobiParser.headingOf(content.parts[i]);
    const fallback = '第 ' + (i + 1) + ' 章';
    const link = new ChapterLink();
    link.title = heading.title.length > 0 ? heading.title : HtmlText.chapterTitle(text, fallback);
    link.anchorId = 'mobi-h-' + i;
    link.level = heading.level > 0 ? heading.level : HtmlText.chapterHeadingLevel(text);
    link.progress = totalText > 0 ? cursor / totalText : 0;
    link.locatorText = HtmlText.firstLine(HtmlText.normalizeNewlines(text), 60);
    book.chapters.push(link);
    cursor += text.length;
  }
  return book;
}

class MobiParser {
  private static readonly CP1252_HIGH: string[] = [
    '\u20AC', '\u0081', '\u201A', '\u0192', '\u201E', '\u2026', '\u2020', '\u2021',
    '\u02C6', '\u2030', '\u0160', '\u2039', '\u0152', '\u008D', '\u017D', '\u008F',
    '\u0090', '\u2018', '\u2019', '\u201C', '\u201D', '\u2022', '\u2013', '\u2014',
    '\u02DC', '\u2122', '\u0161', '\u203A', '\u0153', '\u009D', '\u017E', '\u0178'
  ];

  static parseContainer(bytes: Uint8Array): MobiContent {
    const palm = new PalmDatabase(bytes);
    let header = new MOBIHeader(palm, 0);

    // "combo" 书在同一个 Palm 数据库里同时存旧版 Mobipocket 与 KF8，
    // 优先使用布局更现代的 KF8 分段。
    if (header.version < 8) {
      const limit = Math.max(palm.count() - 1, 1);
      for (let index = 1; index < limit; index++) {
        if (palm.lengthOf(index) !== 8) {
          continue;
        }
        const record = palm.record(index);
        const isBoundary = (record.length === 4 &&
          record[0] === 0xE9 && record[1] === 0x8E &&
          record[2] === 0x0D && record[3] === 0x0A) ||
          Bytes.ascii(record, 0, 8) === 'BOUNDARY';
        if (!isBoundary) {
          continue;
        }
        const next = palm.record(index + 1);
        if (next.length <= 20 || Bytes.ascii(next, 16, 4) !== 'MOBI') {
          continue;
        }
        const candidate = MobiParser.tryHeader(palm, index + 1);
        if (candidate !== null && candidate.version >= 8) {
          header = candidate;
        }
      }
    }

    if (header.compression !== 1 && header.compression !== 2 && header.compression !== 17480) {
      throw new MobiError('unsupportedCompression', '不支持的 MOBI 压缩方式：' + header.compression);
    }
    if (header.cryptoType !== 0) {
      throw new MobiError('encrypted', '带 DRM 的 Kindle 书无法解码');
    }

    const raw = MobiParser.rawMarkup(palm, header);
    if (raw.length === 0) {
      throw mobiCorrupted();
    }

    const resources = MobiParser.collectResources(palm, header);
    const isKF8 = header.version >= 8;
    const content = new MobiContent();
    content.assets = resources.assets;
    content.coverPath = resources.coverPath;

    if (isKF8) {
      const documents = MobiParser.kf8Documents(raw, palm, header);
      for (let i = 0; i < documents.length; i++) {
        const html = MobiParser.decode(documents[i], header.codepage);
        const cleaned = MobiParser.cleanKF8HTML(html, resources.slotNames);
        MobiParser.appendPart(content, cleaned);
      }
    } else {
      const html = MobiParser.cleanMobi6HTML(raw, header, resources.slotNames);
      const documents = MobiParser.splitMobi6HTML(html);
      for (let i = 0; i < documents.length; i++) {
        MobiParser.appendPart(content, documents[i]);
      }
    }
    if (content.parts.length === 0) {
      throw mobiCorrupted();
    }

    content.title = header.title;
    if (content.title.length === 0) {
      const updatedTitle = header.exth.get(503);
      if (updatedTitle !== undefined) {
        content.title = MobiParser.decode(updatedTitle, header.codepage).trim();
      }
    }
    if (content.title.length === 0) {
      content.title = 'MOBI 电子书';
    }
    content.author = header.author;
    return content;
  }

  /** 提取 body 并生成对应的纯文本；空章节直接跳过。 */
  private static appendPart(content: MobiContent, document: string): void {
    const body = MobiParser.sanitizeHtml(MobiParser.bodyContents(document));
    const text = MobiParser.plainText(body);
    if (text.trim().length === 0) {
      return;
    }
    content.parts.push(body);
    content.texts.push(text);
  }

  private static tryHeader(palm: PalmDatabase, index: number): MOBIHeader | null {
    try {
      return new MOBIHeader(palm, index);
    } catch (error) {
      return null;
    }
  }

  // MARK: - 文本流

  private static rawMarkup(palm: PalmDatabase, header: MOBIHeader): Uint8Array {
    const decompressor = MobiParser.makeDecompressor(palm, header);
    const chunks: Uint8Array[] = [];
    const last = Math.max(header.textRecordCount, 1);
    for (let index = 1; index <= last; index++) {
      const recordIndex = header.recordIndex + index;
      if (recordIndex >= palm.count()) {
        break;
      }
      const record = MobiParser.trimTrailingEntries(palm.record(recordIndex), header);
      const piece = decompressor.decompress(record);
      if (piece.length > 0) {
        chunks.push(piece);
      }
    }
    let output = Bytes.concat(chunks);
    if (header.version < 8 && header.textLength > 0 && output.length > header.textLength) {
      output = output.subarray(0, header.textLength);
    }
    return output;
  }

  private static trimTrailingEntries(record: Uint8Array, header: MOBIHeader): Uint8Array {
    if (header.headerLength < 0xE4 || header.minVersion < 5 || header.trailFlags <= 0) {
      return record;
    }
    let data = record;
    const flags = header.trailFlags;
    let trailers = 0;
    let bits = flags >> 1;
    while (bits !== 0) {
      trailers += bits & 1;
      bits >>= 1;
    }
    for (let i = 0; i < trailers; i++) {
      if (data.length < 4) {
        break;
      }
      let size = 0;
      for (let j = data.length - 4; j < data.length; j++) {
        const byte = data[j];
        if ((byte & 0x80) !== 0) {
          size = 0;
        }
        size = (size << 7) | (byte & 0x7F);
      }
      if (size <= 0 || size > data.length) {
        break;
      }
      data = data.subarray(0, data.length - size);
    }
    if ((flags & 1) !== 0 && data.length > 0) {
      const lastByte = data[data.length - 1];
      const count = (lastByte & 3) + 1;
      if (count <= data.length) {
        data = data.subarray(0, data.length - count);
      }
    }
    return data;
  }

  private static makeDecompressor(palm: PalmDatabase, header: MOBIHeader): MobiDecompressor {
    if (header.compression === 1) {
      return new PassthroughDecompressor();
    }
    if (header.compression === 2) {
      return new PalmDOCDecompressor();
    }
    if (header.compression === 17480) {
      const huffRecord = header.huffOffset + header.recordIndex;
      if (header.huffOffset <= 0 || header.huffOffset >= 0xFFFF ||
        huffRecord < 0 || huffRecord >= palm.count() || header.huffCount <= 0) {
        throw mobiCorrupted();
      }
      const cdics: Uint8Array[] = [];
      for (let index = 1; index < header.huffCount; index++) {
        const record = huffRecord + index;
        if (record >= palm.count()) {
          break;
        }
        cdics.push(palm.record(record));
      }
      return new HuffCDICDecompressor(palm.record(huffRecord), cdics);
    }
    throw new MobiError('unsupportedCompression', '不支持的 MOBI 压缩方式：' + header.compression);
  }

  // MARK: - KF8 文档重组

  private static kf8Documents(raw: Uint8Array, palm: PalmDatabase, header: MOBIHeader): Uint8Array[] {
    const flows = MobiParser.fdstFlows(raw, palm, header);
    const text = flows.length > 0 ? flows[0] : raw;

    if (header.skelIndex === 0xFFFF || header.fragIndex === 0xFFFF ||
      header.skelIndex === 0xFFFFFFFF || header.fragIndex === 0xFFFFFFFF) {
      return [text];
    }
    // 与 huffOffset / firstResource 一样，骨架与片段索引也是相对本段
    // MOBI 头记录的偏移；combo 书的 KF8 头不在第 0 条记录，必须加上基准。
    const skelRecord = header.recordIndex + header.skelIndex;
    const fragRecord = header.recordIndex + header.fragIndex;
    let skeletons: IndexEntry[] = [];
    let fragments: IndexEntry[] = [];
    try {
      skeletons = MobiParser.indexEntries(palm, skelRecord);
      fragments = MobiParser.indexEntries(palm, fragRecord);
    } catch (error) {
      return [text];
    }
    if (skeletons.length === 0) {
      // 索引损坏的 KF8：原始文本流本身仍是 XHTML，直接阅读比报错好。
      return [text];
    }

    const skeletonTable: SkeletonEntry[] = [];
    for (let i = 0; i < skeletons.length; i++) {
      const range = skeletons[i].tags.get(6);
      if (range === undefined || range.length < 2) {
        continue;
      }
      const skeleton = new SkeletonEntry();
      const counts = skeletons[i].tags.get(1);
      skeleton.fragmentCount = counts !== undefined && counts.length > 0 ? counts[0] : 0;
      skeleton.start = range[0];
      skeleton.length = range[1];
      skeletonTable.push(skeleton);
    }
    const fragmentTable: FragmentEntry[] = [];
    for (let i = 0; i < fragments.length; i++) {
      const range = fragments[i].tags.get(6);
      if (range === undefined || range.length < 2) {
        continue;
      }
      const insert = fragments[i].numericValue();
      if (insert < 0) {
        continue;
      }
      const fragment = new FragmentEntry();
      fragment.insert = insert;
      fragment.start = range[0];
      fragment.length = range[1];
      fragmentTable.push(fragment);
    }

    const documents: Uint8Array[] = [];
    let fragmentPointer = 0;
    for (let i = 0; i < skeletonTable.length; i++) {
      const skeleton = skeletonTable[i];
      if (skeleton.start < 0 || skeleton.length < 0 ||
        skeleton.start + skeleton.length > text.length) {
        continue;
      }
      let basePointer = skeleton.start + skeleton.length;
      let document = text.subarray(skeleton.start, basePointer);
      for (let j = 0; j < Math.max(skeleton.fragmentCount, 0); j++) {
        if (fragmentPointer >= fragmentTable.length) {
          break;
        }
        const fragment = fragmentTable[fragmentPointer];
        fragmentPointer += 1;
        if (fragment.start < 0 || fragment.length < 0 ||
          basePointer + fragment.length > text.length) {
          break;
        }
        let insert = fragment.insert - skeleton.start;
        insert = Math.min(Math.max(insert, 0), document.length);
        document = MobiParser.insertBytes(
          document,
          insert,
          text.subarray(basePointer, basePointer + fragment.length)
        );
        basePointer += fragment.length;
      }
      documents.push(document);
    }
    if (documents.length === 0) {
      return [text];
    }
    return documents;
  }

  private static insertBytes(target: Uint8Array, at: number, bytes: Uint8Array): Uint8Array {
    const out = new Uint8Array(target.length + bytes.length);
    out.set(target.subarray(0, at), 0);
    out.set(bytes, at);
    out.set(target.subarray(at), at + bytes.length);
    return out;
  }

  private static fdstFlows(raw: Uint8Array, palm: PalmDatabase, header: MOBIHeader): Uint8Array[] {
    if (header.fdst <= 0 || header.fdst >= 0xFFFF || header.fdstCount <= 1 ||
      header.fdst + header.recordIndex >= palm.count()) {
      return [raw];
    }
    const data = palm.record(header.fdst + header.recordIndex);
    if (data.length < 12 || Bytes.ascii(data, 0, 4) !== 'FDST') {
      return [raw];
    }
    const sectionCount = Bytes.readU32BE(data, 8);
    if (sectionCount <= 0) {
      return [raw];
    }
    const starts: number[] = [];
    for (let index = 0; index < sectionCount; index++) {
      const offset = 12 + index * 8;
      if (offset + 4 > data.length) {
        return [raw];
      }
      starts.push(Bytes.readU32BE(data, offset));
    }
    starts.push(raw.length);
    const flows: Uint8Array[] = [];
    for (let index = 0; index < sectionCount; index++) {
      const start = Math.min(Math.max(starts[index], 0), raw.length);
      const end = Math.min(Math.max(starts[index + 1], start), raw.length);
      flows.push(raw.subarray(start, end));
    }
    return flows;
  }

  private static indexEntries(palm: PalmDatabase, index: number): IndexEntry[] {
    if (index < 0 || index >= palm.count()) {
      throw mobiCorrupted();
    }
    const main = palm.record(index);
    if (main.length < 56 || Bytes.ascii(main, 0, 4) !== 'INDX') {
      throw mobiCorrupted();
    }
    const headerLength = Bytes.readU32BE(main, 4);
    const sectionCount = Bytes.readU32BE(main, 24);
    const tagSectionStart = headerLength;
    if (tagSectionStart + 12 > main.length ||
      Bytes.ascii(main, tagSectionStart, 4) !== 'TAGX') {
      throw mobiCorrupted();
    }
    const tagTableEnd = Bytes.readU32BE(main, tagSectionStart + 4);
    const controlByteCount = Bytes.readU32BE(main, tagSectionStart + 8);
    const tagTable: TagDefinition[] = [];
    if (tagTableEnd > 12) {
      let offset = tagSectionStart + 12;
      while (offset + 4 <= tagSectionStart + tagTableEnd && offset + 4 <= main.length) {
        const definition = new TagDefinition();
        definition.tag = main[offset];
        definition.valuesPerEntry = main[offset + 1];
        definition.mask = main[offset + 2];
        definition.endFlag = main[offset + 3];
        tagTable.push(definition);
        offset += 4;
      }
    }
    if (controlByteCount <= 0 || tagTable.length === 0) {
      throw mobiCorrupted();
    }

    const entries: IndexEntry[] = [];
    for (let sectionIndex = 0; sectionIndex < Math.max(sectionCount, 1); sectionIndex++) {
      const recordIndex = index + 1 + sectionIndex;
      if (recordIndex >= palm.count()) {
        break;
      }
      const section = palm.record(recordIndex);
      if (section.length < 24) {
        continue;
      }
      const entryCount = Bytes.readU32BE(section, 24);
      const positionsStart = Bytes.readU32BE(section, 20);
      if (entryCount <= 0 || positionsStart + 4 + entryCount * 2 > section.length) {
        continue;
      }
      const positions: number[] = [];
      for (let entryIndex = 0; entryIndex < entryCount; entryIndex++) {
        const offset = positionsStart + 4 + entryIndex * 2;
        positions.push(Bytes.readU16BE(section, offset));
      }
      positions.push(positionsStart);
      for (let entryIndex = 0; entryIndex < entryCount; entryIndex++) {
        const start = positions[entryIndex];
        const end = positions[entryIndex + 1];
        if (start < 0 || start >= section.length || end > section.length || start >= end) {
          continue;
        }
        const textLength = section[start];
        const textStart = start + 1;
        const tagStart = textStart + textLength;
        if (tagStart > end || tagStart + controlByteCount > end) {
          continue;
        }
        const entry = new IndexEntry();
        entry.tags = MobiParser.parseTags(section, tagStart, controlByteCount, tagTable);
        if (textLength > 0 && textStart + textLength <= section.length) {
          entry.text = section.subarray(textStart, textStart + textLength);
        }
        entries.push(entry);
      }
    }
    return entries;
  }

  private static parseTags(
    bytes: Uint8Array,
    tagStart: number,
    controlByteCount: number,
    tagTable: TagDefinition[]
  ): Map<number, number[]> {
    let dataStart = tagStart + controlByteCount;
    let controlIndex = 0;
    const pending: PendingTag[] = [];

    for (let i = 0; i < tagTable.length; i++) {
      const definition = tagTable[i];
      if (definition.endFlag === 1) {
        controlIndex += 1;
        continue;
      }
      if (tagStart + controlIndex >= bytes.length) {
        break;
      }
      const controlByte = bytes[tagStart + controlIndex];
      const value = controlByte & definition.mask;
      if (value === 0) {
        continue;
      }
      const item = new PendingTag();
      item.tag = definition.tag;
      item.perEntry = definition.valuesPerEntry;
      if (value === definition.mask) {
        if (MobiParser.popCount(definition.mask) > 1) {
          const width = MobiParser.variableWidth(bytes, dataStart);
          if (width === null) {
            continue;
          }
          dataStart += width.consumed;
          item.byteCount = width.value;
        } else {
          item.count = 1;
        }
      } else {
        let shifted = value;
        let mask = definition.mask;
        while ((mask & 1) === 0) {
          mask >>= 1;
          shifted >>= 1;
        }
        item.count = shifted;
      }
      pending.push(item);
    }

    const map: Map<number, number[]> = new Map<number, number[]>();
    for (let i = 0; i < pending.length; i++) {
      const item = pending[i];
      const values: number[] = [];
      if (item.count >= 0) {
        // 每个标签可能定义多个值，实际数量来自 TAGX 的 valuesPerEntry。
        const total = item.count * Math.max(item.perEntry, 1);
        for (let j = 0; j < total; j++) {
          const width = MobiParser.variableWidth(bytes, dataStart);
          if (width === null) {
            break;
          }
          dataStart += width.consumed;
          values.push(width.value);
        }
      } else if (item.byteCount >= 0) {
        let consumedTotal = 0;
        while (consumedTotal < item.byteCount) {
          const width = MobiParser.variableWidth(bytes, dataStart);
          if (width === null) {
            break;
          }
          dataStart += width.consumed;
          consumedTotal += width.consumed;
          values.push(width.value);
        }
      }
      map.set(item.tag, values);
    }
    return map;
  }

  private static popCount(value: number): number {
    let bits = value;
    let count = 0;
    while (bits !== 0) {
      count += bits & 1;
      bits >>= 1;
    }
    return count;
  }

  private static variableWidth(bytes: Uint8Array, offset: number): VarWidth | null {
    let value = 0;
    let consumed = 0;
    while (offset + consumed < bytes.length) {
      const byte = bytes[offset + consumed];
      consumed += 1;
      if ((byte & 0x80) !== 0) {
        const result = new VarWidth();
        result.consumed = consumed;
        result.value = value * 128 + (byte & 0x7F);
        return result;
      }
      value = value * 128 + (byte & 0x7F);
      if (consumed > 4) {
        break;
      }
    }
    return null;
  }

  // MARK: - 资源

  private static collectResources(palm: PalmDatabase, header: MOBIHeader): MobiResources {
    const result = new MobiResources();
    const fallback = header.recordIndex + header.textRecordCount + 1;
    let start = fallback;
    if (header.firstResource > 0 && header.firstResource < 0xFFFF) {
      start = header.firstResource + header.recordIndex;
    }
    if (start <= 0 || start >= palm.count()) {
      return result;
    }
    for (let recordIndex = start; recordIndex < palm.count(); recordIndex++) {
      const slot = recordIndex - start + 1;
      const record = palm.record(recordIndex);
      const ext = MobiParser.imageExtension(record);
      if (ext === null) {
        continue;
      }
      const path = 'assets/mobi-' + slot + '.' + ext;
      result.slotNames.set(slot, path);
      HtmlText.addAsset(result.assets, path, record);
    }

    // EXTH 201：封面图在资源记录中的偏移（0 基）。
    const coverBytes = header.exth.get(201);
    if (coverBytes !== undefined && coverBytes.length >= 4) {
      const coverSlot = Bytes.readU32BE(coverBytes, 0) + 1;
      const coverPath = result.slotNames.get(coverSlot);
      if (coverPath !== undefined) {
        result.coverPath = coverPath;
      }
    }
    return result;
  }

  private static imageExtension(bytes: Uint8Array): string | null {
    if (bytes.length >= 3 && bytes[0] === 0xFF && bytes[1] === 0xD8) {
      return 'jpg';
    }
    if (bytes.length >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50 &&
      bytes[2] === 0x4E && bytes[3] === 0x47) {
      return 'png';
    }
    if (bytes.length >= 6 && Bytes.ascii(bytes, 0, 4) === 'GIF8') {
      return 'gif';
    }
    if (bytes.length >= 2 && bytes[0] === 0x42 && bytes[1] === 0x4D) {
      return 'bmp';
    }
    if (bytes.length >= 12 && Bytes.ascii(bytes, 0, 4) === 'RIFF' &&
      Bytes.ascii(bytes, 8, 4) === 'WEBP') {
      return 'webp';
    }
    return null;
  }

  // MARK: - Mobi6 标记

  private static cleanMobi6HTML(
    raw: Uint8Array,
    header: MOBIHeader,
    slotNames: Map<number, string>
  ): string {
    const bytes = MobiParser.insertFilePositionAnchors(raw);
    let html = MobiParser.decode(bytes, header.codepage);
    html = html.replace(/<mbp:pagebreak\s*\/?>/gi, '<hr class="chapter-break">');
    // filepos 链接改写成锚点；先前的 filepos 值已经被插入了 <a id="fileposN">。
    html = html.replace(/filepos\s*=\s*["']?0*(\d+)["']?/gi,
      (match: string, digits: string): string => 'href="#filepos' + digits + '"');
    html = MobiParser.replaceImageReferences(html, slotNames);
    return html;
  }

  /**
   * Mobipocket 6 用字节偏移做链接（filepos="12345"）。阅读器需要真正的锚点，
   * 所以在解码前向原始字节流插入 ASCII 标记；任何 MOBI 编码都兼容 ASCII。
   */
  private static insertFilePositionAnchors(raw: Uint8Array): Uint8Array {
    const needle = 'filepos';
    const positions: Set<number> = new Set<number>();
    let index = 0;
    while (index + needle.length <= raw.length) {
      if (raw[index] === 0x66 && Bytes.ascii(raw, index, needle.length) === needle) {
        let cursor = index + needle.length;
        while (cursor < raw.length && (raw[cursor] === 0x20 || raw[cursor] === 0x09)) {
          cursor += 1;
        }
        if (cursor < raw.length && raw[cursor] === 0x3D) {
          cursor += 1;
          while (cursor < raw.length && (raw[cursor] === 0x20 || raw[cursor] === 0x09)) {
            cursor += 1;
          }
          if (cursor < raw.length && (raw[cursor] === 0x22 || raw[cursor] === 0x27)) {
            cursor += 1;
          }
          let value = 0;
          let digits = 0;
          while (cursor < raw.length && raw[cursor] >= 0x30 && raw[cursor] <= 0x39) {
            value = value * 10 + (raw[cursor] - 0x30);
            digits += 1;
            cursor += 1;
          }
          if (digits > 0) {
            positions.add(value);
          }
        }
        index = cursor;
      } else {
        index += 1;
      }
    }
    if (positions.size === 0) {
      return raw;
    }
    const unique: number[] = [];
    positions.forEach((value: number): void => {
      if (value > 0 && value < raw.length) {
        unique.push(value);
      }
    });
    if (unique.length === 0) {
      return raw;
    }
    unique.sort((a: number, b: number): number => a - b);

    let total = raw.length;
    const markers: Uint8Array[] = [];
    for (let i = 0; i < unique.length; i++) {
      const marker = MobiParser.anchorMarker(unique[i]);
      markers.push(marker);
      total += marker.length;
    }
    const out = new Uint8Array(total);
    let source = 0;
    let destination = 0;
    for (let i = 0; i < unique.length; i++) {
      const position = unique[i];
      const chunk = raw.subarray(source, position);
      out.set(chunk, destination);
      destination += chunk.length;
      out.set(markers[i], destination);
      destination += markers[i].length;
      source = position;
    }
    const tail = raw.subarray(source);
    out.set(tail, destination);
    return out;
  }

  private static anchorMarker(position: number): Uint8Array {
    const text = '<a id="filepos' + position + '"></a>';
    const out = new Uint8Array(text.length);
    for (let i = 0; i < text.length; i++) {
      out[i] = text.charCodeAt(i) & 0xFF;
    }
    return out;
  }

  private static splitMobi6HTML(html: string): string[] {
    if (html.indexOf('chapter-break') < 0 ||
      html.toLowerCase().indexOf('<body') < 0) {
      return [html];
    }
    const pieces = html.split('<hr class="chapter-break">');
    if (pieces.length <= 1) {
      return [html];
    }
    const result: string[] = [];
    for (let i = 0; i < pieces.length; i++) {
      // mbp:pagebreak 会把一个完整文档切成多段，除最后一段外都没有
      // </body>。这里统一取出 body 内部内容再补回完整包装，避免嵌套
      // <html>/<body> 与残留的 <head> 进入阅读页面。
      const piece = pieces[i];
      const lower = piece.toLowerCase();
      let inner = piece;
      const bodyStart = lower.indexOf('<body');
      if (bodyStart >= 0) {
        const bodyOpenEnd = lower.indexOf('>', bodyStart + 5);
        if (bodyOpenEnd >= 0) {
          inner = piece.substring(bodyOpenEnd + 1);
        }
      }
      const bodyEnd = inner.toLowerCase().indexOf('</body');
      if (bodyEnd >= 0) {
        inner = inner.substring(0, bodyEnd);
      }
      inner = inner.replace(/<head[\s\S]*?<\/head>/gi, '');
      result.push('<html><body>' + inner + '</body></html>');
    }
    return result;
  }

  // MARK: - KF8 标记

  private static cleanKF8HTML(html: string, slotNames: Map<number, string>): string {
    let text = html.replace(/kindle:pos:fid:[0-9A-V]+:off:[0-9A-V]+/gi, '#');
    text = MobiParser.replaceKindleEmbeds(text, slotNames);
    return text;
  }

  private static replaceKindleEmbeds(html: string, slotNames: Map<number, string>): string {
    return html.replace(/kindle:embed:([0-9A-V]+)[^"'\s)]*/gi,
      (match: string, token: string): string => {
        const slot = MobiParser.base32(token);
        const name = slotNames.get(slot);
        return name !== undefined ? name : '';
      });
  }

  private static replaceImageReferences(html: string, slotNames: Map<number, string>): string {
    return html.replace(/recindex\s*=\s*["']?(\d+)["']?/gi,
      (match: string, digits: string): string => {
        const slot = parseInt(digits, 10);
        const name = slotNames.get(slot);
        return name !== undefined ? 'src="' + name + '"' : 'src=""';
      });
  }

  private static base32(value: string): number {
    const upper = value.toUpperCase();
    let result = 0;
    for (let i = 0; i < upper.length; i++) {
      const code = upper.charCodeAt(i);
      let digit = -1;
      if (code >= 0x30 && code <= 0x39) {
        digit = code - 0x30;
      } else if (code >= 0x41 && code <= 0x56) {
        digit = code - 0x41 + 10;
      }
      if (digit < 0) {
        continue;
      }
      result = result * 32 + digit;
    }
    return result;
  }

  // MARK: - HTML 与文本

  /** 返回 <body> 内部 HTML；书里只存裸片段时返回原文档。 */
  static bodyContents(source: string): string {
    const lower = source.toLowerCase();
    const startTag = lower.indexOf('<body');
    if (startTag < 0) {
      return source;
    }
    const startEnd = lower.indexOf('>', startTag + 5);
    if (startEnd < 0) {
      return source;
    }
    const endTag = lower.indexOf('</body', startEnd + 1);
    if (endTag < 0) {
      return source;
    }
    return source.substring(startEnd + 1, endTag);
  }

  /**
   * 去掉 script/style 等危险内容，只保留 p、div、br、img、b、i、u、
   * h1-h6、blockquote、table 这类阅读所需的基本标记。
   */
  private static sanitizeHtml(source: string): string {
    let text = source;
    text = text.replace(/<\?xml[\s\S]*?\?>/gi, '');
    text = text.replace(/<!DOCTYPE[\s\S]*?>/gi, '');
    text = text.replace(/<head[\s\S]*?<\/head>/gi, '');
    text = text.replace(/<script[\s\S]*?<\/script>/gi, '');
    text = text.replace(/<style[\s\S]*?<\/style>/gi, '');
    text = text.replace(/<\/?(iframe|object|embed|applet|form|input|button|select|textarea|base|link|meta|frame|frameset)[^>]*>/gi, '');
    text = text.replace(/\son[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/gi, '');
    text = text.replace(/href\s*=\s*("javascript:[^"]*"|'javascript:[^']*')/gi, 'href="#"');
    return text;
  }

  /** 与 Swift 版 plainText(fromHTML:) 一致：保留换行，不压缩空白。 */
  private static plainText(source: string): string {
    let text = source;
    text = text.replace(/<head[^>]*>[\s\S]*?<\/head>/gi, '');
    text = text.replace(/<(script|style)[^>]*>[\s\S]*?<\/\1>/gi, '');
    text = text.replace(/<br\s*\/?>/gi, '\n');
    text = text.replace(/<\/(p|div|h[1-6]|li|tr)\s*>/gi, '\n');
    text = text.replace(/<[^>]+>/g, '');
    return HtmlText.decodeEntities(text);
  }

  static headingOf(body: string): MobiHeading {
    const heading = new MobiHeading();
    const match = body.match(/<h([1-6])[^>]*>([\s\S]*?)<\/h\1>/i);
    if (match !== null) {
      const title = HtmlText.stripTags(match[2]);
      if (title.length > 0) {
        heading.title = HtmlText.truncate(title, 80);
        heading.level = parseInt(match[1], 10);
      }
    }
    return heading;
  }

  /** 与 Swift 版 decode 一致：合法 UTF-8 优先，否则按 Windows-1252 回退。 */
  static decode(bytes: Uint8Array, codepage: number): string {
    if (bytes.length === 0) {
      return '';
    }
    if (bytes.length >= 3 && bytes[0] === 0xEF && bytes[1] === 0xBB && bytes[2] === 0xBF) {
      return TextCodec.decodeUtf8(bytes.subarray(3));
    }
    // 有些制作工具声明 1252 却存储 UTF-8；合法 UTF-8 胜出。
    if (TextCodec.looksLikeUtf8(bytes)) {
      return TextCodec.decodeUtf8(bytes);
    }
    if (codepage === 65001) {
      return TextCodec.decodeUtf8(bytes);
    }
    return MobiParser.decodeCp1252(bytes);
  }

  private static decodeCp1252(data: Uint8Array): string {
    const chunks: string[] = [];
    const chunk = 8192;
    for (let start = 0; start < data.length; start += chunk) {
      const end = Math.min(data.length, start + chunk);
      let text = '';
      for (let i = start; i < end; i++) {
        const byte = data[i];
        if (byte >= 0x80 && byte <= 0x9F) {
          text += MobiParser.CP1252_HIGH[byte - 0x80];
        } else {
          text += String.fromCharCode(byte);
        }
      }
      chunks.push(text);
    }
    return chunks.join('');
  }
}
