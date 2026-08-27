# 開発ガイド（CONTRIBUTING）

## 必要なツール

- Docker（Docker Compose v2）
- Flutter SDK（Web対応版）
- （任意）GitHub Personal Access Token — GitHub APIのレートリミット緩和用

## ディレクトリ構成

```
repo-educator/
├── README.md          # システム基本設計書
├── backend/           # FastAPI バックエンド（Docker）
│   ├── app/
│   │   ├── main.py            # エンドポイント定義・CORS
│   │   ├── schemas.py         # Pydanticモデル（リクエスト/レスポンス）
│   │   ├── auth.py            # ID/パスワード認証（bcrypt）とJWT発行・検証
│   │   ├── db.py              # SQLAlchemyモデルとDB接続（PostgreSQL）
│   │   ├── github_client.py   # GitHub APIからのソース取得（Blobs API・PAT検証・リポジトリ一覧）
│   │   ├── analysis_cache.py  # メモリキャッシュとsingle-flight（後述）
│   │   ├── store.py           # DBアクセス層（ユーザー・履歴・解析結果キャッシュ）
│   │   ├── crypto.py          # Fernetによる対称鍵暗号化
│   │   ├── gemini.py          # Gemini接続の集約（SDK・モデルの差し替え点）
│   │   ├── quiz_generator.py  # クイズ生成（Gemini + モックフォールバック）
│   │   ├── doc_generator.py   # 逆引きドキュメント生成（同上）
│   │   ├── sample_quizzes.py  # デモ用キュレーション済みクイズ（後述）
│   │   ├── sample_docs.py     # デモ用キュレーション済みドキュメント（後述）
│   │   └── config.py          # 環境変数（pydantic-settings）
│   ├── tests/                 # pytest（キャッシュとエラー分類）
│   ├── Dockerfile
│   ├── docker-compose.yml     # backend + PostgreSQL
│   ├── requirements-dev.txt   # テスト用の依存（本番イメージには入れない）
│   └── .env.example
└── frontend/          # Flutter Web フロントエンド
    └── lib/
        ├── main.dart              # アプリ起動
        ├── start_page.dart        # 起点となる画面
        ├── workspace_page.dart    # レビュー/ドキュメントのタブとクイズUI
        ├── repositories_page.dart # トークンで読めるリポジトリの選択
        ├── api_client.dart        # バックエンドAPIクライアント
        ├── theme.dart             # 配色・タイポグラフィ・共通部品（後述）
        ├── auth/                  # ログイン・登録UIとJWTの永続化
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

- `docker-compose.yml` は `backend` と `db`（PostgreSQL）の2サービス構成。`db` のヘルスチェックが通ってから `backend` が起動する
- http://localhost:8000 で起動する（ホットリロード有効: `./app` をbindマウントして `--reload` 付きで実行）
- APIドキュメント（Swagger UI）: http://localhost:8000/docs
- テーブルは起動時に自動作成される（`app/db.py` の `init_models()`。Alembic等のマイグレーションツールは導入していない）
- 停止: `docker compose down`（`-v` を付けるとDBのボリュームごと消える）

### 環境変数（`backend/.env`）

| 変数 | 説明 |
|---|---|
| `GITHUB_TOKEN` | サーバ共有のGitHub PAT。未ログインでの公開リポジトリ取得に使う。未設定でも動くがレートリミットが厳しくなる（60req/h）。**ユーザー個別のトークンはここには置かない** |
| `GEMINI_API_KEY` | Geminiの利用に必要。[ai.google.dev](https://aistudio.google.com/apikey) で発行するAPIキー1本。**GCPプロジェクトは不要** |
| `GEMINI_MODEL` | 使用するGeminiモデル（既定: `gemini-3.5-flash`）。廃止時はここだけ変えればよい |
| `DATABASE_URL` | PostgreSQLの接続文字列。空ならログイン機能・履歴・解析結果キャッシュがすべて無効になる。ローカルは `docker-compose.yml` の `db` サービスを指す既定値、本番はNeon等に差し替える |
| `JWT_SECRET` | JWTの署名鍵。空ならログイン機能が無効になる。ランダムな文字列を設定する |
| `JWT_EXPIRES_DAYS` | JWTの有効期限（既定: `30`日） |
| `ENCRYPTION_KEY` | ユーザーが入力したGitHub PATの暗号化鍵（Fernet）。空なら**そのトークンを保存しない**（平文保存はしない） |
| `FRONTEND_ORIGIN` | CORS許可オリジン。空なら `*`（開発用）。本番では必ず指定する |

**設定は「揃っていない機能から順に無効になる」設計**にしてあり、何も設定しなくてもアプリは起動する。`GEMINI_API_KEY` と `DATABASE_URL`/`JWT_SECRET`（ログイン機能）は完全に独立しており、どちらか一方だけを設定してもよい。

| 未設定のもの | 起きること |
|---|---|
| `GEMINI_API_KEY` | クイズ・ドキュメントがモック応答になる（下記参照） |
| `DATABASE_URL` | ログイン・学習履歴・解析結果の永続キャッシュがすべて無効。公開リポジトリの学習はメモリキャッシュのみで動く |
| `JWT_SECRET` | ログインボタンは出るが、登録・ログインに失敗する（503） |
| `ENCRYPTION_KEY` | ユーザーがトークンを入力しても保存されない（毎回入力し直しになる） |

**`GEMINI_API_KEY` が未設定の場合、Geminiは呼ばれない。** その場合の応答は2パターンある。

1. 下記「サンプルリポジトリ」に該当するリポジトリ → `app/sample_quizzes.py` と `app/sample_docs.py` の**キュレーション済みデータ**（実コードを人手で読んで作成した固定データ。Geminiによる生成ではない）
2. それ以外のリポジトリ → `generate_mock_sections`（`quiz_generator.py`）と `generate_mock_docs`（`doc_generator.py`）による、内容を反映しない汎用モック

外部サービスなしでもフロントエンドの開発・デモが一通り可能な設計になっている。モックであっても `kind` は4種類すべて揃うため、ドキュメント画面のレイアウト確認はGeminiなしで行える。

### 動作確認

```bash
curl localhost:8000/healthz

