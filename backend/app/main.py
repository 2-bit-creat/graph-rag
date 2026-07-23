from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from .config import get_settings
from .db import init_db
from .routers import auth, debug, graph, graph_chat, graph_chat_distill, jobs, journal, kg_build, legal, ontology, quiz, tutor, vocabulary

settings = get_settings()
_STATIC_DIR = Path(__file__).resolve().parent.parent / "static"


@asynccontextmanager
async def lifespan(app: FastAPI):
    from .extraction_queue import start_worker, stop_worker

    settings = get_settings()
    if settings.is_production and settings.jwt_secret_is_insecure:
        raise RuntimeError(
            "Refusing to start in production with an insecure JWT_SECRET. "
            "Set a strong, random JWT_SECRET in the environment."
        )
    if settings.is_production and settings.db_credentials_are_insecure:
        raise RuntimeError(
            "Refusing to start in production with the default database "
            "credentials. Set DATABASE_URL to a managed database with unique "
            "credentials."
        )
    if not settings.s3_bucket:
        # Local/dev only — on Lambda this directory doesn't persist across
        # invocations, so S3_BUCKET must be set in any deployed environment
        # (quiz TTS and audio uploads both switch to S3 when it is).
        Path(settings.upload_dir).mkdir(parents=True, exist_ok=True)
        _STATIC_DIR.mkdir(parents=True, exist_ok=True)
        (_STATIC_DIR / "audio").mkdir(parents=True, exist_ok=True)
    if settings.debug_enabled:
        # Off by default in production (see Settings.debug_enabled) — and must
        # stay off on Lambda regardless, since /var/task is read-only and this
        # writes raw prompts/transcripts/audio that pipeline_trace.py and the
        # debug router already gate on this same flag before touching disk.
        Path(settings.debug_runs_dir).mkdir(parents=True, exist_ok=True)
        from .pipeline_trace import cleanup_old_debug_runs

        cleanup_old_debug_runs(settings.debug_runs_retention_days)

    await init_db()
    if settings.expression_extraction_enabled:
        start_worker()
    yield
    await stop_worker()


app = FastAPI(title="Graph RAG Language Platform API", version="0.2.0", lifespan=lifespan)

if not settings.s3_bucket:
    # Local/dev static serving only — Lambda's filesystem doesn't persist
    # writes, so deployed environments must set S3_BUCKET (+ MEDIA_BASE_URL)
    # and serve quiz audio / uploads from S3/CloudFront instead.
    _STATIC_DIR.mkdir(parents=True, exist_ok=True)
    app.mount("/static", StaticFiles(directory=str(_STATIC_DIR)), name="static")

_cors_kwargs: dict = {
    "allow_origins": settings.cors_origin_list,
    "allow_credentials": True,
    "allow_methods": ["*"],
    "allow_headers": ["*"],
}
if not settings.is_production:
    # Flutter web dev server uses random localhost ports, and physical-device
    # testing hits the host over LAN Wi-Fi — allow localhost + private ranges in
    # development only. In production the explicit CORS_ORIGINS whitelist is the
    # sole allowed set (no wildcard, no LAN).
    _cors_kwargs["allow_origin_regex"] = (
        r"http://(localhost|127\.0\.0\.1)(:\d+)?|"
        r"http://192\.168\.\d{1,3}\.\d{1,3}(:\d+)?|"
        r"http://10\.\d{1,3}\.\d{1,3}\.\d{1,3}(:\d+)?"
    )
app.add_middleware(CORSMiddleware, **_cors_kwargs)

app.include_router(auth.router)
app.include_router(journal.router)
app.include_router(quiz.router)
app.include_router(vocabulary.router)
app.include_router(debug.router)
app.include_router(jobs.router)
app.include_router(tutor.router)
app.include_router(graph_chat.router)
app.include_router(graph_chat_distill.router)
app.include_router(graph.router)
app.include_router(graph.v1_router)
app.include_router(kg_build.router)
app.include_router(ontology.router)
app.include_router(legal.router)


@app.get("/health", tags=["health"])
async def health() -> dict[str, str]:
    return {"status": "ok"}
