import { AssetBlob, ChapterLink, RenderedBook } from './BookTypes';
import { HtmlText } from './HtmlText';

/** FB2 内嵌图片的原始数据。 */
class Fb2Binary {
  id: string = '';
  contentType: string = '';
  base64: string = '';
}

/** 解析中的一个 section：用于收集纯文本与目录信息。 */
class Fb2Section {
  index: number = 0;
  level: number = 1;
  progress: number = 0;
  title: string = '';
  text: string = '';
}

class Fb2OpenTag {
  name: string = '';
  attributes: Map<string, string> = new Map<string, string>();
}

const BASE64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function buildBase64Table(): number[] {
  const table: number[] = [];
  for (let i = 0; i < 256; i++) {
    table.push(-1);
  }
  for (let i = 0; i < BASE64_ALPHABET.length; i++) {
    table[BASE64_ALPHABET.charCodeAt(i)] = i;
  }
  // URL 安全变体也一并支持
  table['-'.charCodeAt(0)] = 62;
  table['_'.charCodeAt(0)] = 63;
  return table;
}

const BASE64_TABLE: number[] = buildBase64Table();

/** 纯 TS 的 Base64 解码，忽略空白与非法字符。 */
function decodeBase64Text(input: string): Uint8Array {
  const output = new Uint8Array(Math.floor(input.length * 3 / 4) + 4);
  let buffer = 0;
  let bits = 0;
  let length = 0;
  for (let i = 0; i < input.length; i++) {
    const code = input.charCodeAt(i);
    if (code === 61) {
      break;
    }
    const value = code < 256 ? BASE64_TABLE[code] : -1;
    if (value < 0) {
      continue;
    }
    buffer = ((buffer << 6) | value) & 0xFFFFFF;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      output[length] = (buffer >> bits) & 0xFF;
      length += 1;
    }
  }
  return output.slice(0, length);
}

/** 根据 content-type 与文件头判断图片扩展名。 */
function imageExtension(contentType: string, data: Uint8Array): string {
  const lower = contentType.toLowerCase();
  if (lower.indexOf('jpeg') >= 0 || lower.indexOf('jpg') >= 0) {
    return 'jpg';
  }
  if (lower.indexOf('png') >= 0) {
    return 'png';
  }
  if (lower.indexOf('gif') >= 0) {
    return 'gif';
  }
  if (lower.indexOf('svg') >= 0) {
    return 'svg';
  }
  if (lower.indexOf('webp') >= 0) {
    return 'webp';
  }
  if (data.length >= 2 && data[0] === 0xFF && data[1] === 0xD8) {
    return 'jpg';
  }
  if (data.length >= 4 && data[0] === 0x89 && data[1] === 0x50 && data[2] === 0x4E && data[3] === 0x47) {
    return 'png';
  }
  if (data.length >= 4 && data[0] === 0x47 && data[1] === 0x49 && data[2] === 0x46 && data[3] === 0x38) {
    return 'gif';
  }
  if (data.length >= 12 && data[0] === 0x52 && data[1] === 0x49 && data[2] === 0x46 && data[3] === 0x46 &&
    data[8] === 0x57 && data[9] === 0x45 && data[10] === 0x42 && data[11] === 0x50) {
    return 'webp';
  }
  return 'bin';
}

const FB2_CSS = '.fb2-title{font-size:1.34em;font-weight:600;line-height:1.5;margin:1.5em 0 .8em;}' +
  '.fb2-book-title{font-size:1.6em;font-weight:600;text-align:center;margin:1.2em 0 1.6em;}' +
  '.fb2-subtitle{font-weight:600;margin:1.1em 0 .5em;}' +
  '.fb2-epigraph,.fb2-cite{margin:1em 0;padding-left:1em;border-left:3px solid rgba(127,127,127,.35);opacity:.9;}' +
  '.fb2-poem{margin:1em 0;}.fb2-stanza{margin:.8em 0;}.fb2-verse{margin:0 0 .2em;}' +
  '.fb2-text-author{text-align:right;font-style:italic;opacity:.8;}' +
  '.fb2-annotation{margin:1em 0;padding:.8em 1em;background:rgba(127,127,127,.08);border-radius:6px;}' +
  '.fb2-image{max-width:100%;height:auto;display:block;margin:1em auto;}' +
  '.fb2-empty{height:.8em;}' +
  '.fb2-table{border-collapse:collapse;width:100%;margin:1em 0;}' +
  '.fb2-table td,.fb2-table th{border:1px solid rgba(127,127,127,.35);padding:.35em .5em;}';

