#!/usr/bin/env node

// Executes ClipSync's real inline page script with deterministic timers and a
// small upload service. It protects the client queue from the server's upload
// admission limits without changing those limits.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

class Element {
  constructor(id = '') {
    this.id = id;
    this.value = '';
    this.className = '';
    this.dataset = {};
    this.children = [];
    this.parentNode = null;
    this.listeners = {};
    this.checked = false;
    this.clickCount = 0;
    this._textContent = '';
    this.textWrites = 0;
    const classes = new Set();
    this.classList = {
      add: (...names) => names.forEach((name) => classes.add(name)),
      remove: (...names) => names.forEach((name) => classes.delete(name)),
      contains: (name) => classes.has(name),
    };
  }

  get textContent() { return this._textContent; }
  set textContent(value) { this._textContent = String(value); this.textWrites++; }
  get firstChild() { return this.children[0] || null; }
  get innerHTML() { return this._innerHTML || ''; }
  set innerHTML(value) { this._innerHTML = value; this.children = []; }
  addEventListener(name, handler) { this.listeners[name] = handler; }
  appendChild(child) { child.parentNode = this; this.children.push(child); return child; }
  insertBefore(child, before) {
    child.parentNode = this;
    const index = this.children.indexOf(before);
    this.children.splice(index < 0 ? this.children.length : index, 0, child);
    return child;
  }
  removeChild(child) {
    const index = this.children.indexOf(child);
    if (index >= 0) this.children.splice(index, 1);
    child.parentNode = null;
  }
  replaceChild(next, previous) {
    const index = this.children.indexOf(previous);
    if (index >= 0) {
      previous.parentNode = null;
      next.parentNode = this;
      this.children[index] = next;
    }
    return previous;
  }
  remove() { if (this.parentNode) this.parentNode.removeChild(this); }
  querySelector(selector) {
    if (selector === '#empty') return this.children.find((child) => child.id === 'empty') || null;
    if (selector === '.card') return this.children.find((child) => child.className.includes('card')) || null;
    const id = selector.match(/^\.card\[data-id="(.+)"\]$/);
    if (id) return this.children.find((child) => child.className.includes('card') && child.dataset.id === id[1]) || null;
    return null;
  }
  querySelectorAll(selector) { return selector === '.card' ? this.children.filter((child) => child.className.includes('card')) : []; }
  click() { this.clickCount++; if (this.onclick) this.onclick({ preventDefault() {}, stopPropagation() {} }); }
}

class FileLike {
  constructor(name, type = 'application/octet-stream', size = 8) {
    this.name = name;
    this.type = type;
    this.size = size;
  }
  slice(start, end) { return { size: end - start }; }
}

function response(status, body, headers = {}) {
  return {
    status,
    ok: status >= 200 && status < 300,
    headers: { get: (name) => headers[name] || headers[name.toLowerCase()] || null },
    json: () => Promise.resolve(body),
    text: () => Promise.resolve(typeof body === 'string' ? body : ''),
  };
}

