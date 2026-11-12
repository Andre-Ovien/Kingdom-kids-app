export function domFixture() {
  const doc = { hidden: false, activeElement: null }, handlers = new Map();
  class Element {
    constructor() {
      this.children = []; this.parentElement = null; this.dataset = {}; this.style = {}; this.attributes = {};
      this.handlers = new Map(); this.hidden = false; this._text = ''; this._classes = new Set();
      this.classList = { add: (name) => this._classes.add(name), remove: (name) => this._classes.delete(name), contains: (name) => this._classes.has(name) };
    }
    set className(value) { this._classes = new Set(value.split(/\s+/)); }
    get className() { return [...this._classes].join(' '); }
    set textContent(value) { this._text = value; this.children = []; }
    get textContent() { return this._text; }
    setAttribute(name, value) { this.attributes[name] = String(value); }
    getAttribute(name) { return this.attributes[name]; }
    removeAttribute(name) { delete this.attributes[name]; }
    addEventListener(name, callback) { this.handlers.set(name, callback); }
    removeEventListener(name) { this.handlers.delete(name); }
    emit(name, event = {}) { this.handlers.get(name)?.(event); }
    append(...children) { for (const child of children) { this.children.push(child); child.parentElement = this; } }
    remove() { if (this.parentElement) this.parentElement.children = this.parentElement.children.filter((child) => child !== this); }
    contains(element) { return Boolean(element && (element === this || this.children.some((child) => child.contains(element)))); }
    matches() { return false; }
    closest() { return null; }
    focus() { doc.activeElement = this; }
  }
  doc.createElement = () => new Element(); doc.body = new Element();
  doc.addEventListener = (name, callback) => handlers.set(name, callback);
  doc.removeEventListener = (name) => handlers.delete(name);
  doc.emit = (name) => handlers.get(name)?.();
  let time = 0, serial = 0;
  const timers = new Map();
  const options = {
    now: () => time,
    setTimer(callback, delay) { const id = ++serial; timers.set(id, { callback, at: time + delay }); return id; },
    clearTimer(id) { timers.delete(id); },
  };
  const advance = (ms) => {
    const end = time + ms;
    for (;;) {
      const due = [...timers].filter(([, item]) => item.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
      if (!due) break;
      time = due[1].at; timers.delete(due[0]); due[1].callback();
    }
    time = end;
  };
  return { doc, options, advance, Element };
}
