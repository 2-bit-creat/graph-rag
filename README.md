# Graph RAG — Conversational Knowledge Graph (Local MVP)

A local-first app that turns a chat conversation into a personal knowledge graph
and answers follow-up questions with Graph RAG.

- **Frontend:** Next.js 14 (App Router), TypeScript, Tailwind CSS, Shadcn UI, Zustand, `@xyflow/react`
- **Backend:** Python (FastAPI), async SQLAlchemy
- **Database:** PostgreSQL via Docker Compose (schema is Supabase-compatible)
- **AI:** LlamaIndex (`PropertyGraphIndex` / `DynamicLLMPathExtractor`) + OpenAI `gpt-4o-mini`

## How it works

```
You chat ─▶ FastAPI ─▶ LlamaIndex extracts (entity)-[relation]->(entity) triples
                        │
                        ├─▶ upsert into Postgres  nodes / edges  (source of truth)
                        └─▶ Graph RAG: fetch neighborhood ─▶ gpt-4o-mini answer
React Flow graph ◀── GET /graph (live refresh after every turn)
```

## Project structure

```
.
├── docker-compose.yml          # Local Postgres (volume: ./pgdata, port 5432)
├── backend/
│   ├── requirements.txt
│   ├── .env.example
│   └── app/
│       ├── main.py             # FastAPI app + CORS + lifespan(init_db)
│       ├── config.py           # pydantic-settings (.env)
│       ├── db.py               # async SQLAlchemy engine/session
│       ├── models.py           # Node, Edge ORM models
│       ├── schemas.py          # pydantic request/response models
│       ├── crud.py             # upsert triples, graph queries
│       ├── graph_extractor.py  # LlamaIndex triple extraction
│       ├── rag.py              # Graph RAG retrieval + answer
│       └── routers/
│           ├── chat.py         # POST /chat
│           └── graph.py        # GET /graph, POST /graph/edges, DELETE /graph/nodes/{id}
└── frontend/
    ├── app/                    # layout.tsx, page.tsx (split chat | graph), globals.css
    ├── components/             # Chat.tsx, GraphView.tsx, ui/ (shadcn)
    └── lib/                    # store.ts (zustand), api.ts, utils.ts
```

## Prerequisites

- Docker Desktop
- Python 3.11+
- Node.js 18.17+ (20+ recommended)
- An OpenAI API key

## 1. Start the database

```bash
docker compose up -d
```

This launches Postgres on `localhost:5432` (user/password/db all `graphrag`) and
persists data to `./pgdata`.

## 2. Run the backend

```bash
cd backend
python -m venv .venv
# Windows PowerShell:
.venv\Scripts\Activate.ps1
# macOS/Linux:
# source .venv/bin/activate

pip install -r requirements.txt
copy .env.example .env        # macOS/Linux: cp .env.example .env
# edit .env and set OPENAI_API_KEY

uvicorn app.main:app --reload --port 8000
```

API docs: http://localhost:8000/docs · Health: http://localhost:8000/health

## 3. Run the frontend

```bash
cd frontend
npm install
copy .env.local.example .env.local   # macOS/Linux: cp .env.local.example .env.local
npm run dev
```

Open http://localhost:3000. Chat on the left builds the graph on the right.
Drag nodes, connect them (drag handle to handle) to create edges, and press
`Backspace`/`Delete` on a selected node to remove it.

## Switching to Supabase later

The schema is already Supabase-compatible. Create a Supabase project, then set
`DATABASE_URL` in `backend/.env` to the pooled connection string (keep the
`+asyncpg` driver), e.g.:

```
DATABASE_URL=postgresql+asyncpg://postgres.<ref>:<password>@aws-0-<region>.pooler.supabase.com:6543/postgres
```

## Deployment (AWS Lambda + API Gateway, Amplify Hosting)

Architecture: **backend** runs as a container-image Lambda behind an API Gateway
HTTP API (defined in `template.yaml`); **frontend** is hosted on AWS Amplify
Hosting with Git-based CI/CD (`amplify.yml`).

> The backend is packaged as a **container image** because the AI dependencies
> (LlamaIndex, OpenAI, asyncpg) exceed Lambda's 250 MB zip limit.

### Prerequisites

- AWS CLI configured with the `my-ai-app` profile
- AWS SAM CLI
- Docker running locally (SAM builds the image)
- A managed Postgres (Supabase/RDS) — Lambda is stateless, so local Postgres
  won't work in the cloud

### Configure the AWS CLI profile

```bash
aws configure --profile my-ai-app
# AWS Access Key ID / Secret / region (ap-northeast-2) / output json
aws sts get-caller-identity --profile my-ai-app
```

### Backend → AWS Lambda + API Gateway (SAM)

Files: `template.yaml` (SAM), `samconfig.toml` (region/profile),
`backend/Dockerfile`, `backend/lambda_handler.py` (`Mangum(app)` adapter).

```bash
sam build
sam deploy --guided \
  --parameter-overrides \
    DatabaseUrl="postgresql+asyncpg://<supabase-pooled-url>" \
    OpenAiApiKey="sk-..." \
    CorsOrigins="https://<branch>.<app-id>.amplifyapp.com"
```

`samconfig.toml` already pins `region = ap-northeast-2` and
`profile = my-ai-app`, and uses `resolve_image_repos = true` so SAM creates the
ECR repository automatically. After deploy, copy the `ApiUrl` output.

Secrets (`DatabaseUrl`, `OpenAiApiKey`) are passed at deploy time and stored as
Lambda env vars — never commit them.

### Frontend → AWS Amplify Hosting (Git-connected)

The frontend is hosted on **Amplify Hosting** with Git-based CI/CD. The monorepo
build spec lives in `amplify.yml` (`appRoot: frontend`).

1. Push this repo to GitHub.
2. Amplify console -> **Create new app** -> connect the GitHub repo + branch
   (`main`). Amplify auto-detects Next.js SSR and the monorepo `amplify.yml`.
3. Set the environment variable `NEXT_PUBLIC_API_BASE_URL` to the SAM `ApiUrl`
   output (build-time variable; required for `NEXT_PUBLIC_*`).
4. Save and deploy. Pushes to `main` auto-deploy; each branch gets its own URL.
5. Set the backend's `CorsOrigins` to your `*.amplifyapp.com` domain and re-run
   `sam deploy`.

### Architecture summary

- **Frontend:** AWS Amplify Hosting (Git CI/CD, Next.js SSR)
- **Backend:** AWS Lambda (container image) + API Gateway HTTP API, via SAM
- **DB:** managed Postgres (Supabase/RDS) in the cloud; docker-compose locally

> Note: this is a hybrid setup. Amplify is used for **frontend hosting only** —
> the backend stays Python/FastAPI on Lambda, and the data store is Postgres
> (not DynamoDB), which fits the LlamaIndex graph + multi-hop Graph RAG.
