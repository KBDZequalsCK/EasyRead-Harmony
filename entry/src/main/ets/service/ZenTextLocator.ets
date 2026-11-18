import { TextChapter, TextModel } from '../parser/BookTypes';
import { ZenPositionPayload } from '../model/LibraryModels';

class CollapsedText {
  text: string = '';
  offsets: number[] = [];
}

export class ZenTextLocator {
  static locate(progress: number, model: TextModel): ZenPositionPayload | null {
    if (model.totalLength <= 0 || model.chapters.length === 0) {
      return null;
    }
    const clamped = Math.min(Math.max(progress, 0), 1);
    const target = Math.min(Math.max(Math.round(clamped * model.totalLength), 0), model.totalLength - 1);
    let chapterIndex = 0;
    for (let i = 0; i < model.chapters.length; i++) {
      if (target >= model.chapters[i].start) {
        chapterIndex = i;
      } else {
        break;
      }
    }
    const chapter = model.chapters[chapterIndex];
    const offset = Math.min(Math.max(target - chapter.start, 0), Math.max(chapter.length - 1, 0));
    const chapterLength = Math.max(chapter.length, 1);
    const percent = (chapterIndex + offset / chapterLength) / Math.max(model.chapters.length, 1) * 100;
    const payload = new ZenPositionPayload();
    payload.percent = Math.min(Math.max(percent, 0), 100);
    payload.readPage = offset;
    payload.readChapter = chapterIndex;
    payload.readText = ZenTextLocator.snippet(chapter.text, offset);
    return payload;
  }

  static locateByText(readText: string, nearProgress: number, model: TextModel): ZenPositionPayload | null {
    const needle = readText.trim();
    if (needle.length === 0 || model.totalLength <= 0 || model.chapters.length === 0) {
      return null;
    }
    const target = Math.min(Math.max(nearProgress, 0), 1) * model.totalLength;
    let bestChapter = 0;
    let bestOffset = 0;
    let bestDistance = Number.MAX_VALUE;

    const consider = (chapterIndex: number, offset: number): void => {
      const absolute = model.chapters[chapterIndex].start + offset;
      const distance = Math.abs(absolute - target);
      if (distance < bestDistance) {
        bestDistance = distance;
        bestChapter = chapterIndex;
        bestOffset = offset;
      }
    };

    for (let index = 0; index < model.chapters.length; index++) {
      const text = model.chapters[index].text;
      if (text.length === 0) {
        continue;
      }
      let from = 0;
      while (from < text.length) {
        const found = text.indexOf(needle, from);
        if (found < 0) {
          break;
        }
        consider(index, found);
        from = found + Math.max(needle.length, 1);
      }
    }

    if (bestDistance === Number.MAX_VALUE) {
      const collapsedNeedle = ZenTextLocator.collapseWhitespace(needle);
      if (collapsedNeedle.text.length > 0) {
        for (let index = 0; index < model.chapters.length; index++) {
          const collapsed = ZenTextLocator.collapseWhitespace(model.chapters[index].text);
          if (collapsed.text.length === 0) {
            continue;
          }
          let from = 0;
          while (from < collapsed.text.length) {
            const found = collapsed.text.indexOf(collapsedNeedle.text, from);
            if (found < 0) {
              break;
            }
            if (found < collapsed.offsets.length) {
              consider(index, collapsed.offsets[found]);
            }
            from = found + Math.max(collapsedNeedle.text.length, 1);
          }
        }
      }
    }

    if (bestDistance === Number.MAX_VALUE) {
      return null;
    }
    const chapter = model.chapters[bestChapter];
    const chapterLength = Math.max(chapter.length, 1);
    const percent = (bestChapter + bestOffset / chapterLength) / Math.max(model.chapters.length, 1) * 100;
    const payload = new ZenPositionPayload();
    payload.percent = Math.min(Math.max(percent, 0), 100);
    payload.readPage = bestOffset;
    payload.readChapter = bestChapter;
    payload.readText = needle;
    return payload;
  }

  static progressFromPercent(percent: number, readText: string,
    searchNeighborChapters: boolean, model: TextModel): number | null {
    if (model.totalLength <= 0 || model.chapters.length === 0) {
      return null;
    }
    const clamped = Math.min(Math.max(percent, 0), 100);
    const chapterPosition = clamped / 100 * model.chapters.length;
    let chapterIndex = Math.min(Math.max(Math.floor(chapterPosition), 0), model.chapters.length - 1);
    if (chapterPosition >= model.chapters.length) {
      chapterIndex = model.chapters.length - 1;
    }
    const fraction = Math.min(Math.max(chapterPosition - chapterIndex, 0), 1);
    let chapter = model.chapters[chapterIndex];
    let offsetInChapter = Math.min(
      Math.round(fraction * Math.max(chapter.length, 1)),
      chapter.length
    );
    const snippet = readText;
    if (snippet.length > 0) {
      const found = chapter.text.indexOf(snippet);
      if (found >= 0) {
        offsetInChapter = found;
      } else if (searchNeighborChapters) {
        const deltas: number[] = [-3, -2, -1, 1, 2, 3];
        for (let i = 0; i < deltas.length; i++) {
          const neighborIndex = chapterIndex + deltas[i];
          if (neighborIndex < 0 || neighborIndex >= model.chapters.length) {
            continue;
          }
          const neighbor = model.chapters[neighborIndex];
          const neighborFound = neighbor.text.indexOf(snippet);
          if (neighborFound >= 0) {
            chapter = neighbor;
            offsetInChapter = neighborFound;
            break;
          }
        }
      }
    }
    const offset = Math.min(chapter.start + offsetInChapter, model.totalLength - 1);
    return Math.min(Math.max(offset / model.totalLength, 0), 1);
  }

  private static snippet(text: string, offset: number): string {
    if (text.length === 0) {
      return '';
    }
    const start = Math.min(Math.max(offset, 0), text.length - 1);
    const window = text.substring(start, Math.min(text.length, start + 64));
    const trimmed = window.replace(/^[\s\u3000]+/, '');
    return trimmed.substring(0, 12);
  }

  private static collapseWhitespace(text: string): CollapsedText {
    const result = new CollapsedText();
    let builder = '';
    const offsets: number[] = [];
    let pendingSpace = false;
    for (let i = 0; i < text.length; i++) {
      const ch = text.charAt(i);
      if (ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r' || ch === '\u3000') {
        if (builder.length > 0) {
          pendingSpace = true;
        }
        continue;
      }
      if (pendingSpace) {
        builder += ' ';
        offsets.push(Math.max(i - 1, 0));
        pendingSpace = false;
      }
      builder += ch;
      offsets.push(i);
    }
    result.text = builder;
    result.offsets = offsets;
    return result;
  }
}
