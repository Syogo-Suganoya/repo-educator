from app.schemas import FeatureSection, Quiz

"""GCP未接続時にデモ用として返すキュレーション済みクイズ。
実際のリポジトリのソースコードを読んで手動で作成しており、Vertex AIによる生成ではない。
リポジトリごとに実務上意味のある「機能セクション」へグルーピングしている。
"""

_REQUESTS_SECTIONS = [
    FeatureSection(
        section_id="requests-response",
        title="レスポンス判定",
        description="ステータスコードから成功/失敗を判定し、例外に変換する処理群。",
        quizzes=[
            Quiz(
                quiz_id="requests-001",
                file_path="src/requests/models.py",
                scenario="APIクライアントに「レスポンスが失敗だったら例外を投げず真偽値で返す」ヘルパーを追加するとき、このプロパティの実装パターンを踏襲することになる。",
                question_text=(
                    "`Response.ok` プロパティは、内部で例外を捕捉して真偽値を返している。"
                    "捕捉している例外クラスは [BLANK] である。"
                ),
                code_snippet=(
                    "@property\n"
                    "def ok(self) -> bool:\n"
                    "    try:\n"
                    "        self.raise_for_status()\n"
                    "    except ____:\n"
                    "        return False\n"
                    "    return True"
                ),
                choices=["HTTPError", "ValueError", "ConnectionError", "Timeout"],
                correct_answer="HTTPError",
                explanation=(
                    "`raise_for_status()` はステータスコードが4xx/5xxの場合に`HTTPError`を送出する。"
                    "`ok`プロパティはこれを`try/except`で捕捉し、送出されれば`False`、"
                    "されなければ`True`を返すことで、例外ベースの`raise_for_status`を真偽値APIとして"
                    "ラップしている設計になっている。"
                ),
            ),
            Quiz(
                quiz_id="requests-002",
                file_path="src/requests/models.py",
                scenario="500番台エラー時のログメッセージを分かりやすく直す修正依頼が来たとき、まずこのエラーメッセージ組み立て処理を読むことになる。",
                question_text=(
                    "`raise_for_status()` は400番台と500番台でエラーメッセージを出し分けている。"
                    "500番台のエラー種別を表す文言は [BLANK] である。"
                ),
                code_snippet=(
                    "if 400 <= self.status_code < 500:\n"
                    "    http_error_msg = f\"{self.status_code} Client Error: ...\"\n"
                    "elif 500 <= self.status_code < 600:\n"
                    "    http_error_msg = f\"{self.status_code} ____ Error: ...\""
                ),
                choices=["Server", "Gateway", "Internal", "Remote"],
                correct_answer="Server",
                explanation=(
                    "HTTPのステータスコード規約では4xxはクライアント起因（Client Error）、"
                    "5xxはサーバー起因（Server Error）のエラーとされる。requestsの実装もこの規約に"
                    "忠実に従い、`status_code`の範囲で文言を分岐させている。"
                ),
            ),
        ],
    ),
    FeatureSection(
        section_id="requests-session",
        title="セッション・リクエスト送信",
        description="Session経由でHTTPメソッドごとのデフォルト挙動を設定する処理群。",
        quizzes=[
            Quiz(
                quiz_id="requests-003",
                file_path="src/requests/sessions.py",
                scenario="新しいHTTPメソッド（例: PATCH用ショートカット）をSessionに追加するとき、既存のget/headのデフォルト値設定パターンを参考にすることになる。",
                question_text=(
                    "`Session.get()` と `Session.head()` はどちらも `allow_redirects` の"
                    "デフォルト値を設定するが、その値は異なる。`head()` 側のデフォルト値は [BLANK] である。"
                ),
                code_snippet=(
                    "def get(self, url, params=None, **kwargs):\n"
                    "    kwargs.setdefault(\"allow_redirects\", True)\n"
                    "    return self.request(\"GET\", url, params=params, **kwargs)\n"
                    "\n"
                    "def head(self, url, **kwargs):\n"
                    "    kwargs.setdefault(\"allow_redirects\", ____)\n"
                    "    return self.request(\"HEAD\", url, **kwargs)"
                ),
                choices=["False", "True", "None", "0"],
                correct_answer="False",
                explanation=(
                    "HEADリクエストはヘッダのみを取得する軽量な確認用途で使われることが多く、"
                    "自動リダイレクト追跡を既定でオフにすることで、意図しない追加リクエストを防いでいる。"
                    "一方GETは自動追跡が既定で有効（`True`）になっており、通常のブラウジング挙動に近い。"
                ),
            ),
        ],
    ),
]

