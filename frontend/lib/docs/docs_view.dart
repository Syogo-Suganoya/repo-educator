import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models/doc.dart';
import '../theme.dart';
import 'doc_search.dart';

/// 逆引きドキュメントの画面。
///
/// 見た目のテンプレートは theme.dart の共通部品（DiffCard / DiffCodeBlock /
/// AppPalette / appMono など）をそのまま使う。クイズ画面と同じ部品で組むことで、
/// スタイルの定義が1箇所に保たれる。
///
/// 検索は取得済みJSONに対するインメモリ絞り込みで、サーバー往復は発生しない。
class DocsView extends StatefulWidget {
  const DocsView({
    super.key,
    required this.docs,
    required this.apiClient,
    required this.repositoryUrl,
    this.branch = 'main',
    this.onOpenSection,
  });

  final List<DocEntry> docs;

  /// 索引に載っていない質問に答えるため、その場でサーバーに問い合わせる。
  final ApiClient apiClient;
  final String repositoryUrl;
  final String branch;

  /// 関連するクイズセクションへ飛ぶ。セクション名を渡す。
  final void Function(String sectionTitle)? onOpenSection;

  @override
  State<DocsView> createState() => _DocsViewState();
}

/// 1往復分のやりとり。回答待ちの間も質問だけ先に表示する。
class _QaTurn {
  _QaTurn(this.question);

  final String question;
  String? answer;
  List<String> filePaths = const [];
  String? error;
  bool get pending => answer == null && error == null;
}

class _DocsViewState extends State<DocsView> {
  final _queryController = TextEditingController();
  final _questionController = TextEditingController();
  String _query = '';
  String? _selectedDocId;

  /// 質問のやりとり。新しいものほど後ろ。
  final List<_QaTurn> _turns = [];
  bool _asking = false;

  /// 右ペインに会話を出すか、選んだドキュメントを出すか。
  bool _showConversation = false;

  @override
  void dispose() {
    _queryController.dispose();
    _questionController.dispose();
    super.dispose();
  }

  Future<void> _ask() async {
    final question = _questionController.text.trim();
    if (question.isEmpty || _asking) return;

    final turn = _QaTurn(question);
    setState(() {
      _turns.add(turn);
      _questionController.clear();
      _asking = true;
      // 回答は右ペインに出すので、ドキュメントの選択より会話を優先して見せる。
      _showConversation = true;
    });

    try {
      final result = await widget.apiClient.askAboutRepository(
        repositoryUrl: widget.repositoryUrl,
        branch: widget.branch,
        question: question,
      );
      if (!mounted) return;
      setState(() {
        turn.answer = result.answer;
        turn.filePaths = result.filePaths;
      });
    } on QuizApiException catch (e) {
      if (mounted) setState(() => turn.error = e.toUserMessage());
    } catch (_) {
      if (mounted) setState(() => turn.error = 'サーバーに接続できませんでした。');
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  List<DocSearchHit> get _hits => searchDocs(widget.docs, _query);

  DocEntry? get _selected {
    if (_selectedDocId == null) return null;
    for (final doc in widget.docs) {
      if (doc.docId == _selectedDocId) return doc;
    }
    return null;
  }

  void _onQueryChanged(String value) {
    setState(() {
      _query = value;
      // 絞り込みの結果、選択中のエントリが一覧から消えたら選択を解除する。
      if (_selectedDocId != null &&
          !_hits.any((h) => h.entry.docId == _selectedDocId)) {
        _selectedDocId = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.docs.isEmpty) return const _DocsEmptyState();

    final isNarrow = MediaQuery.of(context).size.width < 900;
    final hits = _hits;

    final list = _DocResultList(
      hits: hits,
      selectedDocId: _selectedDocId,
      query: _query,
      onSelect: (id) => setState(() {
        _selectedDocId = id;
        // ドキュメントを選んだらそれを見たいはずなので、会話は一旦引っ込める。
        _showConversation = false;
      }),
    );

    final Widget detail;
    if (_showConversation && _turns.isNotEmpty) {
      detail = _QaThread(turns: _turns);
    } else if (_selected != null) {
      detail = DocDetail(
        entry: _selected!,
        onOpenSection: widget.onOpenSection,
        onBackToConversation: _turns.isEmpty
            ? null
            : () => setState(() => _showConversation = true),
      );
    } else {
      detail = _DocPlaceholder(total: widget.docs.length);
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: DocSearchField(
            controller: _queryController,
            onChanged: _onQueryChanged,
            resultCount: hits.length,
            totalCount: widget.docs.length,
          ),
        ),
        Expanded(
          child: isNarrow
              // 狭い画面では、選択中は詳細だけを出して一覧に戻れるようにする。
              ? (_selected == null
                    ? list
                    : Column(
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: () =>
                                  setState(() => _selectedDocId = null),
                              icon: const Icon(Icons.arrow_back, size: 15),
                              label: Text('検索結果に戻る', style: appMono(12)),
                              style: TextButton.styleFrom(
                                foregroundColor: AppPalette.inkMuted,
                              ),
                            ),
                          ),
                          Expanded(child: detail),
                        ],
                      ))
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 日本語のタイトル・要約が不自然に折り返さない程度の幅を確保する。
                    SizedBox(width: 380, child: list),
                    Container(width: 1, color: AppPalette.line),
                    Expanded(child: detail),
                  ],
                ),
        ),
        // 索引を引いても分からないことは、そのまま質問できるようにする。
        _QuestionComposer(
          controller: _questionController,
          busy: _asking,
          onSubmit: _ask,
        ),
      ],
    );
  }
}

