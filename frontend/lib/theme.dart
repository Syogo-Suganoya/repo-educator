import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import 'code_highlight.dart';

/// デザインの核: 「コードレビュー」のメタファー。
/// クイズの1問=1件の差分（diff）、正解=approve、不正解=changes requested。
/// このアプリのユーザー（開発者）が日常で読んでいる語彙をそのままUIに転用する。
class AppPalette {
  // ベースは温かみのある紙色。長文の問題文・解説を読み続けても疲れない明るい基調。
  static const bg = Color(0xFFF7F5F0);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceSunken = Color(0xFFEFEBE1);
  static const line = Color(0xFFDDD8CB);
  static const ink = Color(0xFF1C1B18);
  static const inkMuted = Color(0xFF726C5E);

  // コードブロックだけは黒に沈める。「差分の中身」という主役を視覚的に切り出す。
  static const codeBg = Color(0xFF14171C);
  static const codeLine = Color(0xFF262B33);
  static const codeText = Color(0xFFE3E1D9);
  static const codeMuted = Color(0xFF6E7681);

  // アクセントは紫みのインディゴ一色に絞る（テラコッタ×クリームの定番配色は避ける）。
  static const accent = Color(0xFF4B3FDB);
  static const accentSoft = Color(0xFFEAE7FB);

  // レビュー結果を表す2色。approve=緑 / changes requested=赤。
  static const add = Color(0xFF1E7D53);
  static const addSoft = Color(0xFFE4F3EA);
  static const remove = Color(0xFFC1432B);
  static const removeSoft = Color(0xFFFBEAE6);

  // 空欄（未回答の差分行）のマーカー色。
  static const pending = Color(0xFFB8791E);
  static const pendingSoft = Color(0xFFFBF0DE);

  // 文章中に埋め込まれた識別子・コード片の色。地の文から浮き上がらせる。
  static const inlineCode = Color(0xFFC1432B);
}

/// 見出し・ボタン・UIラベル用。幾何学的でテクニカルな印象のゴシック。
TextStyle appDisplay(double size, {Color? color, FontWeight? weight, double? height, double? letterSpacing}) {
  return GoogleFonts.zenKakuGothicNew(
    fontSize: size,
    color: color ?? AppPalette.ink,
    fontWeight: weight ?? FontWeight.w700,
    height: height,
    letterSpacing: letterSpacing,
  );
}

/// 設問文・解説・レビューコメントなど長文用。明朝体で読み物としての落ち着きを出す。
TextStyle appBody(double size, {Color? color, FontWeight? weight, double? height}) {
  return GoogleFonts.shipporiMincho(
    fontSize: size,
    color: color ?? AppPalette.ink,
    fontWeight: weight ?? FontWeight.w500,
    height: height,
  );
}

/// コード・ファイルパス・diffメタ情報用の等幅フォント。
TextStyle appMono(double size, {Color? color, FontWeight? weight, double? letterSpacing, double? height}) {
  return GoogleFonts.jetBrainsMono(
    fontSize: size,
    color: color ?? AppPalette.ink,
    fontWeight: weight ?? FontWeight.w500,
    letterSpacing: letterSpacing,
    height: height,
  );
}

/// 共通トップバー。シンプルなワードマークのみ（戻る導線は各画面の文脈で個別に持つ）。
class AppTopBar extends StatelessWidget implements PreferredSizeWidget {
  const AppTopBar({super.key, this.onBack, this.trailing});

  final VoidCallback? onBack;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppPalette.bg,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            if (onBack != null)
              InkWell(
                onTap: onBack,
                child: const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Icon(Icons.arrow_back, size: 20, color: AppPalette.inkMuted),
                ),
              ),
            Icon(Icons.difference_outlined, size: 18, color: AppPalette.accent),
            const SizedBox(width: 8),
            Text('repo-educator', style: appDisplay(15, weight: FontWeight.w700)),
            const SizedBox(width: 16),
            Expanded(
              child: trailing == null
                  ? const SizedBox.shrink()
                  : Align(alignment: Alignment.centerRight, child: trailing!),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(52);
}

/// 差分カードの外枠。git diffのファイルヘッダーを模したチロルを持つ。
/// 右側のメタ表示（+1/-1、レビュー状態など）は呼び出し側で意味を持たせる。
class DiffCard extends StatelessWidget {
  const DiffCard({
    super.key,
    required this.filePath,
    required this.child,
    this.meta,
    this.padding,
  });

  final String filePath;
  final Widget child;
  final Widget? meta;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppPalette.surface,
        border: Border.all(color: AppPalette.line),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 24, offset: const Offset(0, 12)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(
              color: AppPalette.surfaceSunken,
              border: Border(bottom: BorderSide(color: AppPalette.line)),
            ),
            child: Row(
              children: [
                Icon(Icons.insert_drive_file_outlined, size: 14, color: AppPalette.inkMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    filePath,
                    style: appMono(12.5, color: AppPalette.inkMuted, weight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (meta != null) meta!,
              ],
            ),
          ),
          Padding(
            padding: padding ?? const EdgeInsets.all(20),
            child: child,
          ),
        ],
      ),
    );
  }
}

