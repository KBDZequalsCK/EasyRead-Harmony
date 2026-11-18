import { LibraryBook } from '../model/LibraryModels';
import { Theme } from './Theme';

@Component
export struct BookCover {
  @Prop book: LibraryBook = new LibraryBook();
  @Prop themeName: string = 'paper';
  @Prop showAuthor: boolean = true;
  onOpen: (book: LibraryBook) => void = (book: LibraryBook): void => {};
  onMenu: (book: LibraryBook) => void = (book: LibraryBook): void => {};

  private percent(): number {
    const value = this.book.displayProgress();
    return Math.round(Math.min(Math.max(value, 0), 1) * 100);
  }

  private authorLine(): string {
    if (this.book.author.length > 0) {
      return this.book.author;
    }
    return this.book.format + ' · ' + Math.max(1, Math.round(this.book.size / 1024)) + ' KB';
  }

  build() {
    Column({ space: 8 }) {
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.book.coverPath.length > 0) {
          Image('file://' + this.book.coverPath)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .alt($r('app.media.app_icon'))
        } else {
          Column() {
            Blank()
            Text(this.book.title)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
              .maxLines(4)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Start)
              .width('100%')
          }
          .width('100%')
          .height('100%')
          .padding(14)
          .alignItems(HorizontalAlign.Start)
          .linearGradient({
            angle: 145,
            colors: [[Theme.formatColor(this.book.format), 0], ['#24211D', 1]]
          })
        }

        Row() {
          Text(this.book.format)
            .fontSize(10)
            .fontColor('#FFFFFF')
            .backgroundColor('#66000000')
            .borderRadius(6)
            .padding({ left: 6, right: 6, top: 3, bottom: 3 })
        }
        .margin(8)
      }
      .width('100%')
      .aspectRatio(0.68)
      .borderRadius(12)
      .clip(true)
      .shadow({
        radius: 12,
        color: Theme.isDark(this.themeName) ? '#66000000' : '#401F1A12',
        offsetX: 0,
        offsetY: 5
      })
      .onClick(() => {
        this.onOpen(this.book);
      })
      .gesture(LongPressGesture().onAction(() => {
        this.onMenu(this.book);
      }))

      Column({ space: 3 }) {
        Text(this.book.title)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.fg(this.themeName))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (this.showAuthor) {
          Row({ space: 6 }) {
            Text(this.authorLine())
              .fontSize(11)
              .fontColor(Theme.muted(this.themeName))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (this.percent() > 0) {
              Text(this.percent() + '%')
                .fontSize(10)
                .fontColor(Theme.muted(this.themeName))
            }
          }
          .width('100%')
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%')
          .height(3)
          .backgroundColor(Theme.line(this.themeName))
          .borderRadius(2)
        Row()
          .width(this.percent() + '%')
          .height(3)
          .backgroundColor(Theme.progress(this.themeName))
          .borderRadius(2)
      }
      .width('100%')
      .height(3)
      .margin({ top: 1 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/** One compact line of the shelf's list view. */
@Component
export struct BookRow {
  @Prop book: LibraryBook = new LibraryBook();
  @Prop themeName: string = 'paper';
  onOpen: (book: LibraryBook) => void = (book: LibraryBook): void => {};
  onMenu: (book: LibraryBook) => void = (book: LibraryBook): void => {};

  private percent(): number {
    const value = this.book.displayProgress();
    return Math.round(Math.min(Math.max(value, 0), 1) * 100);
  }

  private detailLine(): string {
    if (this.book.author.length > 0) {
      return this.book.author + ' · ' + this.book.format;
    }
    return this.book.format + ' · ' + Math.max(1, Math.round(this.book.size / 1024)) + ' KB';
  }

  private lastReadText(): string {
    if (this.book.progressUpdatedAt <= 0) {
      return this.percent() > 0 ? '有阅读进度' : '尚未阅读';
    }
    const date = new Date(this.book.progressUpdatedAt);
    const pad = (value: number): string => value < 10 ? '0' + value : '' + value;
    return '上次 ' + (date.getMonth() + 1) + '月' + date.getDate() + '日 ' +
      pad(date.getHours()) + ':' + pad(date.getMinutes());
  }

  build() {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        if (this.book.coverPath.length > 0) {
          Image('file://' + this.book.coverPath)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .alt($r('app.media.app_icon'))
        } else {
          Column() {
            Text(this.book.format)
              .fontSize(9)
              .fontColor('#FFFFFF')
              .fontWeight(FontWeight.Medium)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .linearGradient({
            angle: 145,
            colors: [[Theme.formatColor(this.book.format), 0], ['#24211D', 1]]
          })
        }
      }
      .width(44)
      .height(60)
      .borderRadius(7)
      .clip(true)

      Column({ space: 4 }) {
        Row({ space: 8 }) {
          Text(this.book.title)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.fg(this.themeName))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.percent() > 0) {
            Text(this.percent() + '%')
              .fontSize(10)
              .fontColor(Theme.accent(this.themeName))
          }
        }
        .width('100%')

        Text(this.detailLine())
          .fontSize(10)
          .fontColor(Theme.muted(this.themeName))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width('100%')
            .height(3)
            .backgroundColor(Theme.line(this.themeName))
            .borderRadius(2)
          Row()
            .width(this.percent() + '%')
            .height(3)
            .backgroundColor(Theme.progress(this.themeName))
            .borderRadius(2)
        }
        .width('100%')
        .height(3)
        .margin({ top: 1 })

        Row() {
          Text(this.lastReadText())
            .fontSize(9)
            .fontColor(Theme.muted(this.themeName))
          Blank()
          Text('⋯')
            .fontSize(16)
            .fontColor(Theme.muted(this.themeName))
            .padding({ left: 10, right: 2, top: 1, bottom: 1 })
            .onClick((): void => {
              this.onMenu(this.book);
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 10, right: 8, top: 9, bottom: 9 })
    .backgroundColor(Theme.card(this.themeName))
    .borderRadius(12)
    .onClick((): void => {
      this.onOpen(this.book);
    })
    .gesture(LongPressGesture().onAction((): void => {
      this.onMenu(this.book);
    }))
  }
}
