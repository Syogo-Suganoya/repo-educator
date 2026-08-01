import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth/auth_service.dart';
import 'models/quiz.dart';
import 'models/repository.dart';

const String _apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:8000',
);

class ApiClient {
  ApiClient({AuthService? authService}) : _authService = authService;

  final AuthService? _authService;

  /// 認証ヘッダは「取れたときだけ」付ける。
  /// 未ログインでの公開リポジトリ利用を維持するため、取れなくてもリクエストは送る。
  Future<Map<String, String>> _headers({bool json = true}) async {
    final headers = <String, String>{};
    if (json) headers['Content-Type'] = 'application/json';
    final token = await _authService?.idToken();
    if (token != null) headers['Authorization'] = 'Bearer $token';
    return headers;
  }

  Never _throwFrom(http.Response response) {
    String detail;
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      detail = body['detail']?.toString() ?? 'リクエストに失敗しました';
    } catch (_) {
      detail = 'リクエストに失敗しました';
    }
    throw QuizApiException(detail, statusCode: response.statusCode);
  }

  Future<QuizGenerateResponse> generateQuiz({
    required String repositoryUrl,
    String branch = 'main',
    int numQuestions = 5,
  }) async {
    final response = await http.post(
      Uri.parse('$_apiBaseUrl/api/v1/quiz/generate'),
      headers: await _headers(),
      body: jsonEncode({
        'repository_url': repositoryUrl,
        'branch': branch,
        'num_questions': numQuestions,
      }),
    );

    if (response.statusCode != 200) _throwFrom(response);

    return QuizGenerateResponse.fromJson(
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
    );
  }

  /// サインイン直後に一度だけ取得できるGitHubアクセストークンをバックエンドへ渡す。
  Future<AccountInfo> linkGithub(String githubAccessToken) async {
    final response = await http.post(
      Uri.parse('$_apiBaseUrl/api/v1/github/link'),
      headers: await _headers(),
      body: jsonEncode({'github_access_token': githubAccessToken}),
    );
    if (response.statusCode != 200) _throwFrom(response);
    final body = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    return AccountInfo(
      githubLogin: body['github_login'] as String?,
      installationCount: body['installation_count'] as int? ?? 0,
    );
  }

  Future<AccountInfo> fetchMe() async {
    final response = await http.get(
      Uri.parse('$_apiBaseUrl/api/v1/me'),
      headers: await _headers(json: false),
    );
    if (response.statusCode != 200) _throwFrom(response);
    final body = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    return AccountInfo(
      githubLogin: body['github_login'] as String?,
      installationCount: body['installation_count'] as int? ?? 0,
      githubAppAvailable: body['github_app_available'] as bool? ?? false,
    );
  }

  Future<String> fetchInstallUrl() async {
    final response = await http.get(
      Uri.parse('$_apiBaseUrl/api/v1/github/install-url'),
      headers: await _headers(json: false),
    );
    if (response.statusCode != 200) _throwFrom(response);
    final body = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    return body['install_url'] as String;
  }

  Future<List<RepositorySummary>> fetchRepositories() async {
    final response = await http.get(
      Uri.parse('$_apiBaseUrl/api/v1/repositories'),
      headers: await _headers(json: false),
    );
    if (response.statusCode != 200) _throwFrom(response);
    final body = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    return (body['repositories'] as List)
        .map((r) => RepositorySummary.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  /// 学習履歴の記録。未ログインなら送らずに黙って終える（学習の妨げにしない）。
  Future<void> recordAnswer({
    required String repositoryId,
    required String quizId,
    required bool correct,
  }) async {
    final token = await _authService?.idToken();
    if (token == null) return;

    try {
      await http.post(
        Uri.parse('$_apiBaseUrl/api/v1/progress/answer'),
        headers: await _headers(),
        body: jsonEncode({
          'repository_id': repositoryId,
          'quiz_id': quizId,
          'correct': correct,
        }),
      );
    } catch (_) {
      // 履歴の記録に失敗しても学習は続けられるべきなので握りつぶす。
    }
  }
}

/// バックエンドAPIから返る失敗理由。UI側で人が読める文言に変換して表示する。
class QuizApiException implements Exception {
  const QuizApiException(this.detail, {this.statusCode});

  final String detail;
  final int? statusCode;

  /// レビュー担当者（＝利用者）が次に何をすればよいか分かる短い日本語メッセージに変換する。
  String toUserMessage() {
    if (statusCode == 429) {
      // 権限不足と混同されないよう、レートリミットは明確に区別して伝える。
      final match = RegExp(r'(\d+) minute').firstMatch(detail);
      final wait = match != null ? '約${match.group(1)}分後' : 'しばらく経ってから';
      return 'GitHubへのリクエスト上限に達しました。$wait再度お試しください。';
    }
    if (statusCode == 403) {
      return 'このリポジトリを読む権限がありません。プライベートリポジトリの場合は、'
          'GitHubでログインしたうえでリポジトリへのアクセスを許可してください。';
    }
    if (statusCode == 401) {
      return 'ログインの有効期限が切れています。もう一度ログインしてください。';
    }
    if (statusCode == 503) {
      return 'この機能はサーバー側で有効化されていません。';
    }
    if (detail.contains('not found')) {
      return 'リポジトリまたはブランチが見つかりません。URLとブランチ名を確認してください。';
    }
    if (detail.contains('Invalid GitHub repository URL')) {
      return 'GitHubのリポジトリURLの形式が正しくありません。';
    }
    return detail;
  }

  @override
  String toString() => detail;
}
