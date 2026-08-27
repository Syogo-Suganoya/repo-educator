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

  /// 登録済みトークンの本数。Fine-grained PAT は対象リポジトリを絞るため複数登録できる。
  final int githubTokenCount;

  const AccountInfo({
    this.githubLogin,
    this.hasGithubToken = false,
    this.githubTokenCount = 0,
  });
}

/// 登録済みトークン1件。値そのものはサーバーから返らない。
class GithubTokenSummary {
  const GithubTokenSummary({
    required this.id,
    this.label,
    this.githubLogin,
    this.createdAt,
  });

  final int id;

  /// GitHub側で付けたトークン名を、本人が転記したもの。
  /// GitHubのAPIからは取得できないので、登録時に入力してもらう。
  final String? label;
  final String? githubLogin;
  final DateTime? createdAt;

  /// 一覧に出す名前。トークン名があればそれを、無ければアカウント名を使う。
  String get displayName => label ?? githubLogin ?? '登録済み';

  factory GithubTokenSummary.fromJson(Map<String, dynamic> json) {
    final raw = json['created_at'] as String?;
    return GithubTokenSummary(
      id: json['id'] as int,
      label: json['label'] as String?,
      githubLogin: json['github_login'] as String?,
      createdAt: raw == null ? null : DateTime.tryParse(raw),
    );
  }
}
