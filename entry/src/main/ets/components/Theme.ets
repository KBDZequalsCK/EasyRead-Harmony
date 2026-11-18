export class Theme {
  static bg(theme: string): string {
    if (theme === 'night') {
      return '#101214';
    }
    if (theme === 'sepia') {
      return '#F6ECD7';
    }
    if (theme === 'green') {
      return '#E9F0E6';
    }
    return '#FBFAF7';
  }

  static surface(theme: string): string {
    if (theme === 'night') {
      return '#171A1D';
    }
    if (theme === 'sepia') {
      return '#EFE2C8';
    }
    if (theme === 'green') {
      return '#DFEADB';
    }
    return '#F3EFE6';
  }

  static card(theme: string): string {
    if (theme === 'night') {
      return '#1C2024';
    }
    return '#FFFFFF';
  }

  static fg(theme: string): string {
    return theme === 'night' ? '#D9D5CC' : '#2C2925';
  }

  static muted(theme: string): string {
    return theme === 'night' ? '#8C867B' : '#857D70';
  }

  static line(theme: string): string {
    return theme === 'night' ? '#2A2F34' : '#E7E1D5';
  }

  static accent(theme: string): string {
    return theme === 'night' ? '#C9A227' : '#8A5A2B';
  }

  static accentSoft(theme: string): string {
    return theme === 'night' ? '#332A12' : '#F1E5D2';
  }

  static isDark(theme: string): boolean {
    return theme === 'night';
  }

  static progress(theme: string): string {
    return theme === 'night' ? '#C9A227' : '#A66A33';
  }

  static formatColor(format: string): string {
    if (format === 'EPUB') {
      return '#3F6B4A';
    }
    if (format === 'PDF') {
      return '#9C3D3D';
    }
    if (format === 'MOBI' || format === 'AZW' || format === 'AZW3') {
      return '#7A5B2E';
    }
    if (format === 'CBZ') {
      return '#4A5578';
    }
    if (format === 'MD') {
      return '#5B4A86';
    }
    if (format === 'TXT') {
      return '#6B6257';
    }
    return '#6C6A65';
  }
}
