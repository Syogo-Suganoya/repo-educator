# システム基本設計書：GitHubリポジトリ自動解析・AI学習支援サービス

## 1. システム概要
本システムは、ユーザーが指定したGitHubリポジトリ（またはソースコード群）を自動で解析し、そのコードの重要な概念、アルゴリズム、アーキテクチャ、言語仕様に関する **「穴埋めクイズ」** と **「逆引きドキュメント」** を自動生成する学習支援プラットフォームである。

1回の解析から、目的の異なる2つの成果物を生成する。

| 成果物 | 目的 | 使う場面 |
|---|---|---|
| **穴埋めクイズ** | コードを読む力を鍛える | 腰を据えて理解を深めたいとき |
| **逆引きドキュメント** | 知りたいことに最短でたどり着く | 「この機能はどこ？」を今すぐ知りたいとき |

### 1.1 開発要件への適合
* **Google Cloud アプリケーション実行プロダクト**: **Cloud Run** を採用（コンテナベースの柔軟性とリクエスト課金によるコスト最適化）。
* **Google Cloud AI 技術**: **Vertex AI (Gemini API)** を採用（`Gemini 1.5 Pro/Flash` の広大なコンテキストウィンドウを活かし、複数ファイルを丸ごと解析）。
* **その他の技術（任意）**: フロントエンドに **Flutter (Web)**、データ・認証基盤に **Firebase (Authentication, Firestore)** を採用。

---

## 2. システムアーキテクチャ
システム全体の構成およびデータフローを以下に示す。

### 2.1 アーキテクチャ構成図（概念）

```

[ユーザー (Flutter Web)]
│
├── (1) リポジトリURL入力 / クイズ回答
▼
[Firebase (Authentication / Firestore)]
│
├── (2) 認証・進捗データ同期
▼
[Cloud Run (Python FastAPI)] ◄── (3) GitHub APIからソースコード取得
│
├── (4) コンテキスト整形・プロンプト構築
▼
[Vertex AI (Gemini 1.5 Flash)] ── (5) 構造化JSON（クイズデータ）の返却

```

### 2.2 コンポーネントの役割
1. **Frontend (Flutter Web)**:
   * ユーザーインターフェースを提供。GitHubリポジトリのURL受付、クイズの出題（インタラクティブな穴埋めUI）、解答判定、スコア表示、学習履歴の可視化。
2. **Backend (Cloud Run - Python/FastAPI)**:
   * GitHub API等を利用して指定されたリポジトリの主要なソースコード（`.py`, `.js`, `.go`など）をダウンロード・結合。
   * Vertex AI SDK経由でGeminiモデルを呼び出し、構造化データ（JSON）としてクイズとドキュメントを取得・パース。
   * **クイズ生成とドキュメント生成は、取得済みソースを使い回して並行実行する**（`asyncio.gather`）。1回の呼び出しに両方を詰め込むと出力トークン上限でJSONが途中で切れやすいため、あえて別呼び出しにしている。
3. **Database & Auth (Firebase)**:
   * **Firebase Authentication**: ユーザーのサインイン・アカウント管理。
   * **Cloud Firestore**: 生成されたクイズデータ（キャッシュ用）およびユーザーごとの解答履歴、正解率、苦手分野の保存。
4. **AI Engine (Vertex AI)**:
   * `gemini-1.5-flash`（または`gemini-1.5-pro`）を使用。Structured Outputs（スキーマ定義によるJSON強制出力）を利用し、アプリケーション側でパースしやすい形式でクイズを生成。
5. **Repository Access (GitHub App)**:
   * ログインユーザーがアクセスを許可したリポジトリ（プライベート含む）を読み取るための短命トークンを発行。

---

## 2.3 認証とリポジトリアクセス

本システムの**認証は任意**である。公開リポジトリの学習はログインなしで利用でき、ログインするとプライベートリポジトリの学習と学習履歴の保存が加わる。

役割の異なる2つの仕組みを組み合わせている。

| | 担当 | 得られるもの |
|---|---|---|
| Firebase Authentication（GitHubプロバイダ） | **本人確認** | Firebase UID、GitHubユーザートークン |
| GitHub App のインストール | **リポジトリへのアクセス権** | installation ID → installation access token（1時間有効） |

### 認証フロー

