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
  - Cloud KMS API (`cloudkms.googleapis.com`)
  - Firestore API (`firestore.googleapis.com`)
  - Identity Toolkit API (`identitytoolkit.googleapis.com`)

### CLI

```bash
gcloud config set project <YOUR_PROJECT_ID>
gcloud services enable run.googleapis.com aiplatform.googleapis.com \
  artifactregistry.googleapis.com secretmanager.googleapis.com \
  cloudkms.googleapis.com firestore.googleapis.com identitytoolkit.googleapis.com
```

### コンソール（画面操作）

1. [Google Cloud Console](https://console.cloud.google.com/) を開き、画面上部のプロジェクトセレクタで対象プロジェクトを選択（未作成なら「新しいプロジェクト」から作成）
2. 左上のナビゲーションメニュー ≡ →「APIとサービス」→「ライブラリ」を開く
3. 検索ボックスで以下を1つずつ検索し、それぞれのページで「有効にする」をクリック
   - Cloud Run Admin API
   - Vertex AI API
   - Artifact Registry API
   - Secret Manager API
   - Cloud KMS API
   - Cloud Firestore API
   - Identity Toolkit API

> **注意**: `aiplatform.googleapis.com` はコンソール上の表示名が **「Agent Platform API」** に変わっており、「Vertex AI」で検索しても見つからない場合がある。その場合は検索ボックスに API ID (`aiplatform.googleapis.com`) をそのまま貼り付けること。CLIはAPI IDで指定するためこの影響を受けない。

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

## 1.5 ログイン機能のセットアップ（初回のみ）

公開リポジトリの学習だけを提供するなら、この節は丸ごとスキップしてよい（ログインボタンが出ないだけで動作する）。プライベートリポジトリの学習と学習履歴を有効にする場合のみ実施する。

### (a) GitHub App の作成

GitHubの [Settings > Developer settings > GitHub Apps > New GitHub App](https://github.com/settings/apps/new) で作成する。

| 項目 | 値 |
|---|---|
| Homepage URL | フロントエンドのURL |
| Callback URL | `https://<CLOUD_RUN_URL>/api/v1/github/setup-callback` |
| Setup URL | `https://<CLOUD_RUN_URL>/api/v1/github/setup-callback` |
| Request user authorization (OAuth) during installation | **有効にする** |
| Webhook | 使わないので Active のチェックを外す |
| Repository permissions > **Contents** | **Read-only**（これ以外は付与しない） |
| Where can this GitHub App be installed? | Any account |

作成後、以下を控える。

- **App ID**（`GITHUB_APP_ID`）
- **アプリのURL末尾のスラッグ**（`GITHUB_APP_SLUG`。`https://github.com/apps/<slug>` の部分）
- **Client ID / Client secret**（次の (b) で Firebase に設定する）
- **秘密鍵**（"Generate a private key" でPEMをダウンロード）

### (b) Firebase Authentication の設定

1. [Firebase Console](https://console.firebase.google.com/) で対象プロジェクトを開く
2. 「構築」→「Authentication」→「始める」
3. 「Sign-in method」タブ →「GitHub」を選択して有効化
4. (a) で控えた **Client ID / Client secret** を入力
5. 画面に表示される**コールバックURL**をコピーし、GitHub App の設定画面の Callback URL に**追加**する（`setup-callback` と両方登録しておく）

> **検証が必要な点**: ここでは GitHub **App** の Client ID / Secret を Firebase の GitHub プロバイダに設定している。GitHub App も OAuth と同じ authorize / access_token エンドポイントを持つため動作するが、うまくいかない場合は Firebase 用に別途 **OAuth App** を登録し、Client ID / Secret はそちらのものを使う。その構成でもインストールとの紐付けは `setup-callback` の `state` で行われるため、プライベートリポジトリの学習は問題なく動作する（`GET /user/installations` による一覧の自動同期だけが効かなくなる）。

### (c) Firestore の作成とセキュリティルール

```bash
gcloud firestore databases create --location=asia-northeast1
```

**クライアントからの直接アクセスは全面拒否する。** 読み書きはすべてバックエンド（Admin SDK）経由で行うため、ルールは以下のままでよい。

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /{document=**} {
      allow read, write: if false;
    }
  }
}
```

コンソールからは Firebase Console →「構築」→「Firestore Database」→「ルール」タブで設定する。

### (d) Cloud KMS 鍵の作成

GitHubユーザートークンの暗号化に使う。

```bash
gcloud kms keyrings create repo-educator --location=global
gcloud kms keys create github-token \
  --location=global --keyring=repo-educator --purpose=encryption
```

鍵のフルネーム（`GITHUB_APP_PRIVATE_KEY` とは別の `KMS_KEY_NAME`）は次の形式になる。

```
projects/<PROJECT_ID>/locations/global/keyRings/repo-educator/cryptoKeys/github-token
```

### (e) GitHub App 秘密鍵を Secret Manager に登録

```bash
gcloud secrets create github-app-private-key --data-file=<ダウンロードしたPEMのパス>
```

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

# --- 以下はログイン機能を有効にする場合のみ ---

# Firestore（学習履歴・クイズキャッシュ）
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA}" --role="roles/datastore.user"

# Firebase IDトークンの検証
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA}" --role="roles/firebaseauth.viewer"

# GitHubユーザートークンの暗号化・復号
gcloud kms keys add-iam-policy-binding github-token \
  --location=global --keyring=repo-educator \
  --member="serviceAccount:${SA}" --role="roles/cloudkms.cryptoKeyEncrypterDecrypter"

# GitHub App 秘密鍵の読み取り
gcloud secrets add-iam-policy-binding github-app-private-key \
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

> ログイン機能を有効にする場合は、上記に加えて `Cloud Datastore ユーザー`（`roles/datastore.user`）、`Firebase Authentication 閲覧者`（`roles/firebaseauth.viewer`）、`Cloud KMS 暗号鍵の暗号化/復号`（`roles/cloudkms.cryptoKeyEncrypterDecrypter`）を付与し、シークレット `github-app-private-key` にも同じ手順でアクセス権を与える。

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
  --set-env-vars "FIREBASE_PROJECT_ID=${PROJECT_ID}" \
  --set-env-vars "FRONTEND_ORIGIN=https://${PROJECT_ID}.web.app" \
  --set-env-vars "GITHUB_APP_ID=<APP_ID>,GITHUB_APP_SLUG=<APP_SLUG>" \
  --set-env-vars "KMS_KEY_NAME=projects/${PROJECT_ID}/locations/global/keyRings/repo-educator/cryptoKeys/github-token" \
  --set-secrets "GITHUB_TOKEN=github-token:latest" \
  --set-secrets "GITHUB_APP_PRIVATE_KEY=github-app-private-key:latest" \
  --set-secrets "STATE_SECRET=state-secret:latest" \
  --allow-unauthenticated
```

`STATE_SECRET` は複数インスタンスでstate検証を成立させるために必要。事前に登録しておく。

```bash
openssl rand -base64 32 | tr -d '\n' | gcloud secrets create state-secret --data-file=-
gcloud secrets add-iam-policy-binding state-secret \
  --member="serviceAccount:${SA}" --role="roles/secretmanager.secretAccessor"
```

> ログイン機能を使わない場合は、`FIREBASE_PROJECT_ID` / `GITHUB_APP_*` / `KMS_KEY_NAME` / `STATE_SECRET` の各行を省略してよい。該当機能が無効になるだけで、公開リポジトリの学習は動作する。

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

- Cloud Run 上ではサービスアカウントの権限（Application Default Credentials）で Vertex AI を呼び出すため、`GOOGLE_APPLICATION_CREDENTIALS` は設定不要（`app/config.py` の判定は `GCP_PROJECT` の有無のみを見るADCベースに修正済み）
- デプロイ完了後に表示されるURL（`https://repo-educator-api-xxxx.a.run.app`）を控えておく
- **URLが確定したら、GitHub App の Callback URL / Setup URL を実際のCloud Run URLに更新すること**（1.5 (a) で仮のURLを入れていた場合）

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
flutter build web --release \
  --dart-define=API_BASE_URL=https://<CLOUD_RUN_URL> \
  --dart-define=FIREBASE_API_KEY=... \
  --dart-define=FIREBASE_APP_ID=... \
  --dart-define=FIREBASE_PROJECT_ID=... \
  --dart-define=FIREBASE_MESSAGING_SENDER_ID=... \
  --dart-define=FIREBASE_AUTH_DOMAIN=<YOUR_PROJECT>.firebaseapp.com
```

`FIREBASE_*` の値は Firebase Console →「プロジェクトの設定」→「マイアプリ（ウェブアプリ）」から取得する。ウェブアプリを未登録なら、同じ画面の「アプリを追加」→ ウェブ から先に登録する。

`FIREBASE_*` を省略してビルドするとログイン機能が無効になり、公開リポジトリ専用のサイトとして公開される（アプリ自体は正常に動作する）。

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

CORS の許可オリジンは環境変数 `FRONTEND_ORIGIN` で指定する（コード修正は不要）。**未指定だと開発用に全許可（`*`）になる**ため、本番では必ず Firebase Hosting のドメインを設定すること。

```bash
gcloud run services update repo-educator-api --region asia-northeast1 \
  --update-env-vars "FRONTEND_ORIGIN=https://<YOUR_PROJECT>.web.app"
```

カンマ区切りで複数指定できる（例: `.web.app` と `.firebaseapp.com` の両方）。

## 6. Firebase Authentication の承認済みドメイン

Firebase Console →「Authentication」→「Settings」→「承認済みドメイン」に、Hosting のドメイン（`<YOUR_PROJECT>.web.app` / `<YOUR_PROJECT>.firebaseapp.com`）が含まれていることを確認する。含まれていないとログインのポップアップがエラーになる。

## リリースチェックリスト

- [ ] `backend/.env` などのシークレットがコミットされていないこと（`.gitignore` 済み）
- [ ] `FRONTEND_ORIGIN` を本番ドメインに設定したこと（未設定だと全許可になる）
- [ ] `curl` で本番APIの `/healthz` とクイズ生成を確認したこと
- [ ] **未ログインのまま**フロントエンドから公開リポジトリの一連の操作（生成→回答→解説）ができること
- [ ] Cloud Run の最大インスタンス数・同時実行数を設定し、コスト暴走を防いだこと（CLI: `--max-instances 3` / コンソール: Cloud Run のサービス →「新しいリビジョンの編集とデプロイ」→ 自動スケーリングの「インスタンスの最大数」）

### ログイン機能を有効にした場合の追加チェック

- [ ] GitHub App の Callback URL / Setup URL が実際の Cloud Run URL になっていること
- [ ] Firebase の承認済みドメインに Hosting のドメインが入っていること
- [ ] GitHubでログイン → リポジトリを1つ選んでインストール → そのプライベートリポジトリでクイズが生成できること
- [ ] **GitHub側でインストールを解除した後、同じリポジトリで 403 が返り、キャッシュが返らないこと**（プライベートなクイズが権限喪失後も見えてしまう事故の確認。最も重要）
- [ ] 別アカウントでログインし、他人のプライベートリポジトリのクイズが取得できないこと
- [ ] Firestore のセキュリティルールがクライアントからの直接アクセスを拒否していること
- [ ] Cloud Run のログにGitHubトークンが出力されていないこと
