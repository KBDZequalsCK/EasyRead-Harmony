import { ChapterLink, RenderedBook } from './BookTypes';
import { HtmlText } from './HtmlText';
import { TextCodec } from './Bytes';
import { ZipArchive } from './ZipReader';

/**
 * DOCX 阅读器移植自 Mac 版 DOCXRenderer.swift。
 * DOCX 是包含 WordprocessingML 的 ZIP：这里只保留段落、行内强调、标题、
 * 表格文字与内嵌图片，忽略页面布局、页眉页脚和域代码。
 * XML 使用手写的轻量标签扫描器，避免依赖 DOM。
 */

/** XML 标签，只保留解析需要的名称、闭合标记与属性。 */
class XmlTag {
  name: string = '';
  closing: boolean = false;
  selfClosing: boolean = false;
  attrs: Map<string, string> = new Map<string, string>();

  /** 按完整名称或本地名取属性值，找不到返回空串。 */
  attr(name: string): string {
    const direct = this.attrs.get(name);
    if (direct !== undefined) {
      return direct;
    }
    const wanted = name.toLowerCase();
    let found = '';
    this.attrs.forEach((value: string, key: string): void => {
      if (found.length === 0 && xmlLocalName(key) === wanted) {
        found = value;
      }
    });
    return found;
  }
}

/** 扫描结果的两种形态：标签或文本。 */
class XmlToken {
  tag: XmlTag | null = null;
  text: string = '';

  constructor(tag: XmlTag | null, text: string) {
    this.tag = tag;
    this.text = text;
  }
}

function xmlLocalName(name: string): string {
  const colon = name.lastIndexOf(':');
  const local = colon >= 0 ? name.substring(colon + 1) : name;
  return local.toLowerCase();
}

/** 逐段扫描 XML：注释、CDATA、处理指令都会被正确跳过。 */
class XmlScanner {
  private source: string;
  private cursor: number = 0;

  constructor(source: string) {
    this.source = source;
  }

  next(): XmlToken | null {
    const length = this.source.length;
    while (this.cursor < length) {
      const lt = this.source.indexOf('<', this.cursor);
      if (lt < 0) {
        const text = this.source.substring(this.cursor);
        this.cursor = length;
        return new XmlToken(null, text);
      }
      if (lt > this.cursor) {
        const text = this.source.substring(this.cursor, lt);
        this.cursor = lt;
        return new XmlToken(null, text);
      }
      if (this.source.startsWith('<!--', this.cursor)) {
        const end = this.source.indexOf('-->', this.cursor + 4);
        this.cursor = end < 0 ? length : end + 3;
        continue;
      }
      if (this.source.startsWith('<![CDATA[', this.cursor)) {
        const end = this.source.indexOf(']]>', this.cursor + 9);
        const stop = end < 0 ? length : end;
        const text = this.source.substring(this.cursor + 9, stop);
        this.cursor = end < 0 ? length : end + 3;
        return new XmlToken(null, text);
      }
      if (this.source.startsWith('<?', this.cursor)) {
        const end = this.source.indexOf('?>', this.cursor + 2);
        this.cursor = end < 0 ? length : end + 2;
        continue;
      }
      if (this.source.startsWith('<!', this.cursor)) {
        const end = this.source.indexOf('>', this.cursor + 2);
        this.cursor = end < 0 ? length : end + 1;
        continue;
      }
      const end = this.findTagEnd(this.cursor);
      if (end < 0) {
        this.cursor = length;
        return null;
      }
      const tag = this.parseTag(this.source.substring(this.cursor, end + 1));
      this.cursor = end + 1;
      if (tag !== null) {
        return new XmlToken(tag, '');
      }
    }
    return null;
  }

  /** 找到标签结束的 '>'，属性值里的 '>' 不会被误判。 */
  private findTagEnd(start: number): number {
    let quote = '';
    let i = start + 1;
    while (i < this.source.length) {
      const ch = this.source.charAt(i);
      if (quote.length > 0) {
        if (ch === quote) {
          quote = '';
        }
      } else if (ch === '"' || ch === '\'') {
        quote = ch;
      } else if (ch === '>') {
        return i;
      }
      i += 1;
    }
    return -1;
  }

