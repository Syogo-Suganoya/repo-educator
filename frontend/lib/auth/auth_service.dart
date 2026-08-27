import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const String _apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:8000',
);

const _tokenKey = 'access_token';
const _emailKey = 'account_email';
const _nameKey = 'account_name';

/// メールアドレス + パスワードによる自前認証のラッパ。
///
/// バックエンドが発行したJWTを `shared_preferences`（Webではlocalstorage）に
/// 保存し、ブラウザを閉じても再ログイン不要にする。
///
/// このアプリの認証は「任意」である。未ログインのまま公開リポジトリを学習できる
/// 体験を壊さないよう、未ログイン時は idToken() が null を返すだけで、
/// 例外を投げたり画面を止めたりはしない。
class AuthService extends ChangeNotifier {
  /// サーバ側でログイン機能が有効化されているか（未設定なら常にfalse想定でよいが、
  /// リクエストを投げてみて503が返るまでは判定できないため既定はtrue扱いにする）。
  static bool isAvailable = true;

  String? _token;
  String? _email;
  String? _name;
  bool _ready = false;

  bool get isReady => _ready;
  bool get isSignedIn => _token != null;
  String? get displayName => _name ?? _email;

  /// アプリ起動時に一度呼び、保存済みトークンを読み込む。
  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_tokenKey);
    _email = prefs.getString(_emailKey);
    _name = prefs.getString(_nameKey);
    _ready = true;
    notifyListeners();
  }

  Future<void> _persist({
    required String token,
    required String email,
    String? name,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
    await prefs.setString(_emailKey, email);
    if (name != null) {
      await prefs.setString(_nameKey, name);
    } else {
      await prefs.remove(_nameKey);
    }
  }

  Future<void> _handleAuthResponse(http.Response response) async {
    if (response.statusCode != 200) {
      String detail;
      try {
        detail = (jsonDecode(utf8.decode(response.bodyBytes))['detail'] ?? '')
            .toString();
      } catch (_) {
        detail = '';
      }
      throw AuthException(
        detail.isNotEmpty ? detail : '認証に失敗しました。',
        statusCode: response.statusCode,
      );
    }
    final body =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final token = body['access_token'] as String;
    final email = body['email'] as String;
    final name = body['name'] as String?;

    _token = token;
    _email = email;
    _name = name;
    await _persist(token: token, email: email, name: name);
    notifyListeners();
  }

  Future<void> register({
    required String email,
    required String password,
    String? displayName,
  }) async {
    final response = await http.post(
      Uri.parse('$_apiBaseUrl/api/v1/auth/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email,
        'password': password,
        'display_name': displayName,
      }),
    );
    await _handleAuthResponse(response);
  }

  Future<void> login({required String email, required String password}) async {
    final response = await http.post(
      Uri.parse('$_apiBaseUrl/api/v1/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password}),
    );
    await _handleAuthResponse(response);
  }

  Future<void> signOut() async {
    _token = null;
    _email = null;
    _name = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_emailKey);
    await prefs.remove(_nameKey);
    notifyListeners();
  }

  /// バックエンドへ送るJWT。未ログインなら null。
  Future<String?> idToken() async {
    return _token;
  }
}

/// register/login の失敗理由。UI側で文言に変換する。
class AuthException implements Exception {
  const AuthException(this.detail, {this.statusCode});

  final String detail;
  final int? statusCode;

  String toUserMessage() {
    if (statusCode == 409) return 'このメールアドレスは既に登録されています。';
    if (statusCode == 401) return 'メールアドレスまたはパスワードが正しくありません。';
    if (statusCode == 503) return 'ログイン機能はこの環境で有効化されていません。';
    return detail;
  }

  @override
  String toString() => detail;
}