```
1. ユーザーが「GitHubでログイン」→ Firebase Auth (GitHubプロバイダ) でサインイン
2. サインイン直後にしか取得できないGitHubユーザートークンを
   POST /api/v1/github/link へ送り、KMSで暗号化してFirestoreに保存
3. GET /api/v1/github/install-url で、uidを紐付けた署名付きstate付きの
   インストールURLを取得し、ユーザーが対象リポジトリを選んでGitHub Appをインストール
4. GitHubが /api/v1/github/setup-callback に installation_id と state を付けて戻す
5. stateを検証してuidを復元し、users/{uid}.installations に記録
6. 以降、クイズ生成時はそのインストールから installation access token を
   都度発行してリポジトリを読む
```

### トークンの扱い

* **GitHub App 秘密鍵** … Secret Manager に保管する唯一の長期秘密
* **installation access token** … 1時間で失効する短命トークン。**永続化しない**（プロセス内メモリに期限までキャッシュするのみ）
* **GitHub ユーザートークン** … Cloud KMS で暗号化して Firestore に保存。用途は「再ログインなしでインストール一覧を再取得する」ことのみ
* いずれのトークンも**ログには出力しない**。GitHub APIのレスポンス本文をそのままクライアントへ返さない

## 2.4 冗長な処理の排除

同じリポジトリ・同じコミットに対する解析は何度やっても同じ結果になる。GitHub API のレートリミットと Gemini の料金はどちらも実際の制約になるため、**ユーザーをまたいで解析結果を共有する**。

### 3段構えのキャッシュ

| 層 | 効く範囲 | 目的 |
|---|---|---|
| プロセス内メモリ | 単一インスタンス | 最も速い。Firestore未設定でも効く |
| Firestore | 全インスタンス・全ユーザー | インスタンスをまたいで共有する |
| single-flight | 同時実行中のリクエスト | 同じ生成が人数分走るのを防ぐ |

Cloud Run は複数インスタンスに分散するためメモリだけでは共有を保証できず、逆に Firestore だけだと毎回読み取りが発生する。両方を重ねている。

### 更新確認は段階的に、軽い問い合わせから

「リポジトリが更新されたときだけ作り直す」ために、**安い確認から順に行い、必要になるまで次に進まない**。

```
1. fetch_repository_meta()  … pushed_at と public/private（GitHub API 1回）
2. 前回と同じ pushed_at なら → 記録済みのコミットSHAを再利用（ここで確定）
3. 違えば resolve_commit_sha()  … 対象ブランチの先頭SHA（GitHub API 1回）
4. キャッシュ判定             … SHAが一致すればここで返す
5. fetch_repository_files() … ミスしたときだけ。ファイル数に比例してAPIを消費する
6. Gemini呼び出し            … single-flightで1本にまとめる
```

ファイルを取得してからキャッシュを見ると、ヒット時でも数十回のGitHub APIを浪費してしまう。**判定に必要な最小限の情報だけを先に取る**のがこの設計の要点である。

#### pushed_at を「再生成の判断」に使ってはいけない

`pushed_at` は**リポジトリ全体**の最終push時刻で、対象ブランチ固有ではない。別のブランチへのpushでも進む。

そのため次のように非対称に扱う。

| 判定 | 意味 | 動作 |
|---|---|---|
| `pushed_at` が前回と同じ | **確実に**変わっていない | コミットSHAの問い合わせを省く |
| `pushed_at` が進んだ | 変わった**かもしれない** | コミットSHAを確認する。同じなら再生成しない |

「進んでいたら再生成」にすると、無関係なブランチへのpushのたびに作り直してしまう。**再生成の判断は常にコミットSHAで行う。**

また、比較は**GitHubが返した `pushed_at` 同士**で行う（自前の解析時刻とは突き合わせない）。サーバー間の時計のずれで誤判定するのを避けるため。`pushed_at` が取れない場合や記録がない場合は、必ずSHAを確認する側に倒す。

#### 実測（GitHub API の消費回数）

| 状況 | meta | SHA照会 | ファイル取得 | AI生成 |
|---|---|---|---|---|
| 初回 | 1 | 1 | あり | あり |
| 変化なしで再訪問 | 1 | 0 | なし | なし |
| 別ブランチにpush（対象は不変） | 1 | 1 | なし | なし |
| 対象ブランチが進んだ | 1 | 1 | あり | あり |