export function renderFB2(xml: string): RenderedBook {
  const builder = new Fb2Builder();
  return builder.render(xml);
}

class Fb2Builder {
  private html: string[] = [];
  private chapters: ChapterLink[] = [];
  private assets: AssetBlob[] = [];
  private imagePaths: Map<string, string> = new Map<string, string>();
  private sectionTexts: string[] = [];
  private sectionStack: Fb2Section[] = [];
  private sectionCounter: number = 0;
  private sectionDepth: number = 0;
  private headingCounter: number = 0;
  private titleActive: boolean = false;
  private titleText: string = '';
  private titleAnchor: string = '';
  private titleIsHeading: boolean = false;
  private titleLevel: number = 1;
  private titleProgress: number = 0;
  private bodyLength: number = 1;

  render(xml: string): RenderedBook {
    const book = new RenderedBook();
    let source = xml;
    if (source.length > 0 && source.charCodeAt(0) === 0xFEFF) {
      source = source.substring(1);
    }

    this.readMetadata(source, book);
    this.readBinaries(source);
    const coverMatch = source.match(/<coverpage[^>]*>[\s\S]*?<image[^>]*?(?:l:href|xlink:href|href)\s*=\s*["']#([^"']+)["']/i);
    if (coverMatch !== null) {
      const cover = this.imagePaths.get(coverMatch[1]);
      if (cover !== undefined) {
        book.coverPath = cover;
      }
    }

    const bodies = Fb2Builder.bodySections(source);
    if (bodies.length === 0) {
      book.error = '不是有效的 FB2 文件';
      return book;
    }

    for (let i = 0; i < bodies.length; i++) {
      const body = bodies[i];
      this.bodyLength = Math.max(1, body.length);
      this.sectionDepth = 0;
      this.sectionStack = [];
      this.titleActive = false;
      this.scan(body, 0);
    }

    book.html = this.html.join('');
    book.css = FB2_CSS;
    book.assets = this.assets;
    book.textModel = HtmlText.buildTextModel(this.collectSectionTexts());
    for (let i = 0; i < this.chapters.length; i++) {
      book.chapters.push(this.chapters[i]);
    }
    if (book.html.length === 0) {
      book.error = 'FB2 文件中没有可显示的正文';
    }
    return book;
  }

  // MARK: - 元数据与图片

  private readMetadata(xml: string, book: RenderedBook): void {
    const titleInfo = Fb2Builder.firstTagInner(xml, 'title-info');
    const scope = titleInfo.length > 0 ? titleInfo : xml;
    book.title = HtmlText.collapseWhitespace(HtmlText.stripTags(Fb2Builder.firstTagInner(scope, 'book-title')));

    const authors: string[] = [];
    const authorPattern = /<author\b[^>]*>([\s\S]*?)<\/author>/gi;
    let match = authorPattern.exec(scope);
    while (match !== null) {
      const block = match[1];
      const parts: string[] = [];
      Fb2Builder.pushTagText(parts, block, 'first-name');
      Fb2Builder.pushTagText(parts, block, 'middle-name');
      Fb2Builder.pushTagText(parts, block, 'last-name');
      let name = parts.join(' ');
      if (name.length === 0) {
        name = HtmlText.collapseWhitespace(HtmlText.stripTags(Fb2Builder.firstTagInner(block, 'nickname')));
      }
      if (name.length > 0) {
        authors.push(name);
      }
      match = authorPattern.exec(scope);
    }
    if (authors.length === 0) {
      const author = HtmlText.collapseWhitespace(HtmlText.stripTags(Fb2Builder.firstTagInner(scope, 'author')));
      if (author.length > 0) {
        authors.push(author);
      }
    }
    book.author = authors.join(', ');

    if (book.title.length === 0) {
      book.title = HtmlText.collapseWhitespace(HtmlText.stripTags(Fb2Builder.firstTagInner(xml, 'book-title')));
    }
  }

