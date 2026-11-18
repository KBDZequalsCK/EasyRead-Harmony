import { AssetBlob, ChapterLink, RenderedBook } from './BookTypes';
import { HtmlText } from './HtmlText';
import { ZipArchive, naturalCompare } from './ZipReader';
import { XmlLite, XmlAttr, XmlTag, resolvePath, dirName, baseName, stripExtension } from './XmlLite';

class EpubItem {
  id: string = '';
  href: string = '';
  path: string = '';
  mediaType: string = '';
  properties: string = '';
}

class EpubChapterText {
  html: string = '';
  text: string = '';
  title: string = '';
  level: number = 0;
}

class EpubTocEntry {
  title: string = '';
  href: string = '';
  level: number = 0;
}

/**
 * NCX navPoints keep their nesting; flattening them used to turn a multi-book
 * omnibus into one endless chapter list. The entry is recorded when its
 * navPoint opens so document order and depth are both preserved.
 */
function parseNcxEntries(xml: string): EpubTocEntry[] {
  const entries: EpubTocEntry[] = [];
  const stack: EpubTocEntry[] = [];
  const pattern = /<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?text\b[^>]*>([\s\S]*?)<\/(?:[A-Za-z_][A-Za-z0-9_.-]*:)?text\s*>|<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?content\b([^>]*)>|<\/(?:[A-Za-z_][A-Za-z0-9_.-]*:)?navPoint\s*>|<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?navPoint\b[^>]*>/gi;
  let match: RegExpExecArray | null = pattern.exec(xml);
  while (match !== null) {
    if (match[1] !== undefined) {
      if (stack.length > 0) {
        const current = stack[stack.length - 1];
        if (current.title.length === 0) {
          current.title = HtmlText.truncate(
            HtmlText.decodeEntities(HtmlText.stripTags(match[1])), 100);
        }
      }
    } else if (match[2] !== undefined) {
      if (stack.length > 0) {
        const current = stack[stack.length - 1];
        if (current.href.length === 0) {
          const attrs: XmlAttr[] = [];
          XmlLite.parseAttrs(match[2], attrs);
          for (let i = 0; i < attrs.length; i++) {
            const name = attrs[i].name.indexOf(':') >= 0 ?
              attrs[i].name.substring(attrs[i].name.indexOf(':') + 1) : attrs[i].name;
            if (name === 'src') {
              current.href = attrs[i].value;
              break;
            }
          }
        }
      }
    } else if (match[0].charAt(1) === '/') {
      if (stack.length > 0) {
        stack.pop();
      }
    } else if (!match[0].endsWith('/>')) {
      const entry = new EpubTocEntry();
      entry.level = stack.length;
      entries.push(entry);
      stack.push(entry);
    }
    match = pattern.exec(xml);
  }
  return entries;
}

/** EPUB3 nav documents express the same tree with nested ol/ul lists. */
function parseNavEntries(xml: string): EpubTocEntry[] {
  const entries: EpubTocEntry[] = [];
  const pattern = /<a\b([^>]*)>([\s\S]*?)<\/a>|<(?:ol|ul)\b[^>]*>|<\/(?:ol|ul)\s*>/gi;
  let depth = -1;
  let match: RegExpExecArray | null = pattern.exec(xml);
  while (match !== null) {
    if (match[1] !== undefined) {
      const hrefMatch = match[1].match(/href\s*=\s*("([^"]*)"|'([^']*)')/i);
      const href = hrefMatch !== null ?
        (hrefMatch[2] !== undefined ? hrefMatch[2] : hrefMatch[3]) : '';
      const title = HtmlText.truncate(
        HtmlText.decodeEntities(HtmlText.stripTags(match[2])), 100);
      if (href.length > 0 && title.length > 0 && href.indexOf('http') !== 0) {
        const entry = new EpubTocEntry();
        entry.href = href;
        entry.title = title;
        entry.level = depth > 0 ? depth : 0;
        entries.push(entry);
      }
    } else if (match[0].charAt(1) === '/') {
      depth -= 1;
    } else {
      depth += 1;
    }
    match = pattern.exec(xml);
  }
  return entries;
}

