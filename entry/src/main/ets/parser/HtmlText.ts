import { AssetBlob, ChapterLink, TextChapter, TextModel } from './BookTypes';

export class HtmlText {
  static escape(value: string): string {
    let result = '';
    for (let i = 0; i < value.length; i++) {
      const ch = value.charAt(i);
      if (ch === '&') {
        result += '&amp;';
      } else if (ch === '<') {
        result += '&lt;';
      } else if (ch === '>') {
        result += '&gt;';
      } else if (ch === '"') {
        result += '&quot;';
      } else {
        result += ch;
      }
    }
    return result;
  }

  static escapeAttr(value: string): string {
    return HtmlText.escape(value).split('\'').join('&#39;');
  }

  static decodeEntities(value: string): string {
    if (value.indexOf('&') < 0) {
      return value;
    }
    return value
      .replace(/&nbsp;/g, ' ')
      .replace(/&#160;/g, ' ')
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, '\'')
      .replace(/&apos;/g, '\'')
      .replace(/&mdash;/g, '—')
      .replace(/&ndash;/g, '–')
      .replace(/&hellip;/g, '…')
      .replace(/&ldquo;/g, '“')
      .replace(/&rdquo;/g, '”')
      .replace(/&lsquo;/g, '‘')
      .replace(/&rsquo;/g, '’')
      .replace(/&#x([0-9a-fA-F]+);/g, (match: string, hex: string): string => {
        return String.fromCodePoint(parseInt(hex, 16));
      })
      .replace(/&#([0-9]+);/g, (match: string, digits: string): string => {
        return String.fromCodePoint(parseInt(digits, 10));
      });
  }

  /** Removes scripts/styles/head and tags, keeping readable block breaks. */
  static stripTags(html: string): string {
    let text = html;
    text = text.replace(/<head[\s\S]*?<\/head>/gi, '');
    text = text.replace(/<script[\s\S]*?<\/script>/gi, '');
    text = text.replace(/<style[\s\S]*?<\/style>/gi, '');
    text = text.replace(/<br\s*\/?>/gi, '\n');
    text = text.replace(/<\/(p|div|h[1-6]|li|tr|section|article|blockquote|pre)>/gi, '\n');
    text = text.replace(/<[^>]+>/g, '');
    text = HtmlText.decodeEntities(text);
    text = text.replace(/\r\n?/g, '\n');
    text = text.replace(/[ \t\u3000]+/g, ' ');
    text = text.replace(/ *\n */g, '\n');
    text = text.replace(/\n{3,}/g, '\n\n');
    return text.trim();
  }

  static normalizeNewlines(text: string): string {
    return text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  }

  static collapseWhitespace(value: string): string {
    return value.replace(/\s+/g, ' ').trim();
  }

  static truncate(value: string, maxLength: number): string {
    const collapsed = HtmlText.collapseWhitespace(value);
    if (collapsed.length <= maxLength) {
      return collapsed;
    }
    return collapsed.substring(0, maxLength) + '…';
  }

  static headingFromHtml(html: string): string {
    const match = html.match(/<h[1-3][^>]*>([\s\S]*?)<\/h[1-3]>/i);
    if (match !== null) {
      const title = HtmlText.stripTags(match[1]);
      if (title.length > 0) {
        return HtmlText.truncate(title, 80);
      }
    }
    return '';
  }

  static firstLine(text: string, maxLength: number = 60): string {
    const lines = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (line.length > 0) {
        return line.length <= maxLength ? line : '';
      }
    }
    return '';
  }

  static chapterTitle(text: string, fallback: string): string {
    const normalized = HtmlText.normalizeNewlines(text);
    const first = HtmlText.firstLine(normalized, 80);
    if (first.length > 0) {
      return HtmlText.truncate(first, 60);
    }
    return fallback;
  }

  /** 合集里的“第一卷 / Book 2 / 上册”这类分卷标题。 */
  static isVolumeHeading(line: string): boolean {
    const trimmed = line.trim();
    if (trimmed.length === 0 || trimmed.length > 60) {
      return false;
    }
    return /^(第[0-9０-９零〇一二三四五六七八九十百千万两]+[卷部篇集册]|卷[0-9０-９零〇一二三四五六七八九十百千万两]+|(?:Book|Volume|Vol\.?|Part)\s*\d+|(?:上|中|下)册)/i.test(trimmed);
  }

  static isChapterHeading(line: string): boolean {
    const trimmed = line.trim();
    if (trimmed.length === 0 || trimmed.length > 60) {
      return false;
    }
    return HtmlText.isVolumeHeading(trimmed) ||
      /^(第[0-9０-９零〇一二三四五六七八九十百千万两]+[章节回话]|(?:Chapter|Ch\.)\s*\d+)/i.test(trimmed);
  }

  /**
   * 0 for a collection/volume divider, 1 for a normal chapter. A plain novel
   * whose headings are all level 1 stays flat; a multi-book TXT gains one
   * collapsible level per 卷/部 instead of an endless list.
   */
  static chapterHeadingLevel(text: string): number {
    const first = HtmlText.firstLine(HtmlText.normalizeNewlines(text), 60);
    if (first.length === 0) {
      return 1;
    }
    return HtmlText.isVolumeHeading(first) ? 0 : 1;
  }

  /** 合集里每本内含书自带的“目录 / Contents”页标题。 */
  private static isTocMarker(title: string): boolean {
    const compact = title.replace(/\s+/g, '').toLowerCase();
    return compact === '目录' || compact === '目錄' || compact === '目次' ||
      compact === 'contents' || compact === 'tableofcontents';
  }

  /**
   * Splits "系列:第一册+第二册+…(套装共N册)" into the contained book names.
   * The title is only used when the segment count matches the TOC groups;
   * otherwise neutral 第N册 labels keep every group identifiable.
   */
  private static collectionLabels(title: string, count: number): string[] {
    const labels: string[] = [];
    if (count <= 0) {
      return labels;
    }
    let base = title.replace(/\s+/g, ' ').trim();
    while (/[(（][^()（）]*[)）]$/.test(base)) {
      base = base.replace(/[(（][^()（）]*[)）]$/, '').trim();
    }
    const colon = Math.max(base.lastIndexOf(':'), base.lastIndexOf('：'));
    if (colon >= 0 && colon + 1 < base.length) {
      base = base.substring(colon + 1).trim();
    }
    const separators: string[] = ['+', '＋', '、', '|', '｜'];
    for (let s = 0; s < separators.length; s++) {
      const parts = base.split(separators[s]);
      if (parts.length !== count) {
        continue;
      }
      let valid = true;
      const candidate: string[] = [];
      for (let i = 0; i < parts.length; i++) {
        const part = parts[i].trim();
        if (part.length === 0 || part.length > 40) {
          valid = false;
          break;
        }
        candidate.push(part);
      }
      if (valid) {
        return candidate;
      }
    }
    for (let i = 0; i < count; i++) {
      labels.push('第 ' + (i + 1) + ' 册');
    }
    return labels;
  }

  /**
   * Flat omnibus tables often contain one navigation page per contained book
   * (repeated “目录” / “Contents”), while the real book names only appear in
   * the collection title. Use those pages as group boundaries; the global
   * “总目录” and a trailing global contents page stay outside the groups.
   */
  private static normalizeTocMarkerGroups(links: ChapterLink[], title: string): boolean {
    const markers: number[] = [];
    for (let i = 0; i < links.length; i++) {
      if (!HtmlText.isTocMarker(links[i].title)) {
        continue;
      }
      let followers = 0;
      for (let j = i + 1; j < links.length; j++) {
        if (HtmlText.isTocMarker(links[j].title)) {
          break;
        }
        if (links[j].title.trim().length > 0) {
          followers += 1;
        }
      }
      if (followers > 0) {
        markers.push(i);
      }
    }
    if (markers.length < 2) {
      return false;
    }
    const labels = HtmlText.collectionLabels(title, markers.length);
    const parent = links[0].level > 0 ? links[0].level - 1 : 0;
    for (let m = 0; m < markers.length; m++) {
      const start = markers[m];
      const end = m + 1 < markers.length ? markers[m + 1] : links.length;
      links[start].level = parent;
      links[start].title = labels[m];
      for (let i = start + 1; i < end; i++) {
        links[i].level = parent + 1;
      }
    }
    return true;
  }

  /**
   * Some formats only expose one heading style (RTF, a DOCX without heading
   * styles, a MOBI whose chapters are all h2). When such a flat table still
   * contains volume dividers, give the dividers a parent level so the TOC can
   * collapse each contained book. Flat omnibuses whose only boundaries are
   * per-book “目录” pages are grouped the same way. Structured tables are left
   * untouched.
   */
  static normalizeChapterLevels(links: ChapterLink[], collectionTitle: string = ''): void {
    if (links.length < 2) {
      return;
    }
    const base = links[0].level;
    let flat = true;
    let volumeCount = 0;
    let chapterCount = 0;
    for (let i = 0; i < links.length; i++) {
      if (links[i].level !== base) {
        flat = false;
      }
      if (HtmlText.isVolumeHeading(links[i].title)) {
        volumeCount += 1;
      } else if (links[i].title.trim().length > 0) {
        chapterCount += 1;
      }
    }
    if (!flat || chapterCount === 0) {
      return;
    }
    if (volumeCount === 0 && HtmlText.normalizeTocMarkerGroups(links, collectionTitle)) {
      return;
    }
    if (volumeCount === 0) {
      return;
    }
    const parent = base > 0 ? base - 1 : 0;
    for (let i = 0; i < links.length; i++) {
      links[i].level = HtmlText.isVolumeHeading(links[i].title) ? parent : parent + 1;
    }
  }

  /** Paragraph HTML for a plain-text chapter, preserving blank lines. */
  static paragraphsHtml(text: string): string {
    const normalized = HtmlText.normalizeNewlines(text);
    const blocks = normalized.split(/\n{2,}/);
    const parts: string[] = [];
    for (let i = 0; i < blocks.length; i++) {
      const block = blocks[i].replace(/^\n+|\n+$/g, '');
      if (block.trim().length === 0) {
        continue;
      }
      const inner = HtmlText.escape(block).replace(/\n/g, '<br/>');
      parts.push('<p>' + inner + '</p>');
    }
    return parts.join('\n');
  }

  static buildTextModel(chapters: string[]): TextModel {
    const model = new TextModel();
    let cursor = 0;
    for (let i = 0; i < chapters.length; i++) {
      const text = chapters[i];
      if (text.length === 0) {
        continue;
      }
      const chapter = new TextChapter();
      chapter.text = text;
      chapter.start = cursor;
      chapter.length = text.length;
      cursor += text.length;
      model.chapters.push(chapter);
    }
    model.totalLength = cursor;
    return model;
  }

  static chapterLinksFromTextModel(model: TextModel, fallback: string): ChapterLink[] {
    const result: ChapterLink[] = [];
    for (let i = 0; i < model.chapters.length; i++) {
      const chapter = model.chapters[i];
      const link = new ChapterLink();
      link.title = HtmlText.chapterTitle(chapter.text, fallback + ' ' + (i + 1));
      link.progress = model.totalLength > 0 ? chapter.start / model.totalLength : 0;
      link.locatorText = HtmlText.firstLine(HtmlText.normalizeNewlines(chapter.text), 60);
      result.push(link);
    }
    return result;
  }

  static anchorId(prefix: string, index: number): string {
    return prefix + '-' + index;
  }

  /** Replaces `url(...)` and `src` values inside publisher CSS with assets. */
  static rewriteCssUrls(css: string, resolve: (url: string) => string): string {
    return css.replace(/url\(\s*(['"]?)([^'")]+)\1\s*\)/g, (match: string, quote: string, url: string): string => {
      if (/^(data:|https?:|#)/i.test(url)) {
        return match;
      }
      const mapped = resolve(url);
      return 'url("' + mapped + '")';
    });
  }

  static guessMime(path: string): string {
    const lower = path.toLowerCase();
    if (lower.endsWith('.png')) {
      return 'image/png';
    }
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lower.endsWith('.gif')) {
      return 'image/gif';
    }
    if (lower.endsWith('.webp')) {
      return 'image/webp';
    }
    if (lower.endsWith('.svg')) {
      return 'image/svg+xml';
    }
    if (lower.endsWith('.bmp')) {
      return 'image/bmp';
    }
    if (lower.endsWith('.woff')) {
      return 'font/woff';
    }
    if (lower.endsWith('.woff2')) {
      return 'font/woff2';
    }
    if (lower.endsWith('.ttf')) {
      return 'font/ttf';
    }
    if (lower.endsWith('.otf')) {
      return 'font/otf';
    }
    return 'application/octet-stream';
  }

  static assetKey(path: string): string {
    let key = path.replace(/\\/g, '/');
    const slash = key.lastIndexOf('/');
    if (slash >= 0) {
      key = key.substring(slash + 1);
    }
    key = key.replace(/[^A-Za-z0-9._-]/g, '_');
    return key.length > 0 ? key : 'asset.bin';
  }

  static addAsset(assets: AssetBlob[], path: string, bytes: Uint8Array): string {
    const asset = new AssetBlob();
    asset.path = path;
    asset.bytes = bytes;
    asset.mime = HtmlText.guessMime(path);
    assets.push(asset);
    return path;
  }
}
