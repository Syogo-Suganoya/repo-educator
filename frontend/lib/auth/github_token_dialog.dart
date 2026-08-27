import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models/repository.dart';
import '../theme.dart';

/// GitHub Personal Access Token を入力・保存・削除するダイアログ。
///
/// トークンはユーザー自身が発行し、ここで入力したものだけをサーバーに保存する。
/// 環境変数など、アプリ側で用意した共有トークンとは別物。
/// 保存後はログアウトしても残り、次回ログイン時にそのまま使える。
class GithubTokenDialog extends StatefulWidget {
  const GithubTokenDialog({
    super.key,
    required this.apiClient,
    required this.initialAccount,
    this.onShowPatGuide,
  });

  final ApiClient apiClient;
  final AccountInfo initialAccount;

  /// 取得手順はトップページに置いてあるので、ここでは案内するだけにする。
  final VoidCallback? onShowPatGuide;

  /// ダイアログを開く。保存・削除に成功した場合は最新の AccountInfo を返す。
  static Future<AccountInfo?> show(
    BuildContext context, {
    required ApiClient apiClient,
    required AccountInfo account,
    VoidCallback? onShowPatGuide,
  }) {
    return showDialog<AccountInfo>(
      context: context,
      builder: (_) => GithubTokenDialog(
        apiClient: apiClient,
        initialAccount: account,
        onShowPatGuide: onShowPatGuide,
      ),
    );
  }

  @override
  State<GithubTokenDialog> createState() => _GithubTokenDialogState();
}

class _GithubTokenDialogState extends State<GithubTokenDialog> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _errorMessage;
  late final AccountInfo _account = widget.initialAccount;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
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
      final account = await widget.apiClient.saveGithubToken(token);
      if (!mounted) return;
      Navigator.of(context).pop(account);
    } on QuizApiException catch (e) {
      setState(() => _errorMessage = e.toUserMessage());
    } catch (_) {
      setState(() => _errorMessage = '保存に失敗しました。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    setState(() => _busy = true);
    try {
      await widget.apiClient.clearGithubToken();
      if (!mounted) return;
      Navigator.of(context).pop(const AccountInfo());
    } on QuizApiException catch (e) {
      setState(() => _errorMessage = e.toUserMessage());
    } catch (_) {
      setState(() => _errorMessage = '削除に失敗しました。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('GitHubトークン', style: appDisplay(18, weight: FontWeight.w800)),
              const SizedBox(height: 10),
              AppText(
                'プライベートリポジトリを学習するには、GitHubのPersonal Access Token（PAT）を'
                '入力してください。サーバーに暗号化して保存し、ログアウトしても残ります。',
                style: appBody(13.5, color: AppPalette.inkMuted, height: 1.7),
              ),
              const SizedBox(height: 12),
              // 手順そのものはトップページに1箇所だけ置き、ここからはそこへ案内する。
              // 同じ内容を2箇所に書くと、片方だけ古くなる。
              if (widget.onShowPatGuide != null)
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () {
                      Navigator.of(context).pop();
                      widget.onShowPatGuide!();
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          const Icon(Icons.help_outline, size: 15, color: AppPalette.accent),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              'PATの取得手順と必要な権限を見る',
                              style: appMono(12, color: AppPalette.accent, weight: FontWeight.w700),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              if (_account.hasGithubToken) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  color: AppPalette.addSoft,
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle_outline, size: 16, color: AppPalette.add),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _account.githubLogin != null
                              ? '設定済み（${_account.githubLogin}）'
                              : '設定済み',
                          style: appMono(12.5, color: AppPalette.add, weight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              TextField(
                controller: _controller,
                obscureText: true,
                style: appMono(13, color: AppPalette.ink),
                decoration: InputDecoration(
                  hintText: 'github_pat_...',
                  hintStyle: appMono(13, color: AppPalette.inkMuted.withValues(alpha: 0.5)),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  border: const OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: BorderSide(color: AppPalette.line)),
                  enabledBorder: const OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: BorderSide(color: AppPalette.line)),
                  focusedBorder: const OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: BorderSide(color: AppPalette.accent, width: 1.5)),
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
                  child: Text(_errorMessage!, style: appMono(12, color: AppPalette.remove)),
                ),
              ],
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (_account.hasGithubToken)
                    TextButton(
                      onPressed: _busy ? null : _clear,
                      style: TextButton.styleFrom(foregroundColor: AppPalette.remove),
                      child: Text('削除する', style: appMono(12.5, weight: FontWeight.w700)),
                    )
                  else
                    const SizedBox.shrink(),
                  Row(
                    children: [
                      TextButton(
                        onPressed: _busy ? null : () => Navigator.of(context).pop(),
                        child: Text('閉じる', style: appMono(12.5, color: AppPalette.inkMuted)),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _busy ? null : _save,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppPalette.accent,
                          foregroundColor: Colors.white,
                          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                        ),
                        child: _busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : Text('保存', style: appMono(12.5, color: Colors.white, weight: FontWeight.w700)),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
