import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models/repository.dart';
import '../theme.dart';
import 'auth_service.dart';
import 'github_token_dialog.dart';
import 'login_dialog.dart';

/// トップバー右端に置くアカウント表示。
/// 未ログイン時は「ログイン」、ログイン時はアカウント名とメニューを出す。
class AccountButton extends StatefulWidget {
  const AccountButton({
    super.key,
    required this.authService,
    required this.apiClient,
    this.onChanged,
    this.onOpenProfile,
  });

  final AuthService authService;
  final ApiClient apiClient;
  final VoidCallback? onChanged;

  /// アカウントに紐づくもの（トークン・リポジトリ・履歴）をまとめた画面を開く。
  final VoidCallback? onOpenProfile;

  @override
  State<AccountButton> createState() => _AccountButtonState();
}

class _AccountButtonState extends State<AccountButton> {
  AccountInfo _account = const AccountInfo();

  @override
  void initState() {
    super.initState();
    if (widget.authService.isSignedIn) _refreshAccount();
  }

  Future<void> _refreshAccount() async {
    try {
      final account = await widget.apiClient.fetchMe();
      if (mounted) setState(() => _account = account);
    } catch (_) {
      // アカウント情報が取れなくても、ログイン状態の表示自体は継続する。
    }
  }

  Future<void> _signIn() async {
    // ダイアログ内で register/login を行う。ここでは結果を受け取るだけ。
    final signedIn = await LoginDialog.show(
      context,
      authService: widget.authService,
    );
    if (signedIn == true) {
      widget.onChanged?.call();
      await _refreshAccount();
    }
  }

  Future<void> _signOut() async {
    await widget.authService.signOut();
    setState(() => _account = const AccountInfo());
    widget.onChanged?.call();
  }

  Future<void> _openTokenDialog() async {
    final tokens = await GithubTokenDialog.show(
      context,
      apiClient: widget.apiClient,
    );
    if (tokens == null || !mounted) return;
    // 表示用のアカウント情報を取り直す（本数や連携先が変わっている）。
    await _refreshAccount();
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService.isAvailable) return const SizedBox.shrink();

    return ListenableBuilder(
      listenable: widget.authService,
      builder: (context, _) {
        if (!widget.authService.isReady) return const SizedBox.shrink();

        if (!widget.authService.isSignedIn) {
          return TextButton.icon(
            onPressed: _signIn,
            icon: const Icon(
              Icons.lock_open,
              size: 15,
              color: AppPalette.accent,
            ),
            label: Text(
              'ログイン',
              style: appMono(
                12.5,
                color: AppPalette.accent,
                weight: FontWeight.w700,
              ),
            ),
          );
        }

        final name = widget.authService.displayName ?? 'signed in';
        return PopupMenuButton<String>(
          tooltip: 'アカウント',
          onSelected: (value) {
            if (value == 'signout') _signOut();
            if (value == 'profile') widget.onOpenProfile?.call();
            if (value == 'github_token') _openTokenDialog();
          },
          itemBuilder: (context) => [
            if (widget.onOpenProfile != null)
              PopupMenuItem(
                value: 'profile',
                child: Row(
                  children: [
                    const Icon(
                      Icons.person_outline,
                      size: 16,
                      color: AppPalette.inkMuted,
                    ),
                    const SizedBox(width: 8),
                    Text('プロフィール', style: appBody(13.5)),
                  ],
                ),
              ),
            PopupMenuItem(
              value: 'github_token',
              child: Row(
                children: [
                  Icon(
                    _account.hasGithubToken
                        ? Icons.check_circle_outline
                        : Icons.key_outlined,
                    size: 16,
                    color: _account.hasGithubToken
                        ? AppPalette.add
                        : AppPalette.inkMuted,
                  ),
                  const SizedBox(width: 8),
                  Text('GitHubトークン', style: appBody(13.5)),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'signout',
              child: Text('ログアウト', style: appBody(13.5)),
            ),
          ],
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.person_outline,
                size: 16,
                color: AppPalette.inkMuted,
              ),
              const SizedBox(width: 6),
              Text(
                name,
                style: appMono(
                  12.5,
                  color: AppPalette.inkMuted,
                  weight: FontWeight.w600,
                ),
              ),
              const Icon(
                Icons.arrow_drop_down,
                size: 18,
                color: AppPalette.inkMuted,
              ),
            ],
          ),
        );
      },
    );
  }
}
