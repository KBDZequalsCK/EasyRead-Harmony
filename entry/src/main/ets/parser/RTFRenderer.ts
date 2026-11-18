import { ChapterLink, RenderedBook } from './BookTypes';
import { HtmlText } from './HtmlText';
import { TextCodec } from './Bytes';

/**
 * RTF 阅读器移植自 Mac 版 RTFRenderer.swift。
 * RTF 是分组（{}）与控制字（\word）组成的流，这里只保留阅读所需内容：
 * 段落、粗体/斜体/下划线/删除线、章节标题；表格、图片、域按纯文本处理。
 */

/** 单个文本片段的样式。 */
class RtfRunStyle {
  bold: boolean = false;
  italic: boolean = false;
  underline: boolean = false;
  strike: boolean = false;
  /** 半磅值，0 表示未显式设置。 */
  fontSize: number = 0;
}

class RtfRun {
  text: string = '';
  style: RtfRunStyle = new RtfRunStyle();
}

/** 解析状态，遇到 { 时整体入栈，遇到 } 时恢复。 */
class RtfState {
  bold: boolean = false;
  italic: boolean = false;
  underline: boolean = false;
  strike: boolean = false;
  fontSize: number = 0;
  /** 当前分组是否是需要跳过的目标（字体表、图片等）。 */
  skipped: boolean = false;
  /** \ucN 指定 \uN 之后需要跳过的回退字符数。 */
  ucSkip: number = 1;

  clone(): RtfState {
    const copy = new RtfState();
    copy.bold = this.bold;
    copy.italic = this.italic;
    copy.underline = this.underline;
    copy.strike = this.strike;
    copy.fontSize = this.fontSize;
    copy.skipped = this.skipped;
    copy.ucSkip = this.ucSkip;
    return copy;
  }
}

class RtfParser {
  private bytes: Uint8Array;
  private index: number = 0;
  private state: RtfState = new RtfState();
  private stack: RtfState[] = [];
  private codePage: number = 1252;
  private pendingBytes: number[] = [];
  private skipRemaining: number = 0;

  private html: string = '';
  private paragraphRuns: RtfRun[] = [];
  private paragraphPlain: string = '';
  private chapterTexts: string[] = [];
  private chapterLines: string[] = [];
  private chapterLinks: ChapterLink[] = [];
  private chapterProgress: number[] = [];
  private paragraphCount: number = 0;

  constructor(bytes: Uint8Array) {
    this.bytes = bytes;
  }

  render(book: RenderedBook): void {
    while (this.index < this.bytes.length) {
      const byte = this.bytes[this.index];
      if (byte === 0x7B) {
        // {
        this.stack.push(this.state.clone());
        this.skipRemaining = 0;
        this.index += 1;
        continue;
      }
      if (byte === 0x7D) {
        // }
        this.flushPending();
        this.skipRemaining = 0;
        const previous = this.stack.pop();
        if (previous !== undefined) {
          this.state = previous;
        }
        this.index += 1;
        continue;
      }
      if (byte === 0x5C) {
        // 反斜杠，进入控制字解析
        this.index += 1;
        this.parseControl();
        continue;
      }
      if (byte === 0x0D || byte === 0x0A) {
        // RTF 源文件自身的换行不是正文
        this.index += 1;
        continue;
      }
      if (this.state.skipped) {
        this.index += 1;
        continue;
      }
      if (this.skipRemaining > 0) {
        this.skipRemaining -= 1;
        this.index += 1;
        continue;
      }
      if (byte >= 0x80) {
        // 正文里直接出现的高位字节同样属于当前代码页，和 \'hh 一起解码
        this.pendingBytes.push(byte);
        this.index += 1;
        continue;
      }
      this.flushPending();
      this.appendText(String.fromCharCode(byte));
      this.index += 1;
    }
    this.flushPending();
    this.finishParagraph();
    this.flushChapterText();

    book.html = this.html;
    book.chapters = this.chapterLinks;
    book.textModel = HtmlText.buildTextModel(this.chapterTexts);
    for (let i = 0; i < this.chapterLinks.length; i++) {
      this.chapterLinks[i].progress = this.paragraphCount > 0
        ? this.chapterProgress[i] / this.paragraphCount
        : 0;
    }
    if (this.html.length === 0) {
      book.error = 'RTF 内容为空或无法识别';
    }
  }

