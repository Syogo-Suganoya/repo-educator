import 'package:flutter/material.dart';

import 'api_client.dart';
import 'auth/account_button.dart';
import 'auth/auth_service.dart';
import 'models/quiz.dart';
import 'repositories_page.dart';
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

/// 「PRを開く」ことが、そのままクイズを始めることになる1画面完結の起点。
/// マーケティング用の説明とURL入力を分離せず、迷わず最短で最初のレビューに入れることを優先する。
class StartPage extends StatefulWidget {
  const StartPage({super.key});

  @override
  State<StartPage> createState() => _StartPageState();
}

class _StartPageState extends State<StartPage> {
  final _authService = AuthService();
  late final _apiClient = ApiClient(authService: _authService);
  final _urlController = TextEditingController();
  final _branchController = TextEditingController(text: 'main');

  bool _loading = false;
  String? _errorMessage;

  /// PATの取得手順セクション。ダイアログから「手順を見る」で飛ばすための目印。
  final _patSectionKey = GlobalKey();
  bool _patStepsExpanded = false;

  /// 手順を開いた状態で、そのセクションまでスクロールする。
  Future<void> _showPatGuide() async {
    setState(() => _patStepsExpanded = true);
    // 展開後のレイアウトが確定してからでないと、移動先の位置がずれる。
    await WidgetsBinding.instance.endOfFrame;
    final target = _patSectionKey.currentContext;
    if (target == null || !target.mounted) return;
    await Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 300),
      alignment: 0.05,
    );
  }

  @override
  void initState() {
    super.initState();
    // restore() は非同期なので、完了時に本体も描き直す必要がある。
    // これを購読しないと、保存済みセッションで開き直したときに
    // トップバーはログイン済みなのに本文は未ログインの案内のまま、という食い違いが起きる。
    _authService.addListener(_onAuthChanged);
    _authService.restore();
  }

  void _onAuthChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _authService.removeListener(_onAuthChanged);
    _urlController.dispose();
    _branchController.dispose();
    _authService.dispose();
    super.dispose();
  }

  void _openRepositories() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RepositoriesPage(
          apiClient: _apiClient,
          onPick: (repository) {
            Navigator.of(context).pop();
            _openPr(url: repository.htmlUrl, branch: repository.defaultBranch);
          },
        ),
      ),
    );
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
    _openPr(url: sample.url, branch: sample.branch);
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isNarrow = width < 720;

    return Scaffold(
      backgroundColor: AppPalette.bg,
      appBar: AppTopBar(
        trailing: AccountButton(
          authService: _authService,
          apiClient: _apiClient,
          onChanged: () => setState(() {}),
          onShowPatGuide: _showPatGuide,
        ),
      ),
      body: SingleChildScrollView(
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
                  const SizedBox(height: 16),
                  // ログイン済みのときだけ、自分のリポジトリを選ぶ導線を足す。
                  if (_authService.isSignedIn) ...[
                    _PrivateReposEntry(onOpen: _openRepositories),
                    const SizedBox(height: 16),
                  ],
                  // PATの説明はログイン後も参照する（トークン入力ダイアログから飛んでくる）ため、
                  // ログイン状態に関わらず常に置く。手順は畳んでおく。
                  _PrivateRepoAppeal(
                    key: _patSectionKey,
                    expanded: _patStepsExpanded,
                    onToggle: () =>
                        setState(() => _patStepsExpanded = !_patStepsExpanded),
                  ),
                  SizedBox(height: isNarrow ? 48 : 72),
                  _Lifecycle(isNarrow: isNarrow),
                  SizedBox(height: isNarrow ? 48 : 72),
                  _SamplesSection(
                    isNarrow: isNarrow,
                    loading: _loading,
                    onPick: _pickSample,
                    errorMessage: _errorMessage,
                  ),
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
        Text(
          'git diff --learn',
          style: appMono(
            13,
            color: AppPalette.accent,
            weight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'コードを読む力は、\nレビューするほど身につく。',
          style: appDisplay(
            isNarrow ? 30 : 42,
            height: 1.35,
            weight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'GitHubのリポジトリURLを渡すだけで、実際のコードの一部を「差分」に見立てた\n4択クイズが生まれます。空欄になった1行を当てて、変更をapproveしましょう。',
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
                          'このリポジトリのクイズを生成する',
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

/// GitHubのFine-grained PAT発行ページ。
/// 画面の項目名はこのページのものに合わせてある。
const _patSettingsUrl = 'https://github.com/settings/personal-access-tokens';

/// 取得手順の1ステップ。番号と本文を左右に並べ、手順として読ませる。
class _PatStep extends StatelessWidget {
  const _PatStep({
    required this.number,
    required this.body,
    this.link,
    this.linkLabel,
    this.isLast = false,
  });

  final String number;
  final String body;
  final String? link;
  final String? linkLabel;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 18,
            height: 18,
            alignment: Alignment.center,
            margin: const EdgeInsets.only(top: 2, right: 10),
            color: AppPalette.accentSoft,
            child: Text(
              number,
              style: appMono(
                10.5,
                color: AppPalette.accent,
                weight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText(
                  body,
                  style: appBody(12.5, color: AppPalette.inkMuted, height: 1.8),
                ),
                if (link != null) ...[
                  const SizedBox(height: 5),
                  AppLink(
                    label: linkLabel ?? link!,
                    url: link!,
                    style: appMono(11.5, weight: FontWeight.w700),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 未ログイン時に表示する、プライベートリポジトリ対応のアピールと
/// Personal Access Token の取得手順の案内。
class _PrivateRepoAppeal extends StatelessWidget {
  const _PrivateRepoAppeal({
    super.key,
    required this.expanded,
    required this.onToggle,
  });

  /// 手順を開いているか。ダイアログから飛んできたときは開いた状態で表示する。
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return _PlainCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.lock_outline,
                size: 15,
                color: AppPalette.accent,
              ),
              const SizedBox(width: 8),
              Text(
                'プライベートリポジトリも解析できます',
                style: appMono(
                  12.5,
                  color: AppPalette.accent,
                  weight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'ログイン後、アカウントメニューから GitHub の Personal Access Token（PAT）を登録すると、'
            '自分のプライベートリポジトリも解析できます。PATは「このアプリに、指定したリポジトリを'
            '読むことだけを許可する鍵」です。GitHubのパスワードを預ける必要はなく、'
            '許可する範囲も権限も自分で決められます。',
            style: appBody(13.5, color: AppPalette.inkMuted, height: 1.8),
          ),
          const SizedBox(height: 14),
          // 手順は初回だけ必要な情報なので、既定では畳んでおく。
          // 「何ができるか」は畳まず常に見せる。
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: AppPalette.accent,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      expanded ? 'PATの取得手順を折りたたむ' : 'PATの取得手順を見る',
                      style: appMono(
                        12,
                        color: AppPalette.accent,
                        weight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (expanded) ...[
            const SizedBox(height: 10),
            const _PatStep(
              number: '1',
              body:
                  'GitHubのトークン発行ページを開きます（Settings → Developer settings → '
                  'Personal access tokens → Fine-grained tokens でも同じ画面に行けます）。',
              link: _patSettingsUrl,
              linkLabel: 'github.com/settings/personal-access-tokens',
            ),
            const _PatStep(
              number: '2',
              body:
                  '「Generate new token」を押し、Token name（任意の名前）と Expiration（有効期限）を決めます。'
                  '期限は短いほど安全です。切れたら再発行して入れ直してください。',
            ),
            const _PatStep(
              number: '3',
              body:
                  'Repository access で「Only select repositories」を選び、学習したいリポジトリだけを指定します。'
                  '「All repositories」は必要以上に広い許可になるため避けてください。',
            ),
            const _PatStep(
              number: '4',
              body:
                  'Repository permissions で `Contents` を `Read-only` にします。必要な権限はこれだけです。'
                  '`Metadata`（Read-only）は必須項目として自動で有効になります。',
            ),
            const _PatStep(
              number: '5',
              body:
                  '「Generate token」を押し、表示されたトークンをコピーします。'
                  'この画面を離れると二度と表示されないので、その場で次の手順へ進んでください。',
            ),
            const _PatStep(
              number: '6',
              body:
                  '右上のアカウントメニュー →「GitHubトークン」に貼り付けて保存します。'
                  'サーバーには暗号化して保存され、ログアウトしても残ります。',
              isLast: true,
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              color: AppPalette.surfaceSunken,
              child: AppText(
                'なぜ `Contents` だけでよいのか: このアプリはリポジトリの情報取得・コミットの確認・'
                'ソースコードの読み取りしか行いません。書き込み権限（Read and write）や、'
                'Issues・Pull requests などの他の権限は一切不要です。',
                style: appBody(12, color: AppPalette.inkMuted, height: 1.8),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// ログイン済みユーザーだけに見せる、自分のリポジトリへの導線。
class _PrivateReposEntry extends StatelessWidget {
  const _PrivateReposEntry({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(border: Border.all(color: AppPalette.line)),
          child: Row(
            children: [
              const Icon(
                Icons.lock_outline,
                size: 15,
                color: AppPalette.accent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '自分のプライベートリポジトリから選ぶ',
                  style: appMono(
                    12.5,
                    color: AppPalette.accent,
                    weight: FontWeight.w700,
                  ),
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
        Text(
          'PRのライフサイクル',
          style: appMono(
            12,
            color: AppPalette.inkMuted,
            weight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 20),
        isNarrow
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final s in _stages) _StageTile(stage: s.$1, desc: s.$2),
                ],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final s in _stages)
                    Expanded(
                      child: _StageTile(stage: s.$1, desc: s.$2),
                    ),
                ],
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
            child: Text(
              stage,
              style: appMono(
                11.5,
                color: AppPalette.accent,
                weight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(desc, style: appBody(14, color: AppPalette.ink, height: 1.6)),
        ],
      ),
    );
  }
}

class _SamplesSection extends StatelessWidget {
  const _SamplesSection({
    required this.isNarrow,
    required this.loading,
    required this.onPick,
    this.errorMessage,
  });

  final bool isNarrow;
  final bool loading;
  final void Function(_SampleRepository) onPick;

  /// 失敗の表示は入力フォームの中にもあるが、サンプルは画面のずっと下にあるため
  /// そこだけを見ていると「押しても何も起きない」ように見える。ここにも出す。
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'サンプルPRを開く',
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
                          'このPRを開く',
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
          'repo-educator — 実コードを差分レビューする感覚で読む力を鍛える',
          style: appMono(11.5, color: AppPalette.inkMuted),
        ),
      ],
    );
  }
}
