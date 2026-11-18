import { ByteBuffer } from './Bytes';

const LENGTH_BASE: number[] = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59,
  67, 83, 99, 115, 131, 163, 195, 227, 258
];
const LENGTH_EXTRA: number[] = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0
];
const DIST_BASE: number[] = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
  1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577
];
const DIST_EXTRA: number[] = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13
];
const CODE_LENGTH_ORDER: number[] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

class BitReader {
  private data: Uint8Array;
  private position: number = 0;
  private bitBuffer: number = 0;
  private bitCount: number = 0;

  constructor(data: Uint8Array) {
    this.data = data;
  }

  readBits(count: number): number {
    while (this.bitCount < count) {
      if (this.position >= this.data.length) {
        throw new Error('inflate: unexpected end of input');
      }
      this.bitBuffer |= this.data[this.position] << this.bitCount;
      this.position += 1;
      this.bitCount += 8;
    }
    const value = this.bitBuffer & ((1 << count) - 1);
    this.bitBuffer >>>= count;
    this.bitCount -= count;
    return value;
  }

  readBit(): number {
    return this.readBits(1);
  }

  alignToByte(): void {
    this.bitBuffer = 0;
    this.bitCount = 0;
  }

  readBytes(count: number): Uint8Array {
    this.alignToByte();
    const start = this.position;
    this.position += count;
    if (this.position > this.data.length) {
      throw new Error('inflate: stored block exceeds input');
    }
    return this.data.subarray(start, this.position);
  }

  get remaining(): number {
    return this.data.length - this.position;
  }
}

class Huffman {
  private counts: Int32Array = new Int32Array(16);
  private symbols: Int32Array;

  constructor(lengths: Int32Array) {
    this.symbols = new Int32Array(lengths.length);
    for (let i = 0; i < lengths.length; i++) {
      this.counts[lengths[i]] += 1;
    }
    this.counts[0] = 0;
    const offsets = new Int32Array(16);
    for (let i = 1; i < 15; i++) {
      offsets[i + 1] = offsets[i] + this.counts[i];
    }
    for (let symbol = 0; symbol < lengths.length; symbol++) {
      const length = lengths[symbol];
      if (length !== 0) {
        this.symbols[offsets[length]] = symbol;
        offsets[length] += 1;
      }
    }
  }

  decode(reader: BitReader): number {
    let code = 0;
    let first = 0;
    let index = 0;
    for (let length = 1; length <= 15; length++) {
      code |= reader.readBit();
      const count = this.counts[length];
      if (code - first < count) {
        return this.symbols[index + (code - first)];
      }
      index += count;
      first = (first + count) << 1;
      code <<= 1;
    }
    throw new Error('inflate: invalid Huffman code');
  }
}

let fixedLiteralTable: Huffman | null = null;
let fixedDistanceTable: Huffman | null = null;

function fixedTables(): Huffman[] {
  if (fixedLiteralTable === null || fixedDistanceTable === null) {
    const literalLengths = new Int32Array(288);
    for (let i = 0; i < 144; i++) {
      literalLengths[i] = 8;
    }
    for (let i = 144; i < 256; i++) {
      literalLengths[i] = 9;
    }
    for (let i = 256; i < 280; i++) {
      literalLengths[i] = 7;
    }
    for (let i = 280; i < 288; i++) {
      literalLengths[i] = 8;
    }
    const distanceLengths = new Int32Array(30);
    for (let i = 0; i < 30; i++) {
      distanceLengths[i] = 5;
    }
    fixedLiteralTable = new Huffman(literalLengths);
    fixedDistanceTable = new Huffman(distanceLengths);
  }
  return [fixedLiteralTable, fixedDistanceTable];
}

/** Raw DEFLATE (RFC 1951), the compression method used inside ZIP entries. */
export function inflateRaw(input: Uint8Array): Uint8Array {
  const reader = new BitReader(input);
  const output = new ByteBuffer(Math.max(65536, input.length * 3));

  let finalBlock = false;
  while (!finalBlock) {
    finalBlock = reader.readBit() === 1;
    const blockType = reader.readBits(2);
    if (blockType === 0) {
      // A stored block starts on the next byte boundary; the remaining bits
      // of the three-bit block header are padding.
      reader.alignToByte();
      const length = reader.readBits(16);
      const complement = reader.readBits(16);
      if (((length ^ 0xFFFF) & 0xFFFF) !== complement) {
        throw new Error('inflate: invalid stored block length');
      }
      output.pushBytes(reader.readBytes(length));
    } else if (blockType === 1) {
      const tables = fixedTables();
      inflateBlock(reader, output, tables[0], tables[1]);
    } else if (blockType === 2) {
      const literalCount = reader.readBits(5) + 257;
      const distanceCount = reader.readBits(5) + 1;
      const codeLengthCount = reader.readBits(4) + 4;

      const codeLengths = new Int32Array(19);
      for (let i = 0; i < codeLengthCount; i++) {
        codeLengths[CODE_LENGTH_ORDER[i]] = reader.readBits(3);
      }
      const codeLengthTable = new Huffman(codeLengths);

      const total = literalCount + distanceCount;
      const lengths = new Int32Array(total);
      let index = 0;
      while (index < total) {
        const symbol = codeLengthTable.decode(reader);
        if (symbol < 16) {
          lengths[index] = symbol;
          index += 1;
        } else if (symbol === 16) {
          if (index === 0) {
            throw new Error('inflate: repeat with no previous length');
          }
          const previous = lengths[index - 1];
          const repeat = 3 + reader.readBits(2);
          for (let i = 0; i < repeat && index < total; i++) {
            lengths[index] = previous;
            index += 1;
          }
        } else if (symbol === 17) {
          const repeat = 3 + reader.readBits(3);
          index += repeat;
        } else {
          const repeat = 11 + reader.readBits(7);
          index += repeat;
        }
      }
      if (index > total) {
        throw new Error('inflate: code length overflow');
      }
      const literalLengths = lengths.subarray(0, literalCount);
      const distanceLengths = lengths.subarray(literalCount);
      inflateBlock(reader, output, new Huffman(literalLengths), new Huffman(distanceLengths));
    } else {
      throw new Error('inflate: invalid block type');
    }
  }
  return output.toUint8Array();
}

function inflateBlock(reader: BitReader, output: ByteBuffer, literals: Huffman, distances: Huffman): void {
  while (true) {
    const symbol = literals.decode(reader);
    if (symbol < 256) {
      output.push(symbol);
      continue;
    }
    if (symbol === 256) {
      return;
    }
    const lengthIndex = symbol - 257;
    if (lengthIndex >= LENGTH_BASE.length) {
      throw new Error('inflate: invalid length symbol');
    }
    let length = LENGTH_BASE[lengthIndex];
    const lengthExtra = LENGTH_EXTRA[lengthIndex];
    if (lengthExtra > 0) {
      length += reader.readBits(lengthExtra);
    }
    const distanceSymbol = distances.decode(reader);
    if (distanceSymbol >= DIST_BASE.length) {
      throw new Error('inflate: invalid distance symbol');
    }
    let distance = DIST_BASE[distanceSymbol];
    const distanceExtra = DIST_EXTRA[distanceSymbol];
    if (distanceExtra > 0) {
      distance += reader.readBits(distanceExtra);
    }
    if (distance > output.size) {
      throw new Error('inflate: distance exceeds output');
    }
    for (let i = 0; i < length; i++) {
      output.push(output.byteAtFromEnd(distance));
    }
  }
}
