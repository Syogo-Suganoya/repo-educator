import 'package:flutter/material.dart';

import '../theme.dart';

/// GitHubのFine-grained PAT発行ページ。
/// 画面の項目名はこのページのものに合わせてある。
const _patSettingsUrl = 'https://github.com/settings/personal-access-tokens';

/// 取得手順の1ステップ。番号と本文を左右に並べ、手順として読ませる。
class _PatStep extends StatelessWidget {
  const _PatStep({
    required this.number,
    required this.body,
    this.link,
    this.linkLabel,
    this.isLast = false,
  });

  final String number;
  final String body;
  final String? link;
  final String? linkLabel;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            margin: const EdgeInsets.only(top: 2, right: 10),
            color: AppPalette.accentSoft,
            child: Text(
              number,
              style: appMono(
                12,
                color: AppPalette.accent,
                weight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText(
                  body,
                  style: appBody(14, color: AppPalette.ink, height: 1.9),
                ),
                if (link != null) ...[
                  const SizedBox(height: 5),
                  AppLink(
                    label: linkLabel ?? link!,
                    url: link!,
                    style: appMono(13, weight: FontWeight.w700),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 未ログイン時に表示する、プライベートリポジトリ対応のアピールと
/// Personal Access Token の取得手順の案内。

/// PATの取得手順。トークン入力画面と起点画面の両方から開く。
///
/// 手順は初回にしか要らない情報なので、常時表示せずモーダルにしている。
/// 内容をここ1箇所に置くことで、参照元が増えても文言が分岐しない。
class PatGuideDialog extends StatelessWidget {
  const PatGuideDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => const PatGuideDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 700),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
              child: Text(
                'PATの取得手順',
                style: appDisplay(20, weight: FontWeight.w800),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _PatStep(
                      number: '1',
                      body:
                          'GitHubのトークン発行ページを開きます（Settings → Developer settings → '
                          'Personal access tokens → Fine-grained tokens でも同じ画面に行けます）。',
                      link: _patSettingsUrl,
                      linkLabel: 'github.com/settings/personal-access-tokens',
                    ),
                    const _PatStep(
                      number: '2',
                      body:
                          '「Generate new token」を押し、Token name（任意の名前）と Expiration（有効期限）を決めます。'
                          '期限は短いほど安全です。切れたら再発行して入れ直してください。',
                    ),
                    const _PatStep(
                      number: '3',
                      body:
                          'Repository access で「Only select repositories」を選び、学習したいリポジトリだけを指定します。'
                          '「All repositories」は必要以上に広い許可になるため避けてください。',
                    ),
                    const _PatStep(
                      number: '4',
                      body:
                          'Repository permissions で `Contents` を `Read-only` にします。必要な権限はこれだけです。'
                          '`Metadata`（Read-only）は必須項目として自動で有効になります。',
                    ),
                    const _PatStep(
                      number: '5',
                      body:
                          '「Generate token」を押し、表示されたトークンをコピーします。'
                          'この画面を離れると二度と表示されないので、その場で次の手順へ進んでください。',
                    ),
                    const _PatStep(
                      number: '6',
                      body:
                          '右上のアカウントメニュー →「GitHubトークン」に貼り付けて保存します。'
                          'サーバーには暗号化して保存され、ログアウトしても残ります。',
                      isLast: true,
                    ),
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      color: AppPalette.surfaceSunken,
                      child: AppText(
                        'なぜ `Contents` だけでよいのか: このアプリはリポジトリの情報取得・コミットの確認・'
                        'ソースコードの読み取りしか行いません。書き込み権限（Read and write）や、'
                        'Issues・Pull requests などの他の権限は一切不要です。',
                        style: appBody(
                          13.5,
                          color: AppPalette.inkMuted,
                          height: 1.9,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(
                    '閉じる',
                    style: appMono(12.5, color: AppPalette.inkMuted),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
