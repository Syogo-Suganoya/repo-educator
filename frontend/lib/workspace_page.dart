import 'package:flutter/material.dart';

import 'api_client.dart';
import 'docs/docs_view.dart';
import 'models/doc.dart';
import 'models/quiz.dart';
import 'theme.dart';

/// ワークスペース内の表示モード。
/// レビュー（クイズ）と、逆引きドキュメントを行き来する。
enum WorkspaceTab { review, docs }

/// セクション一覧を左サイドバーに、選択中セクションのレビューを右側に表示する
/// ワークスペース画面。ユーザーはサイドバーから狙った機能セクションへ
/// いつでもピンポイントに切り替えられる。
class WorkspacePage extends StatefulWidget {
  const WorkspacePage({
    super.key,
    required this.repositoryUrl,
    required this.repositoryId,
    required this.sections,
    required this.apiClient,
    this.branch = 'main',
    this.docs = const [],
    this.initialTab = WorkspaceTab.review,
  });

  final String repositoryUrl;
  final String repositoryId;
  final List<FeatureSection> sections;
  final ApiClient apiClient;

  /// 出題リクエストで作り直すときに、同じブランチを指すために必要。
  final String branch;
  final List<DocEntry> docs;
  final WorkspaceTab initialTab;

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _SectionProgress {
  int quizIndex = 0;
  final Map<String, String> answers = {};
}

class _WorkspacePageState extends State<WorkspacePage> {
  int? _selectedIndex;
  final Map<int, _SectionProgress> _progress = {};
  late WorkspaceTab _tab = widget.initialTab;

  /// 出題リクエストで差し替わるため、セクションは状態として持つ。
  late List<FeatureSection> _sections = widget.sections;
  final _focusController = TextEditingController();
  bool _regenerating = false;
  String? _regenerateError;

  /// 直前に投げた出題リクエスト。今どの観点のクイズを見ているかを示すために保持する。
  String? _activeFocus;

  @override
  void dispose() {
    _focusController.dispose();
    super.dispose();
  }

  /// 自由文の出題リクエストでクイズを作り直す。
  /// ドキュメントは観点に依存しないので、元の内容をそのまま使い続ける。
  Future<void> _requestFocusedQuizzes() async {
    final text = _focusController.text.trim();
    if (text.isEmpty || _regenerating) return;

    setState(() {
      _regenerating = true;
      _regenerateError = null;
    });

    try {
      final result = await widget.apiClient.generateQuiz(
        repositoryUrl: widget.repositoryUrl,
        branch: widget.branch,
        focus: text,
      );
      if (!mounted) return;
      setState(() {
        _sections = result.sections;
        _activeFocus = text;
        _focusController.clear();
        // セクションの構成が変わるので、進捗と選択はやり直しになる。
        _progress.clear();
        _selectedIndex = result.sections.isEmpty ? null : 0;
        _tab = WorkspaceTab.review;
      });
    } on QuizApiException catch (e) {
      if (mounted) setState(() => _regenerateError = e.toUserMessage());
    } catch (_) {
      if (mounted) setState(() => _regenerateError = 'サーバーに接続できませんでした。');
    } finally {
      if (mounted) setState(() => _regenerating = false);
    }
  }

  _SectionProgress _progressFor(int sectionIndex) => _progress.putIfAbsent(sectionIndex, () => _SectionProgress());

  void _selectSection(int index) {
    setState(() => _selectedIndex = index);
  }

  /// ドキュメントから対応するクイズセクションへ飛ぶ。
  /// セクション名が一致しない場合は何もしない（生成結果が食い違うことがあるため）。
  void _openSectionByTitle(String sectionTitle) {
    final index = _sections.indexWhere((s) => s.title == sectionTitle);
    if (index < 0) return;
    setState(() {
      _tab = WorkspaceTab.review;
      _selectedIndex = index;
    });
  }

