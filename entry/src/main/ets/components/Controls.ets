import { Theme } from './Theme';

@Component
export struct ToolButton {
  @Prop label: string = '';
  /** A system symbol name from the list below; empty renders the text label. */
  @Prop icon: string = '';
  @Prop color: string = '#2C2925';
  @Prop fontSize: number = 19;
  @Prop iconSize: number = 20;
  @Prop buttonWidth: number = 40;
  onTap: () => void = (): void => {};

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.icon === 'gear') {
        SymbolGlyph($r('sys.symbol.gearshape'))
          .fontSize(this.iconSize)
          .fontColor([this.color])
      } else if (this.icon === 'bookmark') {
        SymbolGlyph($r('sys.symbol.bookmark'))
          .fontSize(this.iconSize)
          .fontColor([this.color])
      } else if (this.icon === 'note') {
        SymbolGlyph($r('sys.symbol.notepad'))
          .fontSize(this.iconSize)
          .fontColor([this.color])
      } else if (this.icon === 'search') {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(this.iconSize)
          .fontColor([this.color])
      } else if (this.icon === 'toc') {
        SymbolGlyph($r('sys.symbol.list_bullet'))
          .fontSize(this.iconSize)
          .fontColor([this.color])
      } else if (this.icon === 'close') {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(this.iconSize)
          .fontColor([this.color])
      } else if (this.icon === 'back') {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(this.iconSize)
          .fontColor([this.color])
      } else if (this.icon === 'plus') {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(this.iconSize)
          .fontColor([this.color])
      } else if (this.icon === 'sync') {
        SymbolGlyph($r('sys.symbol.arrow_counterclockwise'))
          .fontSize(this.iconSize)
          .fontColor([this.color])
      } else if (this.icon === 'refresh') {
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(this.iconSize)
          .fontColor([this.color])
      } else if (this.icon === 'folder') {
        SymbolGlyph($r('sys.symbol.folder'))
          .fontSize(this.iconSize)
          .fontColor([this.color])
      } else if (this.icon === 'sidebar-open') {
        SymbolGlyph($r('sys.symbol.open_sidebar'))
          .fontSize(this.iconSize)
          .fontColor([this.color])
      } else if (this.icon === 'sidebar-close') {
        SymbolGlyph($r('sys.symbol.close_sidebar'))
          .fontSize(this.iconSize)
          .fontColor([this.color])
      } else if (this.icon === 'grid') {
        SymbolGlyph($r('sys.symbol.square_grid_2x2'))
          .fontSize(this.iconSize)
          .fontColor([this.color])
      } else if (this.icon === 'list') {
        SymbolGlyph($r('sys.symbol.list_bullet'))
          .fontSize(this.iconSize)
          .fontColor([this.color])
      } else if (this.icon === 'textformat') {
        SymbolGlyph($r('sys.symbol.textformat'))
          .fontSize(this.iconSize)
          .fontColor([this.color])
      } else {
        Text(this.label)
          .fontSize(this.fontSize)
          .fontColor(this.color)
          .textAlign(TextAlign.Center)
      }
    }
    .width(this.buttonWidth)
    .height(40)
    .borderRadius(10)
    .onClick((): void => {
      this.onTap();
    })
  }
}

@Component
export struct OptionChip {
  @Prop label: string = '';
  @Prop selected: boolean = false;
  @Prop themeName: string = 'paper';
  onTap: () => void = (): void => {};

  build() {
    Text(this.label)
      .fontSize(12)
      .fontColor(this.selected ? Theme.bg(this.themeName) : Theme.fg(this.themeName))
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .backgroundColor(this.selected ? Theme.accent(this.themeName) : Theme.card(this.themeName))
      .borderRadius(14)
      .onClick((): void => {
        this.onTap();
      })
  }
}

@Component
export struct LibraryChip {
  @Prop label: string = '';
  @Prop count: number = 0;
  @Prop selected: boolean = false;
  @Prop themeName: string = 'paper';
  /** Optional price/lock hint, for example “¥8”. */
  @Prop badge: string = '';
  onTap: () => void = (): void => {};

  build() {
    Row({ space: 6 }) {
      Text(this.label)
        .fontSize(13)
        .fontWeight(this.selected ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.selected ? Theme.bg(this.themeName) : Theme.fg(this.themeName))
      Text('' + this.count)
        .fontSize(10)
        .fontColor(this.selected ? Theme.bg(this.themeName) : Theme.muted(this.themeName))
      if (this.badge.length > 0) {
        Text(this.badge)
          .fontSize(9)
          .fontColor(this.selected ? Theme.bg(this.themeName) : Theme.accent(this.themeName))
          .padding({ left: 5, right: 5, top: 1, bottom: 1 })
          .backgroundColor(this.selected ? '#22FFFFFF' : Theme.surface(this.themeName))
          .borderRadius(6)
      }
    }
    .padding({ left: 13, right: 13, top: 7, bottom: 7 })
    .backgroundColor(this.selected ? Theme.accent(this.themeName) : '#00000000')
    .borderRadius(18)
    .onClick((): void => {
      this.onTap();
    })
  }
}

@Component
export struct PanelTab {
  @Prop label: string = '';
  @Prop selected: boolean = false;
  @Prop themeName: string = 'paper';
  onTap: () => void = (): void => {};

  build() {
    Text(this.label)
      .fontSize(13)
      .fontWeight(this.selected ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.selected ? Theme.fg(this.themeName) : Theme.muted(this.themeName))
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .backgroundColor(this.selected ? Theme.card(this.themeName) : '#00000000')
      .borderRadius(14)
      .onClick((): void => {
        this.onTap();
      })
  }
}

@Component
export struct SectionHeader {
  @Prop text: string = '';
  @Prop color: string = '#857D70';

  build() {
    Text(this.text)
      .fontSize(11)
      .fontColor(this.color)
      .letterSpacing(1)
      .margin({ top: 16, bottom: 8 })
      .width('100%')
  }
}

@Component
export struct SettingCaption {
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop themeName: string = 'paper';

  build() {
    Row({ space: 8 }) {
      Text(this.label)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.fg(this.themeName))
      Blank()
      if (this.value.length > 0) {
        Text(this.value)
          .fontSize(10)
          .fontColor(Theme.muted(this.themeName))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor(Theme.surface(this.themeName))
          .borderRadius(7)
      }
    }
    .width('100%')
  }
}
