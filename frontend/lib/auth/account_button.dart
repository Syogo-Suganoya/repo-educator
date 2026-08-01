import 'package:flutter/material.dart';

import '../api_client.dart';
import '../theme.dart';
import 'auth_service.dart';

/// トップバー右端に置くアカウント表示。
/// 未ログイン時は「GitHubでログイン」、ログイン時はアカウント名とメニューを出す。
class AccountButton extends StatefulWidget {
  const AccountButton({
    super.key,
    required this.authService,
    required this.apiClient,
    this.onChanged,
  });

  final AuthService authService;
  final ApiClient apiClient;
  final VoidCallback? onChanged;

  @override
  State<AccountButton> createState() => _AccountButtonState();
}

class _AccountButtonState extends State<AccountButton> {
  bool _busy = false;

  Future<void> _signIn() async {
    setState(() => _busy = true);
    try {
      final githubToken = await widget.authService.signInWithGithub();
      // アクセストークンはこの直後しか取れないので、すぐバックエンドへ預ける。
      if (githubToken != null) {
        await widget.apiClient.linkGithub(githubToken);
      }
      widget.onChanged?.call();
    } on AuthUnavailableException {
      _showMessage('ログイン機能はこの環境で有効化されていません。');
    } catch (_) {
      _showMessage('ログインに失敗しました。もう一度お試しください。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    await widget.authService.signOut();
    widget.onChanged?.call();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message, style: appBody(13, color: Colors.white))),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService.isAvailable) return const SizedBox.shrink();

    return ListenableBuilder(
      listenable: widget.authService,
      builder: (context, _) {
        if (_busy) {
          return const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: AppPalette.inkMuted),
          );
        }

        if (!widget.authService.isSignedIn) {
          return TextButton.icon(
            onPressed: _signIn,
            icon: const Icon(Icons.lock_open, size: 15, color: AppPalette.accent),
            label: Text(
              'GitHubでログイン',
              style: appMono(12.5, color: AppPalette.accent, weight: FontWeight.w700),
            ),
          );
        }

        final name = widget.authService.displayName ?? 'signed in';
        return PopupMenuButton<String>(
          tooltip: 'アカウント',
          onSelected: (value) {
            if (value == 'signout') _signOut();
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'signout',
              child: Text('ログアウト', style: appBody(13.5)),
            ),
          ],
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.person_outline, size: 16, color: AppPalette.inkMuted),
              const SizedBox(width: 6),
              Text(name, style: appMono(12.5, color: AppPalette.inkMuted, weight: FontWeight.w600)),
              const Icon(Icons.arrow_drop_down, size: 18, color: AppPalette.inkMuted),
            ],
          ),
        );
      },
    );
  }
}