_ALGORITHMS_SECTIONS = [
    FeatureSection(
        section_id="algorithms-sort",
        title="ソートアルゴリズム",
        description="要素の並び替えを行うアルゴリズム群。分割統治や比較条件の境界値を扱う。",
        quizzes=[
            Quiz(
                quiz_id="algorithms-001",
                file_path="sorts/quick_sort.py",
                scenario="クイックソートに安定ソート版を追加する修正をするとき、この比較条件の境界（以下/未満）の扱いを正しく理解している必要がある。",
                question_text=(
                    "このクイックソート実装は、ピボットをリストから取り除いた上で"
                    "残りの要素を2グループに分割している。ピボットとの比較条件として、"
                    "「ピボット以下」のグループに含める条件は [BLANK] である。"
                ),
                code_snippet=(
                    "pivot_index = randrange(len(collection))\n"
                    "pivot = collection.pop(pivot_index)\n"
                    "\n"
                    "lesser = [item for item in collection if item ____ pivot]\n"
                    "greater = [item for item in collection if item > pivot]"
                ),
                choices=["<=", "<", ">=", "=="],
                correct_answer="<=",
                explanation=(
                    "`lesser`にはピボット\"以下\"の要素を集める必要があるため`<=`を使う。"
                    "ここを`<`にすると、ピボットと同値の要素が`lesser`にも`greater`にも入らず"
                    "結果から消えてしまう（安定性・正当性が崩れる）ため、等号を含めることが重要。"
                ),
            ),
            Quiz(
                quiz_id="algorithms-002",
                file_path="sorts/quick_sort.py",
                scenario="再帰関数のバグ調査で無限再帰が起きたとき、まずベースケース（終了条件）が正しいかをここで確認することになる。",
                question_text=(
                    "要素数が0または1のときにソート処理を打ち切る基底条件（ベースケース）は "
                    "[BLANK] である。"
                ),
                code_snippet=(
                    "def quick_sort(collection: list) -> list:\n"
                    "    if len(collection) ____ 2:\n"
                    "        return collection\n"
                    "    ..."
                ),
                choices=["< ", ">", "==", "<="],
                correct_answer="< ",
                explanation=(
                    "要素数が2未満（つまり0または1）のリストは既にソート済みとみなせるため、"
                    "そのまま返して再帰を終了する。`< 2`はこの2パターンを一度にカバーする簡潔な条件。"
                ),
            ),
        ],
    ),
    FeatureSection(
        section_id="algorithms-search",
        title="探索アルゴリズム",
        description="ソート済みデータに対して効率的に目的の値を探す処理群。",
        quizzes=[
            Quiz(
                quiz_id="algorithms-003",
                file_path="searches/binary_search.py",
                scenario="二分探索に「該当なしの場合はNoneではなく挿入位置を返す」機能を追加するとき、探索範囲を縮める左右の更新ロジックを正確に把握しておく必要がある。",
                question_text=(
                    "二分探索において、探索対象が中間値より小さい場合に更新すべき変数は [BLANK] である。"
                ),
                code_snippet=(
                    "midpoint = left + (right - left) // 2\n"
                    "current_item = sorted_collection[midpoint]\n"
                    "if current_item == item:\n"
                    "    return midpoint\n"
                    "elif item < current_item:\n"
                    "    ____ = midpoint - 1\n"
                    "else:\n"
                    "    left = midpoint + 1"
                ),
                choices=["right", "left", "midpoint", "item"],
                correct_answer="right",
                explanation=(
                    "探索対象が中間値より小さい場合、答えは中間値より左側の区間にしかあり得ない。"
                    "そのため探索範囲の右端`right`を`midpoint - 1`に縮めて、次の反復で左半分だけを"
                    "見るようにする。"
                ),
            ),
        ],
    ),
]

