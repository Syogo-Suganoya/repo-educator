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
│   │   ├── auth.py            # Firebase IDトークン検証（認証は任意）
│   │   ├── github_client.py   # GitHub APIからのソース取得（Blobs API）
│   │   ├── github_app.py      # GitHub App のトークン発行・インストール照会
│   │   ├── analysis_cache.py  # メモリキャッシュとsingle-flight（後述）
│   │   ├── store.py           # Firestore（ユーザー・履歴・解析結果キャッシュ）
│   │   ├── crypto.py          # Cloud KMS による暗号化
│   │   ├── quiz_generator.py  # クイズ生成（Gemini + モックフォールバック）
│   │   ├── doc_generator.py   # 逆引きドキュメント生成（同上）
│   │   ├── sample_quizzes.py  # デモ用キュレーション済みクイズ（後述）
│   │   ├── sample_docs.py     # デモ用キュレーション済みドキュメント（後述）
│   │   └── config.py          # 環境変数（pydantic-settings）
│   ├── tests/                 # pytest（キャッシュとエラー分類）
│   ├── Dockerfile
│   ├── docker-compose.yml
│   ├── requirements-dev.txt   # テスト用の依存（本番イメージには入れない）
│   └── .env.example
└── frontend/          # Flutter Web フロントエンド
    └── lib/
        ├── main.dart              # アプリ起動・Firebase初期化
        ├── start_page.dart        # 起点となる画面
        ├── workspace_page.dart    # レビュー/ドキュメントのタブとクイズUI
        ├── repositories_page.dart # プライベートリポジトリ選択
        ├── firebase_options.dart  # Firebase設定（--dart-defineから読む）
        ├── api_client.dart        # バックエンドAPIクライアント
        ├── theme.dart             # 配色・タイポグラフィ・共通部品（後述）
        ├── auth/                  # ログイン処理とアカウントUI
        ├── docs/                  # 逆引きドキュメント（検索ロジックとUI）
        └── models/                # レスポンスのDartモデル
```

### スタイルは theme.dart に集約する

配色（`AppPalette`）、書体（`appDisplay` / `appBody` / `appMono`）、共通部品（`DiffCard` / `DiffCodeBlock` / `DiffStatBadge` / `AppTopBar`）はすべて `lib/theme.dart` にある。

**画面ごとに色やフォントを直書きしないこと。** クイズ画面とドキュメント画面が同じ見た目に保たれているのは、両方がこのファイルの部品だけで組まれているためである。新しい画面を作るときも同じ部品を使うか、汎用性があるなら `theme.dart` 側に足す。

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
| `GOOGLE_APPLICATION_CREDENTIALS` | サービスアカウントキーのパス（ローカル開発用。Cloud Run上では不要） |
| `FIREBASE_PROJECT_ID` | 空ならログイン機能が無効になる |
| `FIRESTORE_ENABLED` | 学習履歴・クイズキャッシュの有効/無効（既定: `true`） |
| `GITHUB_APP_ID` / `GITHUB_APP_SLUG` / `GITHUB_APP_PRIVATE_KEY` | GitHub App。空ならログインしてもプライベートリポジトリは読めない |
| `KMS_KEY_NAME` | GitHubユーザートークンの暗号化鍵。空なら**トークンを保存しない**（平文保存はしない） |
| `FRONTEND_ORIGIN` | CORS許可オリジン。空なら `*`（開発用）。本番では必ず指定する |
| `STATE_SECRET` | GitHub Appインストール時のstate署名鍵。空ならプロセス起動ごとにランダム生成 |

**設定は「揃っていない機能から順に無効になる」設計**にしてあり、何も設定しなくてもアプリは起動する。

| 未設定のもの | 起きること |
|---|---|
| `FIREBASE_PROJECT_ID` | ログインボタン自体が出ない。公開リポジトリの学習はそのまま使える |
| `GITHUB_APP_*` | ログインはできるが、プライベートリポジトリの一覧・学習ができない |
| `FIRESTORE_ENABLED=false` または プロジェクトID空 | 学習履歴と解析結果のキャッシュが保存されない |
| `KMS_KEY_NAME` | GitHubユーザートークンを保存しない（毎回ログイン時に再取得する） |

**`GCP_PROJECT` が未設定の場合、Vertex AIは呼ばれない。** その場合の応答は2パターンある。

1. 下記「サンプルリポジトリ」に該当するリポジトリ → `app/sample_quizzes.py` と `app/sample_docs.py` の**キュレーション済みデータ**（実コードを人手で読んで作成した固定データ。Geminiによる生成ではない）
2. それ以外のリポジトリ → `generate_mock_sections`（`quiz_generator.py`）と `generate_mock_docs`（`doc_generator.py`）による、内容を反映しない汎用モック

GCPなしでもフロントエンドの開発・デモが一通り可能な設計になっている。モックであっても `kind` は4種類すべて揃うため、ドキュメント画面のレイアウト確認はGCPなしで行える。

### 動作確認

```bash
curl localhost:8000/healthz

