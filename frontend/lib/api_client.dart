import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models/quiz.dart';

const String _apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:8000',
);

class ApiClient {
  Future<QuizGenerateResponse> generateQuiz({
    required String repositoryUrl,
    String branch = 'main',
    int numQuestions = 5,
  }) async {
    final response = await http.post(
      Uri.parse('$_apiBaseUrl/api/v1/quiz/generate'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'repository_url': repositoryUrl,
        'branch': branch,
        'num_questions': numQuestions,
      }),
    );

    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw QuizApiException(body['detail']?.toString() ?? 'クイズの生成に失敗しました');
    }

    return QuizGenerateResponse.fromJson(
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
    );
  }
}

/// バックエンドAPIから返る失敗理由。UI側で人が読める文言に変換して表示する。
class QuizApiException implements Exception {
  const QuizApiException(this.detail);

  final String detail;

  /// レビュー担当者（＝利用者）が次に何をすればよいか分かる短い日本語メッセージに変換する。
  String toUserMessage() {
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
