"""デモ用のキュレーション済み逆引きドキュメント。

sample_quizzes.py と対になる。Gemini未接続でも、実コードを人手で読んで書いた
質の高いドキュメントが返るようにして、GCPなしでも機能をひと通り確認できるようにする。

`related_section_titles` は sample_quizzes.py のセクション名と一致させてあり、
ドキュメントとクイズを相互に行き来できる。
"""

from app.schemas import CodeRef, DocEntry

_REQUESTS_DOCS = [
    DocEntry(
        doc_id="requests-doc-feature-response",
        kind="feature",
        title="レスポンスの成否判定",
        summary="HTTPレスポンスが成功だったかを調べる方法。`ok` と `raise_for_status()` の使い分けを説明します。",
        body=(
            "requests はレスポンスの成否を2通りの方法で表現します。例外を投げる "
            "`raise_for_status()` と、真偽値を返す `ok` プロパティです。\n\n"
            "`ok` は内部で `raise_for_status()` を呼び、`HTTPError` が出たら False を返すという"
            "実装になっています。つまり「例外版が本体で、真偽値版はその薄いラッパー」という関係です。"
            "判定ロジックが1箇所に集約されるため、ステータスコードの解釈を変えたいときも"
            "`raise_for_status()` だけを直せば済みます。\n\n"
            "注意点として、`ok` が True でも通信内容が期待通りとは限りません。"
            "あくまでHTTPステータスコードが 4xx / 5xx でないことを示すだけです。"
        ),
        file_paths=["src/requests/models.py"],
        symbols=["Response.ok", "Response.raise_for_status", "HTTPError"],
        tags=[
            "レスポンス", "判定", "成否", "エラー", "ステータスコード", "例外",
            "response", "ok", "status", "error", "raise_for_status", "http",
        ],
        code_refs=[
            CodeRef(
                file_path="src/requests/models.py",
                snippet=(
                    "@property\n"
                    "def ok(self):\n"
                    "    try:\n"
                    "        self.raise_for_status()\n"
                    "    except HTTPError:\n"
                    "        return False\n"
                    "    return True"
                ),
                note="例外を投げる実装を再利用し、真偽値に変換しているだけの薄いラッパーです。",
            )
        ],
        related_section_titles=["レスポンス判定"],
    ),
    DocEntry(
        doc_id="requests-doc-feature-session",
        kind="feature",
        title="セッションによる接続の再利用",
        summary="`Session` を使うとTCP接続・Cookie・認証情報が複数リクエスト間で共有されます。",
        body=(
            "`requests.get()` のようなトップレベル関数は、呼び出しのたびに新しい `Session` を"
            "作って捨てています。同じホストへ何度もリクエストするなら、`Session` を自分で持つ方が"
            "TCP接続とTLSハンドシェイクを再利用でき、大幅に速くなります。\n\n"
            "`Session` は接続だけでなく、Cookie・認証情報・デフォルトヘッダーも保持します。"
            "ログインが必要なAPIを叩くときは、`Session` を使うことでCookieの引き回しを"
            "自分で書かずに済みます。"
        ),
        file_paths=["src/requests/sessions.py"],
        symbols=["Session", "Session.request", "Session.send"],
        tags=[
            "セッション", "接続", "再利用", "クッキー", "認証", "ヘッダー", "高速化",
            "session", "connection", "cookie", "auth", "keep-alive", "pool",
        ],
        related_section_titles=["セッション・リクエスト送信"],
    ),
    DocEntry(
        doc_id="requests-doc-symbol-ok",
        kind="symbol",
        title="Response.ok",
        summary="レスポンスが 4xx / 5xx でないときに True を返すプロパティ。",
        body=(
            "`raise_for_status()` を try で囲み、`HTTPError` が出なければ True を返します。\n\n"
            "例外を使いたくない場面（分岐で処理を分けたいときなど）で使います。"
            "リダイレクトの 3xx は `HTTPError` にならないため True になる点に注意してください。"
        ),
        file_paths=["src/requests/models.py"],
        symbols=["Response.ok"],
        tags=["ok", "成功", "判定", "真偽値", "bool", "response", "status"],
        related_section_titles=["レスポンス判定"],
    ),
    DocEntry(
        doc_id="requests-doc-task-retry",
        kind="task",
        title="リトライを設定するには",
        summary="`HTTPAdapter` に `urllib3` の `Retry` を渡し、`Session` にマウントします。",
        body=(
            "requests 自体にはリトライ機構がなく、下層の urllib3 の機能を使います。"
            "`Retry` オブジェクトを作って `HTTPAdapter` に渡し、それを `Session.mount()` で"
            "プロトコルごとに登録するという流れです。\n\n"
            "`Session` 単位の設定なので、トップレベルの `requests.get()` では効きません。"
            "リトライが必要なら `Session` を明示的に使う必要があります。"
        ),
        file_paths=["src/requests/adapters.py", "src/requests/sessions.py"],
        symbols=["HTTPAdapter", "Session.mount"],
        tags=[
            "リトライ", "再送", "リトライ設定", "タイムアウト", "アダプタ",
            "retry", "backoff", "adapter", "mount", "resilience",
        ],
        related_section_titles=["セッション・リクエスト送信"],
    ),
    DocEntry(
        doc_id="requests-doc-file-models",
        kind="file",
        title="models.py",
        summary="`Request` / `Response` / `PreparedRequest` といった中心的なデータ構造を定義するファイル。",
        body=(
            "requests のドメインモデルが集まっているファイルです。"
            "ユーザーが書く `Request` を、実際に送信できる形へ変換した `PreparedRequest`、"
            "そして受信結果の `Response` という3段構えになっています。\n\n"
            "レスポンスの中身をどう解釈するか（`json()`、`text`、`content`、`ok`）は"
            "すべてこのファイルにあります。挙動を調べたいときはまずここを見ると早いです。"
        ),
        file_paths=["src/requests/models.py"],
        symbols=["Request", "Response", "PreparedRequest"],
        tags=["models.py", "モデル", "データ構造", "models", "request", "response"],
        related_section_titles=["レスポンス判定"],
    ),
]

