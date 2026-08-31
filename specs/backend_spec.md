# Backend Specification – FastAPI + SQLAlchemy (Modular Monolith)

**Source of truth:** `veda-backend/` implementation
**Target runtime:** Python 3.11+, Docker container
**Framework:** FastAPI (async)
**ORM:** SQLAlchemy 2.x async
**Database:** PostgreSQL 18
**Cache:** Redis via `redis.asyncio`

---

## 1. Architecture

The backend is a feature-oriented modular monolith deployed as one FastAPI application. Business code is grouped under `app/features/`; shared infrastructure and cross-cutting concerns live under `app/core/`.

### Package layout

```
app/
├── main.py
├── core/
│   ├── config.py
│   ├── constants.py
│   ├── dto.py
│   ├── errors.py
│   ├── db/{base.py,session.py,unit_of_work.py,cache.py}
│   └── security/{auth.py,rate_limiter.py}
├── features/
│   ├── config/{router.py,get_config.py,response.py}
│   ├── leaderboard/
│   │   ├── api/router.py
│   │   ├── dto/{request.py,response.py}
│   │   ├── entities/orm.py
│   │   ├── errors/errors.py
│   │   ├── repositories/postgres.py
│   │   └── use_cases/{create_snapshot.py,get_latest_snapshot.py,get_leaderboard_names.py}
│   └── player/
│       ├── api/router.py
│       ├── dto/response.py
│       ├── entities/orm.py
│       ├── errors/errors.py
│       ├── repositories/postgres.py
│       └── use_cases/get_player.py
└── migrations/versions/
```

## 2. Dependencies

Runtime dependencies are declared in `requirements.txt`: `fastapi`, `uvicorn[standard]`, `SQLAlchemy[asyncio]`, `asyncpg`, `alembic`, `structlog`, `pydantic`, `pydantic-settings`, `slowapi`, and `redis`.

Development/test dependencies are declared in `requirements-dev.txt`.

## 3. Application wiring

`app.main:app` creates a FastAPI application titled `Veda`, version `1.0`, with a Redis-closing lifespan handler. It registers:

- `SlowAPIMiddleware`, using the application limiter.
- CORS with `settings.frontend_url` as the only allowed origin, `GET` as the allowed method, and all request headers allowed.
- Exception handlers for `AppError`, rate-limit failures, and unexpected exceptions.
- Leaderboard, player, and config routers.

The API route prefix is `/api/v1` (`API_ROUTE_PREFIX`).

## 4. Configuration and core services

`Settings` loads from environment variables and `.env`:

- `database_url: str`
- `redis_url: str`
- `frontend_url: str`
- `shared_secret: str`
- `app_name: str = "Veda API"`

Constants currently define `60/minute` for GET requests, `5/minute` for POST requests, a player-cache TTL of `3600` seconds, and the `/api/v1` route prefix.

`ErrorResponse` serializes `errorCode`, `message`, and optional `details`. `AppError` handlers preserve the application status and error code. Unexpected exceptions return HTTP 500 with `ERR_INTERNAL`; rate-limit failures return HTTP 429 with `ERR_RATE_LIMITED`.

## 5. HTTP endpoints

| Method | Path | Auth | Rate limit |
|---|---|---|---|
| GET | `/api/v1/leaderboards` | None | 60/minute |
| GET | `/api/v1/leaderboards/{leaderboard_name}` | None | 60/minute |
| POST | `/api/v1/leaderboards/snapshot` | Bearer shared secret | 5/minute |
| GET | `/api/v1/players/{player_name}` | None | 60/minute |
| GET | `/api/v1/config/` | None | 60/minute |

## 6. Leaderboard feature

### Request models

- `EntryIn`: `rank` is an integer greater than zero; `playerName` is 1–16 characters matching `^[a-zA-Z0-9_]+$`; `value` is an integer greater than or equal to zero.
- `LeaderboardSnapshotIn`: `leaderboardName` is 1–128 characters matching `^[a-zA-Z0-9 _.-]+$`; `entries` contains at least one `EntryIn`. Duplicate ranks raise `ERR_DUPLICATE_RANK` (HTTP 400).
- `CreateSnapshotRequest`: `snapshots` contains at least one snapshot block.

Models accept field names and their camelCase aliases and serialize responses using aliases.

### Response models

- `EntryOut`: `entryId`, `rank`, `playerName`, `value`.
- `SnapshotResponse`: `snapshotId`, `leaderboardName`, `fetchedAt`, and `entries`.
- `SnapshotCreatedResponse`: `snapshotIds`, `fetchedAt`, and `message`.
- `LeaderboardNamesResponse`: `leaderboardNames`.

`POST /api/v1/leaderboards/snapshot` uses one UTC timestamp for all snapshots in the request. It upserts leaderboards, creates snapshots and entries, upserts each unique player name, commits the unit of work, invalidates affected player cache keys, and returns HTTP 201. Database work before commit is atomic.

`GET /api/v1/leaderboards` returns all leaderboard names. `GET /api/v1/leaderboards/{leaderboard_name}` returns the latest snapshot, or `ERR_LEADERBOARD_NOT_FOUND` / `ERR_SNAPSHOT_NOT_FOUND` with HTTP 404 as appropriate.

## 7. Player feature

`GET /api/v1/players/{player_name}` accepts a path parameter of 1–16 characters matching `^[a-zA-Z0-9_]+$`.

The use case checks Redis at `player:{lower(name)}`, looks up the player case-insensitively, and returns the player’s latest entry per leaderboard. `totalCompletions` is the sum of returned entry values. Successful responses are cached for `CACHE_TTL_SECONDS`. Missing players return HTTP 404 with `ERR_PLAYER_NOT_FOUND`.

Players are created as a side effect of snapshot ingestion, not by the player GET endpoint.

## 8. Config feature

`GET /api/v1/config/` returns a `ConfigResponse` containing a `config` array. Each item has:

- `leaderboardName: string`
- `leaderboardId: string`
- `pages: int`

The current implementation returns the configured static entries for Zenith Clears, Silver Knights Tomb, and P.O.R.T.A.L. Strike, each with `pages: 50`.

## 9. Security and caching

- Snapshot ingestion requires an HTTP Bearer token equal to `settings.shared_secret`.
- GET and POST endpoints are rate-limited by the configured limiter.
- Player and leaderboard names are validated at the request layer where validation is defined above.
- SQL access uses SQLAlchemy parameter binding.
- Player cache keys are lowercased. Snapshot ingestion deletes affected player keys after commit.
- Redis is closed during application shutdown.

## 10. Persistence

The database schema and migrations in `app/migrations/versions/` define the leaderboard, snapshot, entry, and player tables. Snapshot retention/cleanup is not wired into the FastAPI application; any cleanup job must be treated as deployment/database infrastructure rather than an application endpoint.

---

*Updated from the backend implementation on 2026-08-31.*
