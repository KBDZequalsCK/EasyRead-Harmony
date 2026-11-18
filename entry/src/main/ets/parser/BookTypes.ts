export class ChapterLink {
  title: string = '';
  progress: number = 0;
  anchorId: string = '';
  locatorText: string = '';
  level: number = 0;
  pageIndex: number = -1;
}

export class TextChapter {
  text: string = '';
  start: number = 0;
  length: number = 0;
}

export class TextModel {
  chapters: TextChapter[] = [];
  totalLength: number = 0;
}

export class AssetBlob {
  path: string = '';
  bytes: Uint8Array = new Uint8Array(0);
  mime: string = '';
}

/**
 * The common result every renderer returns. The service layer writes the
 * assets to the reader cache and turns `html` into a complete document.
 */
export class RenderedBook {
  title: string = '';
  author: string = '';
  html: string = '';
  css: string = '';
  chapters: ChapterLink[] = [];
  textModel: TextModel | null = null;
  assets: AssetBlob[] = [];
  coverPath: string = '';
  error: string = '';
}

export class ComicPageInfo {
  index: number = 0;
  entryName: string = '';
  width: number = 0;
  height: number = 0;
  aspect: number = 1;
}

export class RenderedComic {
  title: string = '';
  pages: ComicPageInfo[] = [];
  error: string = '';
}

export class BookMeta {
  title: string = '';
  author: string = '';
  format: string = '';
}
