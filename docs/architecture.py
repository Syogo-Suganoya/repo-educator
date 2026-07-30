"""アーキテクチャ図の生成スクリプト。

README.md「2. システムアーキテクチャ」の構成を diagrams で図示する。

実行:
    /Library/Developer/CommandLineTools/usr/bin/python3 docs/architecture.py

出力: docs/architecture.png（要 graphviz: `brew install graphviz`）
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.firebase.develop import Authentication, Hosting
from diagrams.gcp.compute import Run
from diagrams.gcp.database import Firestore
from diagrams.gcp.ml import VertexAI
from diagrams.gcp.security import SecretManager
from diagrams.onprem.client import Users
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

    with Cluster("Firebase"):
        hosting = Hosting("Firebase Hosting")
        frontend = Flutter("Flutter Web\n(クイズUI / 履歴)")
        auth = Authentication("Authentication\n(サインイン)")
        firestore = Firestore("Cloud Firestore\nクイズキャッシュ / 学習進捗")

        hosting >> Edge(label="配信") >> frontend
        frontend >> Edge(label="(2) 認証") >> auth
        frontend >> Edge(label="進捗同期") >> firestore

    with Cluster("Google Cloud"):
        backend = Run("Cloud Run\nPython / FastAPI\nPOST /api/v1/quiz/generate")
        vertex = VertexAI("Vertex AI\ngemini-1.5-flash\nStructured Outputs")
        secret = SecretManager("Secret Manager\nGITHUB_TOKEN")

        backend >> Edge(label="(4) プロンプト構築") >> vertex
        vertex >> Edge(label="(5) 構造化JSON", style="dashed") >> backend
        backend >> Edge(label="PAT参照", style="dotted") >> secret
        backend >> Edge(label="キャッシュ読み書き", style="dashed") >> firestore

    github = Github("GitHub API\nソースコード取得")

    users >> Edge(label="(1) リポジトリURL入力 / 回答") >> hosting
    frontend >> Edge(label="HTTPS / JSON") >> backend
    backend >> Edge(label="(3) リポジトリ取得") >> github