  private parseTag(raw: string): XmlTag | null {
    let inner = raw.substring(1, raw.length - 1).trim();
    if (inner.length === 0) {
      return null;
    }
    const tag = new XmlTag();
    if (inner.startsWith('/')) {
      tag.closing = true;
      inner = inner.substring(1).trim();
    }
    if (inner.endsWith('/')) {
      tag.selfClosing = true;
      inner = inner.substring(0, inner.length - 1).trim();
    }
    let i = 0;
    while (i < inner.length && !XmlScanner.isSpace(inner.charAt(i))) {
      i += 1;
    }
    tag.name = xmlLocalName(inner.substring(0, i));
    while (i < inner.length) {
      while (i < inner.length && XmlScanner.isSpace(inner.charAt(i))) {
        i += 1;
      }
      const nameStart = i;
      while (i < inner.length && !XmlScanner.isSpace(inner.charAt(i)) && inner.charAt(i) !== '=') {
        i += 1;
      }
      const attrName = inner.substring(nameStart, i);
      let probe = i;
      while (probe < inner.length && XmlScanner.isSpace(inner.charAt(probe))) {
        probe += 1;
      }
      if (probe < inner.length && inner.charAt(probe) === '=') {
        i = probe + 1;
        while (i < inner.length && XmlScanner.isSpace(inner.charAt(i))) {
          i += 1;
        }
        let value = '';
        if (i < inner.length && (inner.charAt(i) === '"' || inner.charAt(i) === '\'')) {
          const quote = inner.charAt(i);
          i += 1;
          const valueStart = i;
          while (i < inner.length && inner.charAt(i) !== quote) {
            i += 1;
          }
          value = inner.substring(valueStart, i);
          if (i < inner.length) {
            i += 1;
          }
        } else {
          const valueStart = i;
          while (i < inner.length && !XmlScanner.isSpace(inner.charAt(i))) {
            i += 1;
          }
          value = inner.substring(valueStart, i);
        }
        if (attrName.length > 0) {
          tag.attrs.set(attrName, value);
        }
      } else if (attrName.length > 0) {
        tag.attrs.set(attrName, '');
        i = probe;
      } else {
        i += 1;
      }
    }
    return tag;
  }

  private static isSpace(ch: string): boolean {
    return ch === ' ' || ch === '\n' || ch === '\t' || ch === '\r';
  }
}

class DocxStyleInfo {
  name: string = '';
  /** 由 outlineLvl 得出，1 起。 */
  level: number = 0;
}

/** 读取 word/_rels/document.xml.rels 中的关系 Id -> Target。 */
function parseRelationships(xml: string): Map<string, string> {
  const result = new Map<string, string>();
  const scanner = new XmlScanner(xml);
  let token = scanner.next();
  while (token !== null) {
    const tag = token.tag;
    if (tag !== null && tag.name === 'relationship' && !tag.closing) {
      const identifier = tag.attr('Id');
      const target = tag.attr('Target');
      const mode = tag.attr('TargetMode');
      const external = mode.toLowerCase() === 'external' || target.toLowerCase().startsWith('http');
      if (identifier.length > 0 && target.length > 0 && !external) {
        result.set(identifier, target);
      }
    }
    token = scanner.next();
  }
  return result;
}

/** 读取 word/styles.xml：styleId -> 名称与大纲级别。 */
function parseStyles(xml: string): Map<string, DocxStyleInfo> {
  const result = new Map<string, DocxStyleInfo>();
  const scanner = new XmlScanner(xml);
  let token = scanner.next();
  let currentId = '';
  let currentType = '';
  let current: DocxStyleInfo | null = null;
  while (token !== null) {
    const tag = token.tag;
    if (tag !== null) {
      if (tag.name === 'style') {
        if (tag.closing) {
          if (current !== null && currentId.length > 0) {
            result.set(currentId, current);
          }
          currentId = '';
          currentType = '';
          current = null;
        } else {
          currentId = tag.attr('styleId');
          currentType = tag.attr('type');
          current = new DocxStyleInfo();
        }
      } else if (current !== null && !tag.closing) {
        if (tag.name === 'name' && currentType !== 'character') {
          current.name = tag.attr('val');
        } else if (tag.name === 'outlinelvl') {
          const value = parseInt(tag.attr('val'), 10);
          if (!isNaN(value)) {
            current.level = clampHeadingLevel(value + 1);
          }
        }
      }
    }
    token = scanner.next();
  }
  return result;
}

function clampHeadingLevel(level: number): number {
  if (level < 1) {
    return 1;
  }
  if (level > 6) {
    return 6;
  }
  return level;
}