  private static pushTagText(parts: string[], block: string, tag: string): void {
    const value = HtmlText.collapseWhitespace(HtmlText.stripTags(Fb2Builder.firstTagInner(block, tag)));
    if (value.length > 0) {
      parts.push(value);
    }
  }

  private readBinaries(xml: string): void {
    const pattern = /<binary\b([^>]*)>([\s\S]*?)<\/binary>/gi;
    let match = pattern.exec(xml);
    while (match !== null) {
      const attrs = Fb2Builder.parseAttributes(match[1]);
      const id = Fb2Builder.attribute(attrs, ['id']);
      const contentType = Fb2Builder.attribute(attrs, ['content-type']);
      const binary = new Fb2Binary();
      binary.id = id;
      binary.contentType = contentType;
      binary.base64 = match[2];
      this.storeBinary(binary);
      match = pattern.exec(xml);
    }
  }

  private storeBinary(binary: Fb2Binary): void {
    if (binary.id.length === 0 || this.imagePaths.has(binary.id)) {
      return;
    }
    const compact = binary.base64.replace(/\s+/g, '');
    if (compact.length === 0) {
      return;
    }
    const bytes = decodeBase64Text(compact);
    if (bytes.length === 0) {
      return;
    }
    const extension = imageExtension(binary.contentType, bytes);
    const assetPath = 'assets/fb2-' + Fb2Builder.safeName(binary.id) + '.' + extension;
    const asset = new AssetBlob();
    asset.path = assetPath;
    asset.bytes = bytes;
    asset.mime = binary.contentType.length > 0 && binary.contentType.toLowerCase().startsWith('image/')
      ? binary.contentType
      : HtmlText.guessMime(assetPath);
    this.assets.push(asset);
    this.imagePaths.set(binary.id, assetPath);
  }