  private parseControl(): void {
    if (this.index >= this.bytes.length) {
      return;
    }
    const byte = this.bytes[this.index];

    // 除 \'hh 外，控制字出现说明上一个 \uN 后面没有回退字符
    if (byte !== 0x27) {
      this.skipRemaining = 0;
    }

    // \'hh：十六进制字节，先累积，随后按代码页整体解码
    if (byte === 0x27) {
      if (this.skipRemaining > 0) {
        this.skipRemaining -= 1;
        this.index += 3;
        return;
      }
      if (this.index + 2 >= this.bytes.length) {
        this.index += 1;
        return;
      }
      const high = this.hexValue(this.bytes[this.index + 1]);
      const low = this.hexValue(this.bytes[this.index + 2]);
      if (high < 0 || low < 0) {
        this.index += 1;
        return;
      }
      this.pendingBytes.push((high << 4) | low);
      this.index += 3;
      return;
    }

    // \{ \} \\ 等转义符号
    if (byte === 0x5C || byte === 0x7B || byte === 0x7D) {
      this.flushPending();
      if (!this.state.skipped) {
        this.appendText(String.fromCharCode(byte));
      }
      this.index += 1;
      return;
    }

    // \* 标记可忽略的目标组
    if (byte === 0x2A) {
      this.flushPending();
      this.state.skipped = true;
      this.index += 1;
      return;
    }

    // 控制字：字母 + 可选负号与数字 + 可选空格分隔符
    let cursor = this.index;
    let word = '';
    while (cursor < this.bytes.length) {
      const value = this.bytes[cursor];
      const isUpper = value >= 0x41 && value <= 0x5A;
      const isLower = value >= 0x61 && value <= 0x7A;
      if (!isUpper && !isLower) {
        break;
      }
      word += String.fromCharCode(value);
      cursor += 1;
    }
    if (word.length === 0) {
      // 未知控制符号（如 \~），跳过反斜杠后的这一个字符
      this.index += 1;
      return;
    }

    let hasParameter = false;
    let parameter = 0;
    let sign = 1;
    if (cursor < this.bytes.length && this.bytes[cursor] === 0x2D) {
      sign = -1;
      cursor += 1;
    }
    let digits = '';
    while (cursor < this.bytes.length && this.bytes[cursor] >= 0x30 && this.bytes[cursor] <= 0x39) {
      digits += String.fromCharCode(this.bytes[cursor]);
      cursor += 1;
    }
    if (digits.length > 0) {
      hasParameter = true;
      parameter = parseInt(digits, 10) * sign;
    }
    if (cursor < this.bytes.length && this.bytes[cursor] === 0x20) {
      cursor += 1;
    }
    this.index = cursor;

    const lower = word.toLowerCase();
    if (lower === 'ansicpg' && hasParameter) {
      this.codePage = parameter;
      return;
    }
    if (lower === 'uc' && hasParameter) {
      this.state.ucSkip = parameter >= 0 ? parameter : 1;
      return;
    }
    if (this.state.skipped) {
      return;
    }

    switch (lower) {
      case 'par':
      case 'pard':
        this.finishParagraph();
        return;
      case 'line':
        this.appendText('\n');
        return;
      case 'tab':
        this.appendText('\t');
        return;
      case 'b':
        this.state.bold = hasParameter ? parameter !== 0 : true;
        return;
      case 'i':
        this.state.italic = hasParameter ? parameter !== 0 : true;
        return;
      case 'ul':
        this.state.underline = hasParameter ? parameter !== 0 : true;
        return;
      case 'ulnone':
        this.state.underline = false;
        return;
      case 'strike':
        this.state.strike = hasParameter ? parameter !== 0 : true;
        return;
      case 'plain':
        this.state.bold = false;
        this.state.italic = false;
        this.state.underline = false;
        this.state.strike = false;
        this.state.fontSize = 0;
        return;
      case 'fs':
        this.state.fontSize = hasParameter ? parameter : 0;
        return;
      case 'u':
        this.flushPending();
        if (hasParameter) {
          const value = parameter < 0 ? parameter + 65536 : parameter;
          if (value >= 0 && value <= 0x10FFFF) {
            this.appendText(String.fromCodePoint(value));
          }
          this.skipRemaining = this.state.ucSkip;
        }
        return;
      case 'bin':
        if (hasParameter && parameter > 0) {
          this.index = Math.min(this.index + parameter, this.bytes.length);
        }
        return;
      default:
        break;
    }

    if (this.isSkippedDestination(lower)) {
      this.state.skipped = true;
    }
  }

  /** 这些目标组只包含字体、颜色、图片等元数据，不能进入正文。 */
  private isSkippedDestination(word: string): boolean {
    if (word === 'fonttbl' || word === 'colortbl' || word === 'stylesheet') {
      return true;
    }
    if (word === 'info' || word === 'pict' || word === 'object') {
      return true;
    }
    if (word === 'header' || word === 'headerl' || word === 'headerr' || word === 'headerf') {
      return true;
    }
    if (word === 'footer' || word === 'footerl' || word === 'footerr' || word === 'footerf') {
      return true;
    }
    if (word === 'footnote' || word === 'annotation' || word === 'generator') {
      return true;
    }
    if (word === 'listtable' || word === 'listoverridetable' || word === 'listtext') {
      return true;
    }
    if (word === 'themedata' || word === 'datastore' || word === 'rsidtbl' || word === 'xmlnstbl') {
      return true;
    }
    if (word === 'filetbl' || word === 'revtbl' || word === 'latentstyles' || word === 'upr') {
      return true;
    }
    return false;
  }

