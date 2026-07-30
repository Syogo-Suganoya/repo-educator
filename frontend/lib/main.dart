import 'package:flutter/material.dart';

import 'start_page.dart';
import 'theme.dart';

void main() {
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
