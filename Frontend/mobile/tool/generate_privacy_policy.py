#!/usr/bin/env python3
"""Bundle the owned website policy as inert native text; never fetch a URL."""

import argparse
import ast
import hashlib
import html
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import sys
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parents[3]
POLICY = ROOT / 'Frontend/website/src/pages/privacy.astro'
CONFIG = ROOT / 'Frontend/website/src/config/site.ts'
OUTPUT = ROOT / 'Frontend/mobile/assets/policies/privacy-policy.json'


def config_string(source, name):
    pattern = rf'\b{re.escape(name)}\s*:\s*(\'(?:\\.|[^\'\\])*\'|"(?:\\.|[^"\\])*")'
    matches = re.findall(pattern, source)
    if len(matches) != 1:
        raise ValueError(f'Expected one literal config value: {name}.')
    return ast.literal_eval(matches[0])


class PolicyParser(HTMLParser):
    """Small, deliberately strict vocabulary so future copy cannot disappear."""

    blocks = {'h2': 'title', 'h3': 'heading', 'p': 'paragraph', 'li': 'bullet'}
    containers = {'article', 'section', 'ul', 'ol'}
    inline = {'strong', 'em', 'a'}

    def __init__(self, origin):
        super().__init__(convert_charrefs=True)
        self.origin = origin
        self.stack = []
        self.sections = []
        self.section = None
        self.block = None
        self.parts = []
        self.links = []

    def handle_starttag(self, tag, attrs):
        if tag not in set(self.blocks) | self.containers | self.inline:
            raise ValueError(f'Unsupported policy tag: {tag}.')
        attrs = dict(attrs)
        if set(attrs) - {'class', 'id', 'aria-labelledby', 'href'}:
            raise ValueError(f'Unsupported attributes on policy tag: {tag}.')
        self.stack.append(tag)
        if tag == 'section':
            if self.section is not None or not attrs.get('aria-labelledby'):
                raise ValueError('Policy sections must be unnested and labelled.')
            self.section = {'id': attrs['aria-labelledby'], 'title': '', 'blocks': []}
        elif tag in self.blocks:
            if self.section is None or self.block is not None:
                raise ValueError('Policy text blocks must be inside one section.')
            self.block, self.parts, self.links = tag, [], []
        elif tag in self.inline:
            if self.block is None:
                raise ValueError('Inline policy markup must belong to a text block.')
            if tag == 'a':
                target = attrs.get('href', '')
                parsed = urlparse(target)
                owned = target.startswith('/') and not target.startswith('//')
                owned = owned or target.startswith(self.origin + '/')
                if not (owned or parsed.scheme == 'mailto'):
                    raise ValueError('Unsupported policy link target.')
                self.links.append(target)

    def handle_endtag(self, tag):
        if not self.stack or self.stack.pop() != tag:
            raise ValueError('Unbalanced policy markup.')
        if tag in self.blocks:
            text = re.sub(r'\s+', ' ', ''.join(self.parts)).strip()
            if not text:
                raise ValueError('Empty policy text block.')
            if tag == 'h2':
                if self.section['title']:
                    raise ValueError('Duplicate policy section title.')
                self.section['title'] = text
            else:
                block = {'kind': self.blocks[tag], 'text': text}
                if self.links:
                    # Keep source destinations for auditing, never navigation.
                    block['source_links'] = list(self.links)
                self.section['blocks'].append(block)
            self.block, self.parts, self.links = None, [], []
        elif tag == 'section':
            if not self.section['title'] or not self.section['blocks']:
                raise ValueError('Policy section has no title or content.')
            self.sections.append(self.section)
            self.section = None

    def handle_data(self, data):
        if self.block is not None:
            self.parts.append(data)
        elif data.strip():
            raise ValueError('Policy text outside a supported text block.')

    def handle_comment(self, data):
        raise ValueError('Policy comments require explicit generator support.')


def generate_document(policy_source, config_source):
    origin = config_string(config_source, 'origin')
    email = config_string(config_source, 'email')
    href = config_string(config_source, 'href')
    if href != 'mailto:' + email:
        raise ValueError('Policy contact email and destination disagree.')
    dates = config_string(config_source, 'privacyLastUpdated')
    provisional = re.findall(r'\bisProvisional\s*:\s*(true|false)\b', config_source)
    if len(provisional) != 1:
        raise ValueError('Missing explicit policy contact status.')
    article = re.findall(
        r'<article\s+class="policy-card policy-article">(.*?)</article>',
        policy_source, re.S,
    )
    if len(article) != 1:
        raise ValueError('Expected exactly one canonical policy article.')
    markup = article[0]
    substitutions = {
        '{privacyContact.href}': '"' + html.escape(href, quote=True) + '"',
        '{privacyContact.email}': html.escape(email),
    }
    for token, value in substitutions.items():
        markup = markup.replace(token, value)
    if '{' in markup or '}' in markup:
        raise ValueError('Unresolved policy expression; update the generator.')
    parser = PolicyParser(origin)
    parser.feed(markup)
    parser.close()
    if parser.stack or parser.section is not None or not parser.sections:
        raise ValueError('Incomplete canonical policy content.')
    ids = [section['id'] for section in parser.sections]
    if len(ids) != len(set(ids)):
        raise ValueError('Duplicate canonical policy sections.')
    return {
        'schema_version': 1,
        'title': 'Privacy policy',
        'last_updated': dates,
        'canonical_url': origin + '/privacy/',
        'contact_email': email,
        'contact_is_provisional': provisional[0] == 'true',
        'source_sha256': {
            'privacy.astro': hashlib.sha256(policy_source.encode()).hexdigest(),
            'site.ts': hashlib.sha256(config_source.encode()).hexdigest(),
        },
        'sections': parser.sections,
    }


def encoded_document(policy_source, config_source):
    document = generate_document(policy_source, config_source)
    return json.dumps(document, ensure_ascii=False, indent=2) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Fail if the bundled policy is stale.')
    args = parser.parse_args()
    try:
        encoded = encoded_document(POLICY.read_text(), CONFIG.read_text())
        if args.check:
            if not OUTPUT.is_file() or OUTPUT.read_text() != encoded:
                raise ValueError('Bundled privacy policy is stale. Run tool/generate_privacy_policy.py.')
            print('Bundled privacy policy matches the canonical website source.')
        else:
            OUTPUT.parent.mkdir(parents=True, exist_ok=True)
            OUTPUT.write_text(encoded)
            print('Generated bundled privacy policy from canonical website source.')
    except (OSError, ValueError, SyntaxError) as error:
        print(f'Privacy policy generation failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
