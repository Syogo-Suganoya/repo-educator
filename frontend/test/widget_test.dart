import 'package:flutter_test/flutter_test.dart';

import 'package:repo_educator_frontend/main.dart';

void main() {
  testWidgets('未ログインでも起動画面が表示される', (WidgetTester tester) async {
    // Firebase未初期化の状態（AuthService.isAvailable == false）で描画できることが、
    // 「公開リポジトリはログイン不要」という前提そのものの確認になる。
    await tester.pumpWidget(const RepoEducatorApp());
    await tester.pump();

    expect(find.text('repo-educator'), findsOneWidget);
    expect(find.text('プルリクエストを開く'), findsOneWidget);
  });

  testWidgets('未ログイン時はプライベートリポジトリの導線を出さない', (WidgetTester tester) async {
    await tester.pumpWidget(const RepoEducatorApp());
    await tester.pump();

    expect(find.text('自分のプライベートリポジトリから選ぶ'), findsNothing);
    // 認証基盤が無効な環境ではログインボタン自体も出さない。
    expect(find.text('GitHubでログイン'), findsNothing);
  });
}
