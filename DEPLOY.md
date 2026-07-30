# リリース・デプロイ手順

本番環境は設計書（[README.md](README.md)）の通り、バックエンドを **Cloud Run**、フロントエンドを **Firebase Hosting** にデプロイする構成を想定している。

各手順には **CLI（コマンド）** と **コンソール（画面操作）** の両方を記載する。どちらか一方で実施すればよい。

## 前提条件

- `gcloud` CLI がインストール・認証済みであること（`gcloud auth login`）
- `firebase` CLI がインストール済みであること（フロントエンドのデプロイに使用）
- GCPプロジェクトが作成済みで、以下のAPIが有効化されていること
  - Cloud Run API (`run.googleapis.com`)
  - Vertex AI API (`aiplatform.googleapis.com`)
  - Artifact Registry API (`artifactregistry.googleapis.com`)
  - Secret Manager API (`secretmanager.googleapis.com`)

### CLI

```bash
gcloud config set project <YOUR_PROJECT_ID>
gcloud services enable run.googleapis.com aiplatform.googleapis.com \
  artifactregistry.googleapis.com secretmanager.googleapis.com
```

### コンソール（画面操作）

1. [Google Cloud Console](https://console.cloud.google.com/) を開き、画面上部のプロジェクトセレクタで対象プロジェクトを選択（未作成なら「新しいプロジェクト」から作成）
2. 左上のナビゲーションメニュー ≡ →「APIとサービス」→「ライブラリ」を開く
3. 検索ボックスで以下を1つずつ検索し、それぞれのページで「有効にする」をクリック
   - Cloud Run Admin API
   - Vertex AI API
   - Artifact Registry API
   - Secret Manager API

## 1. シークレットの登録（初回のみ）

GitHub Personal Access Token を Secret Manager に登録する。

### CLI

```bash
echo -n "<YOUR_GITHUB_TOKEN>" | gcloud secrets create github-token --data-file=-
```

### コンソール（画面操作）

1. ナビゲーションメニュー ≡ →「セキュリティ」→「Secret Manager」を開く
2. 「シークレットを作成」をクリック
3. 以下を入力して「シークレットを作成」
   - 名前: `github-token`
   - シークレットの値: GitHubのPersonal Access Tokenを貼り付け
   - その他の設定は既定のままでよい

## 2. サービスアカウントの設定（初回のみ）

Cloud Run 用のサービスアカウントを作成し、最小権限を付与する（README 6.3 参照）。

### CLI

```bash
gcloud iam service-accounts create repo-educator-backend

PROJECT_ID=$(gcloud config get-value project)
SA="repo-educator-backend@${PROJECT_ID}.iam.gserviceaccount.com"

# Vertex AI の利用権限
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA}" --role="roles/aiplatform.user"

# Secret Manager からの読み取り権限
gcloud secrets add-iam-policy-binding github-token \
  --member="serviceAccount:${SA}" --role="roles/secretmanager.secretAccessor"
```

### コンソール（画面操作）

**サービスアカウントの作成:**

1. ナビゲーションメニュー ≡ →「IAMと管理」→「サービスアカウント」を開く
2. 「サービスアカウントを作成」をクリック
3. サービスアカウント名に `repo-educator-backend` を入力し「作成して続行」
4. 「ロールを選択」で `Vertex AI ユーザー`（`roles/aiplatform.user`）を選択し「完了」

**シークレットへのアクセス権付与:**

1. 「セキュリティ」→「Secret Manager」で `github-token` をクリック
2. 「権限」タブ →「アクセスを許可」をクリック
3. 新しいプリンシパルに `repo-educator-backend@<PROJECT_ID>.iam.gserviceaccount.com` を入力
4. ロールに `Secret Manager のシークレット アクセサー` を選択して「保存」

> Firestore を導入した場合は `Cloud Datastore ユーザー`（`roles/datastore.user`）ロールも追加する。

## 3. バックエンドのデプロイ（Cloud Run）

`backend/Dockerfile` をそのまま利用してソースからデプロイする。

### CLI

```bash
cd backend

gcloud run deploy repo-educator-api \
  --source . \
  --region asia-northeast1 \
  --service-account "repo-educator-backend@${PROJECT_ID}.iam.gserviceaccount.com" \
  --set-env-vars "GCP_PROJECT=${PROJECT_ID},GCP_LOCATION=us-central1" \
  --set-secrets "GITHUB_TOKEN=github-token:latest" \
  --allow-unauthenticated
```

### コンソール（画面操作）

コンソールからのデプロイはGitHubリポジトリ連携（継続的デプロイ）を使うのが簡単。

1. ナビゲーションメニュー ≡ →「Cloud Run」を開き、「サービスを作成」をクリック
2. 「リポジトリから継続的にデプロイする」を選択し「Cloud Buildの設定」をクリック
   - GitHubアカウントを連携し、このプロジェクトのリポジトリを選択
   - ブランチ: `^main$`、ビルドタイプ: `Dockerfile`、ソースの場所: `/repo-educator/backend/Dockerfile`
3. サービス設定を入力
   - サービス名: `repo-educator-api`
   - リージョン: `asia-northeast1`（東京）
   - 認証: 「未認証の呼び出しを許可」にチェック
4. 「コンテナ、ボリューム、ネットワーキング、セキュリティ」を展開して以下を設定
   - **セキュリティ**タブ: サービスアカウントに `repo-educator-backend` を選択
   - **変数とシークレット**タブ:
     - 環境変数を追加: `GCP_PROJECT` = プロジェクトID、`GCP_LOCATION` = `us-central1`
     - 「シークレットを参照」→ シークレット `github-token`、参照方法「環境変数として公開」、名前 `GITHUB_TOKEN`、バージョン `latest`
   - **コンテナ**タブ: コンテナポートが `8000` になっていることを確認
5. 「作成」をクリックし、ビルド・デプロイの完了を待つ
6. サービス詳細画面の上部に表示されるURL（`https://repo-educator-api-xxxx.a.run.app`）を控える

- Cloud Run 上ではサービスアカウントの権限（Application Default Credentials）で Vertex AI を呼び出すため、`GOOGLE_APPLICATION_CREDENTIALS` は設定不要
  - **注意**: 現状の `app/config.py` は `GOOGLE_APPLICATION_CREDENTIALS` の有無で Vertex AI 接続を判定しているため、Cloud Run 本番稼働時は判定ロジックを ADC ベース（`GCP_PROJECT` の有無のみ等）に変更すること
- デプロイ完了後に表示されるURL（`https://repo-educator-api-xxxx.a.run.app`）を控えておく

### 動作確認

```bash
curl https://<CLOUD_RUN_URL>/healthz
curl -X POST https://<CLOUD_RUN_URL>/api/v1/quiz/generate \
  -H "Content-Type: application/json" \
  -d '{"repository_url":"https://github.com/psf/requests","num_questions":3}'
```

## 4. フロントエンドのデプロイ（Firebase Hosting）

### ビルド

APIのベースURLをCloud RunのURLに差し替えてビルドする。

```bash
cd frontend
flutter build web --release --dart-define=API_BASE_URL=https://<CLOUD_RUN_URL>
```

成果物は `frontend/build/web/` に出力される。

### Firebaseプロジェクトの登録（初回のみ・画面操作）

1. [Firebase Console](https://console.firebase.google.com/) を開き「プロジェクトを追加」をクリック
2. 「既存のGoogle Cloudプロジェクトに追加」から対象のGCPプロジェクトを選択
3. 画面の指示に従って作成を完了（Analyticsは任意）
4. 左メニューの「構築」→「Hosting」を開き「始める」をクリック（画面に表示されるCLI手順は下記と同じ内容）

### Hosting 初期設定（初回のみ・CLI）

```bash
firebase login
firebase init hosting
# - 既存のGCPプロジェクトを選択
# - public directory: build/web
# - single-page app: Yes
```

### デプロイ（CLI）

```bash
firebase deploy --only hosting
```

> Firebase Hosting のデプロイ自体はCLIからのみ実行できる（コンソールにファイルアップロード機能はない）。デプロイ後の確認・ロールバックはコンソールの「Hosting」→「リリース履歴」から画面操作で行える（各リリース右側の︙メニュー →「ロールバック」）。

## 5. CORS設定の本番向け調整

現状 `backend/app/main.py` の CORS は `allow_origins=["*"]` になっている。本番リリース時は Firebase Hosting のドメインに限定すること。

```python
allow_origins=["https://<YOUR_PROJECT>.web.app"]
```

## リリースチェックリスト

- [ ] `backend/.env` などのシークレットがコミットされていないこと（`.gitignore` 済み）
- [ ] CORS を本番ドメインに限定したこと
- [ ] Vertex AI 接続判定を ADC ベースに変更したこと（モック応答が本番に出ないこと）
- [ ] `curl` で本番APIの `/healthz` とクイズ生成を確認したこと
- [ ] フロントエンドから本番APIに対して一連の操作（生成→回答→解説）ができること
- [ ] Cloud Run の最大インスタンス数・同時実行数を設定し、コスト暴走を防いだこと（CLI: `--max-instances 3` / コンソール: Cloud Run のサービス →「新しいリビジョンの編集とデプロイ」→ 自動スケーリングの「インスタンスの最大数」）
