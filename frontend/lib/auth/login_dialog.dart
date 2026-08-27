import 'package:flutter/material.dart';

import '../theme.dart';
import 'auth_service.dart';

/// メールアドレス + パスワードでのログイン・新規登録ダイアログ。
///
/// 1つのダイアログで「ログイン」「新規登録」を切り替える。
/// 本人確認はこのアプリ内で完結する。
class LoginDialog extends StatefulWidget {
  const LoginDialog({super.key, required this.authService});

  final AuthService authService;

  static Future<bool?> show(BuildContext context, {required AuthService authService}) {
    return showDialog<bool>(
      context: context,
      builder: (_) => LoginDialog(authService: authService),
    );
  }

  @override
  State<LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<LoginDialog> {
  bool _isRegister = false;
  bool _busy = false;
  String? _errorMessage;

  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() => _errorMessage = 'メールアドレスとパスワードを入力してください。');
      return;
    }
    if (_isRegister && password.length < 8) {
      setState(() => _errorMessage = 'パスワードは8文字以上にしてください。');
      return;
    }

    setState(() {
      _busy = true;
      _errorMessage = null;
    });
    try {
      if (_isRegister) {
        final name = _nameController.text.trim();
        await widget.authService.register(
          email: email,
          password: password,
          displayName: name.isEmpty ? null : name,
        );
      } else {
        await widget.authService.login(email: email, password: password);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on AuthException catch (e) {
      setState(() => _errorMessage = e.toUserMessage());
    } catch (_) {
      setState(() => _errorMessage = 'サーバーに接続できませんでした。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _isRegister ? '新規登録' : 'ログイン',
                style: appDisplay(18, weight: FontWeight.w800),
              ),
              const SizedBox(height: 20),
              if (_isRegister) ...[
                _Field(label: '表示名（任意）', controller: _nameController),
                const SizedBox(height: 12),
              ],
              _Field(label: 'メールアドレス', controller: _emailController, hint: 'you@example.com'),
              const SizedBox(height: 12),
              _Field(label: 'パスワード', controller: _passwordController, obscure: true),
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
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _busy ? null : _submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppPalette.accent,
                    foregroundColor: Colors.white,
                    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : Text(
                          _isRegister ? '登録する' : 'ログイン',
                          style: appDisplay(14, color: Colors.white, weight: FontWeight.w700),
                        ),
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                            _isRegister = !_isRegister;
                            _errorMessage = null;
                          }),
                  child: Text(
                    _isRegister ? 'すでにアカウントをお持ちの方はこちら' : 'アカウントをお持ちでない方はこちら',
                    style: appMono(12, color: AppPalette.inkMuted),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.controller, this.hint, this.obscure = false});

  final String label;
  final TextEditingController controller;
  final String? hint;
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: appMono(11.5, color: AppPalette.inkMuted, weight: FontWeight.w600)),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          obscureText: obscure,
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
