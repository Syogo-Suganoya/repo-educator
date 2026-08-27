import 'package:flutter/material.dart';

/// コード片に色を付けるための最小限のトークナイザ。
///
/// 外部パッケージ（highlight等）を入れない方針にしている。理由は2つ。
///   - 解析対象の言語が事前に分からず、どのみち言語ごとの厳密な文法解析はできない
///   - 目的は「読みやすくする」ことであり、コンパイラ級の正確さは要らない
///
/// そのため、主要言語のキーワードを合成した1つの語彙で色分けする。
/// Python の `type` のように他言語のキーワードと衝突する語はまれに
/// 色が付きすぎるが、読みやすさを損なうものではないため許容する。
class CodePalette {
  static const text = Color(0xFFE3E1D9);
  static const comment = Color(0xFF6E7681);
  static const keyword = Color(0xFFC4A7E7);
  static const string = Color(0xFF9ECE6A);
  static const number = Color(0xFFE0AF68);
  static const call = Color(0xFF7AA2F7);
  static const decorator = Color(0xFFE0AF68);
}

/// Python / Dart / Go / JS / Java あたりで共通に使われる予約語の和集合。
const _keywords = {
  // 制御構造（多くの言語で共通）
  'if', 'else', 'elif', 'for', 'while', 'switch', 'case', 'default',
  'break', 'continue', 'return', 'try', 'catch', 'except', 'finally',
  'throw', 'raise', 'yield', 'await', 'async', 'defer', 'go', 'select',
  'range', 'in', 'is', 'as', 'with', 'pass', 'lambda', 'assert', 'del',
  // 宣言
  'def', 'func', 'function', 'class', 'struct', 'interface', 'enum',
  'type', 'var', 'let', 'const', 'final', 'static', 'import', 'from',
  'export', 'package', 'extends', 'implements', 'abstract', 'override',
  'public', 'private', 'protected', 'global', 'nonlocal',
  // 値・型
  'true', 'false', 'null', 'nil', 'None', 'True', 'False', 'void',
  'int', 'float', 'double', 'bool', 'string', 'str', 'map', 'chan',
  'this', 'self', 'super', 'new', 'not', 'and', 'or',
};

/// 1行を色分けした TextSpan に変換する。
///
/// 行単位で処理するため、複数行にまたがる文字列リテラルやブロックコメントは
/// 正しく色付けできない。実用上の影響は小さいので割り切っている。
TextSpan highlightLine(String line, {required TextStyle baseStyle}) {
  final spans = <TextSpan>[];
  var index = 0;

  for (final match in _tokenPattern.allMatches(line)) {
    if (match.start > index) {
      spans.add(TextSpan(text: line.substring(index, match.start)));
    }
    spans.add(
      TextSpan(
        text: match[0],
        style: TextStyle(color: _colorFor(match)),
      ),
    );
    index = match.end;
  }
  if (index < line.length) {
    spans.add(TextSpan(text: line.substring(index)));
  }

  return TextSpan(style: baseStyle, children: spans);
}

Color _colorFor(RegExpMatch match) {
  if (match.namedGroup('comment') != null) return CodePalette.comment;
  if (match.namedGroup('string') != null) return CodePalette.string;
  if (match.namedGroup('decorator') != null) return CodePalette.decorator;
  if (match.namedGroup('number') != null) return CodePalette.number;
  // 呼び出し・定義の直前にある識別子。`if (` のように予約語のこともある。
  if (match.namedGroup('word') != null) {
    return _keywords.contains(match[0])
        ? CodePalette.keyword
        : CodePalette.call;
  }
  // それ以外の識別子は、予約語のときだけ色を付ける。
  // 変数名まで塗ると画面がうるさくなり、かえって読みにくい。
  return _keywords.contains(match[0]) ? CodePalette.keyword : CodePalette.text;
}

/// 走査順が優先順位になる。コメントと文字列を先に取り、
/// その中身がキーワードとして再解釈されないようにしている。
///
/// `word` は「関数呼び出し・定義の直前にある識別子」だけを拾う。
/// すべての識別子を色分けすると、かえって画面がうるさくなるため。
final _tokenPattern = RegExp(
  r'(?<comment>#.*$|//.*$)'
  r'|(?<string>"(?:\\.|[^"\\])*"|'
  "'(?:\\\\.|[^'\\\\])*'"
  r')'
  r'|(?<decorator>@[A-Za-z_][A-Za-z0-9_]*)'
  r'|(?<number>\b\d+(?:\.\d+)?\b)'
  r'|(?<word>\b[A-Za-z_][A-Za-z0-9_]*\b(?=\s*\())'
  r'|(?<kw>\b[A-Za-z_][A-Za-z0-9_]*\b)',
  multiLine: true,
);