_ALGORITHMS_DOCS = [
    DocEntry(
        doc_id="algorithms-doc-feature-sort",
        kind="feature",
        title="ソートアルゴリズム",
        summary="クイックソートをはじめとする各種ソートの実装が `sorts/` にまとまっています。",
        body=(
            "`sorts/` 配下に、アルゴリズムごとに1ファイルという構成で実装が並んでいます。"
            "教材リポジトリなので、性能よりも「アルゴリズムの考え方が読んで分かること」を"
            "優先した書き方になっています。\n\n"
            "クイックソートの実装では、ピボットを基準に「より小さい要素」と「より大きい要素」の"
            "2つのリストへ内包表記で振り分け、それぞれを再帰的にソートして連結します。"
            "その場での入れ替え（in-place）はしないため、実務的なメモリ効率は劣りますが、"
            "分割統治の構造がそのままコードに現れます。"
        ),
        file_paths=["sorts/quick_sort.py", "sorts/merge_sort.py", "sorts/bubble_sort.py"],
        symbols=["quick_sort", "merge_sort"],
        tags=[
            "ソート", "並び替え", "整列", "クイックソート", "マージソート", "分割統治",
            "sort", "sorting", "quicksort", "mergesort", "divide and conquer",
        ],
        code_refs=[
            CodeRef(
                file_path="sorts/quick_sort.py",
                snippet=(
                    "pivot = collection.pop(pivot_index)\n"
                    "greater = [item for item in collection if item > pivot]\n"
                    "lesser = [item for item in collection if item < pivot]\n"
                    "return quick_sort(lesser) + [pivot] + quick_sort(greater)"
                ),
                note="ピボットを基準に2分し、それぞれを再帰的にソートして連結しています。",
            )
        ],
        related_section_titles=["ソートアルゴリズム"],
    ),
    DocEntry(
        doc_id="algorithms-doc-feature-search",
        kind="feature",
        title="探索アルゴリズム",
        summary="二分探索などの探索アルゴリズムが `searches/` にあります。",
        body=(
            "二分探索は、ソート済みのリストに対して探索範囲を半分ずつ狭めていく手法です。"
            "計算量は O(log n) になります。\n\n"
            "実装上のつまずきどころは、探索範囲を表す `low` と `high` の更新です。"
            "中央値と比較した後に `mid + 1` / `mid - 1` と1つずらさないと、"
            "範囲が狭まらず無限ループになります。"
        ),
        file_paths=["searches/binary_search.py"],
        symbols=["binary_search"],
        tags=[
            "探索", "検索", "二分探索", "バイナリサーチ",
            "search", "binary search", "bisect", "lookup",
        ],
        related_section_titles=["探索アルゴリズム"],
    ),
    DocEntry(
        doc_id="algorithms-doc-symbol-quicksort",
        kind="symbol",
        title="quick_sort()",
        summary="リストを受け取り、新しいソート済みリストを返す再帰関数。",
        body=(
            "引数のリストを破壊せず、新しいリストを返します（`pop` は内部のコピーに対して行われます）。\n\n"
            "要素数が1以下なら、それ以上分割できないのでそのまま返します。"
            "これが再帰の終了条件になっています。"
        ),
        file_paths=["sorts/quick_sort.py"],
        symbols=["quick_sort"],
        tags=["quick_sort", "クイックソート", "再帰", "recursive", "sort", "pivot"],
        related_section_titles=["ソートアルゴリズム"],
    ),
    DocEntry(
        doc_id="algorithms-doc-task-add",
        kind="task",
        title="新しいアルゴリズムを追加するには",
        summary="種別ごとのディレクトリに1ファイル1アルゴリズムで追加し、doctest を書きます。",
        body=(
            "このリポジトリは「種別ディレクトリ / アルゴリズム名.py」という構成です。"
            "ソートなら `sorts/`、探索なら `searches/` に置きます。\n\n"
            "各実装には docstring 内に doctest 形式の例を書く慣習があります。"
            "これがそのままテストとして実行されるため、使い方の例と検証を兼ねられます。"
        ),
        file_paths=["sorts/quick_sort.py", "searches/binary_search.py"],
        tags=[
            "追加", "新規", "実装", "貢献", "テスト", "doctest",
            "add", "new", "contribute", "how to", "test",
        ],
    ),
    DocEntry(
        doc_id="algorithms-doc-file-quicksort",
        kind="file",
        title="quick_sort.py",
        summary="クイックソートの実装ファイル。分割統治の流れがそのまま読めます。",
        body=(
            "1ファイルに1アルゴリズムという方針どおり、クイックソートだけが入っています。"
            "docstring の doctest が使用例を兼ねています。"
        ),
        file_paths=["sorts/quick_sort.py"],
        symbols=["quick_sort"],
        tags=["quick_sort.py", "ファイル", "file", "sort", "ソート"],
        related_section_titles=["ソートアルゴリズム"],
    ),
]