  private static safeName(value: string): string {
    let result = '';
    for (let i = 0; i < value.length; i++) {
      const ch = value.charAt(i);
      const code = value.charCodeAt(i);
      const alnum = (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
      if (alnum || ch === '.' || ch === '-' || ch === '_') {
        result += ch;
      } else {
        result += '_';
      }
    }
    // 与参考实现一致：去掉 id 自带的扩展名，避免 fb2-cover.png.png。
    const dot = result.lastIndexOf('.');
    if (dot > 0 && dot < result.length - 1) {
      result = result.substring(0, dot);
    }
    return result.length > 0 ? result : 'image';
  }

  // MARK: - 扫描

  private scan(xml: string, base: number): void {
    let index = 0;
    while (index < xml.length) {
      const lt = xml.indexOf('<', index);
      if (lt < 0) {
        this.handleText(xml.substring(index));
        break;
      }
      if (lt > index) {
        this.handleText(xml.substring(index, lt));
      }
      if (xml.startsWith('<!--', lt)) {
        const end = xml.indexOf('-->', lt + 4);
        index = end < 0 ? xml.length : end + 3;
        continue;
      }
      if (xml.startsWith('<![CDATA[', lt)) {
        const end = xml.indexOf(']]>', lt + 9);
        const content = end < 0 ? xml.substring(lt + 9) : xml.substring(lt + 9, end);
        this.handleCData(content);
        index = end < 0 ? xml.length : end + 3;
        continue;
      }
      if (xml.startsWith('<?', lt)) {
        const end = xml.indexOf('?>', lt + 2);
        index = end < 0 ? xml.length : end + 2;
        continue;
      }
      if (xml.startsWith('<!', lt)) {
        const end = xml.indexOf('>', lt + 2);
        index = end < 0 ? xml.length : end + 1;
        continue;
      }
      const gt = Fb2Builder.findTagEnd(xml, lt + 1);
      if (gt < 0) {
        break;
      }
      const raw = xml.substring(lt + 1, gt);
      const trimmed = raw.trim();
      if (trimmed.startsWith('/')) {
        this.handleEnd(Fb2Builder.normalizeName(trimmed.substring(1).trim()));
      } else {
        let content = trimmed;
        if (content.endsWith('/')) {
          content = content.substring(0, content.length - 1);
        }
        const tag = Fb2Builder.parseTag(content);
        this.handleStart(tag.name, tag.attributes, base + lt);
      }
      index = gt + 1;
    }
  }

  private static findTagEnd(xml: string, from: number): number {
    let quote = '';
    for (let i = from; i < xml.length; i++) {
      const ch = xml.charAt(i);
      if (quote.length > 0) {
        if (ch === quote) {
          quote = '';
        }
        continue;
      }
      if (ch === '"' || ch === '\'') {
        quote = ch;
        continue;
      }
      if (ch === '>') {
        return i;
      }
    }
    return -1;
  }

  private static parseTag(content: string): Fb2OpenTag {
    const tag = new Fb2OpenTag();
    let index = 0;
    while (index < content.length && !Fb2Builder.isWhitespace(content.charAt(index))) {
      index += 1;
    }
    tag.name = Fb2Builder.normalizeName(content.substring(0, index));
    tag.attributes = Fb2Builder.parseAttributes(content.substring(index));
    return tag;
  }

  private static parseAttributes(text: string): Map<string, string> {
    const result = new Map<string, string>();
    const pattern = /([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*("([^"]*)"|'([^']*)')/g;
    let match = pattern.exec(text);
    while (match !== null) {
      const name = match[1].toLowerCase();
      const value = match[3] !== undefined ? match[3] : match[4];
      if (!result.has(name)) {
        result.set(name, HtmlText.decodeEntities(value));
      }
      match = pattern.exec(text);
    }
    return result;
  }

  private static normalizeName(name: string): string {
    const lower = name.trim().toLowerCase();
    const colon = lower.lastIndexOf(':');
    return colon >= 0 ? lower.substring(colon + 1) : lower;
  }

  private static isWhitespace(ch: string): boolean {
    return ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r';
  }

  private static attribute(attributes: Map<string, string>, names: string[]): string {
    for (let i = 0; i < names.length; i++) {
      const value = attributes.get(names[i]);
      if (value !== undefined && value.length > 0) {
        return value;
      }
    }
    return '';
  }

  // MARK: - 开始 / 结束标签

  private handleStart(name: string, attributes: Map<string, string>, position: number): void {
    switch (name) {
      case 'section': {
        this.sectionDepth += 1;
        const frame = new Fb2Section();
        frame.index = this.sectionCounter;
        this.sectionCounter += 1;
        frame.level = this.sectionDepth;
        frame.progress = this.bodyLength > 0 ? position / this.bodyLength : 0;
        this.sectionStack.push(frame);
        this.html.push('<section>');
        break;
      }
      case 'title':
        this.titleActive = true;
        this.titleText = '';
        this.titleIsHeading = this.sectionDepth > 0;
        this.titleLevel = this.sectionDepth;
        if (this.titleIsHeading) {
          this.headingCounter += 1;
          this.titleAnchor = 'fb2-h-' + (this.headingCounter - 1);
          const frameTop = this.sectionStack[this.sectionStack.length - 1];
          this.titleProgress = frameTop !== undefined ? frameTop.progress : 0;
          this.html.push('<div class="fb2-title" id="' + this.titleAnchor + '">');
        } else {
          this.titleAnchor = '';
          this.titleProgress = 0;
          this.html.push('<div class="fb2-book-title">');
        }
        break;
      case 'subtitle':
        this.html.push('<p class="fb2-subtitle">');
        break;
      case 'p':
        this.html.push('<p>');
        break;
      case 'v':
        this.html.push('<p class="fb2-verse">');
        break;
      case 'text-author':
        this.html.push('<p class="fb2-text-author">');
        break;
      case 'epigraph':
        this.html.push('<div class="fb2-epigraph">');
        break;
      case 'cite':
        this.html.push('<div class="fb2-cite">');
        break;
      case 'poem':
        this.html.push('<div class="fb2-poem">');
        break;
      case 'stanza':
        this.html.push('<div class="fb2-stanza">');
        break;
      case 'annotation':
        this.html.push('<div class="fb2-annotation">');
        break;
      case 'strong':
        this.html.push('<strong>');
        break;
      case 'emphasis':
        this.html.push('<em>');
        break;
      case 'code':
        this.html.push('<code>');
        break;
      case 'sup':
        this.html.push('<sup>');
        break;
      case 'sub':
        this.html.push('<sub>');
        break;
      case 'strikethrough':
        this.html.push('<s>');
        break;
      case 'a': {
        const href = Fb2Builder.attribute(attributes, ['href', 'l:href', 'xlink:href']);
        if (href.length === 0 || href.toLowerCase().startsWith('javascript:')) {
          this.html.push('<a>');
        } else {
          this.html.push('<a href="' + HtmlText.escape(href) + '">');
        }
        break;
      }
      case 'image':
        this.appendImage(Fb2Builder.attribute(attributes, ['href', 'l:href', 'xlink:href']));
        break;
      case 'empty-line':
        this.html.push('<div class="fb2-empty"></div>');
        break;
      case 'table':
        this.html.push('<table class="fb2-table">');
        break;
      case 'tr':
        this.html.push('<tr>');
        break;
      case 'td':
        this.html.push('<td>');
        break;
      case 'th':
        this.html.push('<th>');
        break;
      default:
        break;
    }
  }

  private handleEnd(name: string): void {
    switch (name) {
      case 'section':
        this.closeSection();
        break;
      case 'title':
        this.closeTitle();
        break;
      case 'subtitle':
      case 'p':
      case 'v':
      case 'text-author':
        this.html.push('</p>');
        break;
      case 'epigraph':
      case 'cite':
      case 'poem':
      case 'stanza':
      case 'annotation':
        this.html.push('</div>');
        break;
      case 'strong':
        this.html.push('</strong>');
        break;
      case 'emphasis':
        this.html.push('</em>');
        break;
      case 'code':
        this.html.push('</code>');
        break;
      case 'sup':
        this.html.push('</sup>');
        break;
      case 'sub':
        this.html.push('</sub>');
        break;
      case 'strikethrough':
        this.html.push('</s>');
        break;
      case 'a':
        this.html.push('</a>');
        break;
      case 'table':
        this.html.push('</table>');
        break;
      case 'tr':
        this.html.push('</tr>');
        break;
      case 'td':
        this.html.push('</td>');
        break;
      case 'th':
        this.html.push('</th>');
        break;
      default:
        break;
    }
  }

  private appendImage(href: string): void {
    if (href.length === 0) {
      return;
    }
    let identifier = href;
    if (identifier.startsWith('#')) {
      identifier = identifier.substring(1);
    }
    const path = this.imagePaths.get(identifier);
    if (path === undefined) {
      return;
    }
    this.html.push('<img class="fb2-image" src="' + HtmlText.escape(path) + '" alt="">');
  }

  private closeTitle(): void {
    const title = HtmlText.collapseWhitespace(this.titleText);
    if (this.titleIsHeading) {
      const frame = this.sectionStack[this.sectionStack.length - 1];
      if (frame !== undefined) {
        frame.title = title;
        if (title.length > 0) {
          const link = new ChapterLink();
          link.title = title;
          link.anchorId = this.titleAnchor;
          link.level = this.titleLevel;
          link.progress = this.titleProgress;
          link.locatorText = '';
          this.chapters.push(link);
        }
      }
    }
    this.html.push('</div>');
    this.titleActive = false;
    this.titleText = '';
    this.titleAnchor = '';
    this.titleIsHeading = false;
  }

  private closeSection(): void {
    const frame = this.sectionStack.pop();
    if (frame !== undefined) {
      const bodyText = frame.text;
      let combined = frame.title;
      if (combined.length > 0 && bodyText.trim().length > 0) {
        combined += '\n' + bodyText;
      } else if (combined.length === 0) {
        combined = bodyText;
      }
      while (this.sectionTexts.length <= frame.index) {
        this.sectionTexts.push('');
      }
      this.sectionTexts[frame.index] = combined;
    }
    this.sectionDepth = Math.max(0, this.sectionDepth - 1);
    this.html.push('</section>');
  }

  // MARK: - 文本

  private handleText(text: string): void {
    if (text.length === 0) {
      return;
    }
    const decoded = HtmlText.decodeEntities(text);
    if (this.titleActive) {
      this.titleText += decoded;
    } else if (this.sectionStack.length > 0) {
      const frame = this.sectionStack[this.sectionStack.length - 1];
      frame.text += decoded;
    }
    this.html.push(HtmlText.escape(decoded));
  }

  private handleCData(text: string): void {
    if (text.length === 0) {
      return;
    }
    if (this.titleActive) {
      this.titleText += text;
    } else if (this.sectionStack.length > 0) {
      const frame = this.sectionStack[this.sectionStack.length - 1];
      frame.text += text;
    }
    this.html.push(HtmlText.escape(text));
  }

  private collectSectionTexts(): string[] {
    const result: string[] = [];
    for (let i = 0; i < this.sectionTexts.length; i++) {
      const text = Fb2Builder.normalizeSectionText(this.sectionTexts[i]);
      if (text.length > 0) {
        result.push(text);
      }
    }
    return result;
  }

  private static normalizeSectionText(value: string): string {
    const normalized = HtmlText.normalizeNewlines(value).replace(/[ \t\u3000]+/g, ' ');
    const lines = normalized.split('\n');
    const kept: string[] = [];
    let blank = false;
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (line.length === 0) {
        if (!blank && kept.length > 0) {
          kept.push('');
          blank = true;
        }
        continue;
      }
      kept.push(line);
      blank = false;
    }
    return kept.join('\n').trim();
  }

  // MARK: - 文档结构辅助

  /** 返回所有 body 元素的内部 XML。 */
  private static bodySections(xml: string): string[] {
    const result: string[] = [];
    const openPattern = /<body\b[^>]*>/gi;
    let match = openPattern.exec(xml);
    while (match !== null) {
      const start = match.index + match[0].length;
      const closePattern = /<\/body\s*>/gi;
      closePattern.lastIndex = start;
      const closeMatch = closePattern.exec(xml);
      if (closeMatch === null) {
        result.push(xml.substring(start));
        break;
      }
      result.push(xml.substring(start, closeMatch.index));
      openPattern.lastIndex = closeMatch.index + closeMatch[0].length;
      match = openPattern.exec(xml);
    }
    return result;
  }

  private static firstTagInner(xml: string, tag: string): string {
    const openPattern = new RegExp('<' + tag + '\\b[^>]*>', 'i');
    const open = openPattern.exec(xml);
    if (open === null) {
      return '';
    }
    const start = open.index + open[0].length;
    if (open[0].endsWith('/>')) {
      return '';
    }
    const closePattern = new RegExp('</' + tag + '\\s*>', 'i');
    closePattern.lastIndex = start;
    const close = closePattern.exec(xml);
    if (close === null) {
      return '';
    }
    return xml.substring(start, close.index);
  }
}
