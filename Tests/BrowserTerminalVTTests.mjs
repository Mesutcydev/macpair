import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const testDirectory = dirname(fileURLToPath(import.meta.url));
const sourcePath = join(testDirectory, '..', 'Sources', 'HostApp', 'HostBrowserControlService.swift');
const source = await readFile(sourcePath, 'utf8');
const classStart = source.indexOf('class VampBrowserVT');
const classEnd = source.indexOf('\n\nconst vampNextTerminalTitle', classStart);
assert.ok(classStart >= 0, 'VampBrowserVT class is present');
assert.ok(classEnd > classStart, 'VampBrowserVT class boundary is present');

const escapeHTML = (value) => String(value)
  .replaceAll('&', '&amp;')
  .replaceAll('<', '&lt;')
  .replaceAll('>', '&gt;')
  .replaceAll('"', '&quot;')
  .replaceAll("'", '&#39;');

const VampBrowserVT = new Function('esc', `${source.slice(classStart, classEnd)}\nreturn VampBrowserVT;`)(escapeHTML);
const textEncoder = new TextEncoder();
const terminal = (cols = 80, rows = 24) => new VampBrowserVT(cols, rows);

{
  const vt = terminal();
  vt.feed('\u001b[38;5;');
  vt.feed('255mHello');
  vt.feed('\u001b[0m');
  assert.equal(vt.render().includes('38;5;255m'), false, 'fragmented SGR is not rendered as text');
  assert.equal(vt.render().includes('Hello'), true, 'text after fragmented SGR is rendered');
  assert.match(vt.renderHTML(), /rgb\(238,238,238\)/, '256-color SGR reaches the cell renderer');
}

{
  const vt = terminal(40, 8);
  vt.feed('Downloading 10%\rDownloading 50%\rDownloading 100%');
  assert.equal(vt.render().split('\n')[0], 'Downloading 100%', 'carriage return rewrites the current line');
}

{
  const vt = terminal(40, 8);
  vt.feed('hello\u001b[2D!!');
  assert.equal(vt.render().split('\n')[0], 'hel!!', 'cursor movement overwrites existing cells');
}

{
  const vt = terminal(40, 8);
  vt.feed('abc\u001b[2K');
  assert.equal(vt.render().trim(), '', 'erase-line clears the active row');
}

{
  const vt = terminal(40, 8);
  const bytes = textEncoder.encode('café');
  for (const byte of bytes) vt.feedBytes(Uint8Array.of(byte));
  assert.equal(vt.render().split('\n')[0], 'café', 'UTF-8 characters survive byte fragmentation');
}

{
  const vt = terminal(40, 8);
  vt.feed('a\tb');
  assert.equal(vt.render().split('\n')[0].indexOf('b'), 8, 'tab stops use terminal columns');
}

{
  const vt = terminal(40, 8);
  vt.feed('\u001b[38;2;100;200;255mTRUECOLOR\u001b[0m');
  assert.match(vt.renderHTML(), /rgb\(100,200,255\)/, 'truecolor SGR reaches the cell renderer');
}

{
  const vt = terminal(40, 8);
  vt.feed('main buffer');
  vt.feed('\u001b[?1049halt buffer');
  assert.equal(vt.render().includes('alt buffer'), true, 'alternate screen is isolated while active');
  vt.feed('\u001b[?1049l');
  assert.equal(vt.render().includes('main buffer'), true, 'alternate screen restores the main buffer');
  assert.equal(vt.render().includes('alt buffer'), false, 'alternate screen content is not leaked after restore');
}

{
  const vt = terminal(40, 8);
  vt.feed('stable');
  vt.resize(80, 16);
  assert.equal(vt.cols, 80, 'resize updates terminal columns');
  assert.equal(vt.rows, 16, 'resize updates terminal rows');
  assert.equal(vt.render().split('\n')[0], 'stable', 'resize preserves visible terminal state');
}

console.log('browser VT regression checks passed');
