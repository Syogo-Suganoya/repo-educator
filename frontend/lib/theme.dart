import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

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

/// diffの1行分の増減を表す小さなバッジ。例: +1 -1
class DiffStatBadge extends StatelessWidget {
  const DiffStatBadge({super.key, required this.added, required this.removed});

  final int added;
  final int removed;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('+$added', style: appMono(11.5, color: AppPalette.add, weight: FontWeight.w700)),
        const SizedBox(width: 6),
        Text('-$removed', style: appMono(11.5, color: AppPalette.remove, weight: FontWeight.w700)),
      ],
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
    if (!isBlank) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        child: Text(text, style: appMono(13, color: AppPalette.codeMuted)),
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
          Expanded(child: Text(text, style: appMono(13, color: AppPalette.codeText, weight: FontWeight.w600))),
        ],
      ),
    );
  }
}
