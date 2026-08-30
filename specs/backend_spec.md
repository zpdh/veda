# Backend Specification – FastAPI + SQLAlchemy (Modular Monolith)

**Version:** 1.1
**Target runtime:** Python 3.11+, Docker container
**Framework:** FastAPI (async)
**ORM:** SQLAlchemy 2.x (async) – PostgreSQL 18 backend
**Cache:** Redis (via `redis.asyncio`)
**Database cleanup:** PostgreSQL `pg_cron` extension (defined in `database_spec.md`)

---

## 1. Architecture Overview

Feature-oriented modular monolith. All code lives in a single deployable unit organised by business feature. Cross-cutting concerns live in `core/`.

## 2. Dependencies

### 2.1 Runtime (`requirements.txt`)

| Package | Purpose |
|---------|---------|
| `fastapi` | Async HTTP framework |
| `uvicorn[standard]` | ASGI server |
| `SQLAlchemy[asyncio]` | Async ORM |
| `asyncpg` | PostgreSQL async driver |
| `alembic` | Database migrations |
| `structlog` | Structured JSON logger |
| `pydantic` | Data validation |
| `pydantic-settings` | Settings management |
| `slowapi` | Rate limiting middleware |
| `redis` | Redis client (`redis.asyncio`) |

### 2.2 Development / Testing (`requirements-dev.txt`)

| Package | Purpose |
|---------|---------|
| `pytest` | Test runner |
| `pytest-asyncio` | Async test support |
| `httpx` | Async HTTP client for integration tests |
| `testcontainers` | Temporary PostgreSQL + Redis in CI |

### 2.3 Package layout

```
app/
├── main.py
├── core/
│   ├── config.py          # BaseSettings: database_url, redis_url, frontend_url, shared_secret
│   ├── constants.py       # LIMITER_HTTP_GET, LIMITER_HTTP_POST, CACHE_TTL_SECONDS, API_ROUTE_PREFIX
│   ├── dto.py             # ErrorResponse
│   ├── errors.py          # AppError, ErrorDescription, handlers
│   ├── db/
│   │   ├── base.py        # DeclarativeBase
│   │   ├── session.py     # async engine, get_db
│   │   ├── unit_of_work.py
│   │   └── cache.py       # get_redis, close_redis
│   └── security/
│       ├── auth.py        # Bearer token verification
│       └── rate_limiter.py
├── features/
│   ├── leaderboard/
│   │   ├── api/router.py
│   │   ├── dto/request.py
│   │   ├── dto/response.py
│   │   ├── entities/orm.py
│   │   ├── errors/errors.py
│   │   ├── repositories/postgres.py
│   │   └── use_cases/
│   │       ├── create_snapshot.py
│   │       ├── get_latest_snapshot.py
│   │       └── get_leaderboard_names.py
│   └── player/
│       ├── api/router.py
│       ├── dto/response.py
│       ├── entities/orm.py
│       ├── errors/errors.py
│       ├── repositories/postgres.py
│       └── use_cases/get_player.py
└── migrations/
    └── versions/
        ├── f2f71e98ce26_create_leaderboard_tables.py
        ├── aa47e430a4a4_add_updated_at_trigger.py
        └── 8722c2b5c277_create_player_table.py
```

---

## 3. Application Wiring (`main.py`)

- FastAPI app created with `lifespan=lifespan` to ensure Redis is closed on shutdown.
- `SlowAPIMiddleware` registered for rate limiting.
- `CORSMiddleware`: `allow_origins=[settings.frontend_url]`, `allow_methods=["GET"]` — POST is scraper-only (server-to-server), CORS does not apply.
- Exception handlers: `AppError`, `RateLimitExceeded`, `Exception`.
- Routers: `leaderboard_router`, `player_router`.

---

## 4. Core Modules

