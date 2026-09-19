# Veda

**Live site:** [veda-utils.vercel.app](https://veda-utils.vercel.app)

Veda is a leaderboard and player statistics tracker for the Minecraft server [Monumenta](https://playmonumenta.com/). It collects in-game leaderboard data, stores snapshots in a database, and exposes that data through a REST API, a web UI, and a Discord bot.

---

## Overview

```
veda/
├── veda-frontend/   React + TypeScript web app (Vercel)
├── veda-backend/    FastAPI REST API (Python)
├── veda-bot/        Discord bot (Discord.js / TypeScript)
├── veda-scraper/    Minecraft Fabric mod that scrapes leaderboard data
└── docker-compose.yml
```

### How it fits together

```mermaid
flowchart LR
    subgraph GAME["Minecraft"]
        MC["Minecraft Server"]
    end

    subgraph DATA["Data Collection"]
        SCR["veda-scraper"]
    end

    subgraph BACKEND["Backend"]
        API["veda-backend"]
        PG[("PostgreSQL")]
        REDIS[("Redis")]
    end

    subgraph CLIENTS["Clients"]
        FE["veda-frontend"]
        BOT["veda-bot"]
    end

    MC --> SCR
    SCR -->|"POST /api/v1/leaderboards/snapshot"| API

    API <--> PG
    API <--> REDIS

    FE -->|"REST API"| API
    BOT -->|"REST API"| API
```

The scraper is a headless Fabric mod that logs into Monumenta, reads leaderboard chat messages, and POSTs the collected data to the backend. The backend stores snapshots and player records in PostgreSQL, caches player responses in Redis, and serves a read-only JSON API. The frontend and Discord bot both consume that public API.

---

## Components

### `veda-frontend`

| | |
|---|---|
| **URL** | https://veda-utils.vercel.app |
| **Stack** | React 19, TypeScript, Vite 8, React Router 7, Axios, Tailwind CSS 4 |
| **Runtime** | Node.js 20+ / modern browsers |

**Routes**

| Path | Page |
|---|---|
| `/` | Home |
| `/leaderboards` | Leaderboard viewer (select by name, paginated entries) |
| `/players` | Player search |
| `/players/:playerName` | Player profile (rankings + playtime) |

**Development**

```bash
cd veda-frontend
npm install
npm run dev        # Vite dev server
npm run lint       # Oxlint
npm run build      # tsc -b && vite build
npm run preview    # serve the production build
```

**Environment variable** — create `veda-frontend/.env`:

```env
VITE_API_URL=http://localhost:8000
```

---

### `veda-backend`

| | |
|---|---|
| **Stack** | Python 3.14+, FastAPI, SQLAlchemy (async), Alembic, PostgreSQL, Redis |
| **Base path** | `/api/v1` |

**Endpoints**

| Method | Path | Auth | Description |
|---|---|---|---|
| `GET` | `/api/v1/leaderboards` | — | List all leaderboards |
| `GET` | `/api/v1/leaderboards/weight` | — | Global weight leaderboard (all players, ranked) |
| `GET` | `/api/v1/leaderboards/{name}` | — | Latest snapshot for a leaderboard |
| `POST` | `/api/v1/leaderboards/snapshot` | Bearer secret | Ingest new snapshots (scraper use only) |
| `GET` | `/api/v1/players/` | — | List all player names |
| `GET` | `/api/v1/players/{name}` | — | Player profile with persisted weight and per-leaderboard stats |
| `GET` | `/api/v1/players/achievements/{name}` | — | Player achievement progress (from Monumenta API) |

Rate limits: 60 req/min on all GET endpoints, 5 req/min on the POST ingest endpoint. Player responses are cached in Redis for 1 hour; achievements for 10 minutes.


**Setup**

```bash
cd veda-backend
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

Create `veda-backend/.env`:

```env
DATABASE_URL=postgresql+asyncpg://veda:veda@localhost:5432/veda
REDIS_URL=redis://localhost:6379
FRONTEND_URL=https://veda-utils.vercel.app
SHARED_SECRET=your-secret-here
```

Run migrations and start the server:

```bash
alembic upgrade head
uvicorn app.main:app --reload
```

**Lint / type check**

```bash
ruff check .
basedpyright
pytest
```

---

### `veda-bot`

| | |
|---|---|
| **Stack** | Node.js 20+, Discord.js 14, TypeScript |

The Discord bot exposes a `/leaderboard` slash command. It fetches available leaderboard names from the backend (refreshed every 10 minutes) and provides autocomplete. Results are shown as paginated embeds with a link back to the web UI.

**Setup**

```bash
cd veda-bot
npm install
```

Create `veda-bot/src/.env` (copy from `.env.example`):

```env
TOKEN=your-discord-bot-token
CLIENT_ID=your-application-id
DEFAULT_GUILD_ID=your-guild-id
OWNER_ID=your-discord-user-id
BASE_URL=https://your-backend-url/
```

**Scripts**

```bash
npm run dev    # compile + watch + run
npm run build  # lint, format, compile
npm run prod   # build + start
```

---

### `veda-scraper`

| | |
|---|---|
| **Stack** | Java 17, Fabric mod (Minecraft 1.20.4), Gradle |
| **Runtime** | Headless Minecraft via [HeadlessMC](https://github.com/headlesshq/headlessmc) |

The scraper is a Minecraft Fabric client mod. When launched, it connects to Monumenta, fires `/leaderboard` commands for each configured leaderboard, parses the chat output, and POSTs the collected entries to the backend ingestion endpoint. It then exits automatically.

**First-time login (interactive)**

```bash
docker compose run --rm scraper --login
```

**Run**

```bash
docker compose up scraper
```

The container reads `VALIDATION_KEY` (the backend shared secret) and `BASE_URL` from environment variables.

---

## Running locally

Infrastructure (PostgreSQL + Redis):

```bash
docker compose up postgres redis -d
```

Backend + frontend together (requires Python venv already set up):

```bash
make dev
```

Or individually:

```bash
make backend    # uvicorn on :8000
make frontend   # Vite dev server on :5173
```

---

## Deployment

| Component | Platform |
|---|---|
| Frontend | Vercel (auto-deployed from `veda-frontend/`) |
| Backend | Docker (`docker compose up backend`) |
| Bot | Self-hosted for now (Node.js process or container) |
| Scraper | Docker, run on demand or on a schedule |

The root `docker-compose.yml` orchestrates backend, frontend, PostgreSQL, and Redis on a shared Docker network (`shared`). The scraper has its own `veda-scraper/docker-compose.yaml` on the same network.

---

## License

Apache License 2.0 — see [LICENSE](LICENSE).