curl -X POST localhost:8000/api/v1/quiz/generate \
  -H "Content-Type: application/json" \
  -d '{"repository_url":"https://github.com/octocat/Hello-World","branch":"master","num_questions":2}'
```

> `octocat/Hello-World` はデフォルトブランチが `master` なので注意（APIの既定値は `main`）。

### サンプルリポジトリ（キュレーション済みデータ）

以下3つのリポジトリはGemini未接続でも、実コードに基づいた質の高いクイズとドキュメントが返る。フロントエンドの「サンプルPRを開く」からもワンクリックで呼び出せる。

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
- 認証は自前実装（メールアドレス + パスワード）のため、フロントエンド側に追加の `--dart-define` は不要。バックエンドの `DATABASE_URL` / `JWT_SECRET` が設定されていれば、そのままログイン・新規登録が使える

### プライベートリポジトリを試す

ログイン後、アカウントメニューの「GitHubトークン」から Personal Access Token を入力する。バックエンドが `GET /user` で有効性を確認したうえで保存するため、無効な値は保存されない。

## 開発フロー

1. ブランチを切って作業する（`main` へ直接コミットしない）
2. バックエンドを変更した場合:
   - 依存関係を追加したら `requirements.txt` に追記し `docker compose up --build` で再ビルド
   - `app/` 配下の変更はホットリロードで即反映される
   - `db.py` のモデルを変更した場合、開発中は `docker compose down -v && docker compose up --build` でテーブルを作り直すのが手早い（マイグレーション未導入のため）
3. フロントエンドを変更した場合: 実行中のターミナルで `r`（ホットリロード）
4. コミット前に動作確認（上記curl + ブラウザでの一連の操作）を行う

## 認証（ID / パスワード）

**本人確認はメールアドレス + パスワード認証（JWT）。**

- パスワードは `bcrypt` でハッシュ化して `users.hashed_password` に保存する。平文は一切保存しない
- ログイン成功時に `PyJWT`（HS256、署名鍵は `JWT_SECRET`）でJWTを発行する。有効期限は `JWT_EXPIRES_DAYS`（既定30日）
- フロントエンドは発行されたJWTを `shared_preferences`（Webでは実質localStorage）に保存し、以降 `Authorization: Bearer <JWT>` として送る。`frontend/lib/auth/auth_service.dart` を参照
- 認証ロジックは `app/auth.py` の `optional_user` / `require_user`（FastAPI依存性）に集約している。**未ログインでの公開リポジトリ利用を壊さないよう、`optional_user` は認証ヘッダがなければ黙って `None` を返す**（クイズ生成はこちらを使う）

### GitHubトークンとの違い

このアプリには性質の異なる2種類の認証情報がある。混同しないこと。

| | 役割 | 保存場所 | 有効期限 |
|---|---|---|---|
| メール+パスワード → JWT | **本人確認**（誰がログインしているか） | `users.hashed_password`（ハッシュのみ） | JWTは30日（既定） |
| GitHub Personal Access Token | **リポジトリへのアクセス権** | `users.github_token_encrypted`（Fernet暗号化） | GitHub側の設定次第（無期限〜数日） |

## Gemini の呼び出し

**Gemini への接続は `app/gemini.py` の `generate_json()` に集約してある。** クイズ生成もドキュメント生成もここを経由する。SDKやモデルを直接触るコードを他のファイルに増やさないこと。

- **SDKは `google-genai`。**
- **接続は Gemini Developer API（`GEMINI_API_KEY` 1本）。** `genai.Client(api_key=...)` で初期化する。GCPプロジェクトはこの接続には不要
- 呼び出しは `client.aio.models.generate_content`（非同期）。クイズとドキュメントを `asyncio.gather` で並行実行するため、同期版でイベントループを塞いではいけない
- クライアントはプロセスで1つだけ遅延生成する

### モデルを変えるとき

`.env` の `GEMINI_MODEL` を変えるだけでよい（既定は `gemini-3.5-flash`）。**コードに直書きしないこと。**

Geminiのモデルは定期的に廃止される。Gemini 1.5 系は既に404を返し、2.5 系も2026年10月16日に終了予定。以前はモデルIDが `quiz_generator.py` と `doc_generator.py` の2箇所に直書きされており、廃止時に両方を直す必要があった。

現行モデルは [Gemini Developer API のモデル一覧](https://ai.google.dev/gemini-api/docs/models)で確認する。

## 解析結果のキャッシュ

同じリポジトリ・同じコミットへのリクエストは、**ユーザーをまたいで結果を共有する**。GitHub APIのレートリミットとGeminiの料金がどちらも実際の制約になるため。

- メモリ（`analysis_cache.py`）→ PostgreSQL（`store.py`、`analysis_cache` テーブル）の順に探し、両方ミスしたときだけ生成する
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
- **403 が返る**: プライベートリポジトリに対してログインしていない、またはアカウント設定にGitHubトークンを保存していない。404（存在しない）と403（読めない）は意図的に区別している
- **`PUT /api/v1/github/token` が400を返す**: 入力したトークンをGitHubが受け付けなかった（無効・失効・タイポ）。`GET /user` での検証に失敗している
- **429 が返る**: GitHub APIのレートリミット。未認証は60req/hしかないため、開発中に数リポジトリ解析するだけで到達する。ログインしてアカウント設定にトークンを保存すると5,000req/hになる（バックエンド共有の `.env` の `GITHUB_TOKEN` でも同様に緩和できる）。現在の残数は `curl -s https://api.github.com/rate_limit` で確認できる
- **同じリポジトリなのに毎回生成される**: `.env` の `DATABASE_URL` が空だとDBキャッシュが効かず、プロセス内メモリキャッシュのみになる。バックエンドを再起動するとメモリキャッシュは消える
- **リポジトリを更新したのに問題が変わらない**: 対象ブランチのコミットSHAが変わっているか確認する。別ブランチへのpushでは（`pushed_at` は進んでも）意図的に再生成しない
- **モッククイズ／モックドキュメントしか返らない**: `.env` の `GEMINI_API_KEY` が空。意図的な仕様（上記参照）。`DATABASE_URL` はログイン機能用で、Geminiの動作には関係ない
- **ドキュメントからクイズへのリンクが出ない**: `related_section_titles` とクイズのセクション名が文字列一致していない。Geminiが別々の呼び出しで生成するため命名がずれることがあり、一致しない場合はリンクを出さない仕様にしている
- **登録・ログインで503が返る**: `.env` の `JWT_SECRET` または `DATABASE_URL` が空。ログイン機能そのものが無効になっている
- **登録・ログインでサーバーに接続できないエラーになる**: `db` コンテナが起動しているか確認する（`docker compose ps`）。ヘルスチェック通過前に `backend` が起動していると接続に失敗する
- **CORSエラー**: 開発中は `FRONTEND_ORIGIN` 未指定＝全許可なので通常発生しない。発生したらバックエンドが起動しているか確認
- **プライベートリポジトリが一覧に出ない**: `ENCRYPTION_KEY` が未設定だとトークンが保存されず、毎回未設定扱いになる。次にトークンの Repository access に対象リポジトリが含まれているかを確認する（一覧はプライベートのみを表示するため、公開リポジトリは元から出ない）
- **`.env` は絶対にコミットしない**（`backend/.gitignore` で除外済み）

## セキュリティ上の約束事

- **GitHubのトークンをログに出さない。** 例外処理でGitHub APIのレスポンス本文をそのままクライアントへ返さないこと
- **パスワードは常に `bcrypt` でハッシュ化する。** 平文はDBにもログにも一切残さない
- **ユーザーが入力したPATを平文で保存しない。** Fernetで暗号化できない場合は保存自体をスキップする（`store.save_github_user_token` の戻り値で確認できる）
- **DBへの直接アクセスをフロントエンドに許可しない。** 接続情報を持つのはバックエンドのみとし、読み書きは必ずAPI経由にする
- **`JWT_SECRET` は複数インスタンスで共有すること。** インスタンスごとに異なると、あるインスタンスで発行したJWTが他のインスタンスで検証できず、ユーザーがランダムにログアウトされたような挙動になる
