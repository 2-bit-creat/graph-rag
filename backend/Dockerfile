# Lambda container image (heavy deps like llama-index exceed the zip size limit).
# arm64/Graviton — cheaper per ms than x86_64; must match template.yaml's
# Globals.Function.Architectures. `sam build` passes the matching --platform
# automatically, but the tag is pinned here too for plain `docker build` runs.
FROM --platform=linux/arm64 public.ecr.aws/lambda/python:3.12

COPY requirements.txt ${LAMBDA_TASK_ROOT}/
RUN pip install --no-cache-dir -r requirements.txt

COPY app ${LAMBDA_TASK_ROOT}/app
COPY lambda_handler.py ${LAMBDA_TASK_ROOT}/

CMD ["lambda_handler.handler"]