_GIN_SECTIONS = [
    FeatureSection(
        section_id="gin-middleware",
        title="ミドルウェアチェーン",
        description="リクエストに対して複数のハンドラを順番に実行・中断する仕組み。",
        quizzes=[
            Quiz(
                quiz_id="gin-001",
                file_path="context.go",
                scenario="認証ミドルウェアを追加してリクエストを検証するとき、後続ハンドラがどう連鎖して呼ばれるかをこのループで理解しておく必要がある。",
                question_text=(
                    "`Context.Next()` はミドルウェアチェーンを1つずつ実行するループだが、"
                    "ループ継続条件は [BLANK] である。"
                ),
                code_snippet=(
                    "func (c *Context) Next() {\n"
                    "\tc.index++\n"
                    "\tfor c.index ____ safeInt8(len(c.handlers)) {\n"
                    "\t\tif c.handlers[c.index] != nil {\n"
                    "\t\t\tc.handlers[c.index](c)\n"
                    "\t\t}\n"
                    "\t\tc.index++\n"
                    "\t}\n"
                    "}"
                ),
                choices=["<", "<=", ">", "!="],
                correct_answer="<",
                explanation=(
                    "`c.index`はハンドラのスライスに対する添字なので、`len(c.handlers)`未満"
                    "（`<`）である間だけ次のハンドラを呼び出す。`<=`にすると範囲外アクセスで"
                    "panicする。"
                ),
            ),
            Quiz(
                quiz_id="gin-002",
                file_path="context.go",
                scenario="認証に失敗したリクエストを即座に403で打ち切る機能を実装するとき、この`Abort()`を呼んで後続ハンドラをスキップさせることになる。",
                question_text=(
                    "`Abort()` は残りのミドルウェア・ハンドラの実行を止めるために `c.index` を"
                    "特別な定数に書き換える。この定数は [BLANK] である。"
                ),
                code_snippet=(
                    "const abortIndex int8 = math.MaxInt8 >> 1\n"
                    "\n"
                    "func (c *Context) Abort() {\n"
                    "\tc.index = ____\n"
                    "}"
                ),
                choices=["abortIndex", "0", "-1", "len(c.handlers)"],
                correct_answer="abortIndex",
                explanation=(
                    "`abortIndex`は`math.MaxInt8 >> 1`という十分に大きな値で、`Next()`のループ条件"
                    "`c.index < len(c.handlers)`を確実に満たさなくする番人（センチネル）値。"
                    "これにより`IsAborted()`も`c.index >= abortIndex`で判定できる。"
                ),
            ),
            Quiz(
                quiz_id="gin-003",
                file_path="context.go",
                scenario="ミドルウェアの単体テストを書くとき、「中断済みかどうか」をどう判定できるかをこのメソッドで確認することになる。",
                question_text=(
                    "`IsAborted()` は現在のコンテキストが中断済みかどうかを判定する。"
                    "その判定式は [BLANK] である。"
                ),
                code_snippet=(
                    "func (c *Context) IsAborted() bool {\n"
                    "\treturn c.index ____ abortIndex\n"
                    "}"
                ),
                choices=[">=", "==", "<", "!="],
                correct_answer=">=",
                explanation=(
                    "`Abort()`が呼ばれると`c.index`は`abortIndex`ちょうどに設定されるが、"
                    "その後さらに`Next()`が呼ばれて`index`が増加する可能性もあるため、"
                    "厳密な`==`ではなく`>=`で「中断値以上になっているか」を判定している。"
                ),
            ),
        ],
    ),
]

SAMPLE_REPOSITORIES: dict[str, list[FeatureSection]] = {
    "psf/requests": _REQUESTS_SECTIONS,
    "TheAlgorithms/Python": _ALGORITHMS_SECTIONS,
    "gin-gonic/gin": _GIN_SECTIONS,
}


def get_sample_sections(owner: str, repo: str) -> list[FeatureSection] | None:
    key = f"{owner}/{repo}"
    return SAMPLE_REPOSITORIES.get(key)
