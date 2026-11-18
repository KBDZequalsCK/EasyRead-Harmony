import { LibraryBook, ReaderSettings } from '../model/LibraryModels';
import { JsonCodec, JsonNode } from '../parser/ZenJson';
import { READER_SCRIPT } from '../reader/ReaderScript';

export class ReaderDocument {
  /** Bumped whenever the cached HTML layout or reader script changes. */
  static readonly CACHE_VERSION: string = 'r8';

  static configJson(book: LibraryBook, settings: ReaderSettings,
    windowBase: number = 0, windowSpan: number = 1,
    targetProgress: number = -1, targetLocator: string = ''): string {
    const config = JsonNode.object();
    const progress = targetProgress >= 0 ? targetProgress : book.syncedPosition();
    config.set('mode', JsonNode.string(settings.pageMode === 'scroll' ? 'scroll' : 'paged'));
    config.set('columns', JsonNode.string(settings.columns));
    config.set('fontSize', JsonNode.number(settings.fontSize));
    config.set('lineHeight', JsonNode.number(settings.lineHeight));
    config.set('margin', JsonNode.number(settings.margin));
    config.set('theme', JsonNode.string(settings.theme));
    config.set('fontFamily', JsonNode.string(settings.fontFamily));
    config.set('textProgress', JsonNode.number(progress));
    config.set('progress', JsonNode.number(progress));
    config.set('locatorText', JsonNode.string(targetProgress >= 0 ? targetLocator : book.locatorText));
    config.set('windowBase', JsonNode.number(windowBase));
    config.set('windowSpan', JsonNode.number(windowSpan));
    // The config is embedded in a <script> element, so a book title or
    // locator snippet containing "</script>" must not be able to close it.
    // \u003c is valid both in JSON and in a JavaScript string literal.
    return JsonCodec.stringify(config, false, false, false).split('<').join('\\u003c');
  }

  static build(book: LibraryBook, bodyHtml: string, publisherCss: string,
    settings: ReaderSettings, windowBase: number = 0, windowSpan: number = 1,
    targetProgress: number = -1, targetLocator: string = ''): string {
    const configJson = ReaderDocument.configJson(book, settings, windowBase, windowSpan,
      targetProgress, targetLocator);

    const safePublisherCss = publisherCss.split('</style').join('<\\/style');
    return '<!DOCTYPE html>\n<html lang="zh" data-theme="' + settings.theme + '">\n<head>\n' +
      '<meta charset="utf-8"/>\n' +
      '<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no"/>\n' +
      '<title>' + ReaderDocument.escapeTitle(book.title) + '</title>\n' +
      '<style>\n' + ReaderDocument.baseCss() + '\n' + safePublisherCss + '\n' +
      ReaderDocument.structureCss() + '\n</style>\n' +
      '</head>\n<body>\n' +
      '<div id="er-frame"><div id="er-viewport"><div id="er-paged" class="er-content">' +
      bodyHtml + '</div></div></div>\n' +
      '<script>window.__EASYREAD__ = ' + configJson + ';</script>\n' +
      '<script>' + READER_SCRIPT + '</script>\n' +
      '</body>\n</html>';
  }

  private static escapeTitle(value: string): string {
    return value.split('&').join('&amp;').split('<').join('&lt;').split('>').join('&gt;');
  }

  private static structureCss(): string {
    // Publisher CSS is allowed to style the book, but it must never move the
    // frame that the paged reader measures.
    return `
html, body {
  margin: 0 !important;
  padding: 0 !important;
  width: 100% !important;
  height: 100% !important;
  overflow: hidden !important;
}
#er-frame, #er-viewport, #er-paged {
  box-sizing: border-box !important;
}
/* The first page must not flash before the reader restores the saved
   position; setup() makes the page visible as soon as it has laid out. */
#er-paged {
  visibility: hidden;
}
`;
  }

