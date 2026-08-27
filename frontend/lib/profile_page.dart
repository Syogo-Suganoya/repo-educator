import 'package:flutter/material.dart';

import 'api_client.dart';
import 'auth/auth_service.dart';
import 'auth/github_token_dialog.dart';
import 'history/generation_history.dart';
import 'history/history_list.dart';
import 'models/repository.dart';
import 'repository_card.dart';
import 'theme.dart';

/// アカウントに紐づくものを1画面にまとめたプロフィール。
///
/// GitHubトークン・プライベートリポジトリ・生成したクイズの履歴は、
/// どれも「ログインしているから使えるもの」なので、探し回らずに済むよう
/// ここへ集約する。個々の画面（トークン入力ダイアログ、リポジトリ一覧）は
/// これまで通り単体でも使えるようにしてあり、ここはその入口を兼ねる。
class ProfilePage extends StatefulWidget {
  const ProfilePage({
    super.key,
    required this.apiClient,
    required this.authService,
    required this.history,
    required this.onOpenRepository,
    required this.onOpenHistory,
    this.onSignedOut,
  });

  final ApiClient apiClient;
  final AuthService authService;
  final GenerationHistoryStore history;

  /// リポジトリを選んだとき／履歴を開いたときに、クイズ画面へ遷移させる。
  /// 遷移の責務は起点画面が持っているため、コールバックで渡してもらう。
  final void Function(RepositorySummary) onOpenRepository;
  final void Function(GenerationHistoryEntry) onOpenHistory;

  /// ログアウト後に起点画面へ戻すために呼ぶ。
  final VoidCallback? onSignedOut;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  AccountInfo _account = const AccountInfo();
  List<RepositorySummary> _repositories = [];
  bool _loadingAccount = true;
  bool _loadingRepositories = false;
  String? _repositoryError;

  @override
  void initState() {
    super.initState();
    widget.history.addListener(_onChanged);
    _load();
  }

  @override
  void dispose() {
    widget.history.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() => _loadingAccount = true);
    try {
      final account = await widget.apiClient.fetchMe();
      if (!mounted) return;
      setState(() => _account = account);
      if (account.hasGithubToken) await _loadRepositories();
    } catch (_) {
      // アカウント情報が取れなくても、履歴などは表示できるので画面は出す。
    } finally {
      if (mounted) setState(() => _loadingAccount = false);
    }
    await widget.history.load();
  }

  Future<void> _loadRepositories() async {
    setState(() {
      _loadingRepositories = true;
      _repositoryError = null;
    });
    try {
      final repositories = await widget.apiClient.fetchRepositories();
      if (!mounted) return;
      setState(() => _repositories = repositories);
    } on QuizApiException catch (e) {
      if (mounted) setState(() => _repositoryError = e.toUserMessage());
    } catch (_) {
      if (mounted) setState(() => _repositoryError = 'リポジトリ一覧を取得できませんでした。');
    } finally {
      if (mounted) setState(() => _loadingRepositories = false);
    }
  }

  Future<void> _openTokenDialog() async {
    final tokens = await GithubTokenDialog.show(
      context,
      apiClient: widget.apiClient,
    );
    if (tokens == null || !mounted) return;
    setState(() {
      _account = AccountInfo(
        githubLogin: tokens.isEmpty ? null : tokens.first.githubLogin,
        hasGithubToken: tokens.isNotEmpty,
        githubTokenCount: tokens.length,
      );
      if (tokens.isEmpty) _repositories = [];
    });
    if (tokens.isNotEmpty) await _loadRepositories();
  }

  Future<void> _signOut() async {
    await widget.authService.signOut();
    if (!mounted) return;
    // ログアウトするとこの画面の中身はすべて見られなくなるので、起点画面へ戻す。
    Navigator.of(context).pop();
    widget.onSignedOut?.call();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isNarrow = width < 720;

    return Scaffold(
      backgroundColor: AppPalette.bg,
      appBar: AppTopBar(onBack: () => Navigator.of(context).pop()),
      body: SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: isNarrow ? 20 : 40,
                vertical: isNarrow ? 24 : 36,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'プロフィール',
                    style: appDisplay(
                      isNarrow ? 24 : 30,
                      weight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    widget.authService.displayName ?? 'ログイン中',
                    style: appMono(13, color: AppPalette.inkMuted),
                  ),
                  const SizedBox(height: 32),

                  _ProfileSection(
                    title: 'GitHubトークン',
                    description:
                        'プライベートリポジトリを解析するために使います。'
                        'サーバーに暗号化して保存され、ログアウトしても残ります。',
                    child: _loadingAccount
                        ? const _SectionLoading()
                        : _TokenStatus(
                            account: _account,
                            onEdit: _openTokenDialog,
                          ),
                  ),
                  const SizedBox(height: 32),

                  _ProfileSection(
                    title: 'プライベートリポジトリ',
                    description:
                        'トークンで読めるプライベートリポジトリです。'
                        '公開リポジトリはトップページにURLを貼れば解析できます。',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const PrivacyNotice(),
                        const SizedBox(height: 16),
                        _buildRepositories(isNarrow),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),

                  _ProfileSection(
                    title: '生成したクイズ',
                    description: 'アカウントに保存されています。別のブラウザや端末からも同じ一覧を開けます。',
                    child: widget.history.entries.isEmpty
                        ? const _SectionEmpty(message: 'まだクイズを生成していません。')
                        : HistoryList(
                            entries: widget.history.entries,
                            onOpen: widget.onOpenHistory,
                            onRemove: widget.history.remove,
                          ),
                  ),
                  const SizedBox(height: 40),

                  Container(height: 1, color: AppPalette.line),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: _signOut,
                      icon: const Icon(Icons.logout, size: 15),
                      label: Text(
                        'ログアウト',
                        style: appMono(12.5, weight: FontWeight.w700),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppPalette.remove,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.zero,
                        ),
                        side: const BorderSide(color: AppPalette.line),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRepositories(bool isNarrow) {
    if (_loadingAccount || _loadingRepositories) return const _SectionLoading();

    if (!_account.hasGithubToken) {
      return _SectionEmpty(
        message: 'トークンが未設定です。上の「GitHubトークン」から登録してください。',
        action: TextButton(
          onPressed: _openTokenDialog,
          child: Text(
            'トークンを設定',
            style: appMono(
              12.5,
              color: AppPalette.accent,
              weight: FontWeight.w700,
            ),
          ),
        ),
      );
    }

    if (_repositoryError != null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        color: AppPalette.removeSoft,
        child: Text(
          _repositoryError!,
          style: appMono(12.5, color: AppPalette.remove),
        ),
      );
    }

    if (_repositories.isEmpty) {
      return const _SectionEmpty(
        message:
            '読めるプライベートリポジトリが見つかりませんでした。'
            'トークンの Repository access に対象が含まれているか確認してください。',
      );
    }

    return Wrap(
      spacing: 16,
      runSpacing: 16,
      children: [
        for (final repository in _repositories)
          RepositoryCard(
            repository: repository,
            width: isNarrow ? double.infinity : 380,
            onPick: () => widget.onOpenRepository(repository),
          ),
      ],
    );
  }
}

