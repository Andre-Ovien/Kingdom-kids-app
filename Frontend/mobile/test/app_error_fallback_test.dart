import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/shared/widgets/app_error_fallback.dart';

void main() {
  testWidgets('shows a friendly fallback without technical details', (
    tester,
  ) async {
    await tester.pumpWidget(const AppErrorFallback());

    expect(find.text('Oops—let’s try that again!'), findsOneWidget);
    expect(find.textContaining('grown-up'), findsOneWidget);
    expect(find.textContaining('Exception'), findsNothing);
    expect(find.textContaining('404'), findsNothing);
  });
}
