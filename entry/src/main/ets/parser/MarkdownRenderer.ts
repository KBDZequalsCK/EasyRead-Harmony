import { AssetBlob, ChapterLink, RenderedBook } from './BookTypes';
import { HtmlText } from './HtmlText';

/** 段内硬换行占位符，行内处理结束后替换为 <br>。 */
const HARD_BREAK = '\uE00F';
const TOKEN_OPEN = '\uE000';
const TOKEN_CLOSE = '\uE001';

/** 目录项：标题文本、锚点、级别以及标题在全文中的近似字符比例。 */
class MarkdownHeading {
  title: string = '';
  identifier: string = '';
  level: number = 1;
  progress: number = 0;
}

/** 一组待渲染的行，以及每行在原文中的起始字符位置。 */
class BlockLines {
  lines: string[] = [];
  offsets: number[] = [];

  constructor(lines: string[], offsets: number[]) {
    this.lines = lines;
    this.offsets = offsets;
  }

  offsetAt(index: number): number {
    if (index < 0 || index >= this.offsets.length) {
      return 0;
    }
    return this.offsets[index];
  }
}

class HeadingMatch {
  level: number = 1;
  text: string = '';
}

class FenceInfo {
  character: string = '`';
  length: number = 3;
  info: string = '';
}

class ListMarker {
  indent: number = 0;
  ordered: boolean = false;
  start: number = 1;
  content: string = '';
  contentIndent: number = 0;
}

class ListResult {
  html: string = '';
  next: number = 0;
}

class TableInfo {
  headers: string[] = [];
  alignments: string[] = [];
  rows: string[][] = [];
  next: number = 0;
}

class TaskInfo {
  checked: boolean = false;
  content: string = '';
}

class Destination {
  url: string = '';
  title: string | null = null;
}

/** 图片解析：成功读取时生成 assets 条目，失败时保留原始相对路径。 */
class ImageStore {
  private loader: ((relativePath: string) => Uint8Array | null) | null = null;
  private assets: AssetBlob[] = [];
  private sequence: number = 0;

  constructor(loader: ((relativePath: string) => Uint8Array | null) | null) {
    this.loader = loader;
  }

  getAssets(): AssetBlob[] {
    return this.assets;
  }

  /**
   * 返回可写入 img src 的路径；无法读取本地图片时返回 null，
   * 由调用方回退到原始相对路径。
   */
  resolve(source: string): string | null {
    if (this.loader === null || source.length === 0) {
      return null;
    }
    const lower = source.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://') || lower.startsWith('data:')) {
      return null;
    }
    let path = source;
    if (lower.startsWith('file://')) {
      path = source.substring(7);
    }
    const bytes = this.loader(path);
    if (bytes === null || bytes.length === 0) {
      return null;
    }
    const extension = ImageStore.extensionOf(path);
    const assetPath = 'assets/md-' + this.sequence + '.' + extension;
    this.sequence += 1;
    const asset = new AssetBlob();
    asset.path = assetPath;
    asset.bytes = bytes;
    asset.mime = HtmlText.guessMime(assetPath);
    this.assets.push(asset);
    return assetPath;
  }

  private static extensionOf(path: string): string {
    let value = path;
    const query = value.indexOf('?');
    if (query >= 0) {
      value = value.substring(0, query);
    }
    const hash = value.indexOf('#');
    if (hash >= 0) {
      value = value.substring(0, hash);
    }
    const dot = value.lastIndexOf('.');
    if (dot < 0 || dot === value.length - 1) {
      return 'bin';
    }
    const raw = value.substring(dot + 1).toLowerCase();
    let cleaned = '';
    for (let i = 0; i < raw.length; i++) {
      const ch = raw.charAt(i);
      if ((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')) {
        cleaned += ch;
      }
    }
    return cleaned.length > 0 ? cleaned : 'bin';
  }
}

export function renderMarkdown(
  source: string,
  imageLoader: ((relativePath: string) => Uint8Array | null) | null
): RenderedBook {
  const book = new RenderedBook();
  const store = new ImageStore(imageLoader);
  const builder = new MarkdownBuilder(store);
  book.html = builder.render(source);
  book.textModel = null;
  book.assets = store.getAssets();
  const headings = builder.getHeadings();
  for (let i = 0; i < headings.length; i++) {
    const heading = headings[i];
    const link = new ChapterLink();
    link.title = heading.title;
    link.anchorId = heading.identifier;
    link.level = heading.level;
    link.progress = heading.progress;
    link.locatorText = '';
    book.chapters.push(link);
  }
  return book;
}

class MarkdownBuilder {
  private store: ImageStore;
  private headings: MarkdownHeading[] = [];
  private headingCount: number = 0;
  private totalLength: number = 1;

  constructor(store: ImageStore) {
    this.store = store;
  }

  getHeadings(): MarkdownHeading[] {
    return this.headings;
  }