/** 把 rels 中的相对 Target 归一化成 ZIP 内的完整路径。 */
function normalizeWordPath(target: string): string {
  let path = target.replace(/\\/g, '/');
  const query = path.indexOf('?');
  if (query >= 0) {
    path = path.substring(0, query);
  }
  const hash = path.indexOf('#');
  if (hash >= 0) {
    path = path.substring(0, hash);
  }
  if (path.startsWith('/')) {
    path = path.substring(1);
  } else if (!path.toLowerCase().startsWith('word/')) {
    path = 'word/' + path;
  }
  const parts = path.split('/');
  const resolved: string[] = [];
  for (let i = 0; i < parts.length; i++) {
    const part = parts[i];
    if (part.length === 0 || part === '.') {
      continue;
    }
    if (part === '..') {
      if (resolved.length > 0) {
        resolved.pop();
      }
      continue;
    }
    resolved.push(part);
  }
  return resolved.join('/');
}

function extensionOf(path: string): string {
  const slash = path.lastIndexOf('/');
  const name = slash >= 0 ? path.substring(slash + 1) : path;
  const dot = name.lastIndexOf('.');
  if (dot < 0) {
    return '';
  }
  const ext = name.substring(dot + 1).toLowerCase();
  return /^[a-z0-9]{1,5}$/.test(ext) ? ext : '';
}

class DocxDocumentParser {
  private zip: ZipArchive;
  private relationships: Map<string, string>;
  private styles: Map<string, DocxStyleInfo>;
  private book: RenderedBook;

  private body: string = '';
  private chapterTexts: string[] = [];
  private chapterLines: string[] = [];
  private chapterProgress: number[] = [];
  private paragraphCount: number = 0;
  private headingIndex: number = 0;
  private usedImages: Map<string, string> = new Map<string, string>();

  private inParagraph: boolean = false;
  private paragraphHtml: string = '';
  private paragraphPlain: string = '';
  private paragraphStyleLevel: number = 0;
  private paragraphOutlineLevel: number = 0;
  private paragraphImageRels: string[] = [];

  private inPPr: boolean = false;
  private inRPr: boolean = false;
  private inText: boolean = false;
  private inDrawing: boolean = false;
  private drawingHasImage: boolean = false;
  private drawingCx: number = 0;

  private runBold: boolean = false;
  private runItalic: boolean = false;
  private runUnderline: boolean = false;
  private runStrike: boolean = false;

  constructor(zip: ZipArchive, relationships: Map<string, string>,
    styles: Map<string, DocxStyleInfo>, book: RenderedBook) {
    this.zip = zip;
    this.relationships = relationships;
    this.styles = styles;
    this.book = book;
  }

  parse(source: string): void {
    const scanner = new XmlScanner(source);
    let token = scanner.next();
    while (token !== null) {
      const tag = token.tag;
      if (tag === null) {
        if (this.inText && this.inParagraph) {
          this.appendText(token.text);
        }
      } else {
        this.handleTag(tag);
      }
      token = scanner.next();
    }
  }

  private handleTag(tag: XmlTag): void {
    switch (tag.name) {
      case 'p':
        if (tag.closing) {
          this.finishParagraph();
          this.inParagraph = false;
        } else {
          if (this.inParagraph) {
            this.finishParagraph();
          }
          this.startParagraph();
          if (tag.selfClosing) {
            this.finishParagraph();
            this.inParagraph = false;
          }
        }
        return;
      case 'ppr':
        this.inPPr = !tag.closing && !tag.selfClosing;
        return;
      case 'pstyle':
        if (!tag.closing && this.inPPr) {
          this.paragraphStyleLevel = this.headingLevelForStyle(tag.attr('val'));
        }
        return;
      case 'outlinelvl':
        if (!tag.closing && this.inPPr) {
          const value = parseInt(tag.attr('val'), 10);
          if (!isNaN(value)) {
            this.paragraphOutlineLevel = clampHeadingLevel(value + 1);
          }
        }
        return;
      case 'tbl':
      case 'tr':
      case 'tc':
        // 表格内仍是普通段落，直接按文档顺序输出即可
        return;
      case 'r':
        if (!tag.closing) {
          this.runBold = false;
          this.runItalic = false;
          this.runUnderline = false;
          this.runStrike = false;
        }
        return;
      case 'rpr':
        this.inRPr = !tag.closing && !tag.selfClosing;
        return;
      case 'b':
        if (!tag.closing && this.inRPr) {
          this.runBold = this.booleanValue(tag);
        }
        return;
      case 'i':
        if (!tag.closing && this.inRPr) {
          this.runItalic = this.booleanValue(tag);
        }
        return;
      case 'u':
        if (!tag.closing && this.inRPr) {
          this.runUnderline = this.booleanValue(tag);
        }
        return;
      case 'strike':
      case 'dstrike':
        if (!tag.closing && this.inRPr) {
          this.runStrike = this.booleanValue(tag);
        }
        return;
      case 't':
        this.inText = !tag.closing && !tag.selfClosing;
        return;
      case 'tab':
        if (!tag.closing && this.inParagraph && !this.inPPr) {
          this.paragraphHtml += '&nbsp;&nbsp;&nbsp;&nbsp;';
          this.paragraphPlain += '\t';
        }
        return;
      case 'br':
      case 'cr':
        if (!tag.closing && this.inParagraph) {
          this.paragraphHtml += '<br/>';
          this.paragraphPlain += '\n';
        }
        return;
      case 'drawing':
        if (tag.closing) {
          this.inDrawing = false;
          this.drawingHasImage = false;
          this.drawingCx = 0;
        } else {
          this.inDrawing = true;
          this.drawingHasImage = false;
          this.drawingCx = 0;
        }
        return;
      case 'extent':
        if (!tag.closing && this.inDrawing) {
          const cx = parseInt(tag.attr('cx'), 10);
          if (!isNaN(cx) && cx > 0) {
            this.drawingCx = cx;
          }
        }
        return;
      case 'blip':
        if (!tag.closing && this.inParagraph) {
          if (this.inDrawing && this.drawingHasImage) {
            return;
          }
          const relation = tag.attr('embed').length > 0 ? tag.attr('embed') : tag.attr('id');
          this.appendImage(relation, false);
          if (this.inDrawing) {
            this.drawingHasImage = true;
          }
        }
        return;
      case 'imagedata':
        if (!tag.closing && this.inParagraph && !this.inDrawing) {
          // VML 回退图片，和 a:blip 指向同一关系时去重
          this.appendImage(tag.attr('id'), true);
        }
        return;
      default:
        return;
    }
  }

