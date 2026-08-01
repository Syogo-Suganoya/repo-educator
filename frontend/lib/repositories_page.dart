import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api_client.dart';
import 'models/repository.dart';
import 'theme.dart';

/// GitHub App でアクセスを許可したリポジトリの一覧。
/// まだ1つも許可していないユーザーには、インストール導線だけを見せる。
class RepositoriesPage extends StatefulWidget {
  const RepositoriesPage({
    super.key,
    required this.apiClient,
    required this.onPick,
  });

  final ApiClient apiClient;
  final void Function(RepositorySummary) onPick;

  @override
  State<RepositoriesPage> createState() => _RepositoriesPageState();
}

class _RepositoriesPageState extends State<RepositoriesPage> {
  bool _loading = true;
  String? _errorMessage;
  List<RepositorySummary> _repositories = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    try {
      final repositories = await widget.apiClient.fetchRepositories();
      if (!mounted) return;
      setState(() => _repositories = repositories);
    } on QuizApiException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.toUserMessage());
    } catch (_) {
      if (!mounted) return;
      setState(() => _errorMessage = 'リポジトリ一覧を取得できませんでした。');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openInstallPage() async {
    try {
      final url = await widget.apiClient.fetchInstallUrl();
      await launchUrl(Uri.parse(url), webOnlyWindowName: '_blank');
    } on QuizApiException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.toUserMessage());
    } catch (_) {
      if (!mounted) return;
      setState(() => _errorMessage = 'インストールURLを取得できませんでした。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isNarrow = width < 720;

    return Scaffold(
      backgroundColor: AppPalette.bg,
      appBar: AppTopBar(onBack: () => Navigator.of(context).pop()),
      body: SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: isNarrow ? 20 : 48,
                vertical: isNarrow ? 24 : 40,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'あなたのリポジトリ',
                    style: appDisplay(isNarrow ? 24 : 30, weight: FontWeight.w800),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'GitHubで許可したリポジトリだけがここに並びます。'
                    'プライベートリポジトリも、選んだものだけを読み取ります。',
                    style: appBody(15, color: AppPalette.inkMuted, height: 1.8),
                  ),
                  const SizedBox(height: 20),
                  const _PrivacyNotice(),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: _openInstallPage,
                        icon: const Icon(Icons.add, size: 16),
                        label: Text(
                          'リポジトリを追加・変更',
                          style: appMono(12.5, weight: FontWeight.w700),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppPalette.accent,
                          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                          side: const BorderSide(color: AppPalette.line),
                        ),
                      ),
                      const SizedBox(width: 12),
                      TextButton.icon(
                        onPressed: _loading ? null : _load,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: Text('再読み込み', style: appMono(12.5)),
                        style: TextButton.styleFrom(foregroundColor: AppPalette.inkMuted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  if (_errorMessage != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      color: AppPalette.removeSoft,
                      child: Text(_errorMessage!, style: appMono(12.5, color: AppPalette.remove)),
                    ),
                    const SizedBox(height: 20),
                  ],
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 40),
                      child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  else if (_repositories.isEmpty)
                    const _EmptyState()
                  else
                    Wrap(
                      spacing: 20,
                      runSpacing: 20,
                      children: _repositories
                          .map((r) => _RepositoryCard(
                                repository: r,
                                width: isNarrow ? double.infinity : 280,
                                onPick: () => widget.onPick(r),
                              ))
                          .toList(),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// プライベートコードが外部のAIに送られることを、選択の前に明示する。
class _PrivacyNotice extends StatelessWidget {
  const _PrivacyNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      color: AppPalette.pendingSoft,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 16, color: AppPalette.pending),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'クイズ生成のため、選んだリポジトリのソースコードの一部が Google Cloud の '
              'Vertex AI に送信されます。業務のコードを扱う場合は、社内の取り扱い規程をご確認ください。',
              style: appBody(13, color: AppPalette.ink, height: 1.7),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
      decoration: BoxDecoration(border: Border.all(color: AppPalette.line)),
      child: Column(
        children: [
          Text(
            'まだ許可されたリポジトリがありません',
            style: appDisplay(15, weight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Text(
            '「リポジトリを追加・変更」から、学習したいリポジトリを選んでください。',
            style: appBody(13.5, color: AppPalette.inkMuted, height: 1.7),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _RepositoryCard extends StatelessWidget {
  const _RepositoryCard({
    required this.repository,
    required this.width,
    required this.onPick,
  });

  final RepositorySummary repository;
  final double width;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPick,
          child: DiffCard(
            filePath: repository.defaultBranch,
            meta: repository.private
                ? Text('private', style: appMono(11, color: AppPalette.pending, weight: FontWeight.w700))
                : Text('public', style: appMono(11, color: AppPalette.inkMuted)),
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(repository.fullName, style: appDisplay(14, weight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(
                  repository.description ?? '説明なし',
                  style: appBody(12.5, color: AppPalette.inkMuted, height: 1.6),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text(
                      'このPRを開く',
                      style: appMono(12, color: AppPalette.accent, weight: FontWeight.w700),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.arrow_forward, size: 14, color: AppPalette.accent),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