/// 質問の入力欄。レビュータブの出題リクエスト欄と同じ体裁にして、
/// 「下の欄に書けば何か起きる」という理解を画面間で共通にする。
class _QuestionComposer extends StatelessWidget {
  const _QuestionComposer({
    required this.controller,
    required this.busy,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final bool busy;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppPalette.bg,
        border: Border(top: BorderSide(color: AppPalette.line)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              enabled: !busy,
              style: appMono(13, color: AppPalette.ink),
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSubmit(),
              decoration: InputDecoration(
                hintText: 'このリポジトリについて質問する（例: リトライはどこで制御している？）',
                hintStyle: appMono(12.5, color: AppPalette.inkMuted.withValues(alpha: 0.6)),
                prefixIcon: const Icon(Icons.chat_bubble_outline, size: 16, color: AppPalette.inkMuted),
                isDense: true,
                filled: true,
                fillColor: AppPalette.surface,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                border: const OutlineInputBorder(
                  borderRadius: BorderRadius.zero,
                  borderSide: BorderSide(color: AppPalette.line),
                ),
                enabledBorder: const OutlineInputBorder(
                  borderRadius: BorderRadius.zero,
                  borderSide: BorderSide(color: AppPalette.line),
                ),
                focusedBorder: const OutlineInputBorder(
                  borderRadius: BorderRadius.zero,
                  borderSide: BorderSide(color: AppPalette.accent, width: 1.5),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: busy ? null : onSubmit,
            style: FilledButton.styleFrom(
              backgroundColor: AppPalette.accent,
              foregroundColor: Colors.white,
              shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            ),
            child: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : Text('聞く', style: appMono(12.5, color: Colors.white, weight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

/// 質問と回答のやりとり。右ペインに縦に積む。
class _QaThread extends StatelessWidget {
  const _QaThread({required this.turns});

  final List<_QaTurn> turns;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 16, 28, 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final turn in turns) ...[
              _QaTurnView(turn: turn),
              const SizedBox(height: 24),
            ],
          ],
        ),
      ),
    );
  }
}

class _QaTurnView extends StatelessWidget {
  const _QaTurnView({required this.turn});

  final _QaTurn turn;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 質問は「自分が書いたもの」と分かるよう、色面で囲って回答と区別する。
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          color: AppPalette.accentSoft,
          child: AppText(
            turn.question,
            style: appBody(14, color: AppPalette.accent, height: 1.7),
          ),
        ),
        const SizedBox(height: 12),
        if (turn.pending)
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppPalette.inkMuted),
              ),
              const SizedBox(width: 10),
              Text('コードを読んでいます…', style: appMono(12, color: AppPalette.inkMuted)),
            ],
          )
        else if (turn.error != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            color: AppPalette.removeSoft,
            child: Text(turn.error!, style: appMono(12, color: AppPalette.remove)),
          )
        else ...[
          AppText(
            turn.answer!,
            selectable: true,
            style: appBody(14.5, height: 2.0),
          ),
          if (turn.filePaths.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              '根拠にしたファイル',
              style: appMono(11, color: AppPalette.inkMuted, weight: FontWeight.w700, letterSpacing: 0.5),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final path in turn.filePaths)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    color: AppPalette.surfaceSunken,
                    child: Text(path, style: appMono(11.5, color: AppPalette.inkMuted)),
                  ),
              ],
            ),
          ],
        ],
      ],
    );
  }
}

