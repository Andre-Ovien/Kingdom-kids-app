import { readFile } from 'node:fs/promises';

const deletionPage = await readFile(
  new URL('../dist/account-deletion/index.html', import.meta.url),
  'utf8',
);

function tagWith(marker) {
  const match = deletionPage.match(
    new RegExp(`<[^>]+${marker.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}[^>]*>`),
  );
  if (!match) throw new Error(`Built deletion page is missing ${marker}.`);
  return match[0];
}

const form = tagWith('data-deletion-form');
if (!form.includes('method="post"') || !form.includes('action="/account-deletion/"')) {
  throw new Error('Deletion form must have a same-page POST fallback.');
}

const fieldset = tagWith('data-deletion-fields');
if (!/\sdisabled(?:\s|>)/.test(fieldset)) {
  throw new Error('Deletion credentials must be disabled in static HTML.');
}

for (const marker of [
  'data-deletion-email',
  'data-deletion-password',
  'data-deletion-confirmation',
]) {
  if (/\sname=/.test(tagWith(marker))) {
    throw new Error(`${marker} must not be serializable by native form submission.`);
  }
}

console.log('Built account-deletion credential fallback is inert.');