function createHarness(fetchHandler) {
  const ids = ['box', 'dot', 'status', 'feed', 'room-name', 'room-summary-status', 'theme', 'theme-control', 'room', 'toast', 'count', 'send', 'clear', 'drop', 'choose', 'files', 'join', 'rnd', 'upload-status'];
  const elements = Object.fromEntries(ids.map((id) => [id, new Element(id)]));
  const documentListeners = {};
  const body = new Element('body');
  body.dataset = {};
  const document = {
    body,
    hidden: false,
    querySelector(selector) { return elements[selector.slice(1)] || null; },
    createElement() { return new Element(); },
    addEventListener(name, handler) { documentListeners[name] = handler; },
    execCommand() { return true; },
  };
  let now = 0;
  let timerID = 0;
  const timers = new Map();
  const setTimeoutMock = (fn, delay = 0) => {
    const id = ++timerID;
    timers.set(id, { fn, due: now + delay });
    return id;
  };
  const clearTimeoutMock = (id) => timers.delete(id);
  const advance = (milliseconds) => {
    const target = now + milliseconds;
    for (;;) {
      let next = null;
      for (const [id, timer] of timers) if (timer.due <= target && (!next || timer.due < next.timer.due)) next = { id, timer };
      if (!next) break;
      timers.delete(next.id);
      now = next.timer.due;
      next.timer.fn();
    }
    now = target;
  };
  const RealDate = Date;
  function FakeDate(...args) { return new RealDate(...(args.length ? args : [now])); }
  FakeDate.now = () => now;
  FakeDate.parse = RealDate.parse;
  FakeDate.prototype = RealDate.prototype;
  class AbortControllerMock {
    constructor() { this.signal = { aborted: false }; }
    abort() { this.signal.aborted = true; }
  }
  class EventSource {
    constructor() { this.closed = false; setTimeoutMock(() => { if (!this.closed && this.onopen) this.onopen(); }); }
    close() { this.closed = true; }
  }
  const storage = new Map();
  const localStorage = { getItem: (key) => storage.get(key) || null, setItem: (key, value) => storage.set(key, String(value)) };
  const location = { hash: '', reload() {} };
  const window = {
    CLIPSYNC_ROOM_LIMIT: 64,
    CLIPSYNC_MAX_TEXT_BYTES: 1024,
    CLIPSYNC_MAX_FILE_BYTES: 1024 * 1024,
    crypto: { getRandomValues(bytes) { for (let index = 0; index < bytes.length; index++) bytes[index] = index + 1; } },
    addEventListener() {},
    confirm: () => true,
  };
  const requests = [];
  const sandbox = {
    window, document, localStorage, location, EventSource, AbortController: AbortControllerMock,
    setTimeout: setTimeoutMock, clearTimeout: clearTimeoutMock,
    fetch: (url, options = {}) => { requests.push({ url, options }); return fetchHandler(url, options, { now, setTimeout: setTimeoutMock }); },
    navigator: {}, crypto: window.crypto, Uint8Array, Blob, File: FileLike, console, JSON, Math, Date: FakeDate, RegExp, Array, Promise, encodeURIComponent, decodeURIComponent,
  };
  const source = fs.readFileSync(path.join(__dirname, '..', 'web.go'), 'utf8');
  const match = source.match(/<script>\n([\s\S]*?)\n<\/script>/);
  assert(match, 'could not extract the page script from web.go');
  vm.runInNewContext(match[1], sandbox, { filename: 'web.go:inline-script' });
  return { elements, documentListeners, requests, advance };
}

async function settle(rounds = 14) { for (let index = 0; index < rounds; index++) await Promise.resolve(); }

async function openRoom(page, room) {
  page.elements.room.value = room;
  page.elements.join.click();
  page.advance(250);
  await settle();
}

function normalUploadService(delay = 10) {
  const state = { starts: [], active: 0, maxActive: 0, completes: [], aborts: [] };
  return {
    state,
    fetch(url, options, clock) {
      if (url.startsWith('list?')) return Promise.resolve(response(200, { items: [] }));
      if (url.startsWith('upload/start?')) {
        const name = options.headers['X-Name'];
        state.starts.push(name);
        state.active++;
        state.maxActive = Math.max(state.maxActive, state.active);
        return Promise.resolve(response(200, { upload: `u-${name}`, chunkSize: 8 }));
      }
      if (url.startsWith('upload/chunk?')) return Promise.resolve(response(200, { received: 8 }));
      if (url.startsWith('upload/complete?')) {
        const name = decodeURIComponent(url.match(/upload=u-([^&]+)/)[1]);
        return new Promise((resolve) => clock.setTimeout(() => {
          state.active--;
          state.completes.push(name);
          resolve(response(200, { id: `item-${name}`, kind: 'file', name, size: 8, from: 'test', at: 1 }));
        }, delay));
      }
      if (url.startsWith('upload/abort?')) { state.aborts.push(url); return Promise.resolve(response(200, {})); }
      if (url.startsWith('push?')) return Promise.resolve(response(200, { id: 'image', kind: 'image', size: 8, from: 'test', at: 1 }));
      return Promise.resolve(response(200, {}));
    },
  };
}

async function drain(page, rounds = 20) {
  for (let index = 0; index < rounds; index++) { await settle(); page.advance(20); }
  await settle();
}