  void _selectAnswer(int sectionIndex, Quiz quiz, String choice) {
    final progress = _progressFor(sectionIndex);
    if (progress.answers.containsKey(quiz.quizId)) return;
    setState(() => progress.answers[quiz.quizId] = choice);

    // 学習履歴の記録。未ログインなら送信自体がスキップされる。
    widget.apiClient.recordAnswer(
      repositoryId: widget.repositoryId,
      quizId: quiz.quizId,
      correct: choice == quiz.correctAnswer,
    );
  }

  void _next(int sectionIndex) {
    setState(() => _progressFor(sectionIndex).quizIndex += 1);
  }

  void _retry(int sectionIndex) {
    setState(() {
      final progress = _progressFor(sectionIndex);
      progress.quizIndex = 0;
      progress.answers.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isNarrow = width < 900;

    return Scaffold(
      backgroundColor: AppPalette.bg,
      appBar: AppTopBar(
        onBack: () => Navigator.of(context).pop(),
        trailing: Text(widget.repositoryUrl, style: appMono(12, color: AppPalette.inkMuted), overflow: TextOverflow.ellipsis),
      ),
      body: Column(
        children: [
          _WorkspaceTabBar(
            current: _tab,
            docCount: widget.docs.length,
            onSelect: (tab) => setState(() => _tab = tab),
          ),
          Expanded(
            child: _tab == WorkspaceTab.docs
                ? DocsView(
                    docs: widget.docs,
                    apiClient: widget.apiClient,
                    repositoryUrl: widget.repositoryUrl,
                    branch: widget.branch,
                    onOpenSection: _openSectionByTitle,
                  )
                : _reviewBody(isNarrow),
          ),
        ],
      ),
    );
  }

  Widget _reviewBody(bool isNarrow) {
    final sidebar = _SectionSidebar(
      sections: _sections,
      selectedIndex: _selectedIndex,
      progress: _progress,
      horizontal: isNarrow,
      onSelect: _selectSection,
    );
    final content = _MainContent(
      sections: _sections,
      selectedIndex: _selectedIndex,
      progress: _progress,
      onSelectAnswer: _selectAnswer,
      onNext: _next,
      onRetry: _retry,
    );

    final body = isNarrow
        ? Column(children: [sidebar, Expanded(child: content)])
        : Row(children: [sidebar, Expanded(child: content)]);

    return Column(
      children: [
        Expanded(child: body),
        _FocusComposer(
          controller: _focusController,
          busy: _regenerating,
          errorMessage: _regenerateError,
          activeFocus: _activeFocus,
          onSubmit: _requestFocusedQuizzes,
        ),
      ],
    );
  }
}

/// 画面下部の入力欄。「認証まわりだけ出して」のように、
/// 見たい範囲を自由文で指定してクイズを作り直す。
class _FocusComposer extends StatelessWidget {
  const _FocusComposer({
    required this.controller,
    required this.busy,
    required this.errorMessage,
    required this.activeFocus,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final bool busy;
  final String? errorMessage;
  final String? activeFocus;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppPalette.bg,
        border: Border(top: BorderSide(color: AppPalette.line)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (activeFocus != null) ...[
            Row(
              children: [
                const Icon(Icons.filter_alt_outlined, size: 14, color: AppPalette.accent),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '「$activeFocus」で出題中',
                    style: appMono(11.5, color: AppPalette.accent, weight: FontWeight.w700),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          if (errorMessage != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              color: AppPalette.removeSoft,
              child: Text(errorMessage!, style: appMono(12, color: AppPalette.remove)),
            ),
            const SizedBox(height: 8),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  enabled: !busy,
                  style: appMono(13, color: AppPalette.ink),
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => onSubmit(),
                  decoration: InputDecoration(
                    hintText: '出題してほしい範囲を書いてください（例: 認証まわり / エラー処理を重点的に）',
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
                    : Text('作る', style: appMono(12.5, color: Colors.white, weight: FontWeight.w700)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 「レビュー / ドキュメント」の切替。
class _WorkspaceTabBar extends StatelessWidget {
  const _WorkspaceTabBar({
    required this.current,
    required this.docCount,
    required this.onSelect,
  });

  final WorkspaceTab current;
  final int docCount;
  final void Function(WorkspaceTab) onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppPalette.bg,
        border: Border(bottom: BorderSide(color: AppPalette.line)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          _TabButton(
            label: 'レビュー',
            icon: Icons.difference_outlined,
            selected: current == WorkspaceTab.review,
            onTap: () => onSelect(WorkspaceTab.review),
          ),
          const SizedBox(width: 4),
          _TabButton(
            label: 'ドキュメント',
            icon: Icons.menu_book_outlined,
            badge: docCount > 0 ? '$docCount' : null,
            selected: current == WorkspaceTab.docs,
            onTap: () => onSelect(WorkspaceTab.docs),
          ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.badge,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppPalette.accent : AppPalette.inkMuted;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? AppPalette.accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 7),
              Text(label, style: appMono(12.5, color: color, weight: FontWeight.w700)),
              if (badge != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  color: selected ? AppPalette.accentSoft : AppPalette.surfaceSunken,
                  child: Text(badge!, style: appMono(10, color: color, weight: FontWeight.w700)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// セクション一覧のサイドバー。各セクションの進捗（未着手/進行中/完了）をひと目で示す。
class _SectionSidebar extends StatelessWidget {
  const _SectionSidebar({
    required this.sections,
    required this.selectedIndex,
    required this.progress,
    required this.horizontal,
    required this.onSelect,
  });

  final List<FeatureSection> sections;
  final int? selectedIndex;
  final Map<int, _SectionProgress> progress;
  final bool horizontal;
  final void Function(int) onSelect;

  @override
  Widget build(BuildContext context) {
    final items = [
      for (var i = 0; i < sections.length; i++)
        _SectionTile(
          section: sections[i],
          selected: selectedIndex == i,
          progress: progress[i],
          horizontal: horizontal,
          onTap: () => onSelect(i),
        ),
    ];

    if (horizontal) {
      return Container(
        decoration: const BoxDecoration(
          color: AppPalette.surface,
          border: Border(bottom: BorderSide(color: AppPalette.line)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: SizedBox(
          height: 56,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, i) => items[i],
          ),
        ),
      );
    }

    return Container(
      width: 280,
      decoration: const BoxDecoration(
        color: AppPalette.surface,
        border: Border(right: BorderSide(color: AppPalette.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('機能セクション', style: appMono(11.5, color: AppPalette.inkMuted, weight: FontWeight.w700, letterSpacing: 0.5)),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              children: items,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTile extends StatefulWidget {
  const _SectionTile({
    required this.section,
    required this.selected,
    required this.progress,
    required this.horizontal,
    required this.onTap,
  });

  final FeatureSection section;
  final bool selected;
  final _SectionProgress? progress;
  final bool horizontal;
  final VoidCallback onTap;

  @override
  State<_SectionTile> createState() => _SectionTileState();
}

class _SectionTileState extends State<_SectionTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final section = widget.section;
    final total = section.quizzes.length;
    final progress = widget.progress;
    final answered = progress?.answers.length ?? 0;
    final quizIndex = progress?.quizIndex ?? 0;
    final started = progress != null && (answered > 0 || quizIndex > 0);
    final completed = quizIndex >= total && started;
    final correctCount = progress?.answers.entries.where((e) {
          final quiz = section.quizzes.firstWhere((q) => q.quizId == e.key);
          return quiz.correctAnswer == e.value;
        }).length ??
        0;

    String badgeText;
    Color badgeColor;
    if (completed) {
      badgeText = '$correctCount/$total';
      badgeColor = correctCount == total ? AppPalette.add : AppPalette.remove;
    } else if (started) {
      badgeText = '${quizIndex + 1}/$total';
      badgeColor = AppPalette.accent;
    } else {
      badgeText = '$total件';
      badgeColor = AppPalette.inkMuted;
    }

    final tile = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Material(
        color: widget.selected ? AppPalette.accentSoft : Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          child: Container(
            constraints: widget.horizontal ? const BoxConstraints(minWidth: 200) : null,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              border: Border.all(
                color: widget.selected ? AppPalette.accent : (_hover ? AppPalette.line : Colors.transparent),
              ),
            ),
            child: widget.horizontal
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(section.title, style: appDisplay(12.5, weight: FontWeight.w700)),
                      const SizedBox(width: 8),
                      _Badge(text: badgeText, color: badgeColor),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text(section.title, style: appDisplay(13.5, weight: FontWeight.w700))),
                          _Badge(text: badgeText, color: badgeColor),
                        ],
                      ),
                      const SizedBox(height: 4),
                      AppText(
                        section.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: appBody(12, color: AppPalette.inkMuted, height: 1.4),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );

    return widget.horizontal ? tile : Padding(padding: const EdgeInsets.only(bottom: 8), child: tile);
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      color: color.withValues(alpha: 0.12),
      child: Text(text, style: appMono(10.5, color: color, weight: FontWeight.w700)),
    );
  }
}

/// 右側メインエリア。未選択時のプレースホルダー、レビュー中、セクション完了後の
/// サマリーの3状態を切り替える。
class _MainContent extends StatelessWidget {
  const _MainContent({
    required this.sections,
    required this.selectedIndex,
    required this.progress,
    required this.onSelectAnswer,
    required this.onNext,
    required this.onRetry,
  });

  final List<FeatureSection> sections;
  final int? selectedIndex;
  final Map<int, _SectionProgress> progress;
  final void Function(int sectionIndex, Quiz quiz, String choice) onSelectAnswer;
  final void Function(int sectionIndex) onNext;
  final void Function(int sectionIndex) onRetry;

  @override
  Widget build(BuildContext context) {
    if (selectedIndex == null) {
      return const _EmptyState();
    }
    final sectionIndex = selectedIndex!;
    final section = sections[sectionIndex];
    final sectionProgress = progress[sectionIndex] ?? _SectionProgress();
    final total = section.quizzes.length;

    if (sectionProgress.quizIndex >= total) {
      return _SectionSummary(
        section: section,
        answers: sectionProgress.answers,
        onRetry: () => onRetry(sectionIndex),
      );
    }

    final quiz = section.quizzes[sectionProgress.quizIndex];
    final selectedAnswer = sectionProgress.answers[quiz.quizId];
    final answered = selectedAnswer != null;
    final isCorrect = selectedAnswer == quiz.correctAnswer;
    final revealColor = answered ? (isCorrect ? AppPalette.add : AppPalette.remove) : null;
    final isLast = sectionProgress.quizIndex == total - 1;
    final width = MediaQuery.of(context).size.width;
    final isNarrow = width < 720;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: ValueKey('${section.sectionId}-${sectionProgress.quizIndex}'),
          padding: EdgeInsets.symmetric(horizontal: isNarrow ? 20 : 32, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(section.title, style: appDisplay(18, weight: FontWeight.w800)),
                  Text('${sectionProgress.quizIndex + 1} / $total', style: appMono(12, color: AppPalette.inkMuted)),
                ],
              ),
              const SizedBox(height: 12),
              _ProgressBar(current: sectionProgress.quizIndex + 1, total: total),
              const SizedBox(height: 20),
              DiffCard(
                filePath: quiz.filePath,
                // 正誤は空欄行の色・選択肢のチェック・レビューコメントで十分伝わるため、
                // 増減行数のバッジは出さない（差分の行数を表す記号としては誤解を招く）。
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 主役は設問。場面の説明はその後ろに、控えめな体裁で置く。
                    AppText(
                      quiz.questionText,
                      style: appBody(18, weight: FontWeight.w700, height: 1.55),
                      markBlanks: true,
                      blankColor: revealColor,
                    ),
                    const SizedBox(height: 12),
                    _ScenarioNote(scenario: quiz.scenario),
                    const SizedBox(height: 16),
                    DiffCodeBlock(code: quiz.codeSnippet, revealColor: revealColor),
                    const SizedBox(height: 20),
                    for (final choice in quiz.choices)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _SuggestionChoice(
                          choice: choice,
                          isCorrect: choice == quiz.correctAnswer,
                          isSelected: choice == selectedAnswer,
                          answered: answered,
                          onTap: () => onSelectAnswer(sectionIndex, quiz, choice),
                        ),
                      ),
                    if (answered) ...[
                      const SizedBox(height: 4),
                      _ReviewComment(isCorrect: isCorrect, explanation: quiz.explanation),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 24),
              if (answered)
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppPalette.accent,
                    foregroundColor: Colors.white,
                    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: () => onNext(sectionIndex),
                  child: Text(
                    isLast ? 'レビューを完了する' : '次のファイルへ',
                    style: appDisplay(14, color: Colors.white, weight: FontWeight.w700),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.playlist_add_check_circle_outlined, size: 40, color: AppPalette.inkMuted.withValues(alpha: 0.4)),
            const SizedBox(height: 16),
            Text('サイドバーからセクションを選んでください', style: appDisplay(15, color: AppPalette.inkMuted, weight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text('気になる機能から、ピンポイントでレビューを始められます。', style: appBody(13.5, color: AppPalette.inkMuted)),
          ],
        ),
      ),
    );
  }
}

class _SectionSummary extends StatelessWidget {
  const _SectionSummary({required this.section, required this.answers, required this.onRetry});

  final FeatureSection section;
  final Map<String, String> answers;
  final VoidCallback onRetry;

  List<Quiz> get _needsChanges => section.quizzes.where((q) => answers[q.quizId] != q.correctAnswer).toList();

  @override
  Widget build(BuildContext context) {
    final total = section.quizzes.length;
    final needsChanges = _needsChanges;
    final approved = needsChanges.isEmpty;
    final correctCount = total - needsChanges.length;
    final width = MediaQuery.of(context).size.width;
    final isNarrow = width < 720;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(horizontal: isNarrow ? 20 : 32, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: approved ? AppPalette.addSoft : AppPalette.surface,
                  border: Border.all(color: approved ? AppPalette.add : AppPalette.line),
                ),
                child: Row(
                  children: [
                    Icon(
                      approved ? Icons.merge_type : Icons.rate_review_outlined,
                      size: 32,
                      color: approved ? AppPalette.add : AppPalette.accent,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            approved ? '「${section.title}」はマージ可能です' : '「${section.title}」のレビュー完了',
                            style: appDisplay(18, weight: FontWeight.w800),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '$correctCount / $total 件 approved',
                            style: appMono(13, color: AppPalette.inkMuted, weight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                approved ? '全ての差分にapproveできました。お見事です。' : '${needsChanges.length}件、changes requestedのまま残っています。振り返っておきましょう。',
                style: appBody(15, color: AppPalette.inkMuted),
              ),
              if (needsChanges.isNotEmpty) ...[
                const SizedBox(height: 32),
                Text('Changes requested', style: appMono(12, color: AppPalette.remove, weight: FontWeight.w700, letterSpacing: 0.5)),
                const SizedBox(height: 16),
                for (final quiz in needsChanges)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: _NeedsChangesCard(quiz: quiz, yourAnswer: answers[quiz.quizId]),
                  ),
              ],
              const SizedBox(height: 24),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppPalette.accent,
                  side: const BorderSide(color: AppPalette.accent),
                  shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                onPressed: onRetry,
                child: Text('このセクションをもう一度レビューする', style: appDisplay(14, color: AppPalette.accent, weight: FontWeight.w700)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NeedsChangesCard extends StatelessWidget {
  const _NeedsChangesCard({required this.quiz, required this.yourAnswer});

  final Quiz quiz;
  final String? yourAnswer;

  @override
  Widget build(BuildContext context) {
    return DiffCard(
      filePath: quiz.filePath,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText(quiz.questionText, style: appBody(15, weight: FontWeight.w700, height: 1.6)),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.close, size: 14, color: AppPalette.remove),
              const SizedBox(width: 6),
              Expanded(child: Text('あなたの回答: ${yourAnswer ?? "-"}', style: appMono(12.5, color: AppPalette.remove))),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.check, size: 14, color: AppPalette.add),
              const SizedBox(width: 6),
              Expanded(child: Text('正解: ${quiz.correctAnswer}', style: appMono(12.5, color: AppPalette.add))),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: AppPalette.surfaceSunken,
            child: AppText(quiz.explanation, style: appBody(13.5, color: AppPalette.ink, height: 1.7)),
          ),
        ],
      ),
    );
  }
}

/// 「実務でこの機能を触るとき」の場面を示す注記。PRの説明文コメント風に見せる。
class _ScenarioNote extends StatelessWidget {
  const _ScenarioNote({required this.scenario});

  final String scenario;

  @override
  Widget build(BuildContext context) {
    // 解答には不要な補足なので、設問より弱い見た目にする。
    // 以前は塗りつぶしの色面で最も目立っており、重要度と視覚的な強さが逆転していた。
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.only(left: 10),
      decoration: const BoxDecoration(
        border: Border(left: BorderSide(color: AppPalette.line, width: 2)),
      ),
      child: AppText(
        scenario,
        style: appBody(13, color: AppPalette.inkMuted, height: 1.7),
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.current, required this.total});

  final int current;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 1; i <= total; i++)
          Expanded(
            child: Container(
              height: 4,
              margin: EdgeInsets.only(right: i == total ? 0 : 4),
              color: i <= current ? AppPalette.accent : AppPalette.line,
            ),
          ),
      ],
    );
  }
}

class _SuggestionChoice extends StatelessWidget {
  const _SuggestionChoice({
    required this.choice,
    required this.isCorrect,
    required this.isSelected,
    required this.answered,
    required this.onTap,
  });

  final String choice;
  final bool isCorrect;
  final bool isSelected;
  final bool answered;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    Color borderColor = AppPalette.line;
    Color background = AppPalette.surface;
    IconData? icon;
    Color iconColor = AppPalette.ink;

    if (answered && isSelected) {
      borderColor = isCorrect ? AppPalette.add : AppPalette.remove;
      background = isCorrect ? AppPalette.addSoft : AppPalette.removeSoft;
      icon = isCorrect ? Icons.check_circle : Icons.cancel;
      iconColor = isCorrect ? AppPalette.add : AppPalette.remove;
    } else if (answered && isCorrect) {
      borderColor = AppPalette.add;
      background = AppPalette.addSoft;
      icon = Icons.check_circle;
      iconColor = AppPalette.add;
    }

    return Material(
      color: background,
      child: InkWell(
        onTap: answered ? null : onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(border: Border.all(color: borderColor)),
          child: Row(
            children: [
              Expanded(child: Text(choice, style: appMono(13.5, color: AppPalette.ink))),
              if (icon != null) Icon(icon, size: 18, color: iconColor),
            ],
          ),
        ),
      ),
    );
  }
}

/// レビューコメント風に解説を提示する。approve/changes requestedの語彙と揃える。
class _ReviewComment extends StatelessWidget {
  const _ReviewComment({required this.isCorrect, required this.explanation});

  final bool isCorrect;
  final String explanation;

  @override
  Widget build(BuildContext context) {
    final color = isCorrect ? AppPalette.add : AppPalette.remove;
    final label = isCorrect ? 'Approved' : 'Changes requested';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppPalette.surfaceSunken, border: Border(left: BorderSide(color: color, width: 3))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(isCorrect ? Icons.check : Icons.priority_high, size: 14, color: color),
              const SizedBox(width: 6),
              Text(label, style: appMono(11.5, color: color, weight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 8),
          AppText(explanation, style: appBody(14, color: AppPalette.ink, height: 1.7)),
        ],
      ),
    );
  }
}