/// 見出し + 説明 + 中身の3点セット。節ごとの体裁を1箇所に閉じ込める。
class _ProfileSection extends StatelessWidget {
  const _ProfileSection({
    required this.title,
    required this.description,
    required this.child,
  });

  final String title;
  final String description;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: appMono(
            12,
            color: AppPalette.inkMuted,
            weight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          description,
          style: appBody(13.5, color: AppPalette.inkMuted, height: 1.7),
        ),
        const SizedBox(height: 16),
        child,
      ],
    );
  }
}

class _TokenStatus extends StatelessWidget {
  const _TokenStatus({required this.account, required this.onEdit});

  final AccountInfo account;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final configured = account.hasGithubToken;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(border: Border.all(color: AppPalette.line)),
      child: Row(
        children: [
          Icon(
            configured ? Icons.check_circle_outline : Icons.key_outlined,
            size: 16,
            color: configured ? AppPalette.add : AppPalette.inkMuted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              configured
                  ? '${account.githubTokenCount}本 登録済み'
                        '${account.githubLogin != null ? '（${account.githubLogin} ほか）' : ''}'
                  : '未設定',
              style: appMono(
                12.5,
                color: configured ? AppPalette.add : AppPalette.inkMuted,
                weight: FontWeight.w700,
              ),
            ),
          ),
          TextButton(
            onPressed: onEdit,
            child: Text(
              configured ? '追加・削除' : '設定する',
              style: appMono(
                12.5,
                color: AppPalette.accent,
                weight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLoading extends StatelessWidget {
  const _SectionLoading();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 20),
      child: SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: AppPalette.accent,
        ),
      ),
    );
  }
}

class _SectionEmpty extends StatelessWidget {
  const _SectionEmpty({required this.message, this.action});

  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(border: Border.all(color: AppPalette.line)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: appBody(13, color: AppPalette.inkMuted, height: 1.7),
          ),
          if (action != null) ...[const SizedBox(height: 6), action!],
        ],
      ),
    );
  }
}
