import 'package:flutter/material.dart';

import '../theme.dart';
import 'generation_history.dart';

/// 生成したクイズの履歴一覧。検索欄で絞り込める。
///
/// クイズの中身は保存していない。開き直すときは通常の生成APIを呼ぶが、
/// コミットが変わっていなければサーバー側のキャッシュに当たるため待ち時間はほぼない。
///
/// 絞り込みは取得済みの一覧に対するインメモリ処理で、サーバー往復は発生しない
/// （ドキュメントタブの検索と同じ考え方）。
class HistoryList extends StatefulWidget {
  const HistoryList({
    super.key,
    required this.entries,
    required this.onOpen,
    required this.onRemove,
    this.loading = false,
  });

  final List<GenerationHistoryEntry> entries;
  final void Function(GenerationHistoryEntry) onOpen;
  final void Function(GenerationHistoryEntry) onRemove;
  final bool loading;

  /// 検索欄を出すほどの件数かどうか。数件しかないなら邪魔にしかならない。
  static const searchThreshold = 4;

  @override
  State<HistoryList> createState() => _HistoryListState();
}

class _HistoryListState extends State<HistoryList> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// リポジトリ名・URL・ブランチ名のどれかに含まれていれば一致とする。
  /// 日本語は空白で区切られないため、形態素解析はせず小文字化した部分一致で見る。
  List<GenerationHistoryEntry> get _hits {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return widget.entries;
    return widget.entries.where((entry) {
      return entry.label.toLowerCase().contains(query) ||
          entry.repositoryUrl.toLowerCase().contains(query) ||
          entry.branch.toLowerCase().contains(query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final hits = _hits;
    final showSearch = widget.entries.length >= HistoryList.searchThreshold;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showSearch) ...[
          AppSearchField(
            controller: _controller,
            hintText: 'リポジトリ名・ブランチで絞り込む（例: requests / main）',
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: 8),
          Text(
            _query.trim().isEmpty
                ? '${widget.entries.length} 件'
                : '${hits.length} / ${widget.entries.length} 件が一致',
            style: appMono(11.5, color: AppPalette.inkMuted),
          ),
          const SizedBox(height: 14),
        ],
        if (hits.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border.all(color: AppPalette.line),
            ),
            child: Text(
              '「$_query」に一致する履歴はありません。',
              style: appBody(13, color: AppPalette.inkMuted, height: 1.7),
            ),
          )
        else
          for (final entry in hits)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: HistoryRow(
                entry: entry,
                loading: widget.loading,
                onOpen: () => widget.onOpen(entry),
                onRemove: () => widget.onRemove(entry),
              ),
            ),
      ],
    );
  }
}

/// 見出し付きの履歴一覧。トップページ用。
class HistorySection extends StatelessWidget {
  const HistorySection({
    super.key,
    required this.entries,
    required this.isNarrow,
    required this.loading,
    required this.signedIn,
    required this.onOpen,
    required this.onRemove,
  });

  final List<GenerationHistoryEntry> entries;
  final bool isNarrow;
  final bool loading;
  final bool signedIn;
  final void Function(GenerationHistoryEntry) onOpen;
  final void Function(GenerationHistoryEntry) onRemove;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '生成したクイズ',
          style: appMono(
            12,
            color: AppPalette.inkMuted,
            weight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          signedIn
              ? 'アカウントに保存されています。別のブラウザや端末からも同じ一覧を開けます。'
              : 'このブラウザにのみ保存されています。ログインすると、別の端末からも開けるようになります。',
          style: appBody(14, color: AppPalette.inkMuted),
        ),
        const SizedBox(height: 16),
        HistoryList(
          entries: entries,
          loading: loading,
          onOpen: onOpen,
          onRemove: onRemove,
        ),
      ],
    );
  }
}

class HistoryRow extends StatelessWidget {
  const HistoryRow({
    super.key,
    required this.entry,
    required this.loading,
    required this.onOpen,
    required this.onRemove,
  });

  final GenerationHistoryEntry entry;
  final bool loading;
  final VoidCallback onOpen;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(border: Border.all(color: AppPalette.line)),
      child: Row(
        children: [
          Expanded(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: loading ? null : onOpen,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.history,
                        size: 15,
                        color: AppPalette.inkMuted,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.label,
                              style: appDisplay(13.5, weight: FontWeight.w700),
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${entry.branch}'
                              '${entry.quizCount > 0 ? ' ・ ${entry.quizCount}問' : ''}',
                              style: appMono(11, color: AppPalette.inkMuted),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.arrow_forward,
                        size: 14,
                        color: AppPalette.accent,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            onPressed: loading ? null : onRemove,
            tooltip: '履歴から削除',
            icon: const Icon(Icons.close, size: 15, color: AppPalette.inkMuted),
          ),
        ],
      ),
    );
  }
}
