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
    this.clickCount = 0;
    const classes = new Set();
    this.classList = {
      add: (...names) => names.forEach((name) => classes.add(name)),
      remove: (...names) => names.forEach((name) => classes.delete(name)),
      contains: (name) => classes.has(name),
    };
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
    const idMatch = selector.match(/^\.card\[data-id="(.+)"\]$/);
    const matches = (element) => {
      if (selector === '.card') return element.className.includes('card');
      return idMatch && element.className.includes('card') && element.dataset.id === idMatch[1];
    };
    const visit = (element) => {
      for (const child of element.children) {
        if (matches(child)) return child;
        const found = visit(child);
        if (found) return found;
      }
      return null;
    };
    return visit(this);
  }
  querySelectorAll(selector) { return selector === '.card' ? this.children.filter((child) => child.className.includes('card')) : []; }
  click() {
    this.clickCount++;
    if (this.onclick) this.onclick({ preventDefault() {}, stopPropagation() {} });
  }
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
  const requests = [];
  const sandbox = {
    window, document, localStorage, location, EventSource, setTimeout: setTimeoutMock, clearTimeout: clearTimeoutMock,
    fetch: (url, options = {}) => {
      requests.push({ url, options });
      const response = url.startsWith('list?') ? { items: [] } : { deleted: 'item-a' };
      return Promise.resolve({ status: 200, ok: true, json: () => Promise.resolve(response), text: () => Promise.resolve('') });
    },
    navigator: {}, crypto: window.crypto, Uint8Array, Blob, File: class File {}, console, JSON, Math, Date, RegExp, Array, Promise, encodeURIComponent, decodeURIComponent,
  };
  const page = fs.readFileSync(path.join(__dirname, '..', 'web.go'), 'utf8');
  const match = page.match(/<script>\n([\s\S]*?)\n<\/script>/);
  assert(match, 'could not extract the page script from web.go');
  vm.runInNewContext(match[1], sandbox, { filename: 'web.go:inline-script' });
  return { elements, sources, advance, requests, documentListeners };
}

async function settle() {
  for (let index = 0; index < 8; index++) await Promise.resolve();
}

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

function testUnifiedComposerMarkup() {
  const page = fs.readFileSync(path.join(__dirname, '..', 'web.go'), 'utf8');
  assert.match(page, /<div class="composer" id="drop">/, 'the composer must be the single drop target');
  assert.match(page, /<textarea id="box"[^>]*aria-describedby="[^"]*compose-hint/, 'the composer must describe file dropping to assistive technology');
  assert.doesNotMatch(page, /<div class="drop" id="drop">/, 'the standalone drop panel must be removed');
}

function dragEvent(types, files) {
  let prevented = false;
  return {
    event: {
      dataTransfer: { types, files, dropEffect: 'none' },
      preventDefault() { prevented = true; },
    },
    wasPrevented: () => prevented,
  };
}