/// 検索欄。入力のたびに即時で絞り込む（サーバー往復がないため待ち時間がない）。
class DocSearchField extends StatelessWidget {
  const DocSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.resultCount,
    required this.totalCount,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final int resultCount;
  final int totalCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          onChanged: onChanged,
          style: appMono(14, color: AppPalette.ink),
          decoration: InputDecoration(
            hintText: '機能名・関数名・やりたいことで検索（例: 認証 / Context.Next / 追加するには）',
            hintStyle: appMono(
              13,
              color: AppPalette.inkMuted.withValues(alpha: 0.5),
            ),
            prefixIcon: const Icon(
              Icons.search,
              size: 18,
              color: AppPalette.inkMuted,
            ),
            suffixIcon: controller.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(
                      Icons.close,
                      size: 16,
                      color: AppPalette.inkMuted,
                    ),
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                    },
                  ),
            isDense: true,
            filled: true,
            fillColor: AppPalette.surface,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 14,
            ),
            border: const OutlineInputBorder(
              borderRadius: BorderRadius.zero,
              borderSide: BorderSide(color: AppPalette.line),
            ),
            enabledBorder: const OutlineInputBorder(
              borderRadius: BorderRadius.zero,
              borderSide: BorderSide(color: AppPalette.line),
            ),
            focusedBorder: const OutlineInputBorder(
              borderRadius: BorderRadius.zero,
              borderSide: BorderSide(color: AppPalette.accent, width: 1.5),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          controller.text.isEmpty
              ? '$totalCount 件のドキュメント'
              : '$resultCount / $totalCount 件が一致',
          style: appMono(11.5, color: AppPalette.inkMuted),
        ),
      ],
    );
  }
}

/// kind ごとの色分けバッジ。AppPalette の既存色をそのまま割り当てる。
class DocKindBadge extends StatelessWidget {
  const DocKindBadge({super.key, required this.kind});

  final DocKind kind;

  static Color colorOf(DocKind kind) {
    switch (kind) {
      case DocKind.feature:
        return AppPalette.accent;
      case DocKind.symbol:
        return AppPalette.add;
      case DocKind.task:
        return AppPalette.pending;
      case DocKind.file:
        return AppPalette.inkMuted;
    }
  }

  static Color _softColorOf(DocKind kind) {
    switch (kind) {
      case DocKind.feature:
        return AppPalette.accentSoft;
      case DocKind.symbol:
        return AppPalette.addSoft;
      case DocKind.task:
        return AppPalette.pendingSoft;
      case DocKind.file:
        return AppPalette.surfaceSunken;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      color: _softColorOf(kind),
      child: Text(
        kind.label,
        style: appMono(10.5, color: colorOf(kind), weight: FontWeight.w700),
      ),
    );
  }
}

class _DocResultList extends StatelessWidget {
  const _DocResultList({
    required this.hits,
    required this.selectedDocId,
    required this.query,
    required this.onSelect,
  });

  final List<DocSearchHit> hits;
  final String? selectedDocId;
  final String query;
  final void Function(String docId) onSelect;

