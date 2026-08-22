import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(testDirectory, '..', 'linux-host', 'index.html'), 'utf8');
const classStart = source.indexOf('class SemanticStream');
const classEnd = source.indexOf('\n    const $=', classStart);
assert.ok(classStart >= 0 && classEnd > classStart, 'Linux browser Chat semantic stream is present');

const SemanticStream = Function(`${source.slice(classStart, classEnd)}; return SemanticStream;`)();
const encoder = new TextEncoder();
const stream = new SemanticStream();

stream.feedBytes(encoder.encode('prompt$ echo hello\r'));
stream.feedBytes(encoder.encode('\n\u001b[32mhello\u001b[0m\r\nprompt$ '));
assert.equal(stream.text.includes('\u001b'), false, 'Chat never exposes ANSI controls');
assert.match(stream.text, /prompt\$ echo hello\nhello\nprompt\$ /, 'packet-split CRLF preserves readable command output');

const progress = new SemanticStream();
progress.feedBytes(encoder.encode('Downloading 10%\rDownloading 50%'));
assert.equal(progress.text, 'Downloading 50%', 'standalone carriage returns rewrite the current semantic line');

const bounded = new SemanticStream();
bounded.feedBytes(encoder.encode('x'.repeat(30_000)));
assert.equal(bounded.text.length, 24_000, 'Chat response memory stays bounded');

assert.match(source, /node\.responseSemantic=new SemanticStream\(\)/, 'each Chat submission starts a new response boundary');
assert.match(source, /if\(node\.responseSemantic&&node\.turns\.length\)/, 'startup output remains outside Chat turns');
assert.match(source, /looksLikeShellPrompt\(turn\.response\)/, 'returned shell prompts complete the current Chat turn');

console.log('Linux browser Chat regression tests passed');