ブランチ先頭のポインタは Firestore の `repository_heads` コレクション（`owner_repo_branch`）に保持する。解析結果とは別コレクションにして、軽い読み取りだけで済むようにしている。

### 出題数とドキュメントの分離

ドキュメントは出題数に依存しないが、クイズは依存する。そのため1つのキャッシュドキュメント内で、

* `docs` … 常に共有する
* `sections_by_count` … 出題数をキーに保持する

とし、「同じリポジトリを別の出題数で開いただけ」でドキュメントまで作り直すことがないようにしている。

なお、レスポンスの `repository_id` には出題数を含めない。これは学習履歴のキーでもあり、出題数ごとに進捗が分断されるのを避けるため。

### キャッシュとアクセス権

private リポジトリの解析結果は**ユーザーごとにキャッシュを分けず、返す直前に毎回アクセス権を確認する**（`_ensure_can_read`）。インストールを外された後もキャッシュが返り続ける事故を防ぐため。生成を待っている間に権限が変わる可能性があるので、生成完了後にも再確認する。

### ソースコード取得の方式

`raw.githubusercontent.com` は `Authorization` ヘッダを受け付けずプライベートリポジトリを読めないため、**GitHub API の Blobs API**（`GET /repos/{owner}/{repo}/git/blobs/{sha}` + `Accept: application/vnd.github.raw`）を使う。ツリー取得のレスポンスに各ファイルの SHA が含まれるため追加の照会は不要。

---

## 3. データモデル設計 (Firestore)

### 3.1 `repositories` コレクション
リポジトリごとのクイズデータをキャッシュし、2回目以降のアクセスを高速化する。
```json
{
  "repository_id": "string (owner_repo_コミットSHA)",
  "url": "string",
  "commit_sha": "string",
  "visibility": "string (public | private)",
  "analyzed_at": "timestamp",
  "sections": [
    {
      "section_id": "string (UUID)",
      "title": "string (機能セクション名)",
      "description": "string (実務上どんな役割のコード群か)",
      "quizzes": [
        {
          "quiz_id": "string (UUID)",
          "file_path": "string (対象となったソースコードのパス)",
          "scenario": "string (実務でこのコードに触る場面)",
          "question_text": "string (穴埋め用のプレースホルダー [BLANK] を含むテキスト)",
          "code_snippet": "string (関連するコード断片。穴埋め箇所は ___ 表現)",
          "choices": ["string", "string", "string", "string"],
          "correct_answer": "string",
          "explanation": "string (なぜその答えになるのか、コードのどの部分に依存しているかの解説)"
        }
      ]
    }
  ]
}

```

同じドキュメントの `docs` フィールドに、逆引きドキュメントの索引を保存する。

```json
{
  "docs": [
    {
      "doc_id": "string (UUID)",
      "kind": "string (feature | symbol | task | file)",
      "title": "string (検索でそのまま入力されうる語)",
      "summary": "string (1〜2文。検索結果一覧に表示する)",
      "body": "string (本文。段落は空行2つで区切る)",
      "file_paths": ["string"],
      "symbols": ["string (関連する関数名・クラス名)"],
      "tags": ["string (日本語・英語の別名を含む検索キーワード)"],
      "code_refs": [
        {
          "file_path": "string",
          "snippet": "string (穴埋めしない原文のコード)",
          "note": "string (その断片が何をしているかの1文)"
        }
      ],
      "related_section_titles": ["string (対応するクイズのセクション名)"]
    }
  ]
}
```

ドキュメントIDはブランチ名ではなく**コミットSHA**を含める。ブランチが進んだときに古いクイズが返り続けるのを防ぐため。

`docs` フィールドは後から追加されたため、**これを持たない古いキャッシュを読んでも壊れないよう、バックエンド・フロントエンドとも既定値を空リストにしている。**

**キャッシュのスコープ**: `visibility` が `private` のドキュメントは、**返却のたびに呼び出し元が当該リポジトリへのアクセス権を持つかを再確認**してから返す。ユーザーごとにドキュメントを分けるのではなく都度確認する方式にしているのは、GitHub側でインストールを外された後もキャッシュが返り続ける事故を防ぐため。

### 3.2 `users` コレクション

ユーザーの学習進捗を管理する。

