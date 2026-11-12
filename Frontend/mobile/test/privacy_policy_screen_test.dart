import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/privacy/presentation/privacy_policy_screen.dart';

void main() {
  testWidgets('bundled policy stays readable at large text and returns Back', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2.2)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(builder: (_) => const PrivacyPolicyScreen()),
              ),
              child: const Text('Open policy'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open policy'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('privacy-policy-screen')), findsOneWidget);
    expect(find.text('Last updated: 12 November 2026'), findsOneWidget);
    expect(find.text('11. Contact'), findsOneWidget);
    expect(find.textContaining('kingdomkidshq@gmail.com'), findsOneWidget);
    expect(find.textContaining('Kingdom Kids LLC operates'), findsOneWidget);
    expect(find.textContaining('privacy@kingdom-kids.app'), findsNothing);
    expect(find.textContaining('provisional'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('privacy-policy-back')));
    await tester.pumpAndSettle();
    expect(find.text('Open policy'), findsOneWidget);
    expect(find.byKey(const Key('privacy-policy-screen')), findsNothing);
  });

  testWidgets('missing asset shows safe retry and recovers without link-out', (
    tester,
  ) async {
    final bundle = _RetryBundle();
    await tester.pumpWidget(
      MaterialApp(home: PrivacyPolicyScreen(assetBundle: bundle)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('privacy-policy-error')), findsOneWidget);
    expect(find.textContaining('private-error-detail'), findsNothing);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('privacy-policy-error')), findsNothing);
    expect(find.text('Policy contact: privacy@example.test'), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown document markup fails closed to readable fallback', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PrivacyPolicyScreen(
          assetBundle: _RetryBundle(failFirst: false, kind: 'external-link'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('privacy-policy-error')), findsOneWidget);
    expect(find.text('Policy contact: privacy@example.test'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _RetryBundle extends CachingAssetBundle {
  _RetryBundle({this.failFirst = true, this.kind = 'paragraph'});
  final bool failFirst;
  final String kind;
  var attempts = 0;

  @override
  Future<ByteData> load(String key) async {
    attempts++;
    if (failFirst && attempts == 1) {
      throw StateError('private-error-detail');
    }
    final bytes = utf8.encode(
      jsonEncode({
        'schema_version': 1,
        'last_updated': '11 November 2026',
        'sections': [
          {
            'title': 'Contact',
            'blocks': [
              {
                'kind': kind,
                'text': 'Policy contact: privacy@example.test',
                'source_links': ['https://example.test/'],
              },
            ],
          },
        ],
      }),
    );
    return ByteData.sublistView(Uint8List.fromList(bytes));
  }
}