/**
 * ZIP-based EPUB renderer. Chapters come straight from the zip (no disk
 * extraction); only referenced images, fonts and (optionally) publisher CSS
 * become assets beside the generated reader page.
 */
export function renderEPUB(zip: ZipArchive, publisherStyles: boolean): RenderedBook {
  const book = new RenderedBook();
  const assets: AssetBlob[] = [];
  const assetMap: Map<string, string> = new Map<string, string>();
  let assetCounter = 0;

  const container = zip.readText('META-INF/container.xml');
  if (container === null) {
    book.error = 'EPUB 缺少 META-INF/container.xml';
    return book;
  }
  let opfPath = '';
  const rootFiles = XmlLite.tags(container, 'rootfile');
  for (let i = 0; i < rootFiles.length; i++) {
    const type = XmlLite.attr(rootFiles[i], 'media-type');
    const path = XmlLite.attr(rootFiles[i], 'full-path');
    if (path.length > 0 && (type.length === 0 || type.indexOf('oebps-package') >= 0)) {
      opfPath = path;
      break;
    }
  }
  if (opfPath.length === 0 && rootFiles.length > 0) {
    opfPath = XmlLite.attr(rootFiles[0], 'full-path');
  }
  const opf = opfPath.length > 0 ? zip.readText(opfPath) : null;
  if (opf === null) {
    book.error = 'EPUB 缺少 OPF 包文件';
    return book;
  }
  const opfDir = dirName(opfPath);

  book.title = HtmlText.collapseWhitespace(XmlLite.decode(XmlLite.firstInner(opf, 'title')));
  book.author = HtmlText.collapseWhitespace(XmlLite.decode(XmlLite.firstInner(opf, 'creator')));
  if (book.title.length === 0) {
    book.title = stripExtension(baseName(opfPath));
  }

  const manifest: Map<string, EpubItem> = new Map<string, EpubItem>();
  const items = XmlLite.tags(opf, 'item');
  for (let i = 0; i < items.length; i++) {
    const item = new EpubItem();
    item.id = XmlLite.attr(items[i], 'id');
    item.href = XmlLite.attr(items[i], 'href');
    item.mediaType = XmlLite.attr(items[i], 'media-type');
    item.properties = XmlLite.attr(items[i], 'properties');
    item.path = resolvePath(opfDir, item.href);
    if (item.id.length > 0) {
      manifest.set(item.id, item);
    }
  }

  const spineIds: string[] = [];
  const spineTags = XmlLite.tags(opf, 'itemref');
  for (let i = 0; i < spineTags.length; i++) {
    const idref = XmlLite.attr(spineTags[i], 'idref');
    if (idref.length > 0) {
      spineIds.push(idref);
    }
  }

  let spineItems: EpubItem[] = [];
  for (let i = 0; i < spineIds.length; i++) {
    const item = manifest.get(spineIds[i]);
    if (item !== undefined && item.path.length > 0) {
      spineItems.push(item);
    }
  }
  if (spineItems.length === 0) {
    const fallback: EpubItem[] = [];
    manifest.forEach((item: EpubItem): void => {
      if (item.mediaType.indexOf('html') >= 0 || item.path.toLowerCase().endsWith('.xhtml') ||
        item.path.toLowerCase().endsWith('.html') || item.path.toLowerCase().endsWith('.htm')) {
        fallback.push(item);
      }
    });
    fallback.sort((a: EpubItem, b: EpubItem): number => naturalCompare(a.path, b.path));
    spineItems = fallback;
  }

  const assetFor = (zipPath: string): string => {
    const cached = assetMap.get(zipPath);
    if (cached !== undefined) {
      return cached;
    }
    const entry = zip.find(zipPath);
    if (entry === null) {
      return zipPath;
    }
    let bytes: Uint8Array;
    try {
      bytes = zip.readEntry(entry);
    } catch (error) {
      return zipPath;
    }
    assetCounter += 1;
    const path = 'assets/epub-' + assetCounter + '-' + HtmlText.assetKey(zipPath);
    const asset = new AssetBlob();
    asset.path = path;
    asset.bytes = bytes;
    asset.mime = HtmlText.guessMime(zipPath);
    assets.push(asset);
    assetMap.set(zipPath, path);
    return path;
  };

  const rewriteCss = (css: string, cssPath: string): string => {
    return HtmlText.rewriteCssUrls(css, (url: string): string => {
      if (/^(data:|https?:|#)/i.test(url)) {
        return url;
      }
      const resolved = resolvePath(dirName(cssPath), url);
      return assetFor(resolved);
    });
  };

  const chapterTexts: EpubChapterText[] = [];
  const collectedCss: string[] = [];
  let coverPath = '';

  // EPUB2 NCX / EPUB3 nav titles give much better chapter names than the
  // cover page's <title> element or the first heading of a title page. Their
  // nesting is kept as well so an omnibus can group each included book.
  const tocEntries: Map<string, EpubTocEntry> = new Map<string, EpubTocEntry>();
  manifest.forEach((item: EpubItem): void => {
    const isNcx = item.mediaType.indexOf('dtbncx') >= 0 || item.path.toLowerCase().endsWith('.ncx');
    const isNav = item.properties.split(/\s+/).indexOf('nav') >= 0;
    if (!isNcx && !isNav) {
      return;
    }
    const xml = zip.readText(item.path);
    if (xml === null) {
      return;
    }
    const parsed = isNcx ? parseNcxEntries(xml) : parseNavEntries(xml);
    for (let i = 0; i < parsed.length; i++) {
      const entry = parsed[i];
      if (entry.title.length === 0 || entry.href.length === 0) {
        continue;
      }
      const key = resolvePath(dirName(item.path), entry.href).split('#')[0];
      if (key.length > 0 && !tocEntries.has(key)) {
        tocEntries.set(key, entry);
      }
    }
  });

  let fallbackLevel = 0;
  for (let i = 0; i < spineItems.length; i++) {
    const item = spineItems[i];
    const raw = zip.readText(item.path);
    if (raw === null) {
      continue;
    }
    let body = raw;
    const bodyMatch = raw.match(/<body[^>]*>([\s\S]*?)<\/body>/i);
    if (bodyMatch !== null) {
      body = bodyMatch[1];
    } else {
      body = raw.replace(/<head[\s\S]*?<\/head>/gi, '');
    }

    const tocEntry = tocEntries.get(item.path);
    let chapterTitle = tocEntry !== undefined ? tocEntry.title : '';
    if (chapterTitle.length === 0) {
      const headingMatch = body.match(/<h[1-3][^>]*>([\s\S]*?)<\/h[1-3]>/i);
      if (headingMatch !== null) {
        chapterTitle = HtmlText.truncate(HtmlText.stripTags(headingMatch[1]), 80);
      }
    }
    if (chapterTitle.length === 0) {
      const titleMatch = raw.match(/<title[^>]*>([\s\S]*?)<\/title>/i);
      if (titleMatch !== null) {
        chapterTitle = HtmlText.truncate(HtmlText.decodeEntities(titleMatch[1]), 80);
      }
    }
    if (chapterTitle.length === 0 && publisherStyles) {
      const heading = body.match(/<h[1-6][^>]*>([\s\S]*?)<\/h[1-6]>/i);
      if (heading !== null) {
        chapterTitle = HtmlText.truncate(HtmlText.stripTags(heading[1]), 80);
      }
    }

    if (publisherStyles) {
      const linkPattern = /<link\b[^>]*>/gi;
      let linkMatch = linkPattern.exec(raw);
      while (linkMatch !== null) {
        const tagText = linkMatch[0];
        if (/stylesheet/i.test(tagText)) {
          const hrefMatch = tagText.match(/href\s*=\s*("([^"]*)"|'([^']*)')/i);
          if (hrefMatch !== null) {
            const href = hrefMatch[2] !== undefined ? hrefMatch[2] : hrefMatch[3];
            const cssPath = resolvePath(dirName(item.path), href);
            const css = zip.readText(cssPath);
            if (css !== null) {
              collectedCss.push(rewriteCss(css, cssPath));
            }
          }
        }
        linkMatch = linkPattern.exec(raw);
      }
      const stylePattern = /<style[^>]*>([\s\S]*?)<\/style>/gi;
      let styleMatch = stylePattern.exec(raw);
      while (styleMatch !== null) {
        collectedCss.push(rewriteCss(styleMatch[1], item.path));
        styleMatch = stylePattern.exec(raw);
      }
    }

    body = body.replace(/<script[\s\S]*?<\/script>/gi, '');
    body = body.replace(/\s+on[a-z]+\s*=\s*("[^"]*"|'[^']*')/gi, '');
    body = body.replace(/href\s*=\s*("javascript:[^"]*"|'javascript:[^']*')/gi, 'href="#"');

    body = body.replace(/\b(src|xlink:href|poster)\s*=\s*("([^"]*)"|'([^']*)')/gi,
      (match: string, attrName: string, quoted: string, doubleQuoted: string, singleQuoted: string): string => {
        const value = doubleQuoted !== undefined ? doubleQuoted : singleQuoted;
        if (/^(data:|https?:|#)/i.test(value)) {
          return match;
        }
        const resolved = resolvePath(dirName(item.path), value);
        const asset = assetFor(resolved);
        return attrName + '="' + asset + '"';
      });

    body = body.replace(/style\s*=\s*("([^"]*)"|'([^']*)')/gi,
      (match: string, quoted: string, doubleQuoted: string, singleQuoted: string): string => {
        const value = doubleQuoted !== undefined ? doubleQuoted : singleQuoted;
        return 'style="' + rewriteCss(value, item.path) + '"';
      });

    body = body.replace(/<img\b([^>]*)>/gi, (match: string, attrs: string): string => {
      if (/loading\s*=/i.test(attrs)) {
        return match;
      }
      return '<img' + attrs + ' loading="lazy" decoding="async"/>';
    });

    const anchorId = 'epub-h-' + i;
    const chapterText = new EpubChapterText();
    chapterText.html = '<section class="epub-chapter" id="' + anchorId + '">' + body + '</section>';
    chapterText.text = HtmlText.stripTags(body);
    chapterText.title = chapterTitle.length > 0 ? chapterTitle : '第 ' + (i + 1) + ' 章';
    chapterText.level = tocEntry !== undefined ? tocEntry.level : fallbackLevel;
    if (tocEntry !== undefined) {
      fallbackLevel = tocEntry.level;
    }
    chapterTexts.push(chapterText);

    if (item.properties.indexOf('cover-image') >= 0 && coverPath.length === 0) {
      coverPath = assetFor(item.path);
    }
  }

  if (coverPath.length === 0) {
    const metas = XmlLite.tags(opf, 'meta');
    let coverId = '';
    for (let i = 0; i < metas.length; i++) {
      if (XmlLite.attr(metas[i], 'name').toLowerCase() === 'cover') {
        coverId = XmlLite.attr(metas[i], 'content');
        break;
      }
    }
    if (coverId.length > 0) {
      const coverItem = manifest.get(coverId);
      if (coverItem !== undefined) {
        coverPath = assetFor(coverItem.path);
      }
    }
  }

  const htmlParts: string[] = [];
  const modelTexts: string[] = [];
  let totalText = 0;
  for (let i = 0; i < chapterTexts.length; i++) {
    htmlParts.push(chapterTexts[i].html);
    modelTexts.push(chapterTexts[i].text);
    totalText += chapterTexts[i].text.length;
  }
  book.html = htmlParts.join('\n');
  book.assets = assets;
  book.coverPath = coverPath;
  book.css = publisherStyles ? collectedCss.join('\n') : '';
  book.textModel = HtmlText.buildTextModel(modelTexts);

  let cursor = 0;
  for (let i = 0; i < chapterTexts.length; i++) {
    const link = new ChapterLink();
    link.title = chapterTexts[i].title;
    link.anchorId = 'epub-h-' + i;
    link.progress = totalText > 0 ? cursor / totalText : 0;
    link.level = chapterTexts[i].level;
    const first = HtmlText.firstLine(chapterTexts[i].text, 60);
    link.locatorText = first;
    book.chapters.push(link);
    cursor += chapterTexts[i].text.length;
  }
  return book;
}
