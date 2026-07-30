import 'package:flutter_test/flutter_test.dart';

import 'package:repo_educator_frontend/main.dart';

void main() {
  testWidgets('LandingPage shows the entry CTA', (WidgetTester tester) async {
    await tester.pumpWidget(const RepoEducatorApp());
    await tester.pump();

    expect(find.text('repo-educator'), findsOneWidget);
    expect(find.text('クイズを作ってみる'), findsOneWidget);
  });
}