async function testUnifiedComposerDropAndExistingActions() {
  const page = createHarness();
  const drop = page.elements.drop;
  assert.equal(typeof drop.listeners.drop, 'function', 'the composer must retain a drop handler');

  const textDrag = dragEvent(['text/plain'], []);
  drop.listeners.dragenter(textDrag.event);
  drop.listeners.dragover(textDrag.event);
  drop.listeners.drop(textDrag.event);
  assert.equal(textDrag.wasPrevented(), false, 'text drags must retain native textarea behavior');
  assert.equal(drop.classList.contains('hot'), false, 'text drags must not trigger the file-drop treatment');

  const file = { name: 'dropped.png', type: 'image/png', size: 3 };
  const outerEnter = dragEvent(['Files'], [file]);
  drop.listeners.dragenter(outerEnter.event);
  assert.equal(outerEnter.wasPrevented(), true, 'file drags must be accepted by the composer');
  assert.equal(outerEnter.event.dataTransfer.dropEffect, 'copy', 'file drags must advertise copy semantics');
  assert.equal(drop.classList.contains('hot'), true, 'file dragging over the composer must show the drop treatment');
  const nestedEnter = dragEvent(['Files'], [file]);
  drop.listeners.dragenter(nestedEnter.event);
  const nestedLeave = dragEvent(['Files'], [file]);
  drop.listeners.dragleave(nestedLeave.event);
  assert.equal(drop.classList.contains('hot'), true, 'moving across composer children must not flicker the drop treatment');
  const outerLeave = dragEvent(['Files'], [file]);
  drop.listeners.dragleave(outerLeave.event);
  assert.equal(drop.classList.contains('hot'), false, 'leaving the composer must clear the drop treatment');
  const fallbackFileDrag = dragEvent([], [file]);
  drop.listeners.dragenter(fallbackFileDrag.event);
  assert.equal(fallbackFileDrag.wasPrevented(), true, 'file lists must be accepted when drag types are unavailable');
  drop.listeners.dragleave(fallbackFileDrag.event);

  page.elements.room.value = 'drop-room';
  page.elements.join.click();
  page.advance(250);
  await settle();
  const droppedFile = dragEvent(['Files'], [file]);
  drop.listeners.dragenter(droppedFile.event);
  drop.listeners.drop(droppedFile.event);
  await settle();
  assert.equal(droppedFile.wasPrevented(), true, 'dropping files must prevent browser navigation');
  assert.equal(drop.classList.contains('hot'), false, 'dropping files must clear the drop treatment');
  const imageRequest = page.requests.find((request) => request.url === 'push?room=drop-room' && request.options.headers['X-Kind'] === 'image');
  assert(imageRequest, 'dropped files must reach the existing upload pipeline');

  page.elements.choose.click();
  assert.equal(page.elements.files.clickCount, 1, 'Add files must retain its explicit file-picker fallback');
  page.elements.box.value = 'manual text';
  page.elements.send.click();
  const sentText = page.requests.find((request) => request.url === 'push?room=drop-room' && request.options.headers['X-Kind'] === 'text');
  assert(sentText, 'typing and Send text must retain the text submission path');
  const paste = { clipboardData: { items: [], getData: () => 'pasted text' }, preventDefault() { this.prevented = true; } };
  page.documentListeners.paste(paste);
  assert.equal(paste.prevented, true, 'text pasting must retain the clipboard submission path');

  const source = page.sources[0];
  source.onmessage({ data: JSON.stringify({ kind: 'snapshot', items: [{ id: 'item-a', kind: 'text', text: 'remove', size: 6, from: 'test', at: 1 }] }) });
  const card = page.elements.feed.querySelector('.card[data-id="item-a"]');
  assert(card, 'snapshot item must render a card');
  const deleteButton = card.children[1].children[2];
  assert.equal(deleteButton.textContent, 'Delete', 'each card must expose a destructive Delete control');
  deleteButton.click();
  await settle();
  const deleteRequest = page.requests.find((request) => request.url === 'delete?room=drop-room&id=item-a');
  assert(deleteRequest, 'Delete control must POST to the item deletion endpoint');
  assert.equal(deleteRequest.options.method, 'POST');
  assert.equal(page.elements.feed.querySelector('.card[data-id="item-a"]'), null, 'successful deletion must remove only its card');
  source.onmessage({ data: JSON.stringify({ kind: 'push', item: { id: 'item-a', kind: 'text', text: 'stale', size: 5, from: 'test', at: 1 } }) });
  source.onmessage({ data: JSON.stringify({ kind: 'snapshot', items: [{ id: 'item-a', kind: 'text', text: 'stale', size: 5, from: 'test', at: 1 }] }) });
  assert.equal(page.elements.feed.querySelector('.card[data-id="item-a"]'), null, 'stale events must not resurrect a deleted card');

  source.onmessage({ data: JSON.stringify({ kind: 'push', item: { id: 'item-b', kind: 'text', text: 'keep', size: 4, from: 'test', at: 1 } }) });
  assert(page.elements.feed.querySelector('.card[data-id="item-b"]'), 'unrelated item must remain visible');
  source.onmessage({ data: JSON.stringify({ kind: 'delete', id: 'item-b' }) });
  assert.equal(page.elements.feed.querySelector('.card[data-id="item-b"]'), null, 'delete SSE must remove exactly the selected card');

  page.elements.clear.click();
  await settle();
  const clearRequest = page.requests.find((request) => request.url === 'clear?room=drop-room');
  assert(clearRequest, 'Clear room must retain its room cleanup path');
}

(async () => {
  await testRapidNewRoomClicks();
  await testSequentialRoomChanges();
  testUnifiedComposerMarkup();
  await testUnifiedComposerDropAndExistingActions();
  console.log('PASS: room selection, unified composer drop, and existing item actions work through the real page script');
})().catch((error) => { console.error(error.stack || error); process.exitCode = 1; });