  render(source: string): string {
    const normalized = HtmlText.normalizeNewlines(source);
    const allLines = normalized.split('\n');
    const lines = MarkdownBuilder.stripFrontMatter(allLines);
    const offsets: number[] = [];
    let cursor = 0;
    for (let i = 0; i < lines.length; i++) {
      offsets.push(cursor);
      cursor += lines[i].length + 1;
    }
    this.totalLength = Math.max(1, cursor);
    return this.renderBlocks(new BlockLines(lines, offsets), false);
  }

  private renderBlocks(block: BlockLines, tight: boolean): string {
    const lines = block.lines;
    const output: string[] = [];
    let index = 0;

    while (index < lines.length) {
      const line = lines[index];
      if (line.trim().length === 0) {
        index += 1;
        continue;
      }

      const fence = MarkdownBuilder.fenceStart(line);
      if (fence !== null) {
        const codeLines: string[] = [];
        let cursor = index + 1;
        while (cursor < lines.length) {
          if (MarkdownBuilder.isFenceClose(lines[cursor], fence)) {
            cursor += 1;
            break;
          }
          codeLines.push(lines[cursor]);
          cursor += 1;
        }
        output.push(MarkdownBuilder.codeBlockHTML(codeLines.join('\n'), fence.info));
        index = cursor;
        continue;
      }

      if (MarkdownBuilder.isIndentedCode(line)) {
        const codeLines: string[] = [];
        let cursor = index;
        while (cursor < lines.length) {
          const candidate = lines[cursor];
          if (candidate.trim().length === 0) {
            codeLines.push('');
            cursor += 1;
            continue;
          }
          if (!MarkdownBuilder.isIndentedCode(candidate)) {
            break;
          }
          codeLines.push(MarkdownBuilder.stripIndent(candidate, 4));
          cursor += 1;
        }
        while (codeLines.length > 0 && codeLines[codeLines.length - 1].length === 0) {
          codeLines.pop();
        }
        output.push(MarkdownBuilder.codeBlockHTML(codeLines.join('\n'), ''));
        index = cursor;
        continue;
      }

      const heading = MarkdownBuilder.heading(line);
      if (heading !== null) {
        output.push(this.headingHTML(heading.level, heading.text, block.offsetAt(index)));
        index += 1;
        continue;
      }

      if (MarkdownBuilder.isThematicBreak(line)) {
        output.push('<hr>');
        index += 1;
        continue;
      }

      if (MarkdownBuilder.blockquoteContent(line) !== null) {
        const quoteLines: string[] = [];
        const quoteOffsets: number[] = [];
        let cursor = index;
        while (cursor < lines.length) {
          const content = MarkdownBuilder.blockquoteContent(lines[cursor]);
          if (content !== null) {
            quoteLines.push(content);
            quoteOffsets.push(block.offsetAt(cursor));
            cursor += 1;
            continue;
          }
          if (lines[cursor].trim().length === 0) {
            let next = cursor + 1;
            while (next < lines.length && lines[next].trim().length === 0) {
              next += 1;
            }
            if (next < lines.length && MarkdownBuilder.blockquoteContent(lines[next]) !== null) {
              quoteLines.push('');
              quoteOffsets.push(block.offsetAt(next));
              cursor += 1;
              continue;
            }
          }
          break;
        }
        const inner = this.renderBlocks(new BlockLines(quoteLines, quoteOffsets), false);
        output.push('<blockquote>\n' + inner + '\n</blockquote>');
        index = cursor;
        continue;
      }

      if (MarkdownBuilder.listMarker(line) !== null) {
        const result = this.renderList(block, index);
        output.push(result.html);
        index = result.next;
        continue;
      }

      const table = this.tableDescriptor(block, index);
      if (table !== null) {
        output.push(this.tableHTML(table));
        index = table.next;
        continue;
      }

      const paragraphLines: string[] = [];
      const paragraphOffsets: number[] = [];
      let setextLevel: number = 0;
      const paragraphStart = index;
      while (index < lines.length) {
        const candidate = lines[index];
        if (candidate.trim().length === 0) {
          break;
        }
        if (paragraphLines.length > 0) {
          const level = MarkdownBuilder.setextUnderlineLevel(candidate);
          if (level > 0) {
            setextLevel = level;
            index += 1;
            break;
          }
          if (this.beginsBlock(block, index)) {
            break;
          }
        }
        paragraphLines.push(candidate);
        paragraphOffsets.push(block.offsetAt(index));
        index += 1;
      }

      if (setextLevel > 0 && paragraphLines.length > 0) {
        const text = this.joinedParagraph(paragraphLines);
        output.push(this.headingHTML(setextLevel, text, block.offsetAt(paragraphStart)));
      } else if (paragraphLines.length > 0) {
        output.push(this.paragraphHTML(paragraphLines, tight));
      }
    }

    return output.join('\n');
  }

