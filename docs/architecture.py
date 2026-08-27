"""アーキテクチャ図の生成スクリプト。

README.md「2. システムアーキテクチャ」の構成を diagrams で図示する。

実行:
    /Library/Developer/CommandLineTools/usr/bin/python3 docs/architecture.py

出力: docs/architecture.png（要 graphviz: `brew install graphviz`）
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.gcp.ml import AIPlatform
from diagrams.gcp.security import SecretManager
from diagrams.onprem.client import Users
from diagrams.onprem.database import PostgreSQL
from diagrams.onprem.vcs import Github
from diagrams.programming.framework import Flutter
from diagrams.programming.language import Python

FONT = "Hiragino Sans"

# アクセントは紫みのインディゴ。アプリの主色（theme.dart の AppPalette.accent）に合わせる
ACCENT = "#4B3FDB"

graph_attr = {
    "fontname": FONT,
    "fontsize": "20",
    "labelloc": "t",
    "bgcolor": "white",
    "pad": "0.5",
    "nodesep": "0.8",
    "ranksep": "1.5",
    "splines": "spline",
}
node_attr = {"fontname": FONT, "fontsize": "13"}
edge_attr = {"fontname": FONT, "fontsize": "11"}
cluster_attr = {"fontname": FONT, "fontsize": "13", "style": "rounded", "penwidth": "1.6"}

with Diagram(
    "repo-educator — 技術スタック",
    filename="docs/architecture",
    outformat="png",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
    node_attr=node_attr,
    edge_attr=edge_attr,
):
    user = Users("ブラウザ")

    frontend = Flutter("Flutter Web\nクイズ / ドキュメント / 質問")

    with Cluster("Cloud Run", graph_attr=cluster_attr):
        backend = Python("FastAPI\nJWT認証・解析API")
        secret = SecretManager("Secret Manager\nAPIキー / 署名鍵")

    # 解析結果と学習履歴の置き場。Neon等のマネージドでも自前ホストでも動く。
    db = PostgreSQL("PostgreSQL\nユーザー / 学習履歴\n解析結果キャッシュ")

    with Cluster("外部サービス", graph_attr=cluster_attr):
        github = Github("GitHub API\nソースコード取得")
        gemini = AIPlatform("Gemini Developer API\ngemini-3.5-flash\nStructured Outputs")

    # --- 主経路。リポジトリURLを渡してからクイズが返るまで ---
    user >> Edge(color=ACCENT, penwidth="2.0") >> frontend
    frontend >> Edge(color=ACCENT, penwidth="2.0", label="HTTPS / JSON") >> backend
    backend >> Edge(color=ACCENT, label="ソース取得") >> github
    backend >> Edge(color=ACCENT, label="プロンプト構築") >> gemini
    gemini >> Edge(color=ACCENT, style="dashed", label="構造化JSON") >> backend

    # --- 補助経路。点線で「毎回は通らない・脇に置く」ことを示す ---
    backend >> Edge(style="dashed", label="キャッシュ / 履歴") >> db
    backend >> Edge(style="dotted", label="起動時に読む") >> secret
