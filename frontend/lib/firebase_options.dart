import 'package:firebase_core/firebase_core.dart';

/// Firebase の接続設定。
///
/// `flutterfire configure` の生成物を置く代わりに、既存の `API_BASE_URL` と同じく
/// `--dart-define` から読む方式にしている。設定を渡さずにビルドしても
/// アプリは起動し、認証機能だけが無効になる（公開リポジトリの学習は使える）。
///
/// 例:
/// ```
/// flutter run -d chrome \
///   --dart-define=API_BASE_URL=http://localhost:8000 \
///   --dart-define=FIREBASE_API_KEY=... \
///   --dart-define=FIREBASE_APP_ID=... \
///   --dart-define=FIREBASE_PROJECT_ID=... \
///   --dart-define=FIREBASE_MESSAGING_SENDER_ID=... \
///   --dart-define=FIREBASE_AUTH_DOMAIN=...
/// ```
class DefaultFirebaseOptions {
  static const String _apiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const String _appId = String.fromEnvironment('FIREBASE_APP_ID');
  static const String _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const String _messagingSenderId =
      String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
  static const String _authDomain = String.fromEnvironment('FIREBASE_AUTH_DOMAIN');
  static const String _storageBucket = String.fromEnvironment('FIREBASE_STORAGE_BUCKET');

  /// 必須項目が揃っているときだけ Firebase を初期化する。
  static bool get isConfigured =>
      _apiKey.isNotEmpty && _appId.isNotEmpty && _projectId.isNotEmpty;

  static FirebaseOptions get currentPlatform => FirebaseOptions(
        apiKey: _apiKey,
        appId: _appId,
        projectId: _projectId,
        messagingSenderId: _messagingSenderId,
        authDomain: _authDomain.isNotEmpty ? _authDomain : '$_projectId.firebaseapp.com',
        storageBucket: _storageBucket.isNotEmpty ? _storageBucket : '$_projectId.appspot.com',
      );
}
