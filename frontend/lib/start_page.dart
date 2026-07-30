import 'package:flutter/material.dart';

import 'api_client.dart';
import 'models/quiz.dart';
import 'theme.dart';
import 'workspace_page.dart';

class _SampleRepository {
  const _SampleRepository({
    required this.label,
    required this.url,
    required this.branch,
    required this.filePath,
    required this.snippetPreview,
  });

  final String label;
  final String url;
  final String branch;
  final String filePath;
  final String snippetPreview;
}

const _samples = [
  _SampleRepository(
    label: 'psf/requests',
    url: 'https://github.com/psf/requests',
    branch: 'main',
    filePath: 'src/requests/models.py',
    snippetPreview: '@property\ndef ok(self) -> bool:\n    try:\n        self.raise_for_status()\n    except ____:\n        return False',
  ),
  _SampleRepository(
    label: 'TheAlgorithms/Python',
    url: 'https://github.com/TheAlgorithms/Python',
    branch: 'master',
    filePath: 'sorts/quick_sort.py',
    snippetPreview: 'pivot = collection.pop(pivot_index)\n\nlesser = [item for item in collection\n          if item ____ pivot]',
  ),
  _SampleRepository(
    label: 'gin-gonic/gin',
    url: 'https://github.com/gin-gonic/gin',
    branch: 'master',
    filePath: 'context.go',
    snippetPreview: 'func (c *Context) Next() {\n  c.index++\n  for c.index ____ safeInt8(len(c.handlers)) {',
  ),
];

/// 「PRを開く」ことが、そのままクイズを始めることになる1画面完結の起点。
/// マーケティング用の説明とURL入力を分離せず、迷わず最短で最初のレビューに入れることを優先する。
class StartPage extends StatefulWidget {
  const StartPage({super.key});

  @override
  State<StartPage> createState() => _StartPageState();
}

class _StartPageState extends State<StartPage> {
  final _apiClient = ApiClient();
  final _urlController = TextEditingController();
  final _branchController = TextEditingController(text: 'main');

  bool _loading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _urlController.dispose();
    _branchController.dispose();
    super.dispose();
  }

  Future<void> _openPr({String? url, String? branch}) async {
    final repositoryUrl = (url ?? _urlController.text).trim();
    final repositoryBranch = (branch ?? _branchController.text).trim();
    if (repositoryUrl.isEmpty) {
      setState(() => _errorMessage = 'GitHubのリポジトリURLを入力してください。');
      return;
    }

    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      final result = await _apiClient.generateQuiz(
        repositoryUrl: repositoryUrl,
        branch: repositoryBranch.isEmpty ? 'main' : repositoryBranch,
      );
      if (!mounted) return;
      _openSections(result);
    } on QuizApiException catch (e) {
      setState(() => _errorMessage = e.toUserMessage());
    } catch (_) {
      setState(() => _errorMessage = 'サーバーに接続できませんでした。バックエンドが起動しているか確認してください。');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openSections(QuizGenerateResponse result) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WorkspacePage(repositoryUrl: result.url, sections: result.sections),
      ),
    );
  }

  void _pickSample(_SampleRepository sample) {
    _urlController.text = sample.url;
    _branchController.text = sample.branch;
    _openPr(url: sample.url, branch: sample.branch);
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isNarrow = width < 720;

    return Scaffold(
      backgroundColor: AppPalette.bg,
      appBar: const AppTopBar(),
      body: SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: isNarrow ? 20 : 48, vertical: isNarrow ? 24 : 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Hero(
                    isNarrow: isNarrow,
                    urlController: _urlController,
                    branchController: _branchController,
                    loading: _loading,
                    errorMessage: _errorMessage,
                    onSubmit: () => _openPr(),
                  ),
                  SizedBox(height: isNarrow ? 48 : 72),
                  _Lifecycle(isNarrow: isNarrow),
                  SizedBox(height: isNarrow ? 48 : 72),
                  _SamplesSection(isNarrow: isNarrow, loading: _loading, onPick: _pickSample),
                  const SizedBox(height: 48),
                  const _Footer(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({
    required this.isNarrow,
    required this.urlController,
    required this.branchController,
    required this.loading,
    required this.errorMessage,
    required this.onSubmit,
  });

  final bool isNarrow;
  final TextEditingController urlController;
  final TextEditingController branchController;
  final bool loading;
  final String? errorMessage;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('git diff --learn', style: appMono(13, color: AppPalette.accent, weight: FontWeight.w700, letterSpacing: 0.5)),
        const SizedBox(height: 16),
        Text(
          'コードを読む力は、\nレビューするほど身につく。',
          style: appDisplay(isNarrow ? 30 : 42, height: 1.35, weight: FontWeight.w800),
        ),
        const SizedBox(height: 16),
        Text(
          'GitHubのリポジトリURLを渡すだけで、実際のコードの一部を「差分」に見立てた\n4択クイズが生まれます。空欄になった1行を当てて、変更をapproveしましょう。',
          style: appBody(isNarrow ? 15 : 17, color: AppPalette.inkMuted, height: 1.8),
        ),
        const SizedBox(height: 32),
        DiffCard(
          filePath: 'pull_request.yml',
          meta: const DiffStatBadge(added: 1, removed: 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _FormField(
                label: 'リポジトリURL',
                controller: urlController,
                hint: 'https://github.com/octocat/Hello-World',
              ),
              const SizedBox(height: 12),
              _FormField(label: 'ブランチ', controller: branchController, hint: 'main'),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppPalette.accent,
                    foregroundColor: Colors.white,
                    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: loading ? null : onSubmit,
                  child: loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : Text('プルリクエストを開く', style: appDisplay(14, color: Colors.white, weight: FontWeight.w700)),
                ),
              ),
              if (errorMessage != null) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  color: AppPalette.removeSoft,
                  child: Text(errorMessage!, style: appMono(12.5, color: AppPalette.remove)),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _FormField extends StatelessWidget {
  const _FormField({required this.label, required this.controller, required this.hint});

  final String label;
  final TextEditingController controller;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: appMono(11.5, color: AppPalette.inkMuted, weight: FontWeight.w600)),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          style: appMono(14, color: AppPalette.ink),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: appMono(14, color: AppPalette.inkMuted.withValues(alpha: 0.5)),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            border: const OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: BorderSide(color: AppPalette.line)),
            enabledBorder: const OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: BorderSide(color: AppPalette.line)),
            focusedBorder: const OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: BorderSide(color: AppPalette.accent, width: 1.5)),
          ),
        ),
      ],
    );
  }
}