_GIN_DOCS = [
    DocEntry(
        doc_id="gin-doc-feature-middleware",
        kind="feature",
        title="ミドルウェアチェーン",
        summary="`Context` がハンドラの配列とインデックスを持ち、`Next()` で連鎖を進めます。",
        body=(
            "gin のミドルウェアは、`Context` が保持するハンドラのスライス `c.handlers` と、"
            "現在位置を指す `c.index` によって実現されています。\n\n"
            "`Next()` はインデックスを1つ進めてから、残りのハンドラを順に呼び出します。"
            "ミドルウェアの中で `Next()` を呼ぶと、そこで後続の処理へ制御が移り、"
            "戻ってきたときに `Next()` 以降のコードが動きます。"
            "これによって「前処理 / 後処理」を1つの関数の中に自然に書けます。\n\n"
            "`Abort()` を呼ぶとインデックスが `abortIndex` に設定され、"
            "以降のハンドラは実行されなくなります。認証ミドルウェアで"
            "認証失敗時に後続を止めるのがこの仕組みです。"
        ),
        file_paths=["context.go", "gin.go"],
        symbols=["Context.Next", "Context.Abort", "Context.IsAborted", "HandlersChain"],
        tags=[
            "ミドルウェア", "チェーン", "連鎖", "前処理", "後処理", "中断", "認証",
            "middleware", "chain", "next", "abort", "handler", "interceptor",
        ],
        code_refs=[
            CodeRef(
                file_path="context.go",
                snippet=(
                    "func (c *Context) Next() {\n"
                    "\tc.index++\n"
                    "\tfor c.index < int8(len(c.handlers)) {\n"
                    "\t\tc.handlers[c.index](c)\n"
                    "\t\tc.index++\n"
                    "\t}\n"
                    "}"
                ),
                note="インデックスを進めながら、残りのハンドラを順に呼び出しています。",
            )
        ],
        related_section_titles=["ミドルウェアチェーン"],
    ),
    DocEntry(
        doc_id="gin-doc-symbol-next",
        kind="symbol",
        title="Context.Next()",
        summary="後続のミドルウェア・ハンドラを実行する。ミドルウェア内でのみ呼ぶ想定。",
        body=(
            "`c.index` を1つ進めてから、ハンドラ列の終端まで順に呼び出します。\n\n"
            "ミドルウェアの中でこれを呼ぶと、呼び出し位置で後続処理が実行され、"
            "戻ってきたときに残りのコードが動きます。"
            "ログ出力や実行時間の計測は、この性質を使って `Next()` の前後に書きます。"
        ),
        file_paths=["context.go"],
        symbols=["Context.Next"],
        tags=["Next", "次", "後続", "ミドルウェア", "next", "middleware", "chain"],
        related_section_titles=["ミドルウェアチェーン"],
    ),
    DocEntry(
        doc_id="gin-doc-symbol-isaborted",
        kind="symbol",
        title="Context.IsAborted()",
        summary="`c.index >= abortIndex` で、チェーンが中断済みかを判定します。",
        body=(
            "`Abort()` を呼ぶと `c.index` は `abortIndex` に設定されますが、"
            "その後さらに `Next()` が呼ばれてインデックスが増える可能性があります。\n\n"
            "そのため厳密な `==` ではなく `>=` で「中断値以上になっているか」を見ています。"
            "ミドルウェアのテストを書くときは、この関数で中断されたかを確認できます。"
        ),
        file_paths=["context.go"],
        symbols=["Context.IsAborted", "Context.Abort"],
        tags=["IsAborted", "中断", "abort", "aborted", "停止", "middleware"],
        related_section_titles=["ミドルウェアチェーン"],
    ),
    DocEntry(
        doc_id="gin-doc-task-middleware",
        kind="task",
        title="独自のミドルウェアを追加するには",
        summary="`gin.HandlerFunc` を返す関数を書き、`Use()` で登録します。",
        body=(
            "ミドルウェアの実体は `func(*gin.Context)` です。"
            "設定値を渡したい場合は、その関数を返す高階関数として書くのが慣習です。\n\n"
            "前処理は `c.Next()` より前に、後処理は後ろに書きます。"
            "後続を止めたい場合は `c.Next()` を呼ばずに `c.Abort()` または "
            "`c.AbortWithStatus()` を使ってください。"
            "`Abort()` を呼ばずに return しただけでは、後続のハンドラが実行されてしまいます。"
        ),
        file_paths=["gin.go", "context.go"],
        symbols=["Engine.Use", "HandlerFunc", "Context.Abort"],
        tags=[
            "ミドルウェア", "追加", "自作", "認証", "ログ", "登録",
            "middleware", "add", "custom", "use", "how to", "auth",
        ],
        related_section_titles=["ミドルウェアチェーン"],
    ),
    DocEntry(
        doc_id="gin-doc-file-context",
        kind="file",
        title="context.go",
        summary="リクエスト単位の状態を持つ `Context` の定義。gin で最もよく読むファイル。",
        body=(
            "1リクエストの処理中に持ち回される `Context` が定義されています。"
            "ハンドラチェーンの制御（`Next` / `Abort`）、パラメータの取得、"
            "レスポンスの書き出し（`JSON` / `String` など）がすべてここにあります。\n\n"
            "gin の挙動で分からないことがあったとき、最初に開くべきファイルです。"
        ),
        file_paths=["context.go"],
        symbols=["Context", "Context.Next", "Context.Abort", "Context.JSON"],
        tags=["context.go", "コンテキスト", "context", "ファイル", "file", "request"],
        related_section_titles=["ミドルウェアチェーン"],
    ),
]

SAMPLE_DOCS: dict[str, list[DocEntry]] = {
    "psf/requests": _REQUESTS_DOCS,
    "TheAlgorithms/Python": _ALGORITHMS_DOCS,
    "gin-gonic/gin": _GIN_DOCS,
}


def get_sample_docs(owner: str, repo: str) -> list[DocEntry] | None:
    return SAMPLE_DOCS.get(f"{owner}/{repo}")