/// diff風コードブロック。空欄行（"____" を含む行）だけをハイライトする。
class DiffCodeBlock extends StatelessWidget {
  const DiffCodeBlock({super.key, required this.code, this.revealColor});

  final String code;
  /// 回答後に空欄行へ適用する色（正解=green/不正解=red）。未回答時はnull（pending色）。
  final Color? revealColor;

  @override
  Widget build(BuildContext context) {
    final lines = code.split('\n');
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(color: AppPalette.codeBg, border: Border.all(color: Colors.black.withValues(alpha: 0.4))),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final line in lines) _CodeLine(text: line, isBlank: line.contains('___'), revealColor: revealColor),
        ],
      ),
    );
  }
}

class _CodeLine extends StatelessWidget {
  const _CodeLine({required this.text, required this.isBlank, required this.revealColor});

  final String text;
  final bool isBlank;
  final Color? revealColor;

  @override
  Widget build(BuildContext context) {
    // 構文に応じた色分けは全行に適用する。空欄行の強調は、背景と左のマーカーで行う。
    final code = Text.rich(highlightLine(text, baseStyle: appMono(13, color: AppPalette.codeText)));

    if (!isBlank) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        child: code,
      );
    }
    final markColor = revealColor ?? AppPalette.pending;
    return Container(
      color: markColor.withValues(alpha: 0.14),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(width: 3, height: 18, color: markColor, margin: const EdgeInsets.only(top: 1, right: 10)),
          Expanded(child: code),
        ],
      ),
    );
  }
}

final _inlinePattern = RegExp(r'(?<blank>\[BLANK\]|_{3,})|`(?<code>[^`]+)`');

/// 文章中の記法を装飾したスパン列を組み立てる。
///
/// - バッククォート … 識別子やコード片なので、地の文と区別できる色の等幅にする。
///   バッククォート自体は表示しない。
/// - `[BLANK]` / `____` … コード側の空欄マーカーと同じ色のチップにする（`markBlanks` 時のみ）。
///   以前は問題文が `[BLANK]`、コードが `____` と別表記だったため、
///   「どの穴のことか」を読み手が毎回対応付ける必要があった。色を揃えて解消する。
List<InlineSpan> appInlineSpans(
  String text, {
  required double baseFontSize,
  Color? blankColor,
  bool markBlanks = false,
}) {
  final color = blankColor ?? AppPalette.pending;
  final spans = <InlineSpan>[];
  var index = 0;

  for (final match in _inlinePattern.allMatches(text)) {
    final code = match.namedGroup('code');
    if (code == null && !markBlanks) continue;

    if (match.start > index) {
      spans.add(TextSpan(text: text.substring(index, match.start)));
    }

    if (code != null) {
      spans.add(
        TextSpan(
          text: code,
          style: appMono(baseFontSize * 0.88, color: AppPalette.inlineCode, weight: FontWeight.w700),
        ),
      );
    } else {
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.16),
              border: Border(bottom: BorderSide(color: color, width: 2)),
            ),
            child: Text('？', style: appMono(13, color: color, weight: FontWeight.w700)),
          ),
        ),
      );
    }
    index = match.end;
  }
  if (index < text.length) spans.add(TextSpan(text: text.substring(index)));
  return spans;
}

/// 外部サイトを新しいタブで開くリンク。
/// 外部へ出ることが分かるようにアイコンを添える。
class AppLink extends StatelessWidget {
  const AppLink({super.key, required this.label, required this.url, this.style});

  final String label;
  final String url;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final textStyle = (style ?? appMono(12, weight: FontWeight.w700)).copyWith(
      color: AppPalette.accent,
      decoration: TextDecoration.underline,
      decorationColor: AppPalette.accent,
    );

    return InkWell(
      onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: Text(label, style: textStyle)),
          const SizedBox(width: 4),
          const Icon(Icons.open_in_new, size: 13, color: AppPalette.accent),
        ],
      ),
    );
  }
}

/// バッククォート部分を色付きの等幅で見せる本文テキスト。
/// 画面をまたいで同じ見え方にするため、地の文はすべてこれを通す。
class AppText extends StatelessWidget {
  const AppText(
    this.text, {
    super.key,
    required this.style,
    this.markBlanks = false,
    this.blankColor,
    this.selectable = false,
    this.maxLines,
    this.overflow,
  });

  final String text;
  final TextStyle style;

  /// 問題文だけは `[BLANK]` を空欄チップとして描く。
  final bool markBlanks;
  final Color? blankColor;
  final bool selectable;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    final span = TextSpan(
      style: style,
      children: appInlineSpans(
        text,
        baseFontSize: style.fontSize ?? 14,
        blankColor: blankColor,
        markBlanks: markBlanks,
      ),
    );
    if (selectable) return SelectableText.rich(span, maxLines: maxLines);
    return Text.rich(span, maxLines: maxLines, overflow: overflow);
  }
}
