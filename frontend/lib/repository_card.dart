import 'package:flutter/material.dart';

import 'models/repository.dart';
import 'theme.dart';

/// プライベートコードが外部のAIに送られることを、選択の前に明示する。
class PrivacyNotice extends StatelessWidget {
  const PrivacyNotice({super.key});

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
              'クイズ生成のため、選んだリポジトリのソースコードの一部が Google の '
              'Gemini に送信されます。業務のコードを扱う場合は、社内の取り扱い規程をご確認ください。',
              style: appBody(13, color: AppPalette.ink, height: 1.7),
            ),
          ),
        ],
      ),
    );
  }
}

/// リポジトリ1件のカード。リポジトリ一覧とプロフィールの両方から使う。
class RepositoryCard extends StatelessWidget {
  const RepositoryCard({
    super.key,
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
            // 一覧はプライベートのみなので、バッジで種別を出し分ける必要はない。
            meta: Text(
              'private',
              style: appMono(
                11,
                color: AppPalette.pending,
                weight: FontWeight.w700,
              ),
            ),
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  repository.fullName,
                  style: appDisplay(14, weight: FontWeight.w700),
                ),
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
                      'クイズを見る',
                      style: appMono(
                        12,
                        color: AppPalette.accent,
                        weight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.arrow_forward,
                      size: 14,
                      color: AppPalette.accent,
                    ),
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
