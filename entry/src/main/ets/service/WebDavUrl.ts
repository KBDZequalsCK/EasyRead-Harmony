/**
 * Pure URL rules for WebDAV. Kept free of HarmonyOS imports so the Node
 * regression test can exercise the exact same code that ships in the app.
 *
 * Two roots are kept apart on purpose:
 * - accountUrl: the account / server root the user typed, ending in "/"
 * - rootUrl: accountUrl + the selected layout ("EasyRead" or "ZenReader/v1")
 *
 * Collections are created below accountUrl; file requests use rootUrl.
 * Mixing them creates .../ZenReader/v1/ZenReader/v1.
 */

export class WebDavRoots {
  accountUrl: string = '';
  rootUrl: string = '';
  collection: string = '';
}

export class WebDavUrlError extends Error {
  constructor(message: string) {
    super(message);
  }
}

const LAYOUT_NAMES: string[] = ['easyread', 'zenreader'];

/** Removes trailing EasyRead / ZenReader / ZenReader/v1 path segments. */
function stripLayoutSuffix(path: string): string {
  let result = path;
  let changed = true;
  while (changed) {
    changed = false;
    const slash = result.lastIndexOf('/');
    if (slash < 0) {
      break;
    }
    const last = result.substring(slash + 1).toLowerCase();
    if (last === 'v1') {
      const before = result.substring(0, slash);
      const parentSlash = before.lastIndexOf('/');
      const parent = parentSlash >= 0 ?
        before.substring(parentSlash + 1).toLowerCase() : before.toLowerCase();
      if (parent === 'zenreader' || parent === 'easyread') {
        result = parentSlash >= 0 ? before.substring(0, parentSlash) : '';
        changed = true;
      }
    } else if (LAYOUT_NAMES.indexOf(last) >= 0) {
      result = slash >= 0 ? result.substring(0, slash) : '';
      changed = true;
    }
  }
  while (result.endsWith('/')) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

export function normalizeWebDavRoots(server: string, collection: string): WebDavRoots {
  let value = server.trim();
  const cut = value.search(/[?#]/);
  if (cut >= 0) {
    value = value.substring(0, cut);
  }
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  const match = value.match(/^(https?):\/\/([^\/]+)(\/.*)?$/i);
  if (match === null) {
    throw new WebDavUrlError('服务器地址无效');
  }
  const scheme = match[1].toLowerCase();
  let host = match[2].toLowerCase();
  if (host.startsWith('[')) {
    const end = host.indexOf(']');
    if (end >= 0) {
      host = host.substring(0, end + 1);
    }
  } else {
    const colon = host.indexOf(':');
    if (colon >= 0) {
      host = host.substring(0, colon);
    }
  }
  if (scheme === 'http' && host !== '127.0.0.1' && host !== 'localhost' && host !== '[::1]') {
    throw new WebDavUrlError('除本机调试外，服务器必须使用 HTTPS');
  }

  let path = match[3] !== undefined ? match[3] : '';
  path = stripLayoutSuffix(path);

  let layout = collection.trim();
  while (layout.startsWith('/')) {
    layout = layout.substring(1);
  }
  while (layout.endsWith('/')) {
    layout = layout.substring(0, layout.length - 1);
  }
  if (layout.length === 0) {
    throw new WebDavUrlError('同步目录无效');
  }

  const roots = new WebDavRoots();
  roots.accountUrl = scheme + '://' + match[2] + path + '/';
  roots.collection = layout;
  roots.rootUrl = roots.accountUrl + layout + '/';
  return roots;
}

/** Joins a base (with or without a trailing slash) and a relative path. */
export function webDavUrl(baseUrl: string, relativePath: string): string {
  let base = baseUrl;
  if (!base.endsWith('/')) {
    base += '/';
  }
  let path = relativePath;
  while (path.startsWith('/')) {
    path = path.substring(1);
  }
  return base + path;
}