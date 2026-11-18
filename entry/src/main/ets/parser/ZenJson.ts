/**
 * JSON tree used for the Jianguoyun/ZenReader snapshot format.
 *
 * The Mac and the phone validate a snapshot by re-serializing it with
 * Foundation (remove top-level createdAt, sort keys, compact form, escape
 * every "/" as "\/", %.17g numbers) and hashing those bytes. A plain
 * JSON.parse/stringify round-trip changes number and slash shapes, so this
 * module implements the same serializer exactly.
 */
export enum JsonKind {
  OBJECT = 0,
  ARRAY = 1,
  STRING = 2,
  NUMBER = 3,
  BOOL = 4,
  NULL = 5
}

export class JsonNode {
  kind: JsonKind = JsonKind.NULL;
  objectValue: Map<string, JsonNode> = new Map<string, JsonNode>();
  arrayValue: JsonNode[] = [];
  stringValue: string = '';
  numberValue: number = 0;
  boolValue: boolean = false;

  static object(): JsonNode {
    const node = new JsonNode();
    node.kind = JsonKind.OBJECT;
    return node;
  }

  static array(): JsonNode {
    const node = new JsonNode();
    node.kind = JsonKind.ARRAY;
    return node;
  }

  static string(value: string): JsonNode {
    const node = new JsonNode();
    node.kind = JsonKind.STRING;
    node.stringValue = value;
    return node;
  }

  static number(value: number): JsonNode {
    const node = new JsonNode();
    node.kind = JsonKind.NUMBER;
    node.numberValue = value;
    return node;
  }

  static bool(value: boolean): JsonNode {
    const node = new JsonNode();
    node.kind = JsonKind.BOOL;
    node.boolValue = value;
    return node;
  }

  static nullValue(): JsonNode {
    return new JsonNode();
  }

  get(key: string): JsonNode | null {
    if (this.kind !== JsonKind.OBJECT) {
      return null;
    }
    const value = this.objectValue.get(key);
    return value !== undefined ? value : null;
  }

  set(key: string, value: JsonNode): void {
    if (this.kind !== JsonKind.OBJECT) {
      this.kind = JsonKind.OBJECT;
    }
    this.objectValue.set(key, value);
  }

  remove(key: string): void {
    if (this.kind === JsonKind.OBJECT) {
      this.objectValue.delete(key);
    }
  }

  get length(): number {
    if (this.kind === JsonKind.ARRAY) {
      return this.arrayValue.length;
    }
    if (this.kind === JsonKind.OBJECT) {
      return this.objectValue.size;
    }
    return 0;
  }

  asString(defaultValue: string = ''): string {
    return this.kind === JsonKind.STRING ? this.stringValue : defaultValue;
  }

  asNumber(defaultValue: number = 0): number {
    if (this.kind === JsonKind.NUMBER) {
      return this.numberValue;
    }
    if (this.kind === JsonKind.STRING) {
      const parsed = Number(this.stringValue.trim());
      return isNaN(parsed) ? defaultValue : parsed;
    }
    return defaultValue;
  }

  asInt(defaultValue: number = 0): number {
    const value = this.asNumber(defaultValue);
    return Math.trunc(value);
  }

  asBool(defaultValue: boolean = false): boolean {
    if (this.kind === JsonKind.BOOL) {
      return this.boolValue;
    }
    if (this.kind === JsonKind.NUMBER) {
      return this.numberValue !== 0;
    }
    return defaultValue;
  }

  isNull(): boolean {
    return this.kind === JsonKind.NULL;
  }

  copy(): JsonNode {
    const node = new JsonNode();
    node.kind = this.kind;
    node.stringValue = this.stringValue;
    node.numberValue = this.numberValue;
    node.boolValue = this.boolValue;
    if (this.kind === JsonKind.ARRAY) {
      for (let i = 0; i < this.arrayValue.length; i++) {
        node.arrayValue.push(this.arrayValue[i].copy());
      }
    } else if (this.kind === JsonKind.OBJECT) {
      this.objectValue.forEach((value: JsonNode, key: string): void => {
        node.objectValue.set(key, value.copy());
      });
    }
    return node;
  }
}

export class JsonCodec {
  static parse(text: string): JsonNode {
    const parser = new JsonParser(text);
    const node = parser.parseValue();
    parser.skipWhitespace();
    return node;
  }

  static stringify(node: JsonNode, sorted: boolean, pretty: boolean, escapeSlash: boolean): string {
    const builder: string[] = [];
    JsonWriter.write(node, builder, 0, sorted, pretty, escapeSlash);
    return builder.join('');
  }

  /** The canonical payload Foundation hashes for manifest dataSha256. */
  static canonical(node: JsonNode): string {
    return JsonCodec.stringify(node, true, false, true);
  }

  static utf8(value: string): Uint8Array {
    return new Utf8Encoder().encode(value);
  }
}

class JsonParser {
  private text: string;
  private index: number = 0;

  constructor(text: string) {
    this.text = text;
  }

