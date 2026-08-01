FROM python:3.11-slim

WORKDIR /app

# requirements-dev.txt も置いておく（docker-compose の開発コンテナが参照するため）。
# インストールするのは本番用の requirements.txt だけ。
COPY requirements.txt requirements-dev.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
