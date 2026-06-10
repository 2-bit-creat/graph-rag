"""AWS Lambda entrypoint.

Wraps the FastAPI ASGI app with Mangum so it can run behind API Gateway.
Used only in deployment; local dev still runs `uvicorn app.main:app`.
"""

from mangum import Mangum

from app.main import app

handler = Mangum(app, lifespan="auto")