  skipWhitespace(): void {
    while (this.index < this.text.length) {
      const ch = this.text.charCodeAt(this.index);
      if (ch === 0x20 || ch === 0x09 || ch === 0x0A || ch === 0x0D) {
        this.index += 1;
      } else {
        break;
      }
    }
  }

  parseValue(): JsonNode {
    this.skipWhitespace();
    if (this.index >= this.text.length) {
      return JsonNode.nullValue();
    }
    const ch = this.text.charAt(this.index);
    if (ch === '{') {
      return this.parseObject();
    }
    if (ch === '[') {
      return this.parseArray();
    }
    if (ch === '"') {
      return JsonNode.string(this.parseString());
    }
    if (ch === 't' && this.text.substring(this.index, this.index + 4) === 'true') {
      this.index += 4;
      return JsonNode.bool(true);
    }
    if (ch === 'f' && this.text.substring(this.index, this.index + 5) === 'false') {
      this.index += 5;
      return JsonNode.bool(false);
    }
    if (ch === 'n' && this.text.substring(this.index, this.index + 4) === 'null') {
      this.index += 4;
      return JsonNode.nullValue();
    }
    return this.parseNumber();
  }

  private parseObject(): JsonNode {
    const node = JsonNode.object();
    this.index += 1;
    this.skipWhitespace();
    if (this.text.charAt(this.index) === '}') {
      this.index += 1;
      return node;
    }
    while (this.index < this.text.length) {
      this.skipWhitespace();
      if (this.text.charAt(this.index) !== '"') {
        break;
      }
      const key = this.parseString();
      this.skipWhitespace();
      if (this.text.charAt(this.index) === ':') {
        this.index += 1;
      }
      const value = this.parseValue();
      node.objectValue.set(key, value);
      this.skipWhitespace();
      const ch = this.text.charAt(this.index);
      if (ch === ',') {
        this.index += 1;
        continue;
      }
      if (ch === '}') {
        this.index += 1;
      }
      break;
    }
    return node;
  }

  private parseArray(): JsonNode {
    const node = JsonNode.array();
    this.index += 1;
    this.skipWhitespace();
    if (this.text.charAt(this.index) === ']') {
      this.index += 1;
      return node;
    }
    while (this.index < this.text.length) {
      node.arrayValue.push(this.parseValue());
      this.skipWhitespace();
      const ch = this.text.charAt(this.index);
      if (ch === ',') {
        this.index += 1;
        continue;
      }
      if (ch === ']') {
        this.index += 1;
      }
      break;
    }
    return node;
  }

  private parseString(): string {
    let result = '';
    this.index += 1;
    while (this.index < this.text.length) {
      const ch = this.text.charAt(this.index);
      this.index += 1;
      if (ch === '"') {
        return result;
      }
      if (ch !== '\\') {
        result += ch;
        continue;
      }
      if (this.index >= this.text.length) {
        break;
      }
      const escape = this.text.charAt(this.index);
      this.index += 1;
      if (escape === '"') {
        result += '"';
      } else if (escape === '\\') {
        result += '\\';
      } else if (escape === '/') {
        result += '/';
      } else if (escape === 'b') {
        result += '\b';
      } else if (escape === 'f') {
        result += '\f';
      } else if (escape === 'n') {
        result += '\n';
      } else if (escape === 'r') {
        result += '\r';
      } else if (escape === 't') {
        result += '\t';
      } else if (escape === 'u') {
        const hex = this.text.substring(this.index, this.index + 4);
        this.index += 4;
        result += String.fromCharCode(parseInt(hex, 16));
      }
    }
    return result;
  }

  private parseNumber(): JsonNode {
    const start = this.index;
    while (this.index < this.text.length) {
      const ch = this.text.charAt(this.index);
      if ((ch >= '0' && ch <= '9') || ch === '-' || ch === '+' || ch === '.' ||
        ch === 'e' || ch === 'E') {
        this.index += 1;
      } else {
        break;
      }
    }
    if (start === this.index) {
      this.index += 1;
      return JsonNode.nullValue();
    }
    return JsonNode.number(Number(this.text.substring(start, this.index)));
  }
}

