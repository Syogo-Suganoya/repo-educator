/// ドキュメント本文から参照する実コードの断片。
class CodeRef {
  final String filePath;
  final String snippet;
  final String note;

  const CodeRef({
    required this.filePath,
    required this.snippet,
    this.note = '',
  });

  factory CodeRef.fromJson(Map<String, dynamic> json) {
    return CodeRef(
      filePath: json['file_path'] as String,
      snippet: json['snippet'] as String,
      note: json['note'] as String? ?? '',
    );
  }
}

/// 逆引きドキュメントの索引の粒度。「何で引くか」を表す。
enum DocKind {
  feature('feature', '機能'),
  symbol('symbol', '関数・クラス'),
  task('task', 'やりたいこと'),
  file('file', 'ファイル');

  const DocKind(this.wire, this.label);

  /// バックエンドとやり取りする文字列表現。
  final String wire;

  /// UI上の日本語ラベル。
  final String label;

  static DocKind fromWire(String value) {
    return DocKind.values.firstWhere(
      (k) => k.wire == value,
      // 未知の kind が来ても落とさない。将来バックエンドが種別を増やしたときに
      // 古いフロントエンドが壊れないようにするため。
      orElse: () => DocKind.feature,
    );
  }
}

/// 逆引きドキュメントの1エントリ。
class DocEntry {
  final String docId;
  final DocKind kind;
  final String title;
  final String summary;
  final String body;
  final List<String> filePaths;
  final List<String> symbols;
  final List<String> tags;
  final List<CodeRef> codeRefs;
  final List<String> relatedSectionTitles;

  const DocEntry({
    required this.docId,
    required this.kind,
    required this.title,
    required this.summary,
    required this.body,
    this.filePaths = const [],
    this.symbols = const [],
    this.tags = const [],
    this.codeRefs = const [],
    this.relatedSectionTitles = const [],
  });

  /// 本文を段落に分割する。バックエンドは段落を空行2つで区切って返す。
  List<String> get paragraphs => body
      .split(RegExp(r'\n\s*\n'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();

  factory DocEntry.fromJson(Map<String, dynamic> json) {
    return DocEntry(
      docId: json['doc_id'] as String,
      kind: DocKind.fromWire(json['kind'] as String? ?? 'feature'),
      title: json['title'] as String,
      summary: json['summary'] as String? ?? '',
      body: json['body'] as String? ?? '',
      filePaths: _stringList(json['file_paths']),
      symbols: _stringList(json['symbols']),
      tags: _stringList(json['tags']),
      codeRefs: (json['code_refs'] as List? ?? [])
          .map((r) => CodeRef.fromJson(r as Map<String, dynamic>))
          .toList(),
      relatedSectionTitles: _stringList(json['related_section_titles']),
    );
  }

  static List<String> _stringList(dynamic value) {
    if (value is! List) return const [];
    return value.map((e) => e.toString()).toList();
  }
}
