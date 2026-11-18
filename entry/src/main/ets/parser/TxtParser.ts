import { ChapterLink, RenderedBook } from './BookTypes';
import { HtmlText } from './HtmlText';
import { TextCodec } from './Bytes';

/**
 * Plain-text renderer. It keeps the original paragraph structure (one <p> per
 * blank-line separated block) so a 1 MB novel does not become a single huge
 * DOM text node, which is what used to make paged layout slow.
 */
export function renderTXT(bytes: Uint8Array, encodingHint: string): RenderedBook {
  const book = new RenderedBook();
  let text = '';
  if (bytes.length >= 3 && bytes[0] === 0xEF && bytes[1] === 0xBB && bytes[2] === 0xBF) {
    text = TextCodec.decodeUtf8(bytes.subarray(3));
  } else if (bytes.length >= 2 && bytes[0] === 0xFF && bytes[1] === 0xFE) {
    text = TextCodec.decodeUtf16(bytes.subarray(2), true);
  } else if (bytes.length >= 2 && bytes[0] === 0xFE && bytes[1] === 0xFF) {
    text = TextCodec.decodeUtf16(bytes.subarray(2), false);
  } else if (encodingHint.length > 0) {
    text = TextCodec.decode(bytes, encodingHint);
  } else if (TextCodec.looksLikeUtf8(bytes)) {
    text = TextCodec.decodeUtf8(bytes);
  } else if (TextCodec.externalDecoder !== null) {
    text = TextCodec.externalDecoder(bytes, 'gb18030');
  } else {
    text = TextCodec.decodeUtf8(bytes);
  }
  text = HtmlText.normalizeNewlines(text).replace(/^\uFEFF/, '');
  if (text.trim().length === 0) {
    book.error = 'TXT 文件没有可显示的文本';
    return book;
  }

  const lines = text.split('\n');
  const chapterStarts: number[] = [];
  let offset = 0;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (HtmlText.isChapterHeading(line)) {
      chapterStarts.push(offset);
    }
    offset += line.length + 1;
  }
  if (chapterStarts.length === 0) {
    chapterStarts.push(0);
  } else if (chapterStarts[0] > 0) {
    const prefix = text.substring(0, chapterStarts[0]);
    if (prefix.trim().length > 0) {
      chapterStarts.unshift(0);
    }
  }

  const chapterTexts: string[] = [];
  const htmlParts: string[] = [];
  for (let i = 0; i < chapterStarts.length; i++) {
    const start = chapterStarts[i];
    const end = i + 1 < chapterStarts.length ? chapterStarts[i + 1] : text.length;
    const chapterText = text.substring(start, end);
    if (chapterText.trim().length === 0) {
      continue;
    }
    const anchorId = 'txt-h-' + i;
    htmlParts.push('<section class="txt-chapter" id="' + anchorId + '">' +
      HtmlText.paragraphsHtml(chapterText) + '</section>');
    chapterTexts.push(chapterText);
  }

  book.html = htmlParts.join('\n');
  book.textModel = HtmlText.buildTextModel(chapterTexts);
  let cursor = 0;
  for (let i = 0; i < chapterTexts.length; i++) {
    const link = new ChapterLink();
    link.title = HtmlText.chapterTitle(chapterTexts[i], '第 ' + (i + 1) + ' 章');
    link.anchorId = 'txt-h-' + i;
    link.progress = book.textModel.totalLength > 0 ? cursor / book.textModel.totalLength : 0;
    link.level = HtmlText.chapterHeadingLevel(chapterTexts[i]);
    link.locatorText = HtmlText.firstLine(chapterTexts[i], 60);
    book.chapters.push(link);
    cursor += chapterTexts[i].length;
  }
  return book;
}

export function comicaPageSort(a: string, b: string): number {
  return a.localeCompare(b, 'zh-Hans-CN', { numeric: true, sensitivity: 'base' });
}
