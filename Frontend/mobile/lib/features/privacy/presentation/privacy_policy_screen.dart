import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// An inert, offline policy document. Links remain text, never navigation.
class PrivacyPolicyScreen extends StatefulWidget {
  const PrivacyPolicyScreen({super.key, this.assetBundle});

  final AssetBundle? assetBundle;

  @override
  State<PrivacyPolicyScreen> createState() => _PrivacyPolicyScreenState();
}

class _PrivacyPolicyScreenState extends State<PrivacyPolicyScreen> {
  late Future<_PolicyDocument> _document;

  @override
  void initState() {
    super.initState();
    _document = _load();
  }

  Future<_PolicyDocument> _load() async {
    final source = await (widget.assetBundle ?? rootBundle).loadString(
      'assets/policies/privacy-policy.json',
      cache: false,
    );
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic> ||
        decoded['schema_version'] != 1 ||
        decoded['last_updated'] is! String ||
        decoded['sections'] is! List) {
      throw const FormatException('Invalid policy document.');
    }
    final sections = <_PolicySection>[];
    for (final section in decoded['sections'] as List) {
      if (section is! Map ||
          section['title'] is! String ||
          section['blocks'] is! List) {
        throw const FormatException('Invalid policy section.');
      }
      final blocks = <_PolicyBlock>[];
      for (final block in section['blocks'] as List) {
        if (block is! Map ||
            !const {'heading', 'paragraph', 'bullet'}.contains(block['kind']) ||
            block['text'] is! String) {
          throw const FormatException('Invalid policy text.');
        }
        blocks.add(
          _PolicyBlock(block['kind'] as String, block['text'] as String),
        );
      }
      sections.add(_PolicySection(section['title'] as String, blocks));
    }
    if (sections.isEmpty) throw const FormatException('Empty policy document.');
    return _PolicyDocument(decoded['last_updated'] as String, sections);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      key: const Key('privacy-policy-screen'),
      appBar: AppBar(
        title: const Text('Privacy policy'),
        leading: BackButton(
          key: const Key('privacy-policy-back'),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: SafeArea(
        child: FutureBuilder<_PolicyDocument>(
          future: _document,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'The privacy policy could not be loaded. Please try again.',
                        key: Key('privacy-policy-error'),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: () => setState(() {
                          _document = _load();
                        }),
                        child: const Text('Try again'),
                      ),
                    ],
                  ),
                ),
              );
            }
            final document = snapshot.data;
            if (document == null) {
              return const Center(child: CircularProgressIndicator());
            }
            return SingleChildScrollView(
              key: const Key('privacy-policy-scroll'),
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Last updated: ${document.updated}',
                        style: text.bodyMedium,
                      ),
                      for (final section in document.sections) ...[
                        const SizedBox(height: 26),
                        Semantics(
                          header: true,
                          child: Text(
                            section.title,
                            style: text.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        for (final block in section.blocks) ...[
                          const SizedBox(height: 12),
                          Semantics(
                            header: block.kind == 'heading',
                            child: Text(
                              block.kind == 'bullet'
                                  ? '• ${block.text}'
                                  : block.text,
                              style: block.kind == 'heading'
                                  ? text.titleMedium?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    )
                                  : text.bodyLarge?.copyWith(height: 1.5),
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _PolicyDocument {
  const _PolicyDocument(this.updated, this.sections);
  final String updated;
  final List<_PolicySection> sections;
}

class _PolicySection {
  const _PolicySection(this.title, this.blocks);
  final String title;
  final List<_PolicyBlock> blocks;
}

class _PolicyBlock {
  const _PolicyBlock(this.kind, this.text);
  final String kind;
  final String text;
}