| Module | Responsibility |
|--------|---------------|
| `core/config.py` | `Settings(BaseSettings)`: `database_url`, `redis_url`, `frontend_url`, `shared_secret`, `app_name` |
| `core/constants.py` | `LIMITER_HTTP_GET`, `LIMITER_HTTP_POST`, `CACHE_TTL_SECONDS`, `API_ROUTE_PREFIX = "/v1/api"` |
| `core/db/session.py` | Async engine, `async_sessionmaker`, `get_db` dependency |
| `core/db/unit_of_work.py` | `UnitOfWork`: wraps `AsyncSession`, exposes `commit()` and `rollback()` |
| `core/db/cache.py` | `get_redis()` dependency returning `redis.asyncio.Redis`; `close_redis()` called in lifespan |
| `core/errors.py` | `ErrorDescription`, `AppError`, `CommonErrors`, `app_error_handler`, `rate_limit_handler`, `error_handler` |
| `core/security/auth.py` | `verify_auth_token`: Bearer token check against `settings.shared_secret` |
| `core/security/rate_limiter.py` | `slowapi.Limiter` keyed by remote address, backed by Redis |

---

## 5. Feature – Leaderboard

### 5.1 Endpoints

| Method | Path | Auth | Rate limit |
|--------|------|------|-----------|
| GET | `/v1/api/leaderboards` | None | 60/min |
| GET | `/v1/api/leaderboards/{leaderboard_name}` | None | 60/min |
| POST | `/v1/api/leaderboards/snapshot` | Bearer token | 5/min |

### 5.2 DTOs

**Request – `request.py`**
- `EntryIn`: `rank` (int, >0), `player_name` (alias `playerName`, 1–16 chars, `^[a-zA-Z0-9_]+$`), `value` (int, ≥0)
- `LeaderboardSnapshotIn`: `leaderboard_name` (alias `leaderboardName`), `entries` (min 1). Validator: duplicate ranks raise `ERR_DUPLICATE_RANK`.
- `CreateSnapshotRequest`: `snapshots` (min 1 `LeaderboardSnapshotIn`)

**Response – `response.py`**
- `EntryOut`: `entryId`, `rank`, `playerName`, `value`
- `SnapshotResponse`: `snapshotId`, `leaderboardName`, `fetchedAt`, `entries: list[EntryOut]`
- `SnapshotCreatedResponse`: `snapshotIds`, `fetchedAt`, `message`
- `LeaderboardNamesResponse`: `leaderboardNames`

### 5.3 ORM Entities (`entities/orm.py`)

- `Leaderboard`: `id` (bigserial PK), `name` (text, unique), `created_at`, `updated_at`
- `LeaderboardSnapshot`: `id`, `leaderboard_id` (FK → leaderboard, CASCADE), `fetched_at`
- `LeaderboardEntry`: `id`, `snapshot_id` (FK → leaderboard_snapshot, CASCADE), `rank` (CHECK >0), `player_name` (text), `value`; UNIQUE(`snapshot_id`, `rank`)

### 5.4 Repository (`repositories/postgres.py`)

- `get_leaderboard_by_name(name)` – case-insensitive via `func.lower()`
- `upsert_leaderboard(name)` – `INSERT ... ON CONFLICT DO NOTHING` with race resolution fallback
- `get_latest_snapshot(leaderboard_id)` – ordered by `fetched_at DESC`, limit 1, eager-loads entries via `selectinload`
- `create_snapshot(snapshot)` – `session.add()` + `flush()`
- `delete_old_snapshots(retention_days=7)`
- `get_leaderboards()` – returns all leaderboard rows

### 5.5 Use Cases

**`GetLeaderboardNames`**: calls `repo.get_leaderboards()`, returns `LeaderboardNamesResponse`.

**`GetLatestSnapshot`**:
1. Lookup leaderboard by name → 404 `ERR_LEADERBOARD_NOT_FOUND` if missing
2. Fetch latest snapshot → 404 `ERR_SNAPSHOT_NOT_FOUND` if none
3. Return `SnapshotResponse`

**`CreateSnapshot`**:
1. For each `LeaderboardSnapshotIn`: upsert leaderboard, create `LeaderboardSnapshot` + entries, flush
2. Bulk-upsert all unique `player_name` values from the request into the `player` table
3. `commit()`
4. Delete Redis cache keys `player:{lower(name)}` for all unique player names
5. Return `SnapshotCreatedResponse`

All within a single session; steps 1–3 are atomic.

---

## 6. Feature – Player

### 6.1 Endpoint

| Method | Path | Auth | Rate limit |
|--------|------|------|-----------|
| GET | `/v1/api/players/{player_name}` | None | 60/min |

Path parameter `player_name`: 1–16 chars, `^[a-zA-Z0-9_]+$`.