  @override
  Widget build(BuildContext context) {
    if (hits.isEmpty) return _DocNoResults(query: query);

    // 検索していないときは kind ごとに見出しを付けて全体像を示す。
    // 検索中はスコア順の並びを崩さないため、フラットに並べる。
    if (query.trim().isEmpty) {
      final grouped = groupByKind(hits);
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          for (final kind in DocKind.values)
            if (grouped[kind] != null) ...[
              _KindHeader(kind: kind, count: grouped[kind]!.length),
              for (final hit in grouped[kind]!)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: DocEntryCard(
                    hit: hit,
                    selected: hit.entry.docId == selectedDocId,
                    // 見出しで種別を示しているので、カード側では繰り返さない。
                    showKind: false,
                    onTap: () => onSelect(hit.entry.docId),
                  ),
                ),
            ],
        ],
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      itemCount: hits.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, i) => DocEntryCard(
        hit: hits[i],
        selected: hits[i].entry.docId == selectedDocId,
        onTap: () => onSelect(hits[i].entry.docId),
      ),
    );
  }
}

/// kind ごとの区切り見出し。カード群の所属が一目で分かるよう、罫線で帯を作る。
class _KindHeader extends StatelessWidget {
  const _KindHeader({required this.kind, required this.count});

  final DocKind kind;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 10),
      child: Row(
        children: [
          DocKindBadge(kind: kind),
          const SizedBox(width: 8),
          Text('$count 件', style: appMono(11, color: AppPalette.inkMuted)),
          const SizedBox(width: 10),
          const Expanded(child: Divider(height: 1, color: AppPalette.line)),
        ],
      ),
    );
  }
}

/// 検索結果1件のカード。
class DocEntryCard extends StatefulWidget {
  const DocEntryCard({
    super.key,
    required this.hit,
    required this.selected,
    required this.onTap,
    this.showKind = true,
  });

  final DocSearchHit hit;
  final bool selected;
  final VoidCallback onTap;

  /// kind ごとに見出しを付けて並べる場面では、カード側のバッジは冗長になる。
  final bool showKind;

  @override
  State<DocEntryCard> createState() => _DocEntryCardState();
}

