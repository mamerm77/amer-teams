FROM python:3.12-slim
RUN pip install --no-cache-dir fastapi==0.115.6 uvicorn==0.34.0 httpx==0.28.1 cryptography==44.0.0
COPY enclave.py /app/enclave.py
WORKDIR /app
# no content is ever logged; access logs off so not even URLs with ids appear
CMD ["uvicorn", "enclave:app", "--host", "0.0.0.0", "--port", "8090", "--no-access-log"]