  private startParagraph(): void {
    this.inParagraph = true;
    this.paragraphHtml = '';
    this.paragraphPlain = '';
    this.paragraphStyleLevel = 0;
    this.paragraphOutlineLevel = 0;
    this.paragraphImageRels = [];
  }

  private appendText(raw: string): void {
    if (raw.length === 0) {
      return;
    }
    const decoded = HtmlText.decodeEntities(raw);
    let markup = HtmlText.escape(decoded);
    if (this.runStrike) {
      markup = '<s>' + markup + '</s>';
    }
    if (this.runUnderline) {
      markup = '<u>' + markup + '</u>';
    }
    if (this.runItalic) {
      markup = '<em>' + markup + '</em>';
    }
    if (this.runBold) {
      markup = '<strong>' + markup + '</strong>';
    }
    this.paragraphHtml += markup;
    this.paragraphPlain += decoded;
  }

  private appendImage(relation: string, dedupeInParagraph: boolean): void {
    if (relation.length === 0) {
      return;
    }
    if (dedupeInParagraph && this.paragraphImageRels.indexOf(relation) >= 0) {
      return;
    }
    const markup = this.imageMarkup(relation);
    if (markup.length === 0) {
      return;
    }
    this.paragraphImageRels.push(relation);
    this.paragraphHtml += markup;
  }

  private imageMarkup(relation: string): string {
    let assetPath = this.usedImages.get(relation);
    if (assetPath === undefined) {
      const target = this.relationships.get(relation);
      if (target === undefined) {
        return '';
      }
      const path = normalizeWordPath(target);
      const data = this.zip.read(path);
      if (data === null) {
        return '';
      }
      let ext = extensionOf(path);
      if (ext.length === 0) {
        ext = 'png';
      }
      assetPath = 'assets/docx-' + (this.usedImages.size + 1) + '.' + ext;
      HtmlText.addAsset(this.book.assets, assetPath, data);
      this.usedImages.set(relation, assetPath);
    }
    let style = 'max-width:100%;height:auto';
    if (this.drawingCx > 0) {
      const width = Math.round(this.drawingCx / 9525);
      if (width > 0) {
        style += ';width:' + width + 'px';
      }
    }
    return '<img class="docx-image" src="' + HtmlText.escapeAttr(assetPath) +
      '" style="' + style + '">';
  }