class _DocEntryCardState extends State<DocEntryCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.hit.entry;
    final accent = DocKindBadge.colorOf(entry.kind);

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: widget.selected ? AppPalette.surface : Colors.transparent,
              border: Border.all(
                color: widget.selected
                    ? accent
                    : (_hover
                          ? AppPalette.inkMuted.withValues(alpha: 0.4)
                          : AppPalette.line),
                width: widget.selected ? 1.5 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.showKind || widget.hit.matchedOn.isNotEmpty) ...[
                  Row(
                    children: [
                      if (widget.showKind) DocKindBadge(kind: entry.kind),
                      const Spacer(),
                      if (widget.hit.matchedOn.isNotEmpty)
                        Text(
                          '${widget.hit.matchedOn}に一致',
                          style: appMono(10, color: AppPalette.inkMuted),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                Text(
                  entry.title,
                  style: appDisplay(14, weight: FontWeight.w700),
                ),
                if (entry.summary.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  AppText(
                    entry.summary,
                    style: appBody(
                      12.5,
                      color: AppPalette.inkMuted,
                      height: 1.6,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 選択されたエントリの詳細。本文と実コードの引用を並べる。
class DocDetail extends StatelessWidget {
  const DocDetail({
    super.key,
    required this.entry,
    this.onOpenSection,
    this.onBackToConversation,
  });

  final DocEntry entry;
  final void Function(String sectionTitle)? onOpenSection;

  /// 質問のやりとりがある場合だけ、そこへ戻る導線を出す。
  final VoidCallback? onBackToConversation;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 40),
      // 本文は読み物なので、広い画面でも1行が長くなりすぎない幅で止める。
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (onBackToConversation != null) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: onBackToConversation,
                  icon: const Icon(Icons.arrow_back, size: 14),
                  label: Text('質問の回答に戻る', style: appMono(11.5, weight: FontWeight.w700)),
                  style: TextButton.styleFrom(
                    foregroundColor: AppPalette.inkMuted,
                    padding: EdgeInsets.zero,
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            DocKindBadge(kind: entry.kind),
            const SizedBox(height: 12),
            SelectableText(
              entry.title,
              style: appDisplay(24, weight: FontWeight.w800, height: 1.4),
            ),
            if (entry.summary.isNotEmpty) ...[
              const SizedBox(height: 10),
              AppText(
                entry.summary,
                selectable: true,
                style: appBody(14.5, color: AppPalette.inkMuted, height: 1.8),
              ),
            ],
            if (entry.filePaths.isNotEmpty) ...[
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final path in entry.filePaths)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      color: AppPalette.surfaceSunken,
                      child: Text(
                        path,
                        style: appMono(11.5, color: AppPalette.inkMuted),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 24),
            for (final paragraph in entry.paragraphs) ...[
              AppText(paragraph, selectable: true, style: appBody(14.5, height: 2.0)),
              const SizedBox(height: 18),
            ],
            if (entry.codeRefs.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '該当コード',
                style: appMono(
                  11.5,
                  color: AppPalette.inkMuted,
                  weight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 12),
              for (final ref in entry.codeRefs) ...[
                DiffCard(
                  filePath: ref.filePath,
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // クイズと違い穴埋めしないので、DiffCodeBlock はハイライトなしで描画される。
                      DiffCodeBlock(code: ref.snippet),
                      if (ref.note.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        AppText(
                          ref.note,
                          style: appBody(
                            13,
                            color: AppPalette.inkMuted,
                            height: 1.7,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],
            ],
            if (entry.symbols.isNotEmpty) ...[
              const SizedBox(height: 8),
              _MetaRow(label: '関連する識別子', values: entry.symbols),
            ],
            if (entry.tags.isNotEmpty) ...[
              const SizedBox(height: 12),
              _MetaRow(label: '検索キーワード', values: entry.tags),
            ],
            if (entry.relatedSectionTitles.isNotEmpty &&
                onOpenSection != null) ...[
              const SizedBox(height: 24),
              Text(
                'この機能のクイズに挑戦する',
                style: appMono(
                  11.5,
                  color: AppPalette.inkMuted,
                  weight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final title in entry.relatedSectionTitles)
                    OutlinedButton.icon(
                      onPressed: () => onOpenSection!(title),
                      icon: const Icon(Icons.play_arrow, size: 15),
                      label: Text(
                        title,
                        style: appMono(12, weight: FontWeight.w700),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppPalette.accent,
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.zero,
                        ),
                        side: const BorderSide(color: AppPalette.line),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.label, required this.values});

  final String label;
  final List<String> values;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: appMono(
            11.5,
            color: AppPalette.inkMuted,
            weight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final value in values)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  border: Border.all(color: AppPalette.line),
                ),
                child: Text(
                  value,
                  style: appMono(11, color: AppPalette.inkMuted),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _DocPlaceholder extends StatelessWidget {
  const _DocPlaceholder({required this.total});

  final int total;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.menu_book_outlined,
              size: 32,
              color: AppPalette.inkMuted,
            ),
            const SizedBox(height: 16),
            Text(
              '知りたいことから引いてください',
              style: appDisplay(16, weight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Text(
              '$total 件のドキュメントを、機能名・関数名・やりたいこと・ファイル名の\n'
              '4通りで検索できます。',
              style: appBody(13.5, color: AppPalette.inkMuted, height: 1.8),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _DocNoResults extends StatelessWidget {
  const _DocNoResults({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '「$query」に一致するものがありません',
            style: appDisplay(14, weight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Text(
            '別の言い方を試してください。関数名の一部や、やりたいことの動詞でも引けます。',
            style: appBody(13, color: AppPalette.inkMuted, height: 1.7),
          ),
        ],
      ),
    );
  }
}

class _DocsEmptyState extends StatelessWidget {
  const _DocsEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.menu_book_outlined,
              size: 30,
              color: AppPalette.inkMuted,
            ),
            const SizedBox(height: 14),
            Text(
              'ドキュメントがありません',
              style: appDisplay(15, weight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Text(
              'このリポジトリの解析結果にドキュメントが含まれていません。\n'
              '再度リポジトリを開き直すと生成されます。',
              style: appBody(13, color: AppPalette.inkMuted, height: 1.8),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
