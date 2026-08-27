import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'api_client.dart';
import 'auth/account_button.dart';
import 'auth/auth_service.dart';
import 'auth/github_token_dialog.dart';
import 'auth/pat_guide_dialog.dart';
import 'history/generation_history.dart';
import 'models/quiz.dart';
import 'profile_page.dart';
import 'theme.dart';
import 'workspace_page.dart';

class _SampleRepository {
  const _SampleRepository({
    required this.label,
    required this.url,
    required this.branch,
    required this.snippetPreview,
  });

  final String label;
  final String url;
  final String branch;
  final String snippetPreview;
}

const _samples = [
  _SampleRepository(
    label: 'psf/requests',
    url: 'https://github.com/psf/requests',
    branch: 'main',
    snippetPreview:
        '@property\ndef ok(self) -> bool:\n    try:\n        self.raise_for_status()\n    except ____:\n        return False',
  ),
  _SampleRepository(
    label: 'TheAlgorithms/Python',
    url: 'https://github.com/TheAlgorithms/Python',
    branch: 'master',
    snippetPreview:
        'pivot = collection.pop(pivot_index)\n\nlesser = [item for item in collection\n          if item ____ pivot]',
  ),
  _SampleRepository(
    label: 'gin-gonic/gin',
    url: 'https://github.com/gin-gonic/gin',
    branch: 'master',
    snippetPreview:
        'func (c *Context) Next() {\n  c.index++\n  for c.index ____ safeInt8(len(c.handlers)) {',
  ),
];

/// URLを渡すことが、そのままクイズを始めることになる1画面完結の起点。
/// 説明とURL入力を分離せず、迷わず最短で最初の1問に入れることを優先する。
class StartPage extends StatefulWidget {
  const StartPage({super.key});

  @override
  State<StartPage> createState() => _StartPageState();
}

class _StartPageState extends State<StartPage> {
  final _authService = AuthService();
  late final _apiClient = ApiClient(authService: _authService);
  late final _history = GenerationHistoryStore(
    apiClient: _apiClient,
    authService: _authService,
  );
  final _urlController = TextEditingController();
  final _branchController = TextEditingController(text: 'main');

