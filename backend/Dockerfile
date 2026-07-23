# Lambda container image (heavy deps like llama-index exceed the zip size limit).
# x86_64 (not arm64/Graviton): this repo's Docker Desktop build environment hits
# a containerd content-store export bug ("content digest ... not found") on
# every emulated linux/arm64 build — confirmed by a side-by-side native-arch
# build succeeding cleanly. Graviton would save ~20% on compute, but isn't
# worth an unreliable local build pipeline; revisit once building on real arm64
# hardware (e.g. CodeBuild) is set up.
FROM public.ecr.aws/lambda/python:3.12

COPY requirements.txt ${LAMBDA_TASK_ROOT}/
RUN pip install --no-cache-dir -r requirements.txt

COPY app ${LAMBDA_TASK_ROOT}/app
COPY lambda_handler.py ${LAMBDA_TASK_ROOT}/

CMD ["lambda_handler.handler"]