curl -X POST localhost:8000/api/v1/quiz/generate \
  -H "Content-Type: application/json" \
  -d '{"repository_url":"https://github.com/octocat/Hello-World","branch":"master","num_questions":2}'
```

> `octocat/Hello-World` はデフォルトブランチが `master` なので注意（APIの既定値は `main`）。

### サンプルリポジトリ（キュレーション済みデータ）

以下3つのリポジトリはGCP未接続でも、実コードに基づいた質の高いクイズとドキュメントが返る。フロントエンドの「サンプルPRを開く」からもワンクリックで呼び出せる。

| リポジトリ | ブランチ | 内容 |
|---|---|---|
| `https://github.com/psf/requests` | `main` | `Response.ok` や `Session` のAPI設計 |
| `https://github.com/TheAlgorithms/Python` | `master` | クイックソート・二分探索の実装 |
| `https://github.com/gin-gonic/gin` | `master` | `Context.Next()` 等のミドルウェアチェーン実装 |

**サンプルを追加・更新する手順:**

1. `app/sample_quizzes.py` に `Quiz` を追記し、`SAMPLE_REPOSITORIES` に `"owner/repo"` キーで紐付ける
2. `app/sample_docs.py` に `DocEntry` を追記し、`SAMPLE_DOCS` に同じキーで紐付ける
   - `kind` は `feature` / `symbol` / `task` / `file` の4種を**最低1件ずつ**含める
   - `tags` には日本語・英語の別名を両方入れる（検索のヒット率に直結する）
   - `related_section_titles` は `sample_quizzes.py` のセクション名と**文字列を完全一致させる**。ここがずれるとドキュメントからクイズへのリンクが機能しない
3. フロントエンドの起点画面にボタンを足す場合は `frontend/lib/start_page.dart` の `_samples` に追記する

## フロントエンドの起動

バックエンドを起動した状態で:

```bash
cd frontend
flutter pub get        # 初回のみ
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8000
```

- Chromeを使わない場合は `-d web-server --web-port=5173` で http://localhost:5173 から確認できる
- `API_BASE_URL` 未指定時の既定値は `http://localhost:8000`（`lib/api_client.dart`）

### ログイン機能を有効にして起動する

`lib/firebase_options.dart` は `flutterfire configure` の生成物ではなく、`API_BASE_URL` と同じく `--dart-define` から設定を読む。値はFirebaseコンソールの「プロジェクトの設定 > マイアプリ（ウェブ）」から取得する。

```bash
flutter run -d chrome \
  --dart-define=API_BASE_URL=http://localhost:8000 \
  --dart-define=FIREBASE_API_KEY=... \
  --dart-define=FIREBASE_APP_ID=... \
  --dart-define=FIREBASE_PROJECT_ID=... \
  --dart-define=FIREBASE_MESSAGING_SENDER_ID=... \
  --dart-define=FIREBASE_AUTH_DOMAIN=...
```

`FIREBASE_API_KEY` / `FIREBASE_APP_ID` / `FIREBASE_PROJECT_ID` の3つが揃わない限り Firebase は初期化されず、ログインボタンも表示されない（アプリ自体は起動する）。

## 開発フロー

1. ブランチを切って作業する（`main` へ直接コミットしない）
2. バックエンドを変更した場合:
   - 依存関係を追加したら `requirements.txt` に追記し `docker compose up --build` で再ビルド
   - `app/` 配下の変更はホットリロードで即反映される
3. フロントエンドを変更した場合: 実行中のターミナルで `r`（ホットリロード）
4. コミット前に動作確認（上記curl + ブラウザでの一連の操作）を行う

## 解析結果のキャッシュ

同じリポジトリ・同じコミットへのリクエストは、**ユーザーをまたいで結果を共有する**。GitHub APIのレートリミットとGeminiの料金がどちらも実際の制約になるため。

- メモリ（`analysis_cache.py`）→ Firestore（`store.py`）の順に探し、両方ミスしたときだけ生成する
- 同時に走る同一リクエストは `analysis_cache.run_once` で1本にまとめる
- キャッシュキーはブランチ名ではなく**コミットSHA**。ブランチが進めば自動的に別エントリになる

### 更新確認は安い問い合わせから順に

`main.py` の `_resolve_ref()` が、GitHubへの問い合わせを段階的に行う。

1. `fetch_repository_meta()` … `pushed_at` を取る（API 1回）
2. 前回と同じ `pushed_at` なら、記録済みのコミットSHAをそのまま使う（**API 1回で完了**）
3. 違えば `resolve_commit_sha()` でSHAを確認する（API 1回）
4. SHAが一致すればキャッシュを返す。違えば取得・生成する

**`pushed_at` はリポジトリ全体の値で、対象ブランチ固有ではない。** 別ブランチへのpushでも進むため、「進んでいたら再生成」にすると無関係な更新で作り直してしまう。`pushed_at` は「変わっていない」ことの確認にのみ使い、**再生成の判断は必ずコミットSHAで行うこと**（`analysis_cache.is_unchanged` は判断がつかない場合すべて `False` を返す＝SHAを確認しに行く、という設計にしてある）。

