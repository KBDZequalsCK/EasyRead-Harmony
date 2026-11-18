import { BookmarkItem } from '../model/LibraryModels';
import { JsonCodec, JsonKind, JsonNode } from '../parser/ZenJson';
import { AppPaths, FileService } from './FileService';

export class BookmarkStore {
  private static instance: BookmarkStore | null = null;
  items: BookmarkItem[] = [];

  static shared(): BookmarkStore {
    if (BookmarkStore.instance === null) {
      BookmarkStore.instance = new BookmarkStore();
    }
    return BookmarkStore.instance;
  }

  load(): void {
    this.items = [];
    if (!FileService.exists(AppPaths.bookmarksFile())) {
      return;
    }
    try {
      const root = JsonCodec.parse(FileService.readText(AppPaths.bookmarksFile()));
      const list = root.get('items');
      if (list === null || list.kind !== JsonKind.ARRAY) {
        return;
      }
      for (let i = 0; i < list.arrayValue.length; i++) {
        const node = list.arrayValue[i];
        const item = new BookmarkItem();
        item.id = BookmarkStore.str(node, 'id');
        item.bookId = BookmarkStore.str(node, 'bookId');
        item.progress = BookmarkStore.num(node, 'progress', 0);
        item.textProgress = BookmarkStore.num(node, 'textProgress', 0);
        item.pageIndex = BookmarkStore.num(node, 'pageIndex', -1);
        item.snippet = BookmarkStore.str(node, 'snippet');
        item.note = BookmarkStore.str(node, 'note');
        item.createdAt = BookmarkStore.num(node, 'createdAt', 0);
        if (item.id.length > 0 && item.bookId.length > 0) {
          this.items.push(item);
        }
      }
    } catch (error) {
      // Ignore a damaged bookmark file; new bookmarks will rewrite it.
    }
  }

  private static str(node: JsonNode, key: string): string {
    const value = node.get(key);
    return value !== null ? value.asString() : '';
  }

  private static num(node: JsonNode, key: string, fallback: number): number {
    const value = node.get(key);
    return value !== null ? value.asNumber(fallback) : fallback;
  }

  private save(): void {
    const root = JsonNode.object();
    root.set('version', JsonNode.number(1));
    const list = JsonNode.array();
    for (let i = 0; i < this.items.length; i++) {
      const item = this.items[i];
      const node = JsonNode.object();
      node.set('id', JsonNode.string(item.id));
      node.set('bookId', JsonNode.string(item.bookId));
      node.set('progress', JsonNode.number(item.progress));
      node.set('textProgress', JsonNode.number(item.textProgress));
      node.set('pageIndex', JsonNode.number(item.pageIndex));
      node.set('snippet', JsonNode.string(item.snippet));
      node.set('note', JsonNode.string(item.note));
      node.set('createdAt', JsonNode.number(item.createdAt));
      list.arrayValue.push(node);
    }
    root.set('items', list);
    FileService.writeTextAtomic(AppPaths.bookmarksFile(), JsonCodec.stringify(root, false, true, false));
  }

  forBook(bookId: string): BookmarkItem[] {
    const result: BookmarkItem[] = [];
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].bookId === bookId) {
        result.push(this.items[i]);
      }
    }
    result.sort((a: BookmarkItem, b: BookmarkItem): number => b.createdAt - a.createdAt);
    return result;
  }

  add(item: BookmarkItem): void {
    if (item.id.length === 0) {
      item.id = 'm' + Date.now().toString(36) + Math.floor(Math.random() * 100000).toString(36);
    }
    if (item.createdAt === 0) {
      item.createdAt = Date.now();
    }
    this.items.push(item);
    this.save();
  }

  updateNote(id: string, note: string, snippet: string): void {
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].id === id) {
        this.items[i].note = note;
        if (snippet.length > 0) {
          this.items[i].snippet = snippet;
        }
        break;
      }
    }
    this.save();
  }

  remove(id: string): void {
    const next: BookmarkItem[] = [];
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].id !== id) {
        next.push(this.items[i]);
      }
    }
    this.items = next;
    this.save();
  }

  removeForBook(bookId: string): void {
    const next: BookmarkItem[] = [];
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].bookId !== bookId) {
        next.push(this.items[i]);
      }
    }
    this.items = next;
    this.save();
  }
}
