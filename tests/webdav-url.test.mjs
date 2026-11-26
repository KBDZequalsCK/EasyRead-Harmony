import test from 'node:test';
import assert from 'node:assert/strict';

import {
  normalizeWebDavRoots,
  webDavUrl,
  WebDavUrlError,
} from '../entry/src/main/ets/service/WebDavUrl.ts';

const JIANGUO = 'https://dav.jianguoyun.com/dav/';

function mkcolOnAccount(roots, relativePath) {
  return webDavUrl(roots.accountUrl, relativePath + '/');
}

test('ZenReader layout keeps account root and layout root apart', () => {
  const roots = normalizeWebDavRoots(JIANGUO, 'ZenReader/v1');
  assert.equal(roots.accountUrl, JIANGUO);
  assert.equal(roots.rootUrl, 'https://dav.jianguoyun.com/dav/ZenReader/v1/');
  assert.equal(roots.collection, 'ZenReader/v1');
});

test('ensureRoot target never appends the layout twice', () => {
  const roots = normalizeWebDavRoots(JIANGUO, 'ZenReader/v1');
  assert.equal(
    mkcolOnAccount(roots, roots.collection),
    'https://dav.jianguoyun.com/dav/ZenReader/v1/'
  );
  assert.notEqual(
    mkcolOnAccount(roots, roots.collection),
    'https://dav.jianguoyun.com/dav/ZenReader/v1/ZenReader/v1/'
  );
});

test('file requests stay under the layout root', () => {
  const roots = normalizeWebDavRoots(JIANGUO, 'ZenReader/v1');
  assert.equal(
    webDavUrl(roots.rootUrl, 'manifest.json'),
    'https://dav.jianguoyun.com/dav/ZenReader/v1/manifest.json'
  );
  assert.equal(
    webDavUrl(roots.rootUrl, 'snapshots/'),
    'https://dav.jianguoyun.com/dav/ZenReader/v1/snapshots/'
  );
  assert.equal(
    webDavUrl(roots.rootUrl, 'objects/books/a.epub'),
    'https://dav.jianguoyun.com/dav/ZenReader/v1/objects/books/a.epub'
  );
});

test('EasyRead layout uses a single EasyRead folder', () => {
  const roots = normalizeWebDavRoots(JIANGUO, 'EasyRead');
  assert.equal(roots.rootUrl, 'https://dav.jianguoyun.com/dav/EasyRead/');
  assert.equal(
    mkcolOnAccount(roots, roots.collection),
    'https://dav.jianguoyun.com/dav/EasyRead/'
  );
  assert.equal(
    webDavUrl(roots.rootUrl, 'manifest.json'),
    'https://dav.jianguoyun.com/dav/EasyRead/manifest.json'
  );
});

test('missing trailing slash normalizes the same as a trailing slash', () => {
  const withSlash = normalizeWebDavRoots(JIANGUO, 'EasyRead');
  const withoutSlash = normalizeWebDavRoots('https://dav.jianguoyun.com/dav', 'EasyRead');
  assert.deepEqual(withoutSlash, withSlash);
});

test('a pasted layout suffix is stripped before appending', () => {
  const variants = [
    'https://dav.jianguoyun.com/dav/ZenReader/v1',
    'https://dav.jianguoyun.com/dav/ZenReader/v1/',
    'https://dav.jianguoyun.com/dav/ZenReader',
    'https://dav.jianguoyun.com/dav/EasyRead/',
    'https://dav.jianguoyun.com/dav/zenreader/V1',
  ];
  for (const server of variants) {
    const roots = normalizeWebDavRoots(server, 'ZenReader/v1');
    assert.equal(roots.accountUrl, JIANGUO, server);
    assert.equal(roots.rootUrl, JIANGUO + 'ZenReader/v1/', server);
  }
});

test('the layout selection wins over a pasted suffix', () => {
  const roots = normalizeWebDavRoots(
    'https://dav.jianguoyun.com/dav/ZenReader/v1/',
    'EasyRead'
  );
  assert.equal(roots.accountUrl, JIANGUO);
  assert.equal(roots.rootUrl, JIANGUO + 'EasyRead/');
});

test('repeated accidental nesting collapses to the account root', () => {
  const roots = normalizeWebDavRoots(
    'https://dav.jianguoyun.com/dav/ZenReader/v1/ZenReader/v1/',
    'ZenReader/v1'
  );
  assert.equal(roots.accountUrl, JIANGUO);
  assert.equal(roots.rootUrl, JIANGUO + 'ZenReader/v1/');
  assert.ok(!roots.rootUrl.includes('ZenReader/v1/ZenReader/v1'));
});

test('query and fragment are dropped', () => {
  const roots = normalizeWebDavRoots(
    'https://dav.jianguoyun.com/dav/?token=x#frag',
    'EasyRead'
  );
  assert.equal(roots.accountUrl, JIANGUO);
  assert.equal(roots.rootUrl, JIANGUO + 'EasyRead/');
});

test('plain HTTP is only allowed for local debugging', () => {
  assert.equal(
    normalizeWebDavRoots('http://127.0.0.1:8080/dav', 'EasyRead').accountUrl,
    'http://127.0.0.1:8080/dav/'
  );
  assert.equal(
    normalizeWebDavRoots('http://localhost:8080/dav/', 'EasyRead').accountUrl,
    'http://localhost:8080/dav/'
  );
  assert.throws(
    () => normalizeWebDavRoots('http://example.com/dav', 'EasyRead'),
    WebDavUrlError
  );
});

test('invalid addresses are rejected', () => {
  assert.throws(() => normalizeWebDavRoots('', 'EasyRead'), WebDavUrlError);
  assert.throws(() => normalizeWebDavRoots('dav.example.com/dav', 'EasyRead'), WebDavUrlError);
  assert.throws(() => normalizeWebDavRoots('ftp://example.com/dav', 'EasyRead'), WebDavUrlError);
});

test('webDavUrl joins bases and paths with exactly one slash', () => {
  assert.equal(
    webDavUrl('https://example.com/dav/EasyRead/', '/manifest.json'),
    'https://example.com/dav/EasyRead/manifest.json'
  );
  assert.equal(
    webDavUrl('https://example.com/dav/EasyRead', 'manifest.json'),
    'https://example.com/dav/EasyRead/manifest.json'
  );
});