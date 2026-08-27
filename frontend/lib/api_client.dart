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

  /// アプリのセッション（JWT）が無効になったことを示すサーバーの応答。
  /// GitHubトークンが無効な場合も401だが、そちらは別の文言で返る。
  static const _invalidSessionDetails = {
    'Invalid authentication token',
    'Authentication required',
  };

  Never _throwFrom(http.Response response) {
    String detail;
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      detail = body['detail']?.toString() ?? 'リクエストに失敗しました';
    } catch (_) {
      detail = 'リクエストに失敗しました';
    }

    // 期限切れなどでセッションが無効になったら、こちらの状態も合わせる。
    // そうしないと「ログイン済みに見えるのに何をしても401」という行き止まりになる。
    if (response.statusCode == 401 && _invalidSessionDetails.contains(detail)) {
      _authService?.signOut();
      throw const QuizApiException(
        'ログインの有効期限が切れました。もう一度ログインしてください。',
        statusCode: 401,
      );
    }

    throw QuizApiException(detail, statusCode: response.statusCode);
  }

  Future<QuizGenerateResponse> generateQuiz({
    required String repositoryUrl,
    String branch = 'main',
    int numQuestions = 5,

    /// 出題の観点を自由文で指定する（例:「認証まわりだけ出して」）。
    /// 指定するとキャッシュを使わず、その観点で生成し直される。
    String? focus,
  }) async {
    final response = await http.post(
      Uri.parse('$_apiBaseUrl/api/v1/quiz/generate'),
      headers: await _headers(),
      body: jsonEncode({
        'repository_url': repositoryUrl,
        'branch': branch,
        'num_questions': numQuestions,
        if (focus != null && focus.trim().isNotEmpty) 'focus': focus.trim(),
      }),
    );

    if (response.statusCode != 200) _throwFrom(response);

    return QuizGenerateResponse.fromJson(
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
    );
  }

  /// リポジトリについての質問に答えてもらう。
  /// 質問は毎回異なるためキャッシュされず、都度AIの呼び出しが走る。
  Future<DocAnswer> askAboutRepository({
    required String repositoryUrl,
    String branch = 'main',
    required String question,
  }) async {
    final response = await http.post(
      Uri.parse('$_apiBaseUrl/api/v1/docs/ask'),
      headers: await _headers(),
      body: jsonEncode({
        'repository_url': repositoryUrl,
        'branch': branch,
        'question': question.trim(),
      }),
    );

    if (response.statusCode != 200) _throwFrom(response);

    final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    return DocAnswer(
      answer: json['answer'] as String? ?? '',
      filePaths: (json['file_paths'] as List?)?.cast<String>() ?? const [],
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
      hasGithubToken: body['has_github_token'] as bool? ?? false,
    );
  }

  /// 設定画面で入力されたPersonal Access Tokenを保存する。
  /// サーバー側でトークンの有効性を確認したうえで暗号化保存するため、失敗しうる。
  Future<AccountInfo> saveGithubToken(String token) async {
    final response = await http.put(
      Uri.parse('$_apiBaseUrl/api/v1/github/token'),
      headers: await _headers(),
      body: jsonEncode({'token': token}),
    );
    if (response.statusCode != 200) _throwFrom(response);
    final body = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    return AccountInfo(
      githubLogin: body['github_login'] as String?,
      hasGithubToken: body['has_github_token'] as bool? ?? false,
    );
  }

  Future<void> clearGithubToken() async {
    final response = await http.delete(
      Uri.parse('$_apiBaseUrl/api/v1/github/token'),
      headers: await _headers(json: false),
    );
    if (response.statusCode != 200) _throwFrom(response);
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
    // サーバーが日本語の案内を返した場合は、それが最も具体的なのでそのまま見せる。
    // 同じ429でもGitHubのレートリミットとAIの利用枠超過では対処が違い、
    // ステータスコードだけで文面を決めると誤った案内になる。
    if (RegExp(r'[ぁ-んァ-ン一-龯]').hasMatch(detail)) return detail;

    if (statusCode == 429) {
      // 権限不足と混同されないよう、レートリミットは明確に区別して伝える。
      final match = RegExp(r'(\d+) minute').firstMatch(detail);
      final wait = match != null ? '約${match.group(1)}分後' : 'しばらく経ってから';
      return 'GitHubへのリクエスト上限に達しました。$wait再度お試しください。';
    }
    if (statusCode == 403) {
      return 'このリポジトリを読む権限がありません。プライベートリポジトリの場合は、'
          'アカウント設定でGitHubのPersonal Access Tokenを保存してください。';
    }
    if (statusCode == 401) {
      return '保存されているGitHubトークンが無効か期限切れです。設定画面で入力し直してください。';
    }
    if (statusCode == 503) {
      return 'この機能はサーバー側で有効化されていません。';
    }
    if (detail.contains('No GitHub token is saved')) {
      return 'GitHubトークンが未設定です。アカウント設定から入力してください。';
    }
    // 以下2つは detail に 'not found' を含むため、汎用の判定より先に見る。
    if (detail.contains('does not grant access')) {
      return 'このリポジトリが見つかりません。URLが正しい場合は、GitHubトークンの'
          '対象リポジトリにこのリポジトリが含まれているか確認してください'
          '（Fine-grained tokenの Repository access の設定）。';
    }
    if (detail.startsWith('Branch ')) {
      final match = RegExp(r"Branch '([^']+)'").firstMatch(detail);
      final name = match?.group(1);
      return name == null
          ? '指定したブランチが見つかりません。ブランチ名を確認してください。'
          : 'ブランチ「$name」が見つかりません。ブランチ名を確認してください。';
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

/// 質問への回答と、その根拠になったファイル。
class DocAnswer {
  const DocAnswer({required this.answer, required this.filePaths});

  final String answer;
  final List<String> filePaths;
}
