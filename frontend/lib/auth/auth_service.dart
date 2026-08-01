import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Firebase Authentication（GitHubプロバイダ）のラッパ。
///
/// このアプリの認証は「任意」である。未ログインのまま公開リポジトリを学習できる
/// 体験を壊さないよう、未ログイン時は idToken() が null を返すだけで、
/// 例外を投げたり画面を止めたりはしない。
class AuthService extends ChangeNotifier {
  AuthService() {
    if (isAvailable) {
      _sub = FirebaseAuth.instance.authStateChanges().listen((user) {
        _user = user;
        notifyListeners();
      });
      _user = FirebaseAuth.instance.currentUser;
    }
  }

  /// Firebase が初期化できていない環境（設定なしのローカル開発）でも
  /// アプリ全体が落ちないようにするためのフラグ。
  static bool isAvailable = false;

  User? _user;
  Object? _sub;

  User? get user => _user;
  bool get isSignedIn => _user != null;
  String? get displayName => _user?.displayName ?? _user?.email;
  String? get photoUrl => _user?.photoURL;

  /// GitHubでサインインし、GitHubユーザートークンを返す。
  ///
  /// このアクセストークンは **サインイン直後のこの1回しか取得できない**
  /// （Firebaseは保持しない）。呼び出し側は取りこぼさずバックエンドの
  /// /api/v1/github/link に渡すこと。
  Future<String?> signInWithGithub() async {
    if (!isAvailable) {
      throw AuthUnavailableException();
    }
    final provider = GithubAuthProvider();
    final credential = await FirebaseAuth.instance.signInWithPopup(provider);
    return credential.credential?.accessToken;
  }

  Future<void> signOut() async {
    if (!isAvailable) return;
    await FirebaseAuth.instance.signOut();
  }

  /// バックエンドへ送る Firebase ID トークン。未ログインなら null。
  Future<String?> idToken() async {
    if (!isAvailable) return null;
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) return null;
    try {
      return await current.getIdToken();
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    (_sub as dynamic)?.cancel();
    super.dispose();
  }
}

class AuthUnavailableException implements Exception {
  @override
  String toString() => 'Firebase Authentication is not configured';
}
