import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:repo_educator_frontend/main.dart';

void main() {
  setUp(() {
    // AuthService.restore() が呼ぶ SharedPreferences をテスト用にモック化する。
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('未ログインでも起動画面が表示される', (WidgetTester tester) async {
    // 未ログインで描画できることが、「公開リポジトリはログイン不要」という
    // 前提そのものの確認になる。
    await tester.pumpWidget(const RepoEducatorApp());
    await tester.pumpAndSettle();

    expect(find.text('repo-educator'), findsOneWidget);
    expect(find.text('プルリクエストを開く'), findsOneWidget);
  });

  testWidgets('未ログイン時はプライベートリポジトリの導線を出さない', (WidgetTester tester) async {
    await tester.pumpWidget(const RepoEducatorApp());
    await tester.pumpAndSettle();

    expect(find.text('自分のプライベートリポジトリから選ぶ'), findsNothing);
  });

  testWidgets('未ログイン時はログインボタンが表示される', (WidgetTester tester) async {
    await tester.pumpWidget(const RepoEducatorApp());
    await tester.pumpAndSettle();

    expect(find.text('ログイン'), findsOneWidget);
  });
}