  private finishParagraph(): void {
    if (!this.inParagraph) {
      return;
    }
    const plain = this.paragraphPlain.trim();
    const markup = this.paragraphHtml.trim();
    const styleLevel = this.paragraphStyleLevel;
    const outlineLevel = this.paragraphOutlineLevel;
    this.paragraphHtml = '';
    this.paragraphPlain = '';
    this.paragraphStyleLevel = 0;
    this.paragraphOutlineLevel = 0;
    this.paragraphImageRels = [];
    if (plain.length === 0 && markup.length === 0) {
      return;
    }
    this.paragraphCount += 1;
    let level = styleLevel > 0 ? styleLevel : outlineLevel;
    let tocLevel = -1;
    if (level <= 0 && plain.length > 0 && HtmlText.isChapterHeading(plain)) {
      // A document without heading styles is split by plain-text titles. Keep
      // the visual h2 size, but use the title pattern to tell a volume divider
      // from an ordinary chapter so a collection can still collapse.
      level = 2;
      tocLevel = HtmlText.chapterHeadingLevel(plain);
    }
    if (level > 0 && plain.length > 0) {
      const clamped = clampHeadingLevel(level);
      this.headingIndex += 1;
      const anchor = 'docx-h-' + this.headingIndex;
      this.body += '<h' + clamped + ' id="' + anchor + '">' + markup + '</h' + clamped + '>';
      const link = new ChapterLink();
      link.title = HtmlText.truncate(plain, 80);
      link.progress = 0;
      link.anchorId = anchor;
      link.locatorText = HtmlText.truncate(plain, 60);
      link.level = tocLevel >= 0 ? tocLevel : clamped - 1;
      this.book.chapters.push(link);
      this.chapterProgress.push(this.paragraphCount);
      this.flushChapterText();
      this.chapterLines.push(plain);
    } else {
      this.body += '<p>' + markup + '</p>';
      if (plain.length > 0) {
        this.chapterLines.push(plain);
      }
    }
  }

  private flushChapterText(): void {
    if (this.chapterLines.length === 0) {
      return;
    }
    let text = '';
    for (let i = 0; i < this.chapterLines.length; i++) {
      if (i > 0) {
        text += '\n';
      }
      text += this.chapterLines[i];
    }
    if (text.trim().length > 0) {
      this.chapterTexts.push(text);
    }
    this.chapterLines = [];
  }

  /** 段落结束后写入 HTML、目录与文本模型，剩余段落也要收尾。 */
  finish(): void {
    this.finishParagraph();
    this.flushChapterText();
    this.book.html = this.body;
    this.book.textModel = HtmlText.buildTextModel(this.chapterTexts);
    for (let i = 0; i < this.book.chapters.length; i++) {
      this.book.chapters[i].progress = this.paragraphCount > 0
        ? this.chapterProgress[i] / this.paragraphCount
        : 0;
    }
  }

  private headingLevelForStyle(styleId: string): number {
    if (styleId.length === 0) {
      return 0;
    }
    const info = this.styles.get(styleId);
    const name = info !== undefined && info.name.length > 0 ? info.name : styleId;
    const lower = name.toLowerCase();
    if (lower === 'title') {
      return 1;
    }
    if (lower === 'subtitle') {
      return 2;
    }
    if (lower.indexOf('heading') >= 0 || lower.indexOf('标题') >= 0) {
      const digits = lower.replace(/[^0-9]/g, '');
      if (digits.length > 0) {
        return clampHeadingLevel(parseInt(digits, 10));
      }
      return info !== undefined && info.level > 0 ? info.level : 1;
    }
    return info !== undefined ? info.level : 0;
  }

  private booleanValue(tag: XmlTag): boolean {
    const value = tag.attr('val').toLowerCase();
    if (value.length === 0) {
      return true;
    }
    return value !== '0' && value !== 'false' && value !== 'none' && value !== 'off';
  }
}

export function renderDOCX(zip: ZipArchive): RenderedBook {
  const book = new RenderedBook();
  try {
    const documentBytes = zip.read('word/document.xml');
    if (documentBytes === null) {
      book.error = 'DOCX 缺少 word/document.xml';
      return book;
    }
    let relationships = new Map<string, string>();
    const relBytes = zip.read('word/_rels/document.xml.rels');
    if (relBytes !== null) {
      relationships = parseRelationships(TextCodec.decode(relBytes));
    }
    let styles = new Map<string, DocxStyleInfo>();
    const styleBytes = zip.read('word/styles.xml');
    if (styleBytes !== null) {
      styles = parseStyles(TextCodec.decode(styleBytes));
    }
    const parser = new DocxDocumentParser(zip, relationships, styles, book);
    parser.parse(TextCodec.decode(documentBytes));
    parser.finish();
  } catch {
    book.html = '';
    book.chapters = [];
    book.assets = [];
    book.textModel = null;
    book.error = 'DOCX 解析失败';
  }
  if (book.error.length === 0 && book.html.length === 0) {
    book.error = 'DOCX 正文为空';
  }
  return book;
}