class JsonWriter {
  static write(node: JsonNode, builder: string[], depth: number, sorted: boolean,
    pretty: boolean, escapeSlash: boolean): void {
    if (node.kind === JsonKind.OBJECT) {
      const keys: string[] = [];
      node.objectValue.forEach((value: JsonNode, key: string): void => {
        keys.push(key);
      });
      if (sorted) {
        keys.sort();
      }
      if (keys.length === 0) {
        if (pretty) {
          builder.push('{\n\n' + JsonWriter.indent(depth) + '}');
        } else {
          builder.push('{}');
        }
        return;
      }
      builder.push('{');
      for (let i = 0; i < keys.length; i++) {
        if (i > 0) {
          builder.push(',');
        }
        if (pretty) {
          builder.push('\n' + JsonWriter.indent(depth + 1));
        }
        builder.push(JsonWriter.quote(keys[i], escapeSlash));
        builder.push(pretty ? ' : ' : ':');
        const value = node.objectValue.get(keys[i]);
        if (value !== undefined) {
          JsonWriter.write(value, builder, depth + 1, sorted, pretty, escapeSlash);
        } else {
          builder.push('null');
        }
      }
      if (pretty) {
        builder.push('\n' + JsonWriter.indent(depth));
      }
      builder.push('}');
      return;
    }
    if (node.kind === JsonKind.ARRAY) {
      if (node.arrayValue.length === 0) {
        if (pretty) {
          builder.push('[\n\n' + JsonWriter.indent(depth) + ']');
        } else {
          builder.push('[]');
        }
        return;
      }
      builder.push('[');
      for (let i = 0; i < node.arrayValue.length; i++) {
        if (i > 0) {
          builder.push(',');
        }
        if (pretty) {
          builder.push('\n' + JsonWriter.indent(depth + 1));
        }
        JsonWriter.write(node.arrayValue[i], builder, depth + 1, sorted, pretty, escapeSlash);
      }
      if (pretty) {
        builder.push('\n' + JsonWriter.indent(depth));
      }
      builder.push(']');
      return;
    }
    if (node.kind === JsonKind.STRING) {
      builder.push(JsonWriter.quote(node.stringValue, escapeSlash));
      return;
    }
    if (node.kind === JsonKind.NUMBER) {
      builder.push(JsonWriter.number(node.numberValue));
      return;
    }
    if (node.kind === JsonKind.BOOL) {
      builder.push(node.boolValue ? 'true' : 'false');
      return;
    }
    builder.push('null');
  }

  private static indent(depth: number): string {
    let result = '';
    for (let i = 0; i < depth; i++) {
      result += '  ';
    }
    return result;
  }

  static quote(value: string, escapeSlash: boolean): string {
    let result = '"';
    for (let i = 0; i < value.length; i++) {
      const ch = value.charAt(i);
      const code = value.charCodeAt(i);
      if (ch === '"') {
        result += '\\"';
      } else if (ch === '\\') {
        result += '\\\\';
      } else if (ch === '/') {
        result += escapeSlash ? '\\/' : '/';
      } else if (ch === '\b') {
        result += '\\b';
      } else if (ch === '\f') {
        result += '\\f';
      } else if (ch === '\n') {
        result += '\\n';
      } else if (ch === '\r') {
        result += '\\r';
      } else if (ch === '\t') {
        result += '\\t';
      } else if (code < 0x20) {
        const hex = code.toString(16);
        result += '\\u' + ('0000' + hex).substring(hex.length);
      } else {
        result += ch;
      }
    }
    return result + '"';
  }

  /** C printf("%.17g") formatting, which Foundation uses for doubles. */
  static number(value: number): string {
    if (value === 0) {
      return (1 / value) === -Infinity ? '-0' : '0';
    }
    if (value < 0) {
      return '-' + JsonWriter.number(-value);
    }
    if (!isFinite(value)) {
      return 'null';
    }
    const exponential = value.toExponential(16);
    const eIndex = exponential.indexOf('e');
    let mantissa = exponential.substring(0, eIndex);
    const exponent = parseInt(exponential.substring(eIndex + 1), 10);
    if (mantissa.indexOf('.') >= 0) {
      while (mantissa.endsWith('0')) {
        mantissa = mantissa.substring(0, mantissa.length - 1);
      }
      if (mantissa.endsWith('.')) {
        mantissa = mantissa.substring(0, mantissa.length - 1);
      }
    }
    if (exponent < -4 || exponent >= 17) {
      let digits = mantissa.replace('.', '');
      let text = digits.charAt(0);
      if (digits.length > 1) {
        text += '.' + digits.substring(1);
      }
      const sign = exponent >= 0 ? '+' : '-';
      let exponentText = Math.abs(exponent).toString();
      while (exponentText.length < 2) {
        exponentText = '0' + exponentText;
      }
      return text + 'e' + sign + exponentText;
    }
    const digits = mantissa.replace('.', '');
    if (exponent >= 0) {
      const integerLength = exponent + 1;
      if (digits.length <= integerLength) {
        let result = digits;
        while (result.length < integerLength) {
          result += '0';
        }
        return result;
      }
      return digits.substring(0, integerLength) + '.' + digits.substring(integerLength);
    }
    let result = '0.';
    for (let i = 0; i < -exponent - 1; i++) {
      result += '0';
    }
    return result + digits;
  }
}

class Utf8Encoder {
  encode(value: string): Uint8Array {
    const bytes: number[] = [];
    for (let i = 0; i < value.length; i++) {
      let code = value.charCodeAt(i);
      if (code >= 0xD800 && code <= 0xDBFF && i + 1 < value.length) {
        const low = value.charCodeAt(i + 1);
        if (low >= 0xDC00 && low <= 0xDFFF) {
          code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
          i += 1;
        }
      }
      if (code < 0x80) {
        bytes.push(code);
      } else if (code < 0x800) {
        bytes.push(0xC0 | (code >> 6), 0x80 | (code & 0x3F));
      } else if (code < 0x10000) {
        bytes.push(0xE0 | (code >> 12), 0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F));
      } else {
        bytes.push(0xF0 | (code >> 18), 0x80 | ((code >> 12) & 0x3F),
          0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F));
      }
    }
    return new Uint8Array(bytes);
  }
}
