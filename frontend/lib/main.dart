import 'package:flutter/material.dart';

import 'start_page.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RepoEducatorApp());
}

class RepoEducatorApp extends StatelessWidget {
  const RepoEducatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Repo Educator',
      // 右上のDEBUGリボンを出さない（デバッグビルドでも見た目を本番と揃える）。
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: AppPalette.accent,
        scaffoldBackgroundColor: AppPalette.bg,
        useMaterial3: true,
      ),
      home: const StartPage(),
    );
  }
}
