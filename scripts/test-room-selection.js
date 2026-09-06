#!/usr/bin/env node

// Exercises the page's real inline room-selection code with a deterministic
// EventSource and clock. It protects the SSE connection cap from click bursts.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

class Element {
  constructor(id = '') {
    this.id = id;
    this.value = '';
    this.textContent = '';
    this.className = '';
    this.dataset = {};
    this.children = [];
    this.parentNode = null;
    this.listeners = {};
    this.checked = false;
    this.classList = { add() {}, remove() {} };
  }

  set innerHTML(value) {
    this._innerHTML = value;
    this.children = [];
  }

  get innerHTML() { return this._innerHTML || ''; }
  addEventListener(name, handler) { this.listeners[name] = handler; }
  appendChild(child) { child.parentNode = this; this.children.push(child); return child; }
  insertBefore(child, before) {
    child.parentNode = this;
    const index = this.children.indexOf(before);
    this.children.splice(index < 0 ? this.children.length : index, 0, child);
    return child;
  }
  removeChild(child) { this.children.splice(this.children.indexOf(child), 1); child.parentNode = null; }
  remove() { if (this.parentNode) this.parentNode.removeChild(this); }
  querySelector() { return null; }
  querySelectorAll(selector) { return selector === '.card' ? this.children.filter((child) => child.className.includes('card')) : []; }
  click() { if (this.onclick) this.onclick({ preventDefault() {} }); }
}

function createHarness() {
  const ids = ['box', 'dot', 'status', 'feed', 'room-name', 'room-summary-status', 'theme', 'theme-control', 'room', 'toast', 'count', 'send', 'clear', 'drop', 'choose', 'files', 'join', 'rnd'];
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
  const storage = new Map();
  const localStorage = { getItem: (key) => storage.get(key) || null, setItem: (key, value) => storage.set(key, String(value)) };
  let now = 0;
  let nextTimer = 1;
  const timers = new Map();
  const setTimeoutMock = (fn, delay) => { const id = nextTimer++; timers.set(id, { fn, due: now + delay }); return id; };
  const clearTimeoutMock = (id) => timers.delete(id);
  const advance = (milliseconds) => {
    const target = now + milliseconds;
    for (;;) {
      let selected;
      for (const [id, timer] of timers) if (timer.due <= target && (!selected || timer.due < selected.timer.due)) selected = { id, timer };
      if (!selected) break;
      timers.delete(selected.id);
      now = selected.timer.due;
      selected.timer.fn();
    }
    now = target;
  };
  const sources = [];
  class EventSource {
    constructor(url) {
      this.url = url;
      this.closed = false;
      sources.push(this);
      setTimeoutMock(() => { if (!this.closed && this.onopen) this.onopen(); }, 0);
    }
    close() { this.closed = true; }
  }
  let randomSeed = 0;
  const windowListeners = {};
  const location = { hash: '', reload() {} };
  const window = {
    CLIPSYNC_ROOM_LIMIT: 64,
    CLIPSYNC_MAX_TEXT_BYTES: 1024,
    CLIPSYNC_MAX_FILE_BYTES: 1024,
    crypto: { getRandomValues(bytes) { for (let index = 0; index < bytes.length; index++) bytes[index] = ++randomSeed; return bytes; } },
    addEventListener(name, handler) { windowListeners[name] = handler; },
    confirm: () => true,
  };
  const sandbox = {
    window, document, localStorage, location, EventSource, setTimeout: setTimeoutMock, clearTimeout: clearTimeoutMock,
    fetch: () => Promise.resolve({ status: 200, ok: true, json: () => Promise.resolve({ items: [] }), text: () => Promise.resolve('') }),
    navigator: {}, crypto: window.crypto, Uint8Array, Blob, File: class File {}, console, JSON, Math, Date, RegExp, Array, Promise, encodeURIComponent, decodeURIComponent,
  };
  const page = fs.readFileSync(path.join(__dirname, '..', 'web.go'), 'utf8');
  const match = page.match(/<script>\n([\s\S]*?)\n<\/script>/);
  assert(match, 'could not extract the page script from web.go');
  vm.runInNewContext(match[1], sandbox, { filename: 'web.go:inline-script' });
  return { elements, sources, advance };
}

async function settle() { await Promise.resolve(); await Promise.resolve(); }

async function testRapidNewRoomClicks() {
  const page = createHarness();
  for (let index = 0; index < 12; index++) page.elements.rnd.click();
  const finalRoom = page.elements.room.value;
  assert.equal(page.sources.length, 0, 'rapid room clicks must wait before opening an EventSource');
  page.advance(249);
  assert.equal(page.sources.length, 0, 'room action must remain coalesced until the trailing delay expires');
  page.advance(1);
  await settle();
  assert.equal(page.sources.length, 1, 'a rapid New Room burst must create one EventSource');
  assert.match(page.sources[0].url, new RegExp(`room=${encodeURIComponent(finalRoom)}`));
  assert.equal(page.elements.status.textContent, 'Live', 'the final room must reach Live');
}

async function testSequentialRoomChanges() {
  const page = createHarness();
  page.elements.rnd.click();
  page.advance(250);
  await settle();
  assert.equal(page.sources.length, 1, 'the first normal room selection must open an EventSource');
  assert.equal(page.elements.status.textContent, 'Live', 'the first normal room must reach Live');
  page.elements.room.value = 'second-room';
  page.elements.join.click();
  page.advance(250);
  await settle();
  assert.equal(page.sources.length, 2, 'a later normal room selection must open its own EventSource');
  assert.equal(page.sources[0].closed, true, 'the prior room EventSource must close before the next one is used');
  assert.match(page.sources[1].url, /room=second-room/);
  assert.equal(page.elements.status.textContent, 'Live', 'the later normal room must reach Live');
}

(async () => {
  await testRapidNewRoomClicks();
  await testSequentialRoomChanges();
  console.log('PASS: room selection coalesces rapid clicks and preserves sequential room changes');
})().catch((error) => { console.error(error.stack || error); process.exitCode = 1; });
