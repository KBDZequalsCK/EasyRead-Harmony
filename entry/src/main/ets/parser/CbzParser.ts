import { ChapterLink, ComicPageInfo, RenderedComic } from './BookTypes';
import { HtmlText } from './HtmlText';
import { ZipArchive, ZipEntry, naturalCompare } from './ZipReader';

const IMAGE_EXTENSIONS: string[] = ['.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'];

export function isComicImage(name: string): boolean {
  const lower = name.toLowerCase();
  if (lower.indexOf('__macosx/') === 0 || lower.indexOf('.') === 0) {
    return false;
  }
  for (let i = 0; i < IMAGE_EXTENSIONS.length; i++) {
    if (lower.endsWith(IMAGE_EXTENSIONS[i])) {
      return true;
    }
  }
  return false;
}

/**
 * Lists the image pages of a CBZ in natural order. Pages are not extracted
 * here; the comic reader asks the service for the pages around the viewport.
 */
export function renderCBZ(zip: ZipArchive, title: string): RenderedComic {
  const comic = new RenderedComic();
  comic.title = title;
  const names: string[] = [];
  for (let i = 0; i < zip.entries.length; i++) {
    const entry = zip.entries[i];
    if (!entry.isDirectory && isComicImage(entry.name)) {
      names.push(entry.name);
    }
  }
  names.sort((a: string, b: string): number => naturalCompare(a, b));
  for (let i = 0; i < names.length; i++) {
    const page = new ComicPageInfo();
    page.index = i;
    page.entryName = names[i];
    comic.pages.push(page);
  }
  if (comic.pages.length === 0) {
    comic.error = '这本 CBZ 里没有图片页';
  }
  return comic;
}

export function comicChapters(comic: RenderedComic): ChapterLink[] {
  const links: ChapterLink[] = [];
  for (let i = 0; i < comic.pages.length; i++) {
    const link = new ChapterLink();
    link.title = '第 ' + (i + 1) + ' 页';
    link.pageIndex = i;
    link.progress = comic.pages.length > 0 ? i / comic.pages.length : 0;
    links.push(link);
  }
  return links;
}

export class ImageSize {
  width: number = 0;
  height: number = 0;
}

/** Reads the intrinsic size from JPEG/PNG/GIF/WebP/BMP headers. */
export function imageSize(bytes: Uint8Array): ImageSize {
  const size = new ImageSize();
  if (bytes.length >= 24 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4E && bytes[3] === 0x47) {
    size.width = ((bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19]) >>> 0;
    size.height = ((bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23]) >>> 0;
    return size;
  }
  if (bytes.length >= 10 && bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46) {
    size.width = bytes[6] | (bytes[7] << 8);
    size.height = bytes[8] | (bytes[9] << 8);
    return size;
  }
  if (bytes.length >= 30 && bytes[0] === 0x42 && bytes[1] === 0x4D) {
    size.width = (bytes[18] | (bytes[19] << 8) | (bytes[20] << 16) | (bytes[21] << 24)) >>> 0;
    size.height = (bytes[22] | (bytes[23] << 8) | (bytes[24] << 16) | (bytes[25] << 24)) >>> 0;
    return size;
  }
  if (bytes.length >= 30 && bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46 &&
    bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50) {
    // VP8X
    if (bytes[12] === 0x56 && bytes[13] === 0x50 && bytes[14] === 0x38 && bytes[15] === 0x58) {
      size.width = 1 + (bytes[24] | (bytes[25] << 8) | (bytes[26] << 16));
      size.height = 1 + (bytes[27] | (bytes[28] << 8) | (bytes[29] << 16));
      return size;
    }
    // VP8 (lossy)
    if (bytes[12] === 0x56 && bytes[13] === 0x50 && bytes[14] === 0x38 && bytes[15] === 0x20 && bytes.length >= 30) {
      size.width = (bytes[26] | (bytes[27] << 8)) & 0x3FFF;
      size.height = (bytes[28] | (bytes[29] << 8)) & 0x3FFF;
      return size;
    }
  }
  if (bytes.length >= 4 && bytes[0] === 0xFF && bytes[1] === 0xD8) {
    let offset = 2;
    while (offset + 9 < bytes.length) {
      if (bytes[offset] !== 0xFF) {
        offset++;
        continue;
      }
      const marker = bytes[offset + 1];
      if (marker === 0xD8 || marker === 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        offset += 2;
        continue;
      }
      if (offset + 4 > bytes.length) {
        break;
      }
      const length = (bytes[offset + 2] << 8) | bytes[offset + 3];
      if (length < 2) {
        break;
      }
      const isSof = marker >= 0xC0 && marker <= 0xCF && marker !== 0xC4 && marker !== 0xC8 && marker !== 0xCC;
      if (isSof && offset + 9 <= bytes.length) {
        size.height = (bytes[offset + 5] << 8) | bytes[offset + 6];
        size.width = (bytes[offset + 7] << 8) | bytes[offset + 8];
        return size;
      }
      offset += 2 + length;
    }
  }
  return size;
}
