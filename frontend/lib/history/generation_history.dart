import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api_client.dart';
import '../auth/auth_service.dart';

/// 一度生成したクイズを、あとから開き直すための1件分。
///
/// クイズの中身は持たない。開き直すときは通常の生成APIを呼ぶ
/// （同じコミットならサーバー側のキャッシュに当たるため待ち時間はほぼない）。
class GenerationHistoryEntry {
  const GenerationHistoryEntry({
    required this.repositoryUrl,
    required this.branch,
    this.sectionCount = 0,
    this.quizCount = 0,
    this.lastOpened,
  });

  final String repositoryUrl;
  final String branch;
  final int sectionCount;
  final int quizCount;
  final DateTime? lastOpened;

  /// 同じリポジトリ・同じブランチなら同一の履歴として扱う。
  String get key => '$repositoryUrl@$branch';

  /// `owner/repo` の形に縮めて表示に使う。
  String get label {
    final match = RegExp(
      r'github\.com/([^/]+/[^/?#]+)',
    ).firstMatch(repositoryUrl);
    return match?.group(1)?.replaceAll(RegExp(r'\.git$'), '') ?? repositoryUrl;
  }

  Map<String, dynamic> toJson() => {
    'repository_url': repositoryUrl,
    'branch': branch,
    'section_count': sectionCount,
    'quiz_count': quizCount,
    'last_opened': lastOpened?.toIso8601String(),
  };

  static GenerationHistoryEntry fromJson(Map<String, dynamic> json) {
    final raw = json['last_opened'] as String?;
    return GenerationHistoryEntry(
      repositoryUrl: json['repository_url'] as String? ?? '',
      branch: json['branch'] as String? ?? 'main',
      sectionCount: json['section_count'] as int? ?? 0,
      quizCount: json['quiz_count'] as int? ?? 0,
      lastOpened: raw == null ? null : DateTime.tryParse(raw),
    );
  }
}

/// 生成したクイズの履歴。保存先はログイン状態で変わる。
///
/// - ログイン中 … サーバー（DB）。端末やブラウザをまたいで残る
/// - 未ログイン … このブラウザの localStorage。同じブラウザでだけ残る
///
/// 未ログイン分をサーバーに置かないのは、誰のものか特定できない履歴が
/// 溜まり続けるのを避けるため。ログインの利点を素直に説明できる形でもある。
class GenerationHistoryStore extends ChangeNotifier {
  GenerationHistoryStore({required this.apiClient, required this.authService});

  final ApiClient apiClient;
  final AuthService authService;

  static const _storageKey = 'generation_history';

  /// 保存件数の上限。古いものから捨てる。
  static const _maxEntries = 30;

  List<GenerationHistoryEntry> _entries = const [];
  bool _loaded = false;

  List<GenerationHistoryEntry> get entries => _entries;
  bool get isLoaded => _loaded;

  /// 現在のログイン状態に応じた保存先から読み直す。
  Future<void> load() async {
    if (authService.isSignedIn) {
      try {
        _entries = await apiClient.fetchHistory();
      } catch (_) {
        // 履歴が取れなくても学習は始められるべきなので、空として扱う。
        _entries = const [];
      }
    } else {
      _entries = await _loadLocal();
    }
    _loaded = true;
    notifyListeners();
  }

  /// 生成に成功したときに呼ぶ。
  /// ログイン中はサーバー側が記録するため、ここではローカルだけを更新する。
  Future<void> record(GenerationHistoryEntry entry) async {
    if (!authService.isSignedIn) {
      final local = await _loadLocal();
      local.removeWhere((e) => e.key == entry.key);
      local.insert(0, entry);
      await _saveLocal(local.take(_maxEntries).toList());
    }
    await load();
  }

  Future<void> remove(GenerationHistoryEntry entry) async {
    if (authService.isSignedIn) {
      try {
        await apiClient.deleteHistory(
          repositoryUrl: entry.repositoryUrl,
          branch: entry.branch,
        );
      } catch (_) {
        // 消せなかった場合は一覧を読み直せば元に戻る。黙って進める。
      }
    } else {
      final local = await _loadLocal();
      local.removeWhere((e) => e.key == entry.key);
      await _saveLocal(local);
    }
    await load();
  }

  Future<List<GenerationHistoryEntry>> _loadLocal() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw) as List;
      return decoded
          .map(
            (e) => GenerationHistoryEntry.fromJson(e as Map<String, dynamic>),
          )
          .where((e) => e.repositoryUrl.isNotEmpty)
          .toList();
    } catch (_) {
      // 壊れた保存内容で画面が開けなくなるより、履歴を失う方がまし。
      return [];
    }
  }

  Future<void> _saveLocal(List<GenerationHistoryEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _storageKey,
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
  }
}