  bool _loading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    // restore() は非同期なので、完了時に本体も描き直す必要がある。
    // これを購読しないと、保存済みセッションで開き直したときに
    // トップバーはログイン済みなのに本文は未ログインの案内のまま、という食い違いが起きる。
    _authService.addListener(_onAuthChanged);
    _history.addListener(_onHistoryChanged);
    _authService.restore();
    _history.load();
  }

  void _onAuthChanged() {
    if (!mounted) return;
    setState(() {});
    // 保存先がログイン状態で変わるので、切り替わったら読み直す。
    _history.load();
  }

  void _onHistoryChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _authService.removeListener(_onAuthChanged);
    _history.removeListener(_onHistoryChanged);
    _urlController.dispose();
    _branchController.dispose();
    _authService.dispose();
    super.dispose();
  }

  void _openProfile() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProfilePage(
          apiClient: _apiClient,
          authService: _authService,
          history: _history,
          onOpenRepository: (repository) {
            Navigator.of(context).pop();
            _openPr(url: repository.htmlUrl, branch: repository.defaultBranch);
          },
          onSignedOut: () => setState(() {}),
          onOpenHistory: (entry) {
            Navigator.of(context).pop();
            _openPr(url: entry.repositoryUrl, branch: entry.branch);
          },
        ),
      ),
    );
  }

  /// [fromSample] はサンプルカード起点かどうか。サンプルは誰が押しても同じ
  /// キュレーション済みデータで、「自分が何を解析したか」を残す履歴には要らない。
  Future<void> _openPr({
    String? url,
    String? branch,
    bool fromSample = false,
  }) async {
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
        fromSample: fromSample,
      );
      if (!mounted) return;
      if (!fromSample) {
        // ログイン中はサーバー側が記録済み。ここでの呼び出しは未ログイン分の保存と再読込。
        _history.record(
          GenerationHistoryEntry(
            repositoryUrl: result.url,
            branch: repositoryBranch.isEmpty ? 'main' : repositoryBranch,
            sectionCount: result.sections.length,
            quizCount: result.sections.fold(0, (n, s) => n + s.quizzes.length),
            lastOpened: DateTime.now(),
          ),
        );
      }
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
        builder: (_) => WorkspacePage(
          repositoryUrl: result.url,
          repositoryId: result.repositoryId,
          sections: result.sections,
          docs: result.docs,
          apiClient: _apiClient,
          branch: _branchController.text.trim().isEmpty
              ? 'main'
              : _branchController.text.trim(),
          // 起点はクイズに一本化する。ドキュメントは遷移先のタブから開く。
          initialTab: WorkspaceTab.review,
        ),
      ),
    );
  }

  void _pickSample(_SampleRepository sample) {
    _urlController.text = sample.url;
    _branchController.text = sample.branch;
    _openPr(url: sample.url, branch: sample.branch, fromSample: true);
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isNarrow = width < 720;
    // 3カラムに割ると中央が窮屈になるため、十分な幅があるときだけ横に並べる。
    final useColumns = width >= 1180;

    return Scaffold(
      backgroundColor: AppPalette.bg,
      appBar: AppTopBar(
        trailing: AccountButton(
          authService: _authService,
          apiClient: _apiClient,
          onChanged: () => setState(() {}),
          onOpenProfile: _openProfile,
        ),
      ),
      body: useColumns ? _wideLayout() : _stackedLayout(isNarrow),
    );
  }

  /// アカウント（ログイン・PAT）は左、試せるサンプルは右。
  /// 画面いっぱいに広げず、左右に余白を残した中央寄せの3カラムにする。
  ///
  /// スクロールは画面全体ではなくカラムごとに持たせる。長いカラムに引きずられて
  /// 短いカラムまで流れていくと、見たいものが視界から消えるため。
  Widget _wideLayout() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1280),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Row(
            // 各カラムを画面の高さいっぱいに伸ばす。伸びていないとスクロール域が
            // 中身の高さで決まってしまい、独立してスクロールできない。
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 260, child: _scrollColumn(_accountPanel())),
              const SizedBox(width: 40),
              Expanded(
                child: _scrollColumn(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Hero(
                        isNarrow: false,
                        urlController: _urlController,
                        branchController: _branchController,
                        loading: _loading,
                        errorMessage: _errorMessage,
                        onSubmit: () => _openPr(),
                      ),
                      const SizedBox(height: 48),
                      const _Footer(),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 40),
              SizedBox(
                width: 300,
                child: _scrollColumn(
                  _SamplesSection(
                    // 縦に積むため、カードは幅いっぱいにする。
                    isNarrow: true,
                    loading: _loading,
                    onPick: _pickSample,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 3カラム表示での1カラム分。上下の余白はスクロール領域の内側に入れて、
  /// 端まで送ったときに中身が画面の縁に貼り付かないようにする。
  Widget _scrollColumn(Widget child) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: child,
    );
  }

  /// 幅が足りないときは、サイドバーの中身を本文の下に順に積む。
  Widget _stackedLayout(bool isNarrow) {
    return SingleChildScrollView(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: isNarrow ? 20 : 48,
              vertical: isNarrow ? 24 : 40,
            ),
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
                SizedBox(height: isNarrow ? 24 : 32),
                _SamplesSection(
                  isNarrow: isNarrow,
                  loading: _loading,
                  onPick: _pickSample,
                ),
                SizedBox(height: isNarrow ? 40 : 56),
                _accountPanel(),
                const SizedBox(height: 48),
                const _Footer(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// ログイン状態とPATの案内。横並びでも縦積みでも同じものを使う。
  Widget _accountPanel() {
    return _PrivateRepoAppeal(
      signedIn: _authService.isSignedIn,
      onRegisterToken: () =>
          GithubTokenDialog.show(context, apiClient: _apiClient),
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
        Text(
          'URL → quiz → remember',
          style: appMono(
            13,
            color: AppPalette.accent,
            weight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          '4択を解くだけで、\nコードが頭に入る。',
          style: appDisplay(
            isNarrow ? 30 : 42,
            height: 1.35,
            weight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'URLを渡すだけ。実際のコードから4択クイズを作ります。',
          style: appBody(
            isNarrow ? 15 : 17,
            color: AppPalette.inkMuted,
            height: 1.8,
          ),
        ),
        const SizedBox(height: 32),
        _PlainCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _FormField(
                label: 'リポジトリURL',
                controller: urlController,
                hint: 'https://github.com/octocat/Hello-World',
              ),
              const SizedBox(height: 12),
              _FormField(
                label: 'ブランチ',
                controller: branchController,
                hint: 'main',
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppPalette.accent,
                    foregroundColor: Colors.white,
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.zero,
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: loading ? null : onSubmit,
                  child: loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          'クイズを作る',
                          style: appDisplay(
                            14,
                            color: Colors.white,
                            weight: FontWeight.w700,
                          ),
                        ),
                ),
              ),
              if (errorMessage != null) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  color: AppPalette.removeSoft,
                  child: Text(
                    errorMessage!,
                    style: appMono(12.5, color: AppPalette.remove),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// DiffCardからファイルパスのバー（git diffヘッダー風の表記）を外した、素の枠線カード。
/// 「pull_request.yml」のような表記がかえって分かりにくいため、トップページではこちらを使う。
class _PlainCard extends StatelessWidget {
  const _PlainCard({required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppPalette.surface,
        border: Border.all(color: AppPalette.line),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      padding: padding ?? const EdgeInsets.all(20),
      child: child,
    );
  }
}

/// ログインの利点を1件ずつ並べる。
class _LoginBenefit extends StatefulWidget {
  const _LoginBenefit({
    required this.icon,
    required this.title,
    required this.body,
    this.linkLabel,
    this.onLinkTap,
  });

  final IconData icon;
  final String title;
  final String body;

  /// 本文の末尾に続けて置く補足リンク。
  /// 独立した行にすると別の項目に見えてしまうため、文章の一部として並べる。
  final String? linkLabel;
  final VoidCallback? onLinkTap;

  @override
  State<_LoginBenefit> createState() => _LoginBenefitState();
}

class _LoginBenefitState extends State<_LoginBenefit> {
  // 文中リンクのタップ判定。State側で持ち、破棄まで面倒を見る。
  final _recognizer = TapGestureRecognizer();

  @override
  void dispose() {
    _recognizer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = appBody(13, color: AppPalette.inkMuted, height: 1.8);
    final spans = <InlineSpan>[
      ...appInlineSpans(widget.body, baseFontSize: style.fontSize ?? 13),
    ];

    if (widget.linkLabel != null && widget.onLinkTap != null) {
      _recognizer.onTap = widget.onLinkTap;
      spans.add(const TextSpan(text: ' '));
      spans.add(
        TextSpan(
          text: widget.linkLabel,
          recognizer: _recognizer,
          style: style.copyWith(
            color: AppPalette.accent,
            fontWeight: FontWeight.w700,
            decoration: TextDecoration.underline,
            decorationColor: AppPalette.accent,
          ),
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 3, right: 10),
          child: Icon(widget.icon, size: 15, color: AppPalette.inkMuted),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.title,
                style: appDisplay(13.5, weight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text.rich(TextSpan(style: style, children: spans)),
            ],
          ),
        ),
      ],
    );
  }
}

class _PrivateRepoAppeal extends StatelessWidget {
  const _PrivateRepoAppeal({
    required this.signedIn,
    required this.onRegisterToken,
  });

  /// ログイン済みなら「ログインでできること」は役目を終えている。
  /// ただしPATの取得手順はトークン入力ダイアログから参照されるため、常に残す。
  final bool signedIn;

  /// PAT登録ダイアログを開く。ログイン後はここが実際の入口になる。
  final VoidCallback onRegisterToken;

  @override
  Widget build(BuildContext context) {
    return _PlainCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ログイン後は見出しを出さない。「ログインでできること」という
          // 誘い文句は役目を終えており、中身のPAT案内だけが残ればよい。
          if (!signedIn) ...[
            Row(
              children: [
                const Icon(
                  Icons.lock_outline,
                  size: 15,
                  color: AppPalette.accent,
                ),
                const SizedBox(width: 8),
                Text(
                  'ログインでできること',
                  style: appMono(
                    12.5,
                    color: AppPalette.accent,
                    weight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const _LoginBenefit(
              icon: Icons.history,
              title: '生成したクイズの一覧が残る',
              body: '一度作ったクイズをアカウントに保存し、別のブラウザや端末からも開き直せます。',
            ),
            const SizedBox(height: 10),
          ],
          // PATを登録すれば選べる、という案内はログイン後も必要。
          // 実際にPATを登録するのはログイン後なので、ここで消すと導線が切れる。
          _LoginBenefit(
            icon: Icons.lock_outline,
            title: 'プライベートリポジトリも解析できる',
            linkLabel: '取得手順はこちら',
            onLinkTap: () => PatGuideDialog.show(context),
            body: signedIn
                ? 'GitHub の Personal Access Token（PAT）を登録すると、'
                      '自分のプライベートリポジトリを一覧から選んで解析できます。'
                : 'ログイン後に GitHub の Personal Access Token（PAT）を登録すると、'
                      '自分のプライベートリポジトリを一覧から選んで解析できます。',
          ),
          // 説明を読んだその場から登録に進めるようにする。
          // ログイン前はダイアログを開いても保存できないので出さない。
          if (signedIn) ...[
            const SizedBox(height: 12),
            _SidebarAction(
              icon: Icons.key_outlined,
              label: 'PATを登録する',
              onTap: onRegisterToken,
            ),
          ],
        ],
      ),
    );
  }
}

/// サイドバー内の小さな行動リンク。枠で囲って「押せる」ことを見せる。
class _SidebarAction extends StatelessWidget {
  const _SidebarAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(border: Border.all(color: AppPalette.line)),
          child: Row(
            children: [
              Icon(icon, size: 15, color: AppPalette.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: appMono(
                    12,
                    color: AppPalette.accent,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
              const Icon(
                Icons.arrow_forward,
                size: 13,
                color: AppPalette.accent,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FormField extends StatelessWidget {
  const _FormField({
    required this.label,
    required this.controller,
    required this.hint,
  });

  final String label;
  final TextEditingController controller;
  final String hint;

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
            weight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          style: appMono(14, color: AppPalette.ink),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: appMono(
              14,
              color: AppPalette.inkMuted.withValues(alpha: 0.5),
            ),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 12,
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
      ],
    );
  }
}

class _SamplesSection extends StatelessWidget {
  const _SamplesSection({
    required this.isNarrow,
    required this.loading,
    required this.onPick,
  });

  final bool isNarrow;
  final bool loading;
  final void Function(_SampleRepository) onPick;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'まずは3件のサンプルから',
          style: appMono(
            12,
            color: AppPalette.inkMuted,
            weight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '自分のリポジトリがなくても、実コードから作った3件のサンプルですぐ試せます。',
          style: appBody(14, color: AppPalette.inkMuted),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 20,
          runSpacing: 20,
          children: _samples
              .map(
                (s) => _SampleCard(
                  sample: s,
                  width: isNarrow ? double.infinity : 280,
                  loading: loading,
                  onPick: () => onPick(s),
                ),
              )
              .toList(),
        ),
      ],
    );
  }
}

class _SampleCard extends StatefulWidget {
  const _SampleCard({
    required this.sample,
    required this.width,
    required this.loading,
    required this.onPick,
  });

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
        // Wrap の中では子の高さが内容任せになるので、明示的に揃える。
        // 最も行数の多いスニペットが収まる高さにしてある。
        height: 290,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.loading ? null : widget.onPick,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              transform: Matrix4.translationValues(0, _hover ? -3 : 0, 0),
              child: _PlainCard(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sample.label,
                      style: appDisplay(14, weight: FontWeight.w700),
                    ),
                    const SizedBox(height: 10),
                    // スニペットの行数がカードごとに違うため、そのまま並べると
                    // 高さが不揃いになる。コード部分を伸縮させて全カードを同じ高さに揃える。
                    // 折り返しで想定より縦に伸びることがあるので、はみ出しは切り取る。
                    Expanded(
                      child: ClipRect(
                        child: OverflowBox(
                          alignment: Alignment.topLeft,
                          maxHeight: double.infinity,
                          child: DiffCodeBlock(code: sample.snippetPreview),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Text(
                          'クイズを見る',
                          style: appMono(
                            12,
                            color: AppPalette.accent,
                            weight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.arrow_forward,
                          size: 14,
                          color: AppPalette.accent,
                        ),
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
        Text(
          'repo-educator — 4択を解くだけで、コードが頭に入る',
          style: appMono(11.5, color: AppPalette.inkMuted),
        ),
      ],
    );
  }
}
