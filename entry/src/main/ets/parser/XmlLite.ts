export class XmlAttr {
  name: string = '';
  value: string = '';
}

export class XmlTag {
  name: string = '';
  localName: string = '';
  attrs: XmlAttr[] = [];
  selfClosing: boolean = false;
  start: number = 0;
  end: number = 0;
}

/** Minimal tag scanner for OPF/NCX/container files and DOCX-like XML. */
export class XmlLite {
  static tags(xml: string, localName: string): XmlTag[] {
    const result: XmlTag[] = [];
    const pattern = /<([A-Za-z_][A-Za-z0-9_.:-]*)((?:"[^"]*"|'[^']*'|[^>])*?)(\/?)>/g;
    let match: RegExpExecArray | null = pattern.exec(xml);
    while (match !== null) {
      const fullName = match[1];
      const local = fullName.indexOf(':') >= 0 ? fullName.substring(fullName.indexOf(':') + 1) : fullName;
      if (local === localName) {
        const tag = new XmlTag();
        tag.name = fullName;
        tag.localName = local;
        tag.selfClosing = match[3] === '/';
        tag.start = match.index;
        tag.end = match.index + match[0].length;
        XmlLite.parseAttrs(match[2], tag.attrs);
        result.push(tag);
      }
      match = pattern.exec(xml);
    }
    return result;
  }

  static parseAttrs(source: string, target: XmlAttr[]): void {
    const pattern = /([A-Za-z_][A-Za-z0-9_.:-]*)\s*=\s*("([^"]*)"|'([^']*)')/g;
    let match: RegExpExecArray | null = pattern.exec(source);
    while (match !== null) {
      const attr = new XmlAttr();
      attr.name = match[1];
      attr.value = match[3] !== undefined ? match[3] : match[4];
      target.push(attr);
      match = pattern.exec(source);
    }
  }

  static attr(tag: XmlTag, name: string, defaultValue: string = ''): string {
    for (let i = 0; i < tag.attrs.length; i++) {
      if (tag.attrs[i].name === name) {
        return tag.attrs[i].value;
      }
    }
    // Namespaced attributes such as `xlink:href` are often written with
    // different prefixes; accept the local name as a fallback.
    for (let i = 0; i < tag.attrs.length; i++) {
      const attrName = tag.attrs[i].name;
      const local = attrName.indexOf(':') >= 0 ? attrName.substring(attrName.indexOf(':') + 1) : attrName;
      if (local === name) {
        return tag.attrs[i].value;
      }
    }
    return defaultValue;
  }

  static hasAttr(tag: XmlTag, name: string): boolean {
    return XmlLite.attr(tag, name, '\u0000') !== '\u0000';
  }

  /** Raw inner text between a tag's end and its matching close tag. */
  static inner(xml: string, tag: XmlTag): string {
    if (tag.selfClosing) {
      return '';
    }
    const pattern = new RegExp('</' + tag.name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\s*>', 'g');
    pattern.lastIndex = tag.end;
    const match = pattern.exec(xml);
    if (match === null) {
      return '';
    }
    return xml.substring(tag.end, match.index);
  }

  static firstInner(xml: string, localName: string): string {
    const tags = XmlLite.tags(xml, localName);
    if (tags.length === 0) {
      return '';
    }
    return XmlLite.inner(xml, tags[0]);
  }

  static decode(value: string): string {
    return value
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&apos;/g, '\'')
      .replace(/&#x([0-9a-fA-F]+);/g, (m: string, hex: string): string => String.fromCodePoint(parseInt(hex, 16)))
      .replace(/&#([0-9]+);/g, (m: string, digits: string): string => String.fromCodePoint(parseInt(digits, 10)))
      .replace(/&amp;/g, '&');
  }
}

/** Joins a relative href onto a base directory and normalizes `..`. */
export function resolvePath(baseDir: string, href: string): string {
  let value = href;
  const hash = value.indexOf('#');
  if (hash >= 0) {
    value = value.substring(0, hash);
  }
  const query = value.indexOf('?');
  if (query >= 0) {
    value = value.substring(0, query);
  }
  try {
    value = decodeURIComponent(value);
  } catch (error) {
    // Keep the raw value when it contains a stray percent sign.
  }
  if (value.startsWith('/')) {
    value = value.substring(1);
  }
  const parts: string[] = [];
  const baseParts = baseDir.length > 0 ? baseDir.split('/') : [];
  for (let i = 0; i < baseParts.length; i++) {
    if (baseParts[i].length > 0 && baseParts[i] !== '.') {
      parts.push(baseParts[i]);
    }
  }
  const segments = value.split('/');
  for (let i = 0; i < segments.length; i++) {
    const segment = segments[i];
    if (segment.length === 0 || segment === '.') {
      continue;
    }
    if (segment === '..') {
      if (parts.length > 0) {
        parts.pop();
      }
    } else {
      parts.push(segment);
    }
  }
  return parts.join('/');
}

export function dirName(path: string): string {
  const slash = path.lastIndexOf('/');
  return slash >= 0 ? path.substring(0, slash) : '';
}

export function baseName(path: string): string {
  const slash = path.lastIndexOf('/');
  return slash >= 0 ? path.substring(slash + 1) : path;
}

export function stripExtension(path: string): string {
  const slash = path.lastIndexOf('/');
  const dot = path.lastIndexOf('.');
  if (dot > slash) {
    return path.substring(0, dot);
  }
  return path;
}