  private appendText(text: string): void {
    if (this.state.skipped || text.length === 0) {
      return;
    }
    this.paragraphPlain += text;
    const style = new RtfRunStyle();
    style.bold = this.state.bold;
    style.italic = this.state.italic;
    style.underline = this.state.underline;
    style.strike = this.state.strike;
    style.fontSize = this.state.fontSize;
    const last = this.paragraphRuns.length > 0 ? this.paragraphRuns[this.paragraphRuns.length - 1] : null;
    if (last !== null && this.sameStyle(last.style, style)) {
      last.text += text;
    } else {
      const run = new RtfRun();
      run.text = text;
      run.style = style;
      this.paragraphRuns.push(run);
    }
  }

  private sameStyle(left: RtfRunStyle, right: RtfRunStyle): boolean {
    return left.bold === right.bold && left.italic === right.italic &&
      left.underline === right.underline && left.strike === right.strike &&
      left.fontSize === right.fontSize;
  }

  private flushPending(): void {
    if (this.pendingBytes.length === 0) {
      return;
    }
    const bytes = new Uint8Array(this.pendingBytes.length);
    for (let i = 0; i < this.pendingBytes.length; i++) {
      bytes[i] = this.pendingBytes[i];
    }
    this.pendingBytes = [];
    this.appendText(this.decodeBytes(bytes));
  }

  /** 936 等代码页优先走注入的外部解码器，未注入时回退到 UTF-8。 */
  private decodeBytes(bytes: Uint8Array): string {
    if (this.codePage === 65001) {
      return TextCodec.decodeUtf8(bytes);
    }
    if (this.codePage === 936 || this.codePage === 950) {
      if (TextCodec.externalDecoder !== null) {
        const encoding = this.codePage === 936 ? 'gbk' : 'big5';
        return TextCodec.externalDecoder(bytes, encoding);
      }
      return this.codePage === 936 ? TextCodec.decodeUtf8(bytes) : TextCodec.decodeLatin1(bytes);
    }
    return TextCodec.decodeLatin1(bytes);
  }

  private finishParagraph(): void {
    this.flushPending();
    const plain = this.paragraphPlain.trim();
    const markup = this.buildMarkup().trim();
    this.paragraphRuns = [];
    this.paragraphPlain = '';
    if (plain.length === 0 && markup.length === 0) {
      return;
    }
    this.paragraphCount += 1;
    if (plain.length > 0 && HtmlText.isChapterHeading(plain)) {
      const anchor = 'rtf-h-' + (this.chapterLinks.length + 1);
      this.html += '<h2 id="' + anchor + '">' + markup + '</h2>';
      const link = new ChapterLink();
      link.title = HtmlText.truncate(plain, 80);
      link.progress = 0;
      link.anchorId = anchor;
      link.locatorText = HtmlText.truncate(plain, 60);
      link.level = HtmlText.chapterHeadingLevel(plain);
      this.chapterLinks.push(link);
      this.chapterProgress.push(this.paragraphCount);
      // 标题另起一章，正文按标题切分，便于进度定位
      this.flushChapterText();
      this.chapterLines.push(plain);
    } else {
      this.html += '<p>' + markup + '</p>';
      if (plain.length > 0) {
        this.chapterLines.push(plain);
      }
    }
  }

  /** 把已累积的段落纯文本收束为一章，供 textModel 使用。 */
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

  private buildMarkup(): string {
    let result = '';
    for (let i = 0; i < this.paragraphRuns.length; i++) {
      const run = this.paragraphRuns[i];
      let text = HtmlText.escape(run.text);
      text = text.split('\n').join('<br/>');
      text = text.split('\t').join('&nbsp;&nbsp;&nbsp;&nbsp;');
      if (run.style.strike) {
        text = '<s>' + text + '</s>';
      }
      if (run.style.underline) {
        text = '<u>' + text + '</u>';
      }
      if (run.style.italic) {
        text = '<em>' + text + '</em>';
      }
      if (run.style.bold) {
        text = '<strong>' + text + '</strong>';
      }
      if (run.style.fontSize > 0) {
        text = '<span style="font-size:' + RtfParser.pointSize(run.style.fontSize) + 'pt">' + text + '</span>';
      }
      result += text;
    }
    return result;
  }

  private static pointSize(halfPoints: number): string {
    const points = halfPoints / 2;
    if (Math.abs(points - Math.round(points)) < 0.01) {
      return String(Math.round(points));
    }
    return points.toFixed(1);
  }

  private hexValue(byte: number): number {
    if (byte >= 0x30 && byte <= 0x39) {
      return byte - 0x30;
    }
    if (byte >= 0x41 && byte <= 0x46) {
      return byte - 0x41 + 10;
    }
    if (byte >= 0x61 && byte <= 0x66) {
      return byte - 0x61 + 10;
    }
    return -1;
  }
}

export function renderRTF(bytes: Uint8Array): RenderedBook {
  const book = new RenderedBook();
  if (bytes.length === 0) {
    book.error = 'RTF 文件为空';
    return book;
  }
  try {
    const parser = new RtfParser(bytes);
    parser.render(book);
  } catch {
    book.html = '';
    book.chapters = [];
    book.textModel = null;
    book.error = 'RTF 解析失败';
  }
  return book;
}