class _Lifecycle extends StatelessWidget {
  const _Lifecycle({required this.isNarrow});

  final bool isNarrow;

  static const _stages = [
    ('Open', 'リポジトリURLを送り、PRを開く'),
    ('Sync', 'GitHub APIで実際のソースコードを取得する'),
    ('Generate', 'AIがコードから差分クイズを生成する'),
    ('Review', '1問ずつ回答し、approve / changes requestedで理解を確認する'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('PRのライフサイクル', style: appMono(12, color: AppPalette.inkMuted, weight: FontWeight.w600, letterSpacing: 0.5)),
        const SizedBox(height: 20),
        isNarrow
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [for (final s in _stages) _StageTile(stage: s.$1, desc: s.$2)],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [for (final s in _stages) Expanded(child: _StageTile(stage: s.$1, desc: s.$2))],
              ),
      ],
    );
  }
}

class _StageTile extends StatelessWidget {
  const _StageTile({required this.stage, required this.desc});

  final String stage;
  final String desc;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 16, bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            color: AppPalette.accentSoft,
            child: Text(stage, style: appMono(11.5, color: AppPalette.accent, weight: FontWeight.w700)),
          ),
          const SizedBox(height: 8),
          Text(desc, style: appBody(14, color: AppPalette.ink, height: 1.6)),
        ],
      ),
    );
  }
}

class _SamplesSection extends StatelessWidget {
  const _SamplesSection({required this.isNarrow, required this.loading, required this.onPick});

  final bool isNarrow;
  final bool loading;
  final void Function(_SampleRepository) onPick;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('サンプルPRを開く', style: appMono(12, color: AppPalette.inkMuted, weight: FontWeight.w600, letterSpacing: 0.5)),
        const SizedBox(height: 8),
        Text('自分のリポジトリがなくても、実コードから作った3件のサンプルですぐ試せます。', style: appBody(14, color: AppPalette.inkMuted)),
        const SizedBox(height: 20),
        Wrap(
          spacing: 20,
          runSpacing: 20,
          children: _samples
              .map((s) => _SampleCard(sample: s, width: isNarrow ? double.infinity : 280, loading: loading, onPick: () => onPick(s)))
              .toList(),
        ),
      ],
    );
  }
}

class _SampleCard extends StatefulWidget {
  const _SampleCard({required this.sample, required this.width, required this.loading, required this.onPick});

  final _SampleRepository sample;
  final double width;
  final bool loading;
  final VoidCallback onPick;

  @override
  State<_SampleCard> createState() => _SampleCardState();
}

class _SampleCardState extends State<_SampleCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final sample = widget.sample;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: SizedBox(
        width: widget.width,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.loading ? null : widget.onPick,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              transform: Matrix4.translationValues(0, _hover ? -3 : 0, 0),
              child: DiffCard(
                filePath: sample.filePath,
                meta: const DiffStatBadge(added: 1, removed: 0),
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(sample.label, style: appDisplay(14, weight: FontWeight.w700)),
                    const SizedBox(height: 10),
                    DiffCodeBlock(code: sample.snippetPreview),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Text('このPRを開く', style: appMono(12, color: AppPalette.accent, weight: FontWeight.w700)),
                        const SizedBox(width: 4),
                        Icon(Icons.arrow_forward, size: 14, color: AppPalette.accent),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(height: 1, color: AppPalette.line),
        const SizedBox(height: 16),
        Text('repo-educator — 実コードを差分レビューする感覚で読む力を鍛える', style: appMono(11.5, color: AppPalette.inkMuted)),
      ],
    );
  }
}
