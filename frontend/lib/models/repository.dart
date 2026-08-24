/// 保存済みのPersonal Access Tokenでアクセスできるリポジトリ1件。
class RepositorySummary {
  final String fullName;
  final String htmlUrl;
  final String defaultBranch;
  final bool private;
  final String? description;
  final String? language;

  RepositorySummary({
    required this.fullName,
    required this.htmlUrl,
    required this.defaultBranch,
    required this.private,
    this.description,
    this.language,
  });

  factory RepositorySummary.fromJson(Map<String, dynamic> json) {
    return RepositorySummary(
      fullName: json['full_name'] as String,
      htmlUrl: json['html_url'] as String,
      defaultBranch: json['default_branch'] as String? ?? 'main',
      private: json['private'] as bool? ?? false,
      description: json['description'] as String?,
      language: json['language'] as String?,
    );
  }
}

/// ログイン中のアカウントとGitHubトークンの状態。
class AccountInfo {
  final String? githubLogin;
  final bool hasGithubToken;

  const AccountInfo({
    this.githubLogin,
    this.hasGithubToken = false,
  });
}