比較は自前の時刻ではなく**GitHubが返した `pushed_at` 同士**で行う。サーバー間の時計のずれで誤判定しないため。

**キャッシュ判定はソースコードをダウンロードする前に行うこと。** 上記1〜4はGitHub APIを最大2回しか使わないが、`fetch_repository_files()` はファイル数に比例して消費する（1回の解析で最大30回程度）。順序を逆にすると、キャッシュヒット時でもレートリミットを浪費してしまう。

```bash
docker compose exec backend python -m pytest -q
```

初回は `docker compose up` 時にテスト用の依存（`requirements-dev.txt`）が自動で入る。

### レートリミットの扱い

GitHubは**権限不足にもレートリミットにも `403`** を返す。同一視すると、レートリミットなのに「権限がありません」と誤って案内してしまうため、`x-ratelimit-remaining` ヘッダーで区別している（`github_client.py` の `_check_response`）。未認証は60req/hしかなく、実際に到達する。

開発中に `429` が頻発する場合は `.env` に `GITHUB_TOKEN` を設定すると5,000req/hに緩和される。

## 逆引きドキュメント機能

クイズと並んで生成される、機能名・関数名・やりたいこと・ファイル名の4通りで引けるドキュメント。

- 生成は `app/doc_generator.py`。**クイズ生成とは別のGemini呼び出しを `asyncio.gather` で並行実行する。** 1回の呼び出しに両方を詰め込むと出力トークン上限でJSONが途中で切れやすいため
- **検索はフロントエンド側のインメモリ処理で完結し、サーバー往復は発生しない。** ロジックは `frontend/lib/docs/doc_search.dart` にUI非依存の純粋関数として置いてあり、`test/doc_search_test.dart` でテストしている。検索仕様を変えるときは必ずテストも更新すること
- 日本語は空白で分かち書きされないため、形態素解析はせず小文字化した部分一致で判定している

```bash
cd frontend && flutter test test/doc_search_test.dart
```

## コーディング規約

- **バックエンド**: 型ヒント必須。APIの入出力は必ず `schemas.py` のPydanticモデルを通す
- **フロントエンド**: `flutter analyze` が通ること。モデルのJSON変換は手書き `fromJson`（`json_serializable` は使わない方針）
- **スタイルは `theme.dart` に集約する**（画面ごとに色・フォントを直書きしない）
- **レスポンスにフィールドを追加するときは既定値を持たせる。** 古いキャッシュや古いクライアントと組み合わさっても壊れないようにするため（`docs` フィールドがこの方針で追加されている）
- コミットメッセージは日本語でよい（既存の履歴に合わせる）

## よくあるハマりどころ

- **404 "not found"**: ブランチ名の間違いが多い。古いリポジトリは `master` がデフォルト
- **403 が返る**: プライベートリポジトリに対してログインしていない、またはGitHub Appをそのリポジトリにインストールしていない。404（存在しない）と403（読めない）は意図的に区別している
- **429 が返る**: GitHub APIのレートリミット。未認証は60req/hしかないため、開発中に数リポジトリ解析するだけで到達する。`.env` に `GITHUB_TOKEN` を設定すると5,000req/hになる。現在の残数は `curl -s https://api.github.com/rate_limit` で確認できる
- **同じリポジトリなのに毎回生成される**: `.env` の `FIREBASE_PROJECT_ID` が空だとFirestoreキャッシュが効かず、プロセス内メモリキャッシュのみになる。バックエンドを再起動するとメモリキャッシュは消える
- **リポジトリを更新したのに問題が変わらない**: 対象ブランチのコミットSHAが変わっているか確認する。別ブランチへのpushでは（`pushed_at` は進んでも）意図的に再生成しない
- **モッククイズ／モックドキュメントしか返らない**: `.env` の `GCP_PROJECT` が空。意図的な仕様（上記参照）
- **ドキュメントからクイズへのリンクが出ない**: `related_section_titles` とクイズのセクション名が文字列一致していない。Geminiが別々の呼び出しで生成するため命名がずれることがあり、一致しない場合はリンクを出さない仕様にしている
- **ログインボタンが出ない**: `FIREBASE_*` の `--dart-define` が未指定。これも意図的な仕様（上記参照）
- **CORSエラー**: 開発中は `FRONTEND_ORIGIN` 未指定＝全許可なので通常発生しない。発生したらバックエンドが起動しているか確認
- **プライベートリポジトリが一覧に出ない**: GitHub App のインストール時にそのリポジトリを選択したか確認する。リポジトリ選択画面の「リポジトリを追加・変更」から変更できる
- **`.env` は絶対にコミットしない**（`backend/.gitignore` で除外済み）

## セキュリティ上の約束事

- **GitHubのトークンをログに出さない。** 例外処理でGitHub APIのレスポンス本文をそのままクライアントへ返さないこと（`github_app.py` はステータスコードのみをログに出している）
- **installation access token を永続化しない。** 1時間で失効する短命トークンであり、都度発行するのが正しい
- **Firestoreへのクライアント直接アクセスを許可しない。** ルールは全拒否のままにし、読み書きは必ずバックエンド経由にする