async function testFifoConcurrencyAcrossSources() {
  const service = normalUploadService();
  const page = createHarness(service.fetch);
  await openRoom(page, 'queue-room');
  const picker = [new FileLike('pick-1'), new FileLike('pick-2'), new FileLike('pick-3'), new FileLike('pick-4')];
  page.elements.files.listeners.change({ target: { files: picker, value: 'chosen' } });
  const drop = [new FileLike('drop-1'), new FileLike('drop-2'), new FileLike('drop-3')];
  page.elements.drop.listeners.drop({ dataTransfer: { types: ['Files'], files: drop, dropEffect: '' }, preventDefault() {} });
  const pasted = [new FileLike('paste-1'), new FileLike('paste-2'), new FileLike('paste-3')];
  page.documentListeners.paste({ clipboardData: { items: pasted.map((file) => ({ kind: 'file', getAsFile: () => file })), getData: () => '' }, preventDefault() {} });
  await settle();
  assert.equal(service.state.maxActive, 2, 'no more than two resumable workflows may be active');
  await drain(page);
  assert.deepEqual(service.state.starts, ['pick-1', 'pick-2', 'pick-3', 'pick-4', 'drop-1', 'drop-2', 'drop-3', 'paste-1', 'paste-2', 'paste-3'], 'picker, drop, and paste files must use one FIFO');
  assert.equal(service.state.completes.length, 10, 'all ten ordinary files must complete');
  assert.match(page.elements['upload-status'].textContent, /10 uploads complete/, 'the composer must retain compact upload progress/result text');
}

async function testRetryAfterAndImageBypass() {
  let startAttempts = 0;
  const starts = [];
  const service = normalUploadService(1);
  const fetch = (url, options, clock) => {
    if (url.startsWith('upload/start?')) {
      startAttempts++;
      starts.push({ at: clock.now, name: options.headers['X-Name'] });
      if (startAttempts === 1) return Promise.resolve(response(429, 'try later', { 'Retry-After': '0.01' }));
    }
    return service.fetch(url, options, clock);
  };
  const page = createHarness(fetch);
  await openRoom(page, 'retry-room');
  page.elements.files.listeners.change({ target: { files: [new FileLike('retry-a'), new FileLike('retry-b')], value: '' } });
  await settle();
  assert.equal(starts.length, 1, 'the first admission denial must pause all new starts');
  page.advance(9);
  await settle();
  assert.equal(starts.length, 1, 'Retry-After cooldown must block starts before it expires');
  page.advance(1);
  await drain(page);
  assert.equal(starts.length, 3, 'the rejected task must retry before the later queued task starts');
  assert.equal(starts[1].name, 'retry-a');
  assert.equal(starts[2].name, 'retry-b');
  assert.equal(page.elements.toast.textWrites, 0, 'retryable admission denial must not create a toast flood');

  const image = new FileLike('photo.png', 'image/png');
  page.elements.drop.listeners.drop({ dataTransfer: { types: ['Files'], files: [image], dropEffect: '' }, preventDefault() {} });
  await settle();
  assert(page.requests.some((request) => request.url.startsWith('push?room=retry-room') && request.options.headers['X-Kind'] === 'image'), 'previewable images must retain direct push uploads');
  assert.equal(starts.length, 3, 'previewable images must never enter resumable upload/start');
}

async function testRoomSwitchAndClearCancellation() {
  const service = normalUploadService(1000);
  const page = createHarness(service.fetch);
  await openRoom(page, 'old-room');
  page.elements.files.listeners.change({ target: { files: [new FileLike('old-active'), new FileLike('old-queued')], value: '' } });
  await settle();
  assert.deepEqual(service.state.starts, ['old-active', 'old-queued'], 'two old-room uploads start before a room switch');
  page.elements.files.listeners.change({ target: { files: [new FileLike('old-never-starts')], value: '' } });
  await settle();
  await openRoom(page, 'new-room');
  page.advance(1000);
  await settle();
  assert.equal(service.state.starts.includes('old-never-starts'), false, 'queued old-room uploads must never start after switching rooms');
  assert.equal(service.state.aborts.length, 2, 'active old-room sessions must be aborted once');
  assert.equal(page.elements.feed.querySelector('.card'), null, 'a delayed old-room completion must never render in the new room');

  page.elements.files.listeners.change({ target: { files: [new FileLike('clear-active'), new FileLike('clear-queued'), new FileLike('clear-never-starts')], value: '' } });
  await settle();
  page.elements.clear.click();
  page.advance(1000);
  await settle();
  assert.equal(service.state.starts.includes('clear-never-starts'), false, 'clear room must cancel queued uploads');
  assert(service.state.aborts.length >= 4, 'clear room must abort known active sessions');
}

(async () => {
  await testFifoConcurrencyAcrossSources();
  await testRetryAfterAndImageBypass();
  await testRoomSwitchAndClearCancellation();
  console.log('PASS: upload queue paces batches, honors Retry-After, preserves image pushes, and cancels stale rooms');
})().catch((error) => { console.error(error.stack || error); process.exitCode = 1; });
