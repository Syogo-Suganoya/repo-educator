# システム基本設計書：GitHubリポジトリ自動解析・AI学習クイズ生成サービス

## 1. システム概要
本システムは、ユーザーが指定したGitHubリポジトリ（またはソースコード群）を自動で解析し、そのコードの重要な概念、アルゴリズム、アーキテクチャ、言語仕様に関する「穴埋め問題（クイズ）」および詳細な解説を自動生成する学習支援プラットフォームである。

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
   * Vertex AI SDK経由でGeminiモデルを呼び出し、構造化データ（JSON）としてクイズを取得・パース。
3. **Database & Auth (Firebase)**:
   * **Firebase Authentication**: ユーザーのサインイン・アカウント管理。
   * **Cloud Firestore**: 生成されたクイズデータ（キャッシュ用）およびユーザーごとの解答履歴、正解率、苦手分野の保存。
4. **AI Engine (Vertex AI)**:
   * `gemini-1.5-flash`（または`gemini-1.5-pro`）を使用。Structured Outputs（スキーマ定義によるJSON強制出力）を利用し、アプリケーション側でパースしやすい形式でクイズを生成。

---

## 3. データモデル設計 (Firestore)

### 3.1 `repositories` コレクション
リポジトリごとのクイズデータをキャッシュし、2回目以降のアクセスを高速化する。
```json
{
  "repository_id": "string (owner_repo_branch)",
  "url": "string",
  "analyzed_at": "timestamp",
  "quizzes": [
    {
      "quiz_id": "string (UUID)",
      "file_path": "string (対象となったソースコードのパス)",
      "question_text": "string (穴埋め用のプレースホルダー [BLANK] を含むテキスト)",
      "code_snippet": "string (関連するコード断片。穴埋め箇所は ___ 表現)",
      "choices": ["string", "string", "string", "string"],
      "correct_answer": "string",
      "explanation": "string (なぜその答えになるのか、コードのどの部分に依存しているかの解説)"
    }
  ]
}

```

### 3.2 `users` コレクション

ユーザーの学習進捗を管理する。

```json
{
  "uid": "string (Firebase Auth UID)",
  "email": "string",
  "created_at": "timestamp",
  "learning_progress": {
    "repository_id_1": {
      "total_answered": "number",
      "correct_count": "number",
      "last_accessed": "timestamp"
    }
  }
}

```

---

## 4. APIエンドポイント設計 (Cloud Run)

### 4.1 クイズ生成・取得API

* **Endpoint**: `/api/v1/quiz/generate`
* **Method**: `POST`
* **Request Body**:
```json
{
  "repository_url": "[https://github.com/user/repo](https://github.com/user/repo)",
  "branch": "main",
  "num_questions": 5,
  "focus_language": "python" 
}

```


* **Response Body**: `repositories` コレクションのスキーマに準拠したJSON。

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

### 5.2 出力スキーマ

Structured Outputs で強制する出力スキーマは、`quizzes` を要素とする配列とし、各要素は `file_path` / `question_text` / `code_snippet` / `choices` / `correct_answer` / `explanation` を持つ（`code_snippet` を除く5項目を必須とする）。各項目の意味は「3.1 `repositories` コレクション」のスキーマに準拠する。

実装は `backend/app/quiz_generator.py` を参照。

---

## 6. セキュリティ・運用要件

1. **GitHub APIのレートリミット対策**:
* 公開リポジトリであっても、大量のアクセスに対応するため、Cloud Run側にGitHubの「Personal Access Token」をSecret Manager経由で環境変数として埋め込み、認証付きリクエストを行う。


2. **コスト管理**:
* GeminiのAPI料金を抑制するため、同一リポジトリ・同一コミットハッシュに対するリクエストは、Firestoreにキャッシュされたデータを優先して返却する。


3. **IAM権限の最小化**:
* Cloud Runのサービスアカウントには `roles/aiplatform.user`（Vertex AIユーザー）および `roles/datastore.user`（Firestoreユーザー）のみを付与する。
