"""アーキテクチャ図の生成スクリプト。

README.md「2. システムアーキテクチャ」の構成を diagrams で図示する。

実行:
    /Library/Developer/CommandLineTools/usr/bin/python3 docs/architecture.py

出力: docs/architecture.png（要 graphviz: `brew install graphviz`）
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.firebase.develop import Hosting
from diagrams.gcp.compute import Run
from diagrams.gcp.ml import AIPlatform
from diagrams.gcp.security import SecretManager
from diagrams.onprem.client import Users
from diagrams.onprem.database import PostgreSQL
from diagrams.onprem.vcs import Github
from diagrams.programming.framework import Flutter

GRAPH_ATTR = {
    "fontsize": "20",
    "bgcolor": "white",
    "splines": "spline",
    "pad": "0.5",
    "nodesep": "0.7",
    "ranksep": "1.1",
}

with Diagram(
    "repo-educator アーキテクチャ",
    filename="docs/architecture",
    outformat="png",
    show=False,
    direction="LR",
    graph_attr=GRAPH_ATTR,
):
    users = Users("ユーザー")
    hosting = Hosting("静的ホスティング")
    frontend = Flutter("Flutter Web\nクイズ / ドキュメント / 質問")

    with Cluster("Google Cloud"):
        backend = Run("Cloud Run\nPython / FastAPI\nJWT認証・解析API")
        secret = SecretManager(
            "Secret Manager\nGITHUB_TOKEN\nGEMINI_API_KEY\nJWT_SECRET"
        )

    # ログイン・学習履歴・解析結果キャッシュの保存先。
    # Neon等のマネージドPostgresでも自前ホストでも、接続文字列を変えるだけで動く。
    db = PostgreSQL("PostgreSQL\nユーザー / 学習履歴\n解析結果キャッシュ")
    gemini = AIPlatform(
        "Gemini Developer API\ngemini-3.5-flash\nAPIキー認証・Structured Outputs"
    )
    github = Github("GitHub API\nソースコード取得")

    # ラベルが意図した線に沿うよう、ノードを出し切ってからエッジをまとめて引く。
    users >> Edge(label="(1) リポジトリURL入力 / 回答") >> hosting
    hosting >> Edge(label="配信") >> frontend
    frontend >> Edge(label="(2) HTTPS / JSON") >> backend

    backend >> Edge(label="シークレット参照", style="dotted") >> secret
    backend >> Edge(label="(3) リポジトリ取得") >> github
    backend >> Edge(label="(4) プロンプト構築") >> gemini
    gemini >> Edge(label="(5) 構造化JSON", style="dashed") >> backend
    backend >> Edge(label="キャッシュ / 履歴の読み書き", style="dashed") >> db