  private static baseCss(): string {
    return `
:root {
  --er-font-size: 20px;
  --er-line-height: 1.8;
  --er-margin: 0.08;
  --er-gap: 28px;
  --bg: #fbf8f1;
  --fg: #2c2925;
  --muted: #857d70;
  --line: #e6dfd2;
  --accent: #8a5a2b;
  --font: "Songti SC", "Source Han Serif SC", "Noto Serif CJK SC", serif;
}
html[data-theme="sepia"] { --bg: #f6ecd7; --fg: #443728; --muted: #8b7b63; --line: #e4d5b8; --accent: #8a5a2b; }
html[data-theme="green"] { --bg: #e9f0e6; --fg: #263a2c; --muted: #6f8274; --line: #d3dfd0; --accent: #3f6b4a; }
html[data-theme="night"] { --bg: #101214; --fg: #d7d3ca; --muted: #8b857a; --line: #262a2e; --accent: #c9a227; }
html[data-font="sans"] { --font: "HarmonyOS Sans SC", "PingFang SC", "Noto Sans CJK SC", sans-serif; }
html[data-font="kai"] { --font: "Kaiti SC", "STKaiti", "KaiTi", serif; }
html[data-font="system"] { --font: system-ui, "HarmonyOS Sans SC", sans-serif; }
html, body {
  margin: 0;
  padding: 0;
  width: 100%;
  height: 100%;
  overflow: hidden;
  background: var(--bg);
  color: var(--fg);
  -webkit-text-size-adjust: 100%;
}
#er-frame {
  position: absolute;
  inset: 0;
  box-sizing: border-box;
  overflow: hidden;
}
#er-viewport {
  position: relative;
  width: 100%;
  height: 100%;
  overflow: hidden;
  -webkit-overflow-scrolling: touch;
  scrollbar-width: none;
}
#er-viewport::-webkit-scrollbar { width: 0; height: 0; }
#er-paged {
  box-sizing: border-box;
  font-family: var(--font);
  font-size: var(--er-font-size);
  line-height: var(--er-line-height);
  text-align: justify;
  overflow-wrap: break-word;
  font-kerning: none;
  font-variant-ligatures: none;
  column-fill: auto;
}
#er-paged p {
  margin: 0 0 0.55em;
  text-indent: 2em;
  orphans: 2;
  widows: 2;
}
#er-paged div { text-indent: 0; }
#er-paged h1, #er-paged h2, #er-paged h3, #er-paged h4, #er-paged h5, #er-paged h6 {
  font-weight: 600;
  line-height: 1.35;
  margin: 1.1em 0 0.55em;
  text-indent: 0;
  break-after: avoid-column;
}
#er-paged h1 { font-size: 1.55em; }
#er-paged h2 { font-size: 1.35em; }
#er-paged h3 { font-size: 1.18em; }
#er-paged img {
  display: block;
  max-width: 100%;
  max-height: 84vh;
  object-fit: contain;
  height: auto;
  margin: 0.6em auto;
  break-inside: avoid-column;
}
#er-paged svg { max-width: 100%; height: auto; }
#er-paged blockquote {
  margin: 0.8em 0;
  padding: 0.1em 0 0.1em 1em;
  border-left: 3px solid var(--line);
  color: var(--muted);
  text-indent: 0;
}
#er-paged table {
  border-collapse: collapse;
  max-width: 100%;
  margin: 0.8em auto;
  font-size: 0.92em;
  text-indent: 0;
}
#er-paged td, #er-paged th { border: 1px solid var(--line); padding: 0.3em 0.5em; }
#er-paged pre {
  white-space: pre-wrap;
  word-break: break-word;
  background: rgba(127, 127, 127, 0.08);
  padding: 0.7em;
  border-radius: 6px;
  text-indent: 0;
}
#er-paged code { font-family: ui-monospace, "SFMono-Regular", Menlo, monospace; font-size: 0.92em; }
#er-paged ul, #er-paged ol { padding-left: 1.6em; margin: 0.5em 0; text-indent: 0; }
#er-paged li { margin: 0.18em 0; }
#er-paged hr { border: none; border-top: 1px solid var(--line); margin: 1.2em 0; }
#er-paged a { color: var(--accent); text-decoration: none; }
#er-paged sup, #er-paged sub { line-height: 0; }
::selection { background: rgba(201, 162, 39, 0.35); }
mark.er-find { background: #ffe08a; color: #1b1b1b; border-radius: 2px; }
mark.er-find-current { background: #ff9f43; color: #1b1b1b; }
@media (prefers-color-scheme: dark) {
  html[data-theme="night"] { color-scheme: dark; }
}
`;
  }
}
