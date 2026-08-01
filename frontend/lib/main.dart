import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'auth/auth_service.dart';
import 'firebase_options.dart';
import 'start_page.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Firebaseの設定がない環境（未設定のローカル開発）でもアプリは起動させる。
  // 認証機能だけが無効になり、公開リポジトリの学習はそのまま使える。
  if (DefaultFirebaseOptions.isConfigured) {
    try {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
      AuthService.isAvailable = true;
    } catch (e) {
      debugPrint('Firebase initialization failed; running without authentication: $e');
    }
  }

  runApp(const RepoEducatorApp());
}

class RepoEducatorApp extends StatelessWidget {
  const RepoEducatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Repo Educator',
      theme: ThemeData(
        colorSchemeSeed: AppPalette.accent,
        scaffoldBackgroundColor: AppPalette.bg,
        useMaterial3: true,
      ),
      home: const StartPage(),
    );
  }
}
