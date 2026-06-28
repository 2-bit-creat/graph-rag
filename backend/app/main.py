from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from .config import get_settings
from .db import init_db
from .routers import agent, auth, chat, debug, graph, jobs, journal, kg_build, ontology, quiz, subscription, vocabulary

settings = get_settings()
_STATIC_DIR = Path(__file__).resolve().parent.parent / "static"


@asynccontextmanager
async def lifespan(app: FastAPI):
    from .quiz_vocab_bank import ensure_vocab_files
    from .ielts_vocab_bank import ensure_ielts_vocab_file
    from .extraction_queue import start_worker, stop_worker

    settings = get_settings()
    Path(settings.upload_dir).mkdir(parents=True, exist_ok=True)
    Path(settings.debug_runs_dir).mkdir(parents=True, exist_ok=True)
    _STATIC_DIR.mkdir(parents=True, exist_ok=True)
    (_STATIC_DIR / "audio").mkdir(parents=True, exist_ok=True)
    ensure_vocab_files()
    ensure_ielts_vocab_file()
    await init_db()
    start_worker()
    yield
    await stop_worker()


app = FastAPI(title="Graph RAG Language Platform API", version="0.2.0", lifespan=lifespan)

app.mount("/static", StaticFiles(directory=str(_STATIC_DIR)), name="static")

# Flutter web dev server uses random localhost ports — allow all localhost origins in dev.
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origin_list,
    allow_origin_regex=(
        r"http://(localhost|127\.0\.0\.1)(:\d+)?|"
        r"http://192\.168\.\d{1,3}\.\d{1,3}(:\d+)?|"
        r"http://10\.\d{1,3}\.\d{1,3}\.\d{1,3}(:\d+)?"
    ),
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth.router)
app.include_router(journal.router)
app.include_router(quiz.router)
app.include_router(vocabulary.router)
app.include_router(debug.router)
app.include_router(jobs.router)
app.include_router(subscription.router)
app.include_router(chat.router)
app.include_router(graph.router)
app.include_router(graph.v1_router)
app.include_router(kg_build.router)
app.include_router(ontology.router)
app.include_router(agent.router)


@app.get("/health", tags=["health"])
async def health() -> dict[str, str]:
    return {"status": "ok"}