  // MARK: - 块级输出

  private paragraphHTML(lines: string[], tight: boolean): string {
    const text = this.joinedParagraph(lines);
    const inline = new InlineRenderer(this.store).render(text);
    return tight ? inline : '<p>' + inline + '</p>';
  }

  private headingHTML(level: number, text: string, offset: number): string {
    const identifier = 'md-h-' + this.headingCount;
    this.headingCount += 1;
    const heading = new MarkdownHeading();
    heading.title = MarkdownBuilder.plainHeadingTitle(text);
    heading.identifier = identifier;
    heading.level = level;
    heading.progress = this.totalLength > 0 ? offset / this.totalLength : 0;
    this.headings.push(heading);
    const inline = new InlineRenderer(this.store).render(text);
    return '<h' + level + ' id="' + identifier + '">' + inline + '</h' + level + '>';
  }

  private static codeBlockHTML(code: string, info: string): string {
    let className = '';
    const parts = info.split(/[ \t]+/);
    if (parts.length > 0 && parts[0].length > 0) {
      const language = parts[0];
      let allowed = '';
      for (let i = 0; i < language.length; i++) {
        const ch = language.charAt(i);
        const code = language.charCodeAt(i);
        const isLetter = (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
        const isDigit = code >= 48 && code <= 57;
        if (isLetter || isDigit || '-_+#.'.indexOf(ch) >= 0) {
          allowed += ch;
        }
      }
      if (allowed.length > 0) {
        className = ' class="language-' + allowed + '"';
      }
    }
    return '<pre><code' + className + '>' + HtmlText.escape(code) + '</code></pre>';
  }

  private joinedParagraph(lines: string[]): string {
    let result = '';
    let previousWasHardBreak = false;
    for (let i = 0; i < lines.length; i++) {
      const rawLine = lines[i];
      const trimmedLine = rawLine.trim();
      const hardBreak = rawLine.endsWith('  ') || trimmedLine.endsWith('\\');
      let content = trimmedLine;
      if (content.endsWith('\\')) {
        content = content.substring(0, content.length - 1);
      }
      if (i > 0 && !previousWasHardBreak) {
        result += MarkdownBuilder.softSeparator(result, content);
      }
      result += content;
      if (hardBreak) {
        result += HARD_BREAK;
      }
      previousWasHardBreak = hardBreak;
    }
    return result;
  }

  /** 中文之间不插空格，避免换行在段内产生空隙。 */
  private static softSeparator(previous: string, next: string): string {
    if (previous.length === 0 || next.length === 0) {
      return '';
    }
    const last = previous.charCodeAt(previous.length - 1);
    const first = next.charCodeAt(0);
    return MarkdownBuilder.isCJK(last) && MarkdownBuilder.isCJK(first) ? '' : ' ';
  }

  private static isCJK(code: number): boolean {
    return (code >= 0x2E80 && code <= 0x9FFF) ||
      (code >= 0xF900 && code <= 0xFAFF) ||
      (code >= 0xFE30 && code <= 0xFE4F) ||
      (code >= 0xFF00 && code <= 0xFFEF);
  }

  private static heading(line: string): HeadingMatch | null {
    const indent = MarkdownBuilder.leadingColumns(line);
    if (indent >= 4) {
      return null;
    }
    const content = MarkdownBuilder.stripIndent(line, indent);
    let hashes = 0;
    while (hashes < content.length && content.charAt(hashes) === '#') {
      hashes += 1;
    }
    if (hashes < 1 || hashes > 6 || hashes >= content.length) {
      return null;
    }
    const separator = content.charAt(hashes);
    if (separator !== ' ' && separator !== '\t') {
      return null;
    }
    let text = content.substring(hashes).trim();
    if (text.endsWith('#')) {
      let candidate = text;
      while (candidate.endsWith('#')) {
        candidate = candidate.substring(0, candidate.length - 1);
      }
      if (candidate.length === 0) {
        text = '';
      } else {
        const last = candidate.charAt(candidate.length - 1);
        if (last === ' ' || last === '\t') {
          text = candidate.trim();
        }
      }
    }
    const match = new HeadingMatch();
    match.level = hashes;
    match.text = text;
    return match;
  }

  private static setextUnderlineLevel(line: string): number {
    const trimmed = line.trim();
    if (trimmed.length === 0) {
      return 0;
    }
    let allEquals = true;
    let allDashes = true;
    for (let i = 0; i < trimmed.length; i++) {
      const ch = trimmed.charAt(i);
      if (ch !== '=') {
        allEquals = false;
      }
      if (ch !== '-') {
        allDashes = false;
      }
    }
    if (allEquals) {
      return 1;
    }
    if (allDashes) {
      return 2;
    }
    return 0;
  }

  private static isThematicBreak(line: string): boolean {
    const trimmed = line.trim();
    let characters = '';
    for (let i = 0; i < trimmed.length; i++) {
      const ch = trimmed.charAt(i);
      if (ch !== ' ' && ch !== '\t') {
        characters += ch;
      }
    }
    if (characters.length < 3) {
      return false;
    }
    const first = characters.charAt(0);
    if ('*_-'.indexOf(first) < 0) {
      return false;
    }
    for (let i = 1; i < characters.length; i++) {
      if (characters.charAt(i) !== first) {
        return false;
      }
    }
    return true;
  }

  private static fenceStart(line: string): FenceInfo | null {
    const indent = MarkdownBuilder.leadingColumns(line);
    if (indent >= 4) {
      return null;
    }
    const content = MarkdownBuilder.stripIndent(line, indent);
    if (content.length === 0) {
      return null;
    }
    const first = content.charAt(0);
    if (first !== '`' && first !== '~') {
      return null;
    }
    let run = 0;
    while (run < content.length && content.charAt(run) === first) {
      run += 1;
    }
    if (run < 3) {
      return null;
    }
    const info = content.substring(run).trim();
    if (first === '`' && info.indexOf('`') >= 0) {
      return null;
    }
    const fence = new FenceInfo();
    fence.character = first;
    fence.length = run;
    fence.info = info;
    return fence;
  }

  private static isFenceClose(line: string, fence: FenceInfo): boolean {
    const indent = MarkdownBuilder.leadingColumns(line);
    if (indent >= 4) {
      return false;
    }
    const trimmed = MarkdownBuilder.stripIndent(line, indent).trim();
    if (trimmed.length < fence.length) {
      return false;
    }
    for (let i = 0; i < trimmed.length; i++) {
      if (trimmed.charAt(i) !== fence.character) {
        return false;
      }
    }
    return true;
  }

  private static isIndentedCode(line: string): boolean {
    return line.startsWith('    ') || line.startsWith('\t');
  }

  private static blockquoteContent(line: string): string | null {
    const indent = MarkdownBuilder.leadingColumns(line);
    if (indent >= 4) {
      return null;
    }
    let content = MarkdownBuilder.stripIndent(line, indent);
    if (content.length === 0 || content.charAt(0) !== '>') {
      return null;
    }
    content = content.substring(1);
    if (content.startsWith(' ')) {
      content = content.substring(1);
    }
    return content;
  }

  private beginsBlock(block: BlockLines, index: number): boolean {
    const line = block.lines[index];
    if (line.trim().length === 0) {
      return true;
    }
    if (MarkdownBuilder.fenceStart(line) !== null) {
      return true;
    }
    if (MarkdownBuilder.heading(line) !== null) {
      return true;
    }
    if (MarkdownBuilder.blockquoteContent(line) !== null) {
      return true;
    }
    if (MarkdownBuilder.listMarker(line) !== null) {
      return true;
    }
    if (MarkdownBuilder.isThematicBreak(line)) {
      return true;
    }
    if (this.tableDescriptor(block, index) !== null) {
      return true;
    }
    return false;
  }

  // MARK: - 列表

  private static listMarker(line: string): ListMarker | null {
    const indent = MarkdownBuilder.leadingColumns(line);
    const content = MarkdownBuilder.stripIndent(line, indent);
    if (content.length === 0) {
      return null;
    }

    let markerWidth = 0;
    let ordered = false;
    let start = 1;

    const first = content.charAt(0);
    if ('-+*'.indexOf(first) >= 0) {
      if (content.length < 2) {
        return null;
      }
      const after = content.charAt(1);
      if (after !== ' ' && after !== '\t') {
        return null;
      }
      markerWidth = 1;
    } else {
      let digits = 0;
      while (digits < content.length) {
        const ch = content.charAt(digits);
        if (ch < '0' || ch > '9') {
          break;
        }
        digits += 1;
      }
      if (digits === 0 || digits > 9 || digits >= content.length) {
        return null;
      }
      const separator = content.charAt(digits);
      if (separator !== '.' && separator !== ')') {
        return null;
      }
      if (digits + 1 >= content.length) {
        return null;
      }
      const afterMarker = content.charAt(digits + 1);
      if (afterMarker !== ' ' && afterMarker !== '\t') {
        return null;
      }
      ordered = true;
      const parsedStart = parseInt(content.substring(0, digits), 10);
      start = parsedStart > 0 ? parsedStart : 1;
      markerWidth = digits + 1;
    }

    let contentStart = markerWidth;
    let whitespaceColumns = 0;
    while (contentStart < content.length) {
      const ch = content.charAt(contentStart);
      if (ch === ' ') {
        whitespaceColumns += 1;
      } else if (ch === '\t') {
        whitespaceColumns += 4;
      } else {
        break;
      }
      contentStart += 1;
    }

    const marker = new ListMarker();
    marker.indent = indent;
    marker.ordered = ordered;
    marker.start = start;
    marker.content = content.substring(contentStart);
    marker.contentIndent = indent + markerWidth + whitespaceColumns;
    return marker;
  }

  private renderList(block: BlockLines, startIndex: number): ListResult {
    const lines = block.lines;
    const result = new ListResult();
    const first = MarkdownBuilder.listMarker(lines[startIndex]);
    if (first === null) {
      result.html = '';
      result.next = startIndex;
      return result;
    }
    const baseIndent = first.indent;
    const ordered = first.ordered;
    const contentIndent = Math.max(first.contentIndent, baseIndent + 2);
    const items: string[][] = [];
    const itemOffsets: number[][] = [];
    let current: string[] = [];
    let currentOffsets: number[] = [];
    let started = false;
    let cursor = startIndex;

    while (cursor < lines.length) {
      const line = lines[cursor];
      if (line.trim().length === 0) {
        let next = cursor + 1;
        while (next < lines.length && lines[next].trim().length === 0) {
          next += 1;
        }
        if (next >= lines.length) {
          break;
        }
        const nextMarker = MarkdownBuilder.listMarker(lines[next]);
        const nextIndent = MarkdownBuilder.leadingColumns(lines[next]);
        const continues = (nextIndent > baseIndent) ||
          (nextMarker !== null && nextMarker.indent === baseIndent && nextMarker.ordered === ordered);
        if (continues) {
          cursor += 1;
          continue;
        }
        break;
      }

      const marker = MarkdownBuilder.listMarker(line);
      if (marker !== null) {
        if (marker.indent === baseIndent) {
          if (marker.ordered !== ordered) {
            break;
          }
          if (started) {
            items.push(current);
            itemOffsets.push(currentOffsets);
          }
          current = [marker.content];
          currentOffsets = [block.offsetAt(cursor)];
          started = true;
          cursor += 1;
          continue;
        }
        if (marker.indent > baseIndent) {
          current.push(MarkdownBuilder.stripIndent(line, Math.min(marker.indent, contentIndent)));
          currentOffsets.push(block.offsetAt(cursor));
          cursor += 1;
          continue;
        }
        break;
      }

      const indent = MarkdownBuilder.leadingColumns(line);
      if (indent > baseIndent) {
        current.push(MarkdownBuilder.stripIndent(line, Math.min(indent, contentIndent)));
        currentOffsets.push(block.offsetAt(cursor));
        cursor += 1;
        continue;
      }

      if (this.beginsBlock(block, cursor)) {
        break;
      }

      current.push(line.trim());
      currentOffsets.push(block.offsetAt(cursor));
      cursor += 1;
    }

    if (started) {
      items.push(current);
      itemOffsets.push(currentOffsets);
    }
    result.next = cursor;

    let hasTaskItem = false;
    const itemHTML: string[] = [];
    for (let i = 0; i < items.length; i++) {
      const itemLines = items[i];
      const offsets = itemOffsets[i];
      let task: TaskInfo | null = null;
      if (itemLines.length > 0) {
        const parsed = MarkdownBuilder.taskPrefix(itemLines[0]);
        if (parsed !== null) {
          task = parsed;
          itemLines[0] = parsed.content;
        }
      }
      const inner = this.renderBlocks(new BlockLines(itemLines, offsets), true);
      if (task !== null) {
        hasTaskItem = true;
        const checked = task.checked ? ' checked' : '';
        itemHTML.push('<li class="task-list-item"><input type="checkbox" disabled' + checked + '> ' + inner + '</li>');
      } else {
        itemHTML.push('<li>' + inner + '</li>');
      }
    }

    const tag = ordered ? 'ol' : 'ul';
    const classAttribute = hasTaskItem ? ' class="task-list"' : '';
    const startAttribute = ordered && first.start !== 1 ? ' start="' + first.start + '"' : '';
    result.html = '<' + tag + classAttribute + startAttribute + '>\n' +
      itemHTML.join('\n') + '\n</' + tag + '>';
    return result;
  }

  private static taskPrefix(line: string): TaskInfo | null {
    if (line.length < 4 || line.charAt(0) !== '[' || line.charAt(2) !== ']' || line.charAt(3) !== ' ') {
      return null;
    }
    const marker = line.charAt(1);
    if (marker !== ' ' && marker !== 'x' && marker !== 'X') {
      return null;
    }
    const task = new TaskInfo();
    task.checked = marker !== ' ';
    task.content = line.substring(4);
    return task;
  }

  // MARK: - 表格

  private tableDescriptor(block: BlockLines, index: number): TableInfo | null {
    const lines = block.lines;
    if (index + 1 >= lines.length) {
      return null;
    }
    const headerLine = lines[index];
    if (headerLine.indexOf('|') < 0) {
      return null;
    }
    const separatorCells = MarkdownBuilder.splitTableRow(lines[index + 1]);
    if (separatorCells.length === 0) {
      return null;
    }
    const alignments: string[] = [];
    for (let i = 0; i < separatorCells.length; i++) {
      const trimmed = separatorCells[i].trim();
      if (!/^:?-{3,}:?$/.test(trimmed)) {
        return null;
      }
      const left = trimmed.startsWith(':');
      const right = trimmed.endsWith(':');
      if (left && right) {
        alignments.push('center');
      } else if (right) {
        alignments.push('right');
      } else if (left) {
        alignments.push('left');
      } else {
        alignments.push('');
      }
    }
    const headers = MarkdownBuilder.splitTableRow(headerLine);
    if (headers.length !== separatorCells.length) {
      return null;
    }

    const rows: string[][] = [];
    let cursor = index + 2;
    while (cursor < lines.length) {
      const line = lines[cursor];
      if (line.trim().length === 0 || line.indexOf('|') < 0) {
        break;
      }
      if (MarkdownBuilder.heading(line) !== null || MarkdownBuilder.fenceStart(line) !== null ||
        MarkdownBuilder.blockquoteContent(line) !== null || MarkdownBuilder.listMarker(line) !== null ||
        MarkdownBuilder.isThematicBreak(line)) {
        break;
      }
      const cells = MarkdownBuilder.splitTableRow(line);
      const padded: string[] = [];
      for (let i = 0; i < headers.length; i++) {
        padded.push(i < cells.length ? cells[i] : '');
      }
      rows.push(padded);
      cursor += 1;
    }

    const table = new TableInfo();
    table.headers = headers;
    table.alignments = alignments;
    table.rows = rows;
    table.next = cursor;
    return table;
  }

  private static splitTableRow(line: string): string[] {
    const trimmed = line.trim();
    if (trimmed.indexOf('|') < 0) {
      return [];
    }
    const cells: string[] = [];
    let current = '';
    let escaped = false;
    let inCode = false;
    for (let i = 0; i < line.length; i++) {
      const ch = line.charAt(i);
      if (escaped) {
        current += ch;
        escaped = false;
        continue;
      }
      if (ch === '\\') {
        current += ch;
        escaped = true;
        continue;
      }
      if (ch === '`') {
        inCode = !inCode;
        current += ch;
        continue;
      }
      if (ch === '|' && !inCode) {
        cells.push(current);
        current = '';
        continue;
      }
      current += ch;
    }
    cells.push(current);

    if (trimmed.startsWith('|') && cells.length > 0 && cells[0].trim().length === 0) {
      cells.shift();
    }
    if (trimmed.endsWith('|') && cells.length > 0 && cells[cells.length - 1].trim().length === 0) {
      cells.pop();
    }
    return cells;
  }

  private tableHTML(table: TableInfo): string {
    let html = '<div class="table-wrap"><table><thead><tr>';
    for (let i = 0; i < table.headers.length; i++) {
      html += this.tableCell(table.headers[i], 'th', table.alignments[i]);
    }
    html += '</tr></thead>';
    if (table.rows.length > 0) {
      html += '<tbody>';
      for (let r = 0; r < table.rows.length; r++) {
        const row = table.rows[r];
        html += '<tr>';
        for (let c = 0; c < row.length; c++) {
          html += this.tableCell(row[c], 'td', table.alignments[c]);
        }
        html += '</tr>';
      }
      html += '</tbody>';
    }
    html += '</table></div>';
    return html;
  }

  private tableCell(text: string, tag: string, alignment: string): string {
    const style = alignment.length === 0 ? '' : ' style="text-align: ' + alignment + '"';
    const inline = new InlineRenderer(this.store).render(text.trim());
    return '<' + tag + style + '>' + inline + '</' + tag + '>';
  }

  // MARK: - 缩进辅助

  private static leadingColumns(line: string): number {
    let columns = 0;
    for (let i = 0; i < line.length; i++) {
      const ch = line.charAt(i);
      if (ch === ' ') {
        columns += 1;
      } else if (ch === '\t') {
        columns += 4;
      } else {
        break;
      }
    }
    return columns;
  }

  private static stripIndent(line: string, columns: number): string {
    let removed = 0;
    let index = 0;
    while (index < line.length && removed < columns) {
      const ch = line.charAt(index);
      if (ch === ' ') {
        removed += 1;
      } else if (ch === '\t') {
        removed += 4;
      } else {
        break;
      }
      index += 1;
    }
    return line.substring(index);
  }

  // MARK: - 文本处理

  /** 去掉 YAML front matter；只有开闭围栏之间确实像元数据时才剥离。 */
  private static stripFrontMatter(lines: string[]): string[] {
    if (lines.length === 0 || lines[0].trim() !== '---') {
      return lines;
    }
    const limit = Math.min(lines.length, 80);
    for (let index = 1; index < limit; index++) {
      const marker = lines[index].trim();
      if (marker !== '---' && marker !== '...') {
        continue;
      }
      let looksLikeMetadata = false;
      for (let i = 1; i < index; i++) {
        const value = lines[i].trim();
        if (value.length > 0 && (value.indexOf(':') >= 0 || value.startsWith('- '))) {
          looksLikeMetadata = true;
          break;
        }
      }
      if (looksLikeMetadata) {
        return lines.slice(index + 1);
      }
      return lines;
    }
    return lines;
  }

  /** 标题纯文本：去掉图片、链接与强调标记。 */
  private static plainHeadingTitle(text: string): string {
    let value = text;
    value = value.replace(/!\[([^\]]*)\]\([^)]*\)/g, '$1');
    value = value.replace(/\[([^\]]*)\]\([^)]*\)/g, '$1');
    value = value.replace(/[*_`~]/g, '');
    return value.trim();
  }
}

/** 行内渲染：先把代码、转义、图片、链接替换成占位符，再处理强调。 */
class InlineRenderer {
  private tokens: string[] = [];
  private store: ImageStore;

  constructor(store: ImageStore) {
    this.store = store;
  }

  render(text: string): string {
    let value = this.extractCodeSpans(text);
    value = this.protectEscapes(value);
    value = this.extractPattern(value, /!\[([^\]]*)\]\(((?:[^()\n]|\([^()\n]*\))*)\)/g,
      (match: RegExpExecArray): string => {
        return this.imageHTML(match[1], match[2]);
      });
    value = this.extractPattern(value, /\[([^\]]+)\]\(((?:[^()\n]|\([^()\n]*\))*)\)/g,
      (match: RegExpExecArray): string => {
        return this.linkHTML(match[1], match[2]);
      });
    value = this.extractPattern(value, /<((?:https?|mailto):[^\s<>]+)>/gi,
      (match: RegExpExecArray): string => {
        const destination = match[1];
        return '<a href="' + HtmlText.escape(destination) + '">' + HtmlText.escape(destination) + '</a>';
      });
    value = HtmlText.escape(value);
    value = this.applyEmphasis(value);
    value = value.split(HARD_BREAK).join('<br>');
    return this.restoreTokens(value);
  }

  private stash(html: string): string {
    this.tokens.push(html);
    return TOKEN_OPEN + (this.tokens.length - 1) + TOKEN_CLOSE;
  }

  private restoreTokens(input: string): string {
    const pattern = new RegExp(TOKEN_OPEN + '([0-9]+)' + TOKEN_CLOSE, 'g');
    return input.replace(pattern, (match: string, digits: string): string => {
      const index = parseInt(digits, 10);
      if (index >= 0 && index < this.tokens.length) {
        return this.tokens[index];
      }
      return '';
    });
  }

  private extractPattern(
    input: string,
    pattern: RegExp,
    build: (match: RegExpExecArray) => string
  ): string {
    const matches: RegExpExecArray[] = [];
    pattern.lastIndex = 0;
    let match = pattern.exec(input);
    while (match !== null) {
      matches.push(match);
      if (match[0].length === 0) {
        pattern.lastIndex += 1;
      }
      match = pattern.exec(input);
    }
    let result = input;
    for (let i = matches.length - 1; i >= 0; i--) {
      const current = matches[i];
      const replacement = this.stash(build(current));
      result = result.substring(0, current.index) + replacement +
        result.substring(current.index + current[0].length);
    }
    return result;
  }

  private protectEscapes(text: string): string {
    const escapable = '\\`*_{}[]()#+-.!~>|';
    let result = '';
    let index = 0;
    while (index < text.length) {
      const ch = text.charAt(index);
      if (ch === '\\' && index + 1 < text.length && escapable.indexOf(text.charAt(index + 1)) >= 0) {
        result += this.stash(HtmlText.escape(text.charAt(index + 1)));
        index += 2;
        continue;
      }
      result += ch;
      index += 1;
    }
    return result;
  }

  private extractCodeSpans(input: string): string {
    let result = '';
    let index = 0;
    while (index < input.length) {
      const ch = input.charAt(index);
      const escaped = index > 0 && input.charAt(index - 1) === '\\';
      if (ch !== '`' || escaped) {
        result += ch;
        index += 1;
        continue;
      }
      let run = 0;
      while (index + run < input.length && input.charAt(index + run) === '`') {
        run += 1;
      }
      let cursor = index + run;
      let closeStart = -1;
      while (cursor < input.length) {
        if (input.charAt(cursor) === '`') {
          let closeRun = 0;
          while (cursor + closeRun < input.length && input.charAt(cursor + closeRun) === '`') {
            closeRun += 1;
          }
          if (closeRun === run) {
            closeStart = cursor;
            break;
          }
          cursor += closeRun;
        } else {
          cursor += 1;
        }
      }
      if (closeStart < 0) {
        result += input.substring(index, index + run);
        index += run;
        continue;
      }
      let content = input.substring(index + run, closeStart);
      if (content.length > 2 && content.startsWith(' ') && content.endsWith(' ') &&
        content.trim().length > 0) {
        content = content.substring(1, content.length - 1);
      }
      result += this.stash('<code>' + HtmlText.escape(content) + '</code>');
      index = closeStart + run;
    }
    return result;
  }

  private applyEmphasis(input: string): string {
    let value = input;
    value = this.replaceDelimited(value, /\*\*\*([\s\S]+?)\*\*\*/g, '<strong><em>', '</em></strong>');
    value = this.replaceDelimited(value, /___([\s\S]+?)___/g, '<strong><em>', '</em></strong>');
    value = this.replaceDelimited(value, /\*\*([\s\S]+?)\*\*/g, '<strong>', '</strong>');
    value = this.replaceDelimited(value, /__([\s\S]+?)__/g, '<strong>', '</strong>');
    value = this.replaceDelimited(value, /~~([\s\S]+?)~~/g, '<del>', '</del>');
    value = this.replaceDelimited(value, /\*([^*\n]+?)\*/g, '<em>', '</em>');
    value = value.replace(/(^|[^A-Za-z0-9_])_([^_\n]+?)_(?![A-Za-z0-9_])/g,
      (match: string, prefix: string, inner: string): string => {
        if (!InlineRenderer.isTightSpan(inner)) {
          return match;
        }
        return prefix + '<em>' + inner + '</em>';
      });
    return value;
  }

  /**
   * 强调标记替换：要求首尾都不是空白，避免把 `a * b * c` 误判成斜体。
   * 使用分组而非后行断言，保证 ArkTS 正则引擎兼容。
   */
  private replaceDelimited(input: string, pattern: RegExp, open: string, close: string): string {
    return input.replace(pattern, (match: string, inner: string): string => {
      if (!InlineRenderer.isTightSpan(inner)) {
        return match;
      }
      return open + inner + close;
    });
  }

  private static isTightSpan(inner: string): boolean {
    if (inner.length === 0) {
      return false;
    }
    const first = inner.charAt(0);
    const last = inner.charAt(inner.length - 1);
    return first.trim().length > 0 && last.trim().length > 0;
  }

  private linkHTML(label: string, destination: string): string {
    const parsed = InlineRenderer.parseDestination(destination);
    const labelHTML = new InlineRenderer(this.store).render(label);
    if (!InlineRenderer.isSafeLink(parsed.url)) {
      return labelHTML;
    }
    const title = parsed.title !== null
      ? ' title="' + HtmlText.escape(parsed.title) + '"'
      : '';
    return '<a href="' + HtmlText.escape(parsed.url) + '"' + title + '>' + labelHTML + '</a>';
  }

  private imageHTML(alt: string, destination: string): string {
    const parsed = InlineRenderer.parseDestination(destination);
    if (parsed.url.length === 0) {
      return HtmlText.escape(alt);
    }
    const resolved = this.store.resolve(parsed.url);
    const src = resolved !== null ? resolved : parsed.url;
    const title = parsed.title !== null
      ? ' title="' + HtmlText.escape(parsed.title) + '"'
      : '';
    return '<img src="' + HtmlText.escape(src) + '" alt="' + HtmlText.escape(alt) + '"' +
      title + ' loading="lazy">';
  }

  private static parseDestination(raw: string): Destination {
    const result = new Destination();
    const value = raw.trim();
    if (value.length === 0) {
      return result;
    }

    let urlPart = '';
    let rest = '';
    if (value.startsWith('<')) {
      const end = value.indexOf('>');
      if (end >= 0) {
        urlPart = value.substring(1, end);
        rest = value.substring(end + 1);
      } else {
        urlPart = value;
      }
    } else {
      let escaped = false;
      let index = 0;
      while (index < value.length) {
        const ch = value.charAt(index);
        if (escaped) {
          escaped = false;
        } else if (ch === '\\') {
          escaped = true;
        } else if (ch === ' ' || ch === '\t') {
          break;
        }
        index += 1;
      }
      urlPart = value.substring(0, index);
      rest = value.substring(index);
    }

    let title = rest.trim();
    if (title.length >= 2 && title.startsWith('"') && title.endsWith('"')) {
      title = title.substring(1, title.length - 1);
    } else if (title.length >= 2 && title.startsWith('\'') && title.endsWith('\'')) {
      title = title.substring(1, title.length - 1);
    } else if (title.length >= 2 && title.startsWith('(') && title.endsWith(')')) {
      title = title.substring(1, title.length - 1);
    } else {
      title = '';
    }

    result.url = urlPart.split('\\ ').join(' ');
    result.title = title.length > 0 ? title : null;
    return result;
  }

  private static isSafeLink(url: string): boolean {
    const lower = url.toLowerCase();
    return lower.startsWith('https://') || lower.startsWith('http://') || lower.startsWith('mailto:');
  }
}