```json
{
  "uid": "string (Firebase Auth UID)",
  "email": "string",
  "display_name": "string",
  "created_at": "timestamp",
  "github_login": "string (GitHubのアカウント名)",
  "installations": ["number (GitHub App の installation ID)"],
  "github_user_token_encrypted": "bytes (Cloud KMSで暗号化したGitHubユーザートークン)",
  "learning_progress": {
    "repository_id_1": {
      "total_answered": "number",
      "correct_count": "number",
      "last_accessed": "timestamp"
    }
  }
}

```

### 3.3 `repository_heads` コレクション

ブランチごとに「最後に確認した状態」を保持する。これがあると、pushがない限りコミットSHAの問い合わせを省ける。

```json
{
  "owner": "string",
  "repo": "string",
  "branch": "string",
  "commit_sha": "string (最後に確認した先頭コミット)",
  "pushed_at": "string (GitHubが返した値をそのまま保持)",
  "checked_at": "timestamp"
}
```

ドキュメントIDは `owner_repo_branch`。解析結果（`repositories`）とは別コレクションにして、更新確認が軽い読み取りだけで済むようにしている。

**Firestore セキュリティルールでは、クライアントからの直接アクセスを全面的に拒否する。** 読み書きはすべてバックエンド（Admin SDK）経由に限定する。これによりフロントエンドはFirestore SDKを持つ必要がなく、`github_user_token_encrypted` のような機微なフィールドがクライアントに露出する経路も存在しなくなる。

---

## 4. APIエンドポイント設計 (Cloud Run)

認証は `Authorization: Bearer <Firebase ID トークン>` で行う。

| メソッド | パス | 認証 | 内容 |
|---|---|---|---|
| POST | `/api/v1/quiz/generate` | **任意** | クイズ生成。認証があればプライベートリポジトリも対象になる |
| GET | `/api/v1/me` | 必須 | アカウント情報とGitHub連携の状態 |
| POST | `/api/v1/github/link` | 必須 | GitHubユーザートークンを預けてインストール一覧を同期 |
| GET | `/api/v1/github/install-url` | 必須 | GitHub App のインストールURLを取得 |
| GET | `/api/v1/github/setup-callback` | — | インストール完了後のGitHubからのリダイレクト受け口 |
| GET | `/api/v1/repositories` | 必須 | アクセスを許可されたリポジトリ一覧 |
| POST | `/api/v1/progress/answer` | 必須 | 1問回答するごとの記録 |
| GET | `/api/v1/progress` | 必須 | 学習履歴の取得 |

### 4.1 クイズ生成・取得API

* **Endpoint**: `/api/v1/quiz/generate`
* **Method**: `POST`
* **認証**: 任意。**Authorizationヘッダがなければ公開リポジトリのみを扱う**（未ログインでの学習を維持するため）
* **Request Body**:
```json
{
  "repository_url": "https://github.com/user/repo",
  "branch": "main",
  "num_questions": 5,
  "focus_language": "python" 
}

```


* **Response Body**: `repositories` コレクションのスキーマに準拠したJSON。
* **エラー**: `400` URL形式不正 / `403` リポジトリを読む権限がない / `404` リポジトリまたはブランチが存在しない / `429` GitHub APIのレートリミット到達
* レスポンスの `cached` は、キャッシュから返したかどうかを示す（動作確認・運用時の切り分け用）

> **`403` と `429` の区別**: GitHubはレートリミットにも権限不足にも `403` を返す。両者を同じ扱いにすると、レートリミットなのに「権限がありません」と誤って案内してしまう。`x-ratelimit-remaining` ヘッダーを見て区別し、レートリミットは `429` と復帰までの目安時間で返している。未認証は60req/hしかないため実際に到達しうる。

---

## 5. AIプロンプト・エンジニアリング & スキーマ設計

Vertex AI への入力プロンプトには、ソースコードの文字列とともに、以下の指示（システムインストラクション）を埋め込む。さらに、出力形式を厳密に制御するために **Structured Outputs (JSON Schema)** を定義する。

### 5.1 システムプロンプト（System Instruction）