### 6.2 DTOs (`dto/response.py`)

- `PlayerEntryOut`: `leaderboardName` (alias, camelCase), `rank`, `value`
- `PlayerResponse`: `username`, `totalCompletions` (alias), `entries: list[PlayerEntryOut]`

### 6.3 ORM Entity (`entities/orm.py`)

- `Player`: `id` (bigserial PK), `name` (text, unique, NOT NULL), `created_at`

No ORM relationship to `LeaderboardEntry` — joined by name in the query layer.

### 6.4 Repository (`repositories/postgres.py`)

**`get_by_name(player_name)`**
```sql
SELECT * FROM player WHERE lower(name) = lower(:player_name)
```

**`upsert_player(player_name)`**
```sql
INSERT INTO player (name) VALUES (:name)
ON CONFLICT DO NOTHING
RETURNING *
```
Falls back to `get_by_name` on race condition (mirrors leaderboard upsert pattern).

**`get_player_entries(player_name)`** — returns `list[PlayerEntryRow]`

Uses `DISTINCT ON (lb.id)` to return one entry per leaderboard — the entry from the most recent snapshot containing this player:

```sql
SELECT DISTINCT ON (lb.id)
    lb.name  AS leaderboard_name,
    le.rank,
    le.value
FROM leaderboard_entry le
JOIN leaderboard_snapshot ls ON ls.id = le.snapshot_id
JOIN leaderboard lb           ON lb.id = ls.leaderboard_id
WHERE lower(le.player_name) = lower(:player_name)
ORDER BY lb.id, ls.fetched_at DESC
```

**`PlayerEntryRow`** is a `@dataclass` with fields `leaderboard_name: str`, `rank: int`, `value: int`.

### 6.5 Use Case (`use_cases/get_player.py`)

```
GetPlayer.execute(player_name):
1. Check Redis: key = player:{lower(player_name)}
   → hit: return PlayerResponse.model_validate_json(cached)
2. get_by_name(player_name) → None: raise PlayerError(PLAYER_NOT_FOUND, 404)
3. get_player_entries(player_name)
4. Build PlayerResponse:
   - username = player.name
   - entries = [PlayerEntryOut(...) for each row]
   - totalCompletions = sum(e.value for e in entries)
5. Cache: redis.set(key, response.model_dump_json(by_alias=True), ex=CACHE_TTL_SECONDS)
6. Return response
```

### 6.6 Errors (`errors/errors.py`)

- `PlayerErrors.PLAYER_NOT_FOUND` → HTTP 404, `ERR_PLAYER_NOT_FOUND`

---

## 7. Caching Strategy

- **Client:** `redis.asyncio.Redis` via `get_redis()` dependency; connection closed in FastAPI lifespan.
- **Cache keys:** `player:{lower(name)}`
- **TTL:** `CACHE_TTL_SECONDS` (defined in `core/constants.py`)
- **Invalidation:** On `POST /snapshot`, delete cache keys for all player names present in the request payload, after commit.
- **No leaderboard caching** at this time.

---

## 8. Security

- POST `/snapshot` protected by Bearer token (`shared_secret`).
- All player names validated at the DTO layer: `^[a-zA-Z0-9_]+$`, max 16 chars.
- Rate limiting on all endpoints via `slowapi` backed by Redis.
- No SQL string interpolation — all queries use SQLAlchemy parameter binding.

---

## 9. Future Considerations

- **UUID column on `player`:** Add as nullable `TEXT` when a resolution strategy (scheduled job respecting Mojang's 200/2min rate limit) is ready.
- **Weight/ranking system:** `player` table is the natural anchor. Add `weight_score NUMERIC` and `last_ranked_at TIMESTAMPTZ` columns in a future migration.
- **Historical graphs:** `leaderboard_entry` already stores full snapshot history. A future `GET /v1/api/players/{name}/history` endpoint can query across all snapshots rather than just the latest.
- **ML feature store:** Player-level derived features (completion rate, rank progression, leaderboard distribution) can be persisted as columns on `player` or a separate `player_features` table.
- **Leaderboard response caching:** If read traffic grows, cache `GET /leaderboards/{name}` in Redis and invalidate on new snapshot POST.

---

*Updated by the Architect – 2026-08-30*
