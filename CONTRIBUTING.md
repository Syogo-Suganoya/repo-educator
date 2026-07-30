# 開発ガイド（CONTRIBUTING）

ローカルでの開発環境のセットアップと開発フローをまとめる。システム全体の設計は [README.md](README.md)、本番デプロイは [DEPLOY.md](DEPLOY.md) を参照。

## 必要なツール

- Docker（Docker Compose v2）
- Flutter SDK（Web対応版）
- （任意）GitHub Personal Access Token — GitHub APIのレートリミット緩和用

## ディレクトリ構成

```
repo-educator/
├── README.md          # システム基本設計書
├── DEPLOY.md          # リリース・デプロイ手順
├── backend/           # FastAPI バックエンド（Docker）
│   ├── app/
│   │   ├── main.py            # エンドポイント定義・CORS
│   │   ├── schemas.py         # Pydanticモデル（リクエスト/レスポンス）
│   │   ├── github_client.py   # GitHub APIからのソース取得
│   │   ├── quiz_generator.py  # Gemini呼び出し + モックフォールバック
│   │   ├── sample_quizzes.py  # デモ用キュレーション済みクイズ（後述）
│   │   └── config.py          # 環境変数（pydantic-settings）
│   ├── Dockerfile
│   ├── docker-compose.yml
│   └── .env.example
└── frontend/          # Flutter Web フロントエンド
    └── lib/
        ├── main.dart          # クイズ画面UI
        ├── api_client.dart    # バックエンドAPIクライアント
        └── models/quiz.dart   # レスポンスのDartモデル
```

## バックエンドの起動

```bash
cd backend
cp .env.example .env   # 初回のみ。必要に応じてトークン等を記入
docker compose up --build
```

- http://localhost:8000 で起動する（ホットリロード有効: `./app` をbindマウントして `--reload` 付きで実行）
- APIドキュメント（Swagger UI）: http://localhost:8000/docs
- 停止: `docker compose down`

### 環境変数（`backend/.env`）

| 変数 | 説明 |
|---|---|
| `GITHUB_TOKEN` | GitHub PAT。未設定でも動くがレートリミットが厳しくなる（60req/h） |
| `GCP_PROJECT` | GCPプロジェクトID。Vertex AI接続に必要 |
| `GCP_LOCATION` | Vertex AIのリージョン（既定: `us-central1`） |
| `GOOGLE_APPLICATION_CREDENTIALS` | サービスアカウントキーのパス |

**`GCP_PROJECT` と `GOOGLE_APPLICATION_CREDENTIALS` が両方未設定の場合、Vertex AIは呼ばれない。** その場合の応答は2パターンある。

1. 下記「サンプルリポジトリ」に該当するリポジトリ → `app/sample_quizzes.py` の**キュレーション済みクイズ**（実コードを人手で読んで作成した固定データ。Geminiによる生成ではない）
2. それ以外のリポジトリ → `app/quiz_generator.py` の `generate_mock_quizzes`（内容を反映しない汎用モック）

GCPなしでもフロントエンドの開発・デモが一通り可能な設計になっている。

### 動作確認

```bash
curl localhost:8000/healthz

curl -X POST localhost:8000/api/v1/quiz/generate \
  -H "Content-Type: application/json" \
  -d '{"repository_url":"https://github.com/octocat/Hello-World","branch":"master","num_questions":2}'
```

> `octocat/Hello-World` はデフォルトブランチが `master` なので注意（APIの既定値は `main`）。

### サンプルリポジトリ（キュレーション済みクイズ）

以下3つのリポジトリはGCP未接続でも実コードに基づいた質の高いクイズが返る（`app/sample_quizzes.py` の `SAMPLE_REPOSITORIES`）。フロントエンドの「サンプルを試す」ボタンからもワンクリックで呼び出せる。

| リポジトリ | ブランチ | 内容 |
|---|---|---|
| `https://github.com/psf/requests` | `main` | `Response.ok` や `Session` のAPI設計に関する問題 |
| `https://github.com/TheAlgorithms/Python` | `master` | クイックソート・二分探索の実装に関する問題 |
| `https://github.com/gin-gonic/gin` | `master` | `Context.Next()` 等のミドルウェアチェーン実装に関する問題 |

サンプルを追加・更新する場合は `app/sample_quizzes.py` に `Quiz` を追記し、`SAMPLE_REPOSITORIES` の対象リポジトリに `"owner/repo"` キーで紐付ける。フロントエンド側は `frontend/lib/main.dart` の `_sampleRepositories` にボタンを追加する。

## フロントエンドの起動

バックエンドを起動した状態で:

```bash
cd frontend
flutter pub get        # 初回のみ
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8000
```

- Chromeを使わない場合は `-d web-server --web-port=5173` で http://localhost:5173 から確認できる
- `API_BASE_URL` 未指定時の既定値は `http://localhost:8000`（`lib/api_client.dart`）

## 開発フロー

1. ブランチを切って作業する（`main` へ直接コミットしない）
2. バックエンドを変更した場合:
   - 依存関係を追加したら `requirements.txt` に追記し `docker compose up --build` で再ビルド
   - `app/` 配下の変更はホットリロードで即反映される
3. フロントエンドを変更した場合: 実行中のターミナルで `r`（ホットリロード）
4. コミット前に動作確認（上記curl + ブラウザでの一連の操作）を行う

## コーディング規約

- **バックエンド**: 型ヒント必須。APIの入出力は必ず `schemas.py` のPydanticモデルを通す
- **フロントエンド**: `flutter analyze` が通ること。モデルのJSON変換は手書き `fromJson`（`json_serializable` は使わない方針）
- コミットメッセージは日本語でよい（既存の履歴に合わせる）

## よくあるハマりどころ

- **404 "not found"**: ブランチ名の間違いが多い。古いリポジトリは `master` がデフォルト
- **モッククイズしか返らない**: `.env` のGCP設定が空。意図的な仕様（上記参照）
- **CORSエラー**: 開発中は `allow_origins=["*"]` なので通常発生しない。発生したらバックエンドが起動しているか確認
- **`.env` は絶対にコミットしない**（`backend/.gitignore` で除外済み）