```text
あなたは高度なソフトウェアエンジニアリングの教育者です。
提供されたソースコードを深く分析し、このコードの仕様、アルゴリズム、設計パターン、あるいは重要な文法を学習者が理解するための「4択の穴埋めクイズ」を生成してください。

【問題作成のルール】
1. 問題文には穴埋め対象として `[BLANK]` という文字列を含めてください。
2. 関連するコード断片（スニペット）がある場合は、該当箇所を `____` に置き換えて提示してください。
3. 選択肢（choices）は4つとし、うち1つだけが正解（correct_answer）となるようにしてください。
4. 解説（explanation）には、なぜその選択肢が正しいのか、コードの挙動や設計思想に基づいた詳細な説明を記述してください。

```

### 5.2 逆引きドキュメントの設計

ドキュメントは**「何で引くか」の4つの粒度**で索引を作る。同じコードでも、探し方は人によって違うため。

| kind | 何で引くか | 例 |
|---|---|---|
| `feature` | 機能名 | 「認証」「リトライ処理」 |
| `symbol` | 関数・クラス名 | `Context.Next()`、`Session` |
| `task` | やりたいこと | 「新しいエンドポイントを追加するには」 |
| `file` | ファイル名 | `context.go` |

`task` はクイズの `scenario` フィールドと発想が同じ（実務でこのコードに触る場面から入る）で、プロンプトで語彙を揃えている。

**`tags` が検索のヒット率を左右する最重要フィールドである。** 日本語と英語の両方の呼び名・略称・関連語を入れさせている（例: 認証なら `["認証", "ログイン", "サインイン", "auth", "authentication", "login"]`）。これにより「ログイン」と入力しても「認証」のエントリにたどり着ける。

#### 検索の実行場所

**検索はフロントエンド側のインメモリ処理で完結し、サーバー往復は発生しない。** 解析結果と一緒に受け取ったJSONに対して、キー入力のたびに絞り込む。

日本語は空白で分かち書きされないため、形態素解析は行わず**小文字化した部分一致**を基本とする。英数字のみのクエリに限り、追加で空白区切りのトークン一致も見る（「context next」で `Context.Next()` を引けるようにするため）。

スコアリングは `frontend/lib/docs/doc_search.dart` を参照。タイトル完全一致 > 識別子一致 > タイトル部分一致 > タグ > 概要 > 本文 の順に重み付けしている。

### 5.3 出力スキーマ

Structured Outputs で強制する出力スキーマは、`quizzes` を要素とする配列とし、各要素は `file_path` / `question_text` / `code_snippet` / `choices` / `correct_answer` / `explanation` を持つ（`code_snippet` を除く5項目を必須とする）。各項目の意味は「3.1 `repositories` コレクション」のスキーマに準拠する。

実装は `backend/app/quiz_generator.py` を参照。

---

## 6. セキュリティ・運用要件

1. **GitHub APIのレートリミット対策**:
* 公開リポジトリであっても、大量のアクセスに対応するため、Cloud Run側にGitHubの「Personal Access Token」をSecret Manager経由で環境変数として埋め込み、認証付きリクエストを行う。


2. **コスト管理**:
* 「2.4 冗長な処理の排除」を参照。同一リポジトリ・同一コミットへのリクエストは、ユーザーをまたいで解析結果を共有する。


3. **IAM権限の最小化**:
* Cloud Runのサービスアカウントには以下のみを付与する。
  * `roles/aiplatform.user`（Vertex AI）
  * `roles/datastore.user`（Firestore）
  * `roles/cloudkms.cryptoKeyEncrypterDecrypter`（GitHubユーザートークンの暗号化）
  * `roles/secretmanager.secretAccessor`（GitHub App秘密鍵の読み取り）


4. **GitHub App の権限最小化**:
* GitHub App に付与する権限は `Repository permissions > Contents: Read-only` のみとする。ユーザーは学習したいリポジトリだけを個別に選んで許可でき、それ以外のリポジトリは読み取れない。


5. **プライベートコードの取り扱い**:
* プライベートリポジトリのソースコードは、クイズ・ドキュメント生成のため Vertex AI に送信される。リポジトリ選択画面でこの旨をユーザーに明示している。
* **ドキュメントはクイズと違い、コードを穴埋めせず原文のまま引用する。** そのためキャッシュのアクセス権再確認（`visibility: private` の都度確認）はクイズ以上に重要であり、この判定を緩めてはならない。


6. **CORS**:
* 許可オリジンは `FRONTEND_ORIGIN` で指定する。未指定時は開発用に全許可（`*`）となるため、**本番では必ず Firebase Hosting のドメインを設定する**。
