import test from 'node:test';
import assert from 'node:assert/strict';
import { createToastClock, TOAST_DURATION_MS } from '../src/scripts/form-toasts.mjs';

function clockFixture() {
  let time = 0;
  let next = 0;
  const tasks = new Map();
  return {
    options: {
      now: () => time,
      setTimer: (callback, delay) => { const id = ++next; tasks.set(id, { callback, at: time + delay }); return id; },
      clearTimer: (id) => tasks.delete(id),
    },
    advance(ms) {
      const end = time + ms;
      for (;;) {
        const due = [...tasks].filter(([, task]) => task.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
        if (!due) break;
        time = due[1].at; tasks.delete(due[0]); due[1].callback();
      }
      time = end;
    },
  };
}

test('a notification disappears once after five seconds, without requiring animation events', () => {
  const fixture = clockFixture(); let dismissed = 0;
  assert.equal(TOAST_DURATION_MS, 5000);
  createToastClock(() => dismissed++, fixture.options);
  fixture.advance(4999); assert.equal(dismissed, 0);
  fixture.advance(1); assert.equal(dismissed, 1);
  fixture.advance(5000); assert.equal(dismissed, 1);
});

test('reading with hover or keyboard focus pauses the same remaining countdown', () => {
  const fixture = clockFixture(); let dismissed = 0;
  const clock = createToastClock(() => dismissed++, fixture.options);
  fixture.advance(2000); clock.pause('hover'); clock.pause('focus');
  fixture.advance(10000); assert.equal(dismissed, 0);
  clock.resume('hover'); fixture.advance(10000); assert.equal(dismissed, 0);
  clock.resume('focus'); fixture.advance(2999); assert.equal(dismissed, 0);
  fixture.advance(1); assert.equal(dismissed, 1);
});

test('a replaced or dismissed notice cannot close a newer notification', () => {
  const fixture = clockFixture(); let oldDismissed = 0; let newDismissed = 0;
  const first = createToastClock(() => oldDismissed++, fixture.options);
  fixture.advance(4000); first.cancel();
  createToastClock(() => newDismissed++, fixture.options);
  fixture.advance(1000); assert.equal(oldDismissed, 0); assert.equal(newDismissed, 0);
  fixture.advance(4000); assert.equal(newDismissed, 1);
});
