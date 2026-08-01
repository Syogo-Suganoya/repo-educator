import 'package:flutter_test/flutter_test.dart';
import 'package:repo_educator_frontend/docs/doc_search.dart';
import 'package:repo_educator_frontend/models/doc.dart';

DocEntry _entry({
  required String id,
  required DocKind kind,
  required String title,
  String summary = '',
  String body = '',
  List<String> symbols = const [],
  List<String> tags = const [],
  List<String> filePaths = const [],
}) {
  return DocEntry(
    docId: id,
    kind: kind,
    title: title,
    summary: summary,
    body: body,
    symbols: symbols,
    tags: tags,
    filePaths: filePaths,
  );
}

final _docs = [
  _entry(
    id: '1',
    kind: DocKind.feature,
    title: '認証',
    summary: 'ユーザーの本人確認を行う仕組み。',
    body: 'トークンを検証して呼び出し元を特定します。',
    symbols: ['verifyIdToken'],
    tags: ['認証', 'ログイン', 'サインイン', 'auth', 'authentication', 'login'],
    filePaths: ['app/auth.py'],
  ),
  _entry(
    id: '2',
    kind: DocKind.symbol,
    title: 'Context.Next()',
    summary: '後続のミドルウェアを実行する。',
    body: 'インデックスを進めてハンドラを順に呼びます。',
    symbols: ['Context.Next'],
    tags: ['next', 'ミドルウェア'],
    filePaths: ['context.go'],
  ),
  _entry(
    id: '3',
    kind: DocKind.task,
    title: '新しいエンドポイントを追加するには',
    summary: 'ルーティングとスキーマの両方に手を入れます。',
    body: 'main.py にハンドラを足し、schemas.py に型を定義します。',
    tags: ['追加', 'エンドポイント', 'endpoint', 'how to'],
    filePaths: ['app/main.py'],
  ),
  _entry(
    id: '4',
    kind: DocKind.file,
    title: 'context.go',
    summary: 'リクエスト単位の状態を持つ Context の定義。',
    body: 'ハンドラチェーンの制御がここにあります。',
    tags: ['context.go', 'コンテキスト'],
    filePaths: ['context.go'],
  ),
];

void main() {
  group('searchDocs', () {
    test('日本語の部分一致で引ける', () {
      final hits = searchDocs(_docs, '認証');
      expect(hits, isNotEmpty);
      expect(hits.first.entry.docId, '1');
    });

    test('関数名で引くと該当エントリが最上位になる', () {
      final hits = searchDocs(_docs, 'Context.Next');
      expect(hits.first.entry.docId, '2');
    });

    test('タグ経由で別名から引ける', () {
      // 「ログイン」はタイトルにも本文にも出てこないが、tags に入れてある。
      final hits = searchDocs(_docs, 'ログイン');
      expect(hits.map((h) => h.entry.docId), contains('1'));
      expect(hits.first.matchedOn, 'タグ');
    });

    test('大文字小文字を区別しない', () {
      final upper = searchDocs(_docs, 'AUTH');
      final lower = searchDocs(_docs, 'auth');
      expect(upper.map((h) => h.entry.docId), lower.map((h) => h.entry.docId));
      expect(upper, isNotEmpty);
    });

    test('英数字クエリは空白区切りの複数語でも引ける', () {
      final hits = searchDocs(_docs, 'context next');
      expect(hits.map((h) => h.entry.docId), contains('2'));
    });

    test('クエリが空なら全件を返す', () {
      expect(searchDocs(_docs, '').length, _docs.length);
      expect(searchDocs(_docs, '   ').length, _docs.length);
    });

    test('一致がなければ空リストを返し例外を投げない', () {
      expect(searchDocs(_docs, 'まったく存在しない語'), isEmpty);
    });

    test('ドキュメントが空でも落ちない', () {
      expect(searchDocs(const [], '認証'), isEmpty);
    });

    test('タイトル一致は概要一致より上位になる', () {
      // 「エンドポイント」はid=3のタイトルと、id=3の本文の両方にある。
      // 別エントリの概要にしか無い場合より上位に来ること。
      final hits = searchDocs(_docs, 'エンドポイント');
      expect(hits.first.entry.docId, '3');
      expect(hits.first.matchedOn, 'タイトル');
    });

    test('ファイルパスでも引ける', () {
      final hits = searchDocs(_docs, 'app/auth.py');
      expect(hits.map((h) => h.entry.docId), contains('1'));
    });
  });

  group('groupByKind', () {
    test('kindごとにまとまる', () {
      final grouped = groupByKind(searchDocs(_docs, ''));
      expect(grouped[DocKind.feature]!.length, 1);
      expect(grouped[DocKind.symbol]!.length, 1);
      expect(grouped[DocKind.task]!.length, 1);
      expect(grouped[DocKind.file]!.length, 1);
    });
  });

  group('DocEntry', () {
    test('本文が空行2つで段落に分かれる', () {
      final entry = _entry(
        id: 'x',
        kind: DocKind.feature,
        title: 't',
        body: '一段落目。\n\n二段落目。\n\n\n三段落目。',
      );
      expect(entry.paragraphs.length, 3);
      expect(entry.paragraphs[1], '二段落目。');
    });

    test('未知のkindが来てもfeatureとして扱い落ちない', () {
      final entry = DocEntry.fromJson({
        'doc_id': 'y',
        'kind': 'unknown_future_kind',
        'title': 'タイトル',
      });
      expect(entry.kind, DocKind.feature);
      expect(entry.summary, '');
      expect(entry.tags, isEmpty);
    });
  });
}
