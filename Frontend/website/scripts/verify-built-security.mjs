import { readdir, readFile } from 'node:fs/promises';

const deletionPage = await readFile(
  new URL('../dist/account-deletion/index.html', import.meta.url),
  'utf8',
);
const assetDirectory = new URL('../dist/_astro/', import.meta.url);
const scriptNames = (await readdir(assetDirectory)).filter((name) => name.endsWith('.js'));
const builtScripts = await Promise.all(
  scriptNames.map((name) => readFile(new URL(name, assetDirectory), 'utf8')),
);
const builtDeletionSurface = `${deletionPage}\n${builtScripts.join('\n')}`;

function tagWith(marker) {
  const match = deletionPage.match(
    new RegExp(`<[^>]+${marker.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}[^>]*>`),
  );
  if (!match) throw new Error(`Built deletion page is missing ${marker}.`);
  return match[0];
}

for (const marker of ['data-deletion-request-form', 'data-deletion-confirm-form']) {
  const form = tagWith(marker);
  if (!form.includes('method="post"') || !form.includes('action="/account-deletion/"')) {
    throw new Error(`${marker} must have a same-page POST fallback.`);
  }
}

for (const marker of ['data-deletion-request-fields', 'data-deletion-confirm-fields']) {
  if (!/\sdisabled(?:\s|>)/.test(tagWith(marker))) {
    throw new Error(`${marker} must be disabled in static HTML.`);
  }
}

for (const marker of [
  'data-deletion-email',
  'data-deletion-code',
  'data-deletion-confirmation',
]) {
  if (/\sname=/.test(tagWith(marker))) {
    throw new Error(`${marker} must not be serializable by native form submission.`);
  }
}

for (const required of [
  '/api/accounts/account-deletion/request/',
  '/api/accounts/account-deletion/confirm/',
]) {
  if (!builtDeletionSurface.includes(required)) {
    throw new Error(`Built deletion page is missing ${required}.`);
  }
}

for (const forbidden of [
  'data-deletion-password',
  '/api/accounts/login/',
  '/api/accounts/me/',
  'Authorization',
  'Bearer ',
  'localStorage',
  'sessionStorage',
  'document.cookie',
]) {
  if (builtDeletionSurface.includes(forbidden)) {
    throw new Error(`Built deletion page contains forbidden credential flow marker: ${forbidden}`);
  }
}

console.log('Built account-deletion email-verification fallback is inert.');

const contactPage = await readFile(new URL('../dist/contact/index.html', import.meta.url), 'utf8');
const contactForm = contactPage.match(/<form[^>]+data-contact-form[^>]*>/)?.[0];
if (!contactForm?.includes('method="post"') || !contactForm.includes('action="/contact/"')) {
  throw new Error('Contact form must have a same-page POST fallback.');
}
if (!/<fieldset[^>]+disabled[^>]+data-contact-fields/.test(contactPage)) {
  throw new Error('Contact fields must be inert in static HTML until the handler is ready.');
}
for (const marker of ['title', 'email', 'message', 'website']) {
  const tag = contactPage.match(new RegExp(`<[^>]+data-contact-${marker}[^>]*>`))?.[0];
  if (!tag || /\sname=/.test(tag)) throw new Error('Contact fields must not leak through native serialization.');
}
if (!builtScripts.some((script) => script.includes('/api/accounts/contact/'))) {
  throw new Error('Built contact handler is missing its same-origin endpoint.');
}
for (const path of ['index.html', 'privacy/index.html', 'account-deletion/index.html']) {
  const html = await readFile(new URL(`../dist/${path}`, import.meta.url), 'utf8');
  if (!html.includes('href="/contact/"')) throw new Error('Public footer must expose the contact page.');
}
console.log('Built contact form fallback is inert; public footers expose Contact.');
