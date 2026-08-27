import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models/repository.dart';
import '../theme.dart';
import 'pat_guide_dialog.dart';

/// GitHub Personal Access Token を追加・削除するダイアログ。
///
/// トークンはユーザー自身が発行し、ここで入力したものだけをサーバーに保存する。
/// 環境変数など、アプリ側で用意した共有トークンとは別物。
/// 保存後はログアウトしても残り、次回ログイン時にそのまま使える。
///
/// **複数登録できる。** Fine-grained PAT は「選んだリポジトリ」しか読めないため、
/// 複数の組織やアカウントにまたがると1本では足りない。どのトークンがどのリポジトリに
/// 効くかはサーバー側が自動で見つけるので、利用者が選ぶ必要はない。
class GithubTokenDialog extends StatefulWidget {
  const GithubTokenDialog({super.key, required this.apiClient});

  final ApiClient apiClient;

  /// ダイアログを開く。閉じたときの最新のトークン一覧を返す。
  static Future<List<GithubTokenSummary>?> show(
    BuildContext context, {
    required ApiClient apiClient,
  }) {
    return showDialog<List<GithubTokenSummary>>(
      context: context,
      builder: (_) => GithubTokenDialog(apiClient: apiClient),
    );
  }

  @override
  State<GithubTokenDialog> createState() => _GithubTokenDialogState();
}

class _GithubTokenDialogState extends State<GithubTokenDialog> {
  final _controller = TextEditingController();
  final _labelController = TextEditingController();
  bool _busy = false;
  bool _loading = true;
  String? _errorMessage;
  List<GithubTokenSummary> _tokens = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    _labelController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final tokens = await widget.apiClient.fetchGithubTokens();
      if (mounted) setState(() => _tokens = tokens);
    } catch (_) {
      // 一覧が取れなくても追加はできるので、画面は開いたままにする。
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _add() async {
    final token = _controller.text.trim();
    if (token.isEmpty) {
      setState(() => _errorMessage = 'トークンを入力してください。');
      return;
    }
    setState(() {
      _busy = true;
      _errorMessage = null;
    });
    try {
      final tokens = await widget.apiClient.addGithubToken(
        token,
        label: _labelController.text,
      );
      if (!mounted) return;
      setState(() {
        _tokens = tokens;
        _controller.clear();
        _labelController.clear();
      });
    } on QuizApiException catch (e) {
      setState(() => _errorMessage = e.toUserMessage());
    } catch (_) {
      setState(() => _errorMessage = '保存に失敗しました。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(GithubTokenSummary token) async {
    setState(() => _busy = true);
    try {
      final tokens = await widget.apiClient.deleteGithubToken(token.id);
      if (mounted) setState(() => _tokens = tokens);
    } on QuizApiException catch (e) {
      if (mounted) setState(() => _errorMessage = e.toUserMessage());
    } catch (_) {
      if (mounted) setState(() => _errorMessage = '削除に失敗しました。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 660),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'GitHubトークン',
                    style: appDisplay(18, weight: FontWeight.w800),
                  ),
                  const SizedBox(height: 10),
                  // 冒頭は「何をすればいいか」だけにする。保存の仕組みは
                  // 入力の判断に要らないので、補足として下部へ回す。
                  AppText(
                    'プライベートリポジトリを学習するには、GitHubのPersonal Access Token（PAT）を'
                    '入力してください。',
                    style: appBody(
                      13.5,
                      color: AppPalette.inkMuted,
                      height: 1.7,
                    ),
                  ),
                  const SizedBox(height: 10),
                  // 手順は別のモーダルで開く。入力中の内容を消さずに参照できる。
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => PatGuideDialog.show(context),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.help_outline,
                              size: 15,
                              color: AppPalette.accent,
                            ),
                            const SizedBox(width: 7),
                            Expanded(
                              child: Text(
                                'PATの取得手順と必要な権限を見る',
                                style: appMono(
                                  12,
                                  color: AppPalette.accent,
                                  weight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 8),
                    if (_loading)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppPalette.accent,
                          ),
                        ),
                      )
                    else if (_tokens.isEmpty)
                      Text(
                        'まだ登録されていません。',
                        style: appMono(12, color: AppPalette.inkMuted),
                      )
                    else
                      for (final token in _tokens)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _TokenRow(
                            token: token,
                            busy: _busy,
                            onDelete: () => _delete(token),
                          ),
                        ),
                    const SizedBox(height: 16),
                    // トークン名。GitHubには「このトークンの名前」を返すAPIが無いため、
                    // 一覧で見分けたいなら本人に転記してもらうしかない。
                    TextField(
                      controller: _labelController,
                      style: appMono(13, color: AppPalette.ink),
                      maxLength: 60,
                      onSubmitted: (_) => _add(),
                      decoration: InputDecoration(
                        hintText: 'トークン名（任意・例: repo-educator 用）',
                        hintStyle: appMono(
                          13,
                          color: AppPalette.inkMuted.withValues(alpha: 0.5),
                        ),
                        isDense: true,
                        counterText: '',
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
                          borderSide: BorderSide(
                            color: AppPalette.accent,
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _controller,
                      obscureText: true,
                      style: appMono(13, color: AppPalette.ink),
                      onSubmitted: (_) => _add(),
                      decoration: InputDecoration(
                        hintText: 'github_pat_...',
                        hintStyle: appMono(
                          13,
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
                          borderSide: BorderSide(
                            color: AppPalette.accent,
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'github_pat_... で始まる文字列です。発行直後の画面でしか表示されません。',
                      style: appMono(11, color: AppPalette.inkMuted),
                    ),
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        color: AppPalette.removeSoft,
                        child: Text(
                          _errorMessage!,
                          style: appMono(12, color: AppPalette.remove),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // 保存の仕組みと複数登録の扱い。知っておくと安心だが、
            // 入力の手を止めてまで読む必要はないので小さく末尾に置く。
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  _Note('サーバーに暗号化して保存され、ログアウトしても残ります'),
                  _Note('複数登録でき、どのトークンでどのリポジトリを読むかは自動で判別します'),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => Navigator.of(context).pop(_tokens),
                    child: Text(
                      '閉じる',
                      style: appMono(12.5, color: AppPalette.inkMuted),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _busy ? null : _add,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppPalette.accent,
                      foregroundColor: Colors.white,
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.zero,
                      ),
                    ),
                    child: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            '追加',
                            style: appMono(
                              12.5,
                              color: Colors.white,
                              weight: FontWeight.w700,
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ダイアログ下部の補足1行。読み飛ばせるよう、行頭の点も文字も小さくする。
class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final style = appBody(11.5, color: AppPalette.inkMuted, height: 1.6);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('・', style: style),
          Expanded(child: AppText(text, style: style)),
        ],
      ),
    );
  }
}

class _TokenRow extends StatelessWidget {
  const _TokenRow({
    required this.token,
    required this.busy,
    required this.onDelete,
  });

  final GithubTokenSummary token;
  final bool busy;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 12),
      color: AppPalette.addSoft,
      child: Row(
        children: [
          const Icon(
            Icons.check_circle_outline,
            size: 16,
            color: AppPalette.add,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              token.displayName,
              style: appMono(
                12.5,
                color: AppPalette.add,
                weight: FontWeight.w700,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            onPressed: busy ? null : onDelete,
            tooltip: '削除',
            icon: const Icon(Icons.close, size: 15, color: AppPalette.inkMuted),
          ),
        ],
      ),
    );
  }
}
