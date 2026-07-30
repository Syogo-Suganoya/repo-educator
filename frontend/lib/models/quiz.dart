class Quiz {
  final String quizId;
  final String filePath;
  final String scenario;
  final String questionText;
  final String codeSnippet;
  final List<String> choices;
  final String correctAnswer;
  final String explanation;

  Quiz({
    required this.quizId,
    required this.filePath,
    required this.scenario,
    required this.questionText,
    required this.codeSnippet,
    required this.choices,
    required this.correctAnswer,
    required this.explanation,
  });

  factory Quiz.fromJson(Map<String, dynamic> json) {
    return Quiz(
      quizId: json['quiz_id'] as String,
      filePath: json['file_path'] as String,
      scenario: json['scenario'] as String,
      questionText: json['question_text'] as String,
      codeSnippet: json['code_snippet'] as String,
      choices: List<String>.from(json['choices'] as List),
      correctAnswer: json['correct_answer'] as String,
      explanation: json['explanation'] as String,
    );
  }
}

/// 実務上意味のある単位でクイズをまとめた「機能セクション」。
/// 例: 認証、ルーティング、ソートアルゴリズムなど。ユーザーはこの単位で
/// ピンポイントに学習するセクションを選ぶ。
class FeatureSection {
  final String sectionId;
  final String title;
  final String description;
  final List<Quiz> quizzes;

  FeatureSection({
    required this.sectionId,
    required this.title,
    required this.description,
    required this.quizzes,
  });

  factory FeatureSection.fromJson(Map<String, dynamic> json) {
    return FeatureSection(
      sectionId: json['section_id'] as String,
      title: json['title'] as String,
      description: json['description'] as String,
      quizzes: (json['quizzes'] as List)
          .map((q) => Quiz.fromJson(q as Map<String, dynamic>))
          .toList(),
    );
  }
}

class QuizGenerateResponse {
  final String repositoryId;
  final String url;
  final List<FeatureSection> sections;

  QuizGenerateResponse({
    required this.repositoryId,
    required this.url,
    required this.sections,
  });

  factory QuizGenerateResponse.fromJson(Map<String, dynamic> json) {
    return QuizGenerateResponse(
      repositoryId: json['repository_id'] as String,
      url: json['url'] as String,
      sections: (json['sections'] as List)
          .map((s) => FeatureSection.fromJson(s as Map<String, dynamic>))
          .toList(),
    );
  }
}
