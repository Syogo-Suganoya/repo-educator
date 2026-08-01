import '../models/doc.dart';

/// 検索結果1件。スコア順に並べるためにスコアを保持する。
class DocSearchHit {
  final DocEntry entry;
  final int score;

  /// どのフィールドで当たったか（UIで「タグ「ログイン」に一致」のように示すため）。
  final String matchedOn;

  const DocSearchHit({
    required this.entry,
    required this.score,
    required this.matchedOn,
  });
}

const _scoreTitleExact = 100;
const _scoreSymbolExact = 80;
const _scoreTitlePartial = 50;
const _scoreTagPartial = 40;
const _scoreSummaryPartial = 20;
const _scoreBodyPartial = 10;

/// ドキュメントを検索する。UIに依存しない純粋な関数。
///
/// 日本語は空白で分かち書きされないため、形態素解析は行わず
/// 小文字化した部分一致（substring）を基本とする。
/// 英数字のみのクエリに限り、追加でトークン単位の一致も見る。
///
/// クエリが空のときは全件を、元の順序を保ったまま返す。
List<DocSearchHit> searchDocs(List<DocEntry> docs, String query) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) {
    return [
      for (final entry in docs)
        DocSearchHit(entry: entry, score: 0, matchedOn: ''),
    ];
  }

  final hits = <DocSearchHit>[];
  for (final entry in docs) {
    final hit = _scoreEntry(entry, normalized);
    if (hit != null) hits.add(hit);
  }

  // スコアが同じときは元の並び順を保ちたいので、安定ソートを保証する形で比較する。
  hits.sort((a, b) => b.score.compareTo(a.score));
  return hits;
}

DocSearchHit? _scoreEntry(DocEntry entry, String query) {
  var score = 0;
  var matchedOn = '';

  void record(int points, String label) {
    if (points <= score) return;
    score = points;
    matchedOn = label;
  }

  final title = entry.title.toLowerCase();
  if (title == query) {
    record(_scoreTitleExact, 'タイトル');
  } else if (_contains(title, query)) {
    record(_scoreTitlePartial, 'タイトル');
  }

  for (final symbol in entry.symbols) {
    final normalizedSymbol = symbol.toLowerCase();
    if (normalizedSymbol == query) {
      record(_scoreSymbolExact, '関数・クラス名');
    } else if (_contains(normalizedSymbol, query)) {
      // 「Context.Next」で「Context.Next()」を引けるようにするため部分一致も見る。
      record(_scoreSymbolExact - 10, '関数・クラス名');
    }
  }

  for (final tag in entry.tags) {
    if (_contains(tag.toLowerCase(), query)) {
      record(_scoreTagPartial, 'タグ');
    }
  }

  if (_contains(entry.summary.toLowerCase(), query)) {
    record(_scoreSummaryPartial, '概要');
  }

  if (_contains(entry.body.toLowerCase(), query)) {
    record(_scoreBodyPartial, '本文');
  }

  for (final path in entry.filePaths) {
    if (_contains(path.toLowerCase(), query)) {
      record(_scoreBodyPartial, 'ファイルパス');
    }
  }

  if (score == 0) return null;
  return DocSearchHit(entry: entry, score: score, matchedOn: matchedOn);
}

final _asciiOnly = RegExp(r'^[a-z0-9 ._()-]+$');
final _tokenSplit = RegExp(r'[\s._()-]+');

/// 部分一致判定。
///
/// 英数字のみのクエリは空白区切りの複数語を許し、全語が含まれれば一致とみなす
/// （「context next」で `Context.Next()` を引けるようにするため）。
/// 日本語を含むクエリはそのまま substring で判定する。
bool _contains(String haystack, String query) {
  if (haystack.contains(query)) return true;
  if (!_asciiOnly.hasMatch(query)) return false;

  final terms = query.split(_tokenSplit).where((t) => t.isNotEmpty).toList();
  if (terms.length < 2) return false;
  return terms.every(haystack.contains);
}

/// 検索結果を kind ごとにまとめる。一覧表示の見出し用。
Map<DocKind, List<DocSearchHit>> groupByKind(List<DocSearchHit> hits) {
  final grouped = <DocKind, List<DocSearchHit>>{};
  for (final hit in hits) {
    grouped.putIfAbsent(hit.entry.kind, () => []).add(hit);
  }
  return grouped;
}
