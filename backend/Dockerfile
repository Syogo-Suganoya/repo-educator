FROM python:3.11-slim

WORKDIR /app

# requirements-dev.txt も置いておく（docker-compose の開発コンテナが参照するため）。
# インストールするのは本番用の requirements.txt だけ。
COPY requirements.txt requirements-dev.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

# Cloud Run は起動時に PORT を注入し、そのポートで待ち受けることを要求する
# （既定は8080）。固定すると health check に失敗してデプロイが通らない。
# ローカルは PORT 未設定なので、既定値の8000で従来通り動く。
ENV PORT=8000
EXPOSE 8000

# シェル形式にして ${PORT} を展開する。exec でPID 1を uvicorn に渡し、
# SIGTERM がそのまま届くようにする（Cloud Run の終了処理に必要）。
CMD exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT}
