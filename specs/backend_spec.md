# Backend Specification – FastAPI + SQLAlchemy (Modular Monolith)

**Version:** 1.0
**Target runtime:** Python 3.11+, Docker container
**Framework:** FastAPI (async)
**ORM:** SQLAlchemy 2.x (async) – PostgreSQL 18 backend
**Database cleanup:** PostgreSQL `pg_cron` extension (defined in `database_spec.md`)

---

## 1. Architecture Overview
We adopt a **feature‑oriented modular monolith**.  All code lives in a single deployable unit (one Docker image, one process) but is organized by business feature (here: *leaderboard*).  Cross‑cutting concerns are placed in a shared `core/` package.

## 2. Dependencies

### 2.1 Runtime (requirements.txt)

| Package | Version Constraint | Purpose |
|---------|-------------------|---------|
| `fastapi` | – | FastAPI framework (async HTTP) |
| `uvicorn[standard]` | – | ASGI server |
| `SQLAlchemy[asyncio]` | – | Async ORM |
| `asyncpg` | – | PostgreSQL async driver |
| `alembic` | – | Database migrations |
| `structlog` | – | Structured JSON logger |
| `pydantic` | – | Data validation & settings |
| `pydantic-settings` | – | Settings management (BaseSettings) |

### 2.2 Development / Testing (requirements-dev.txt)

| Package | Version Constraint | Purpose |
|---------|-------------------|---------|
| `pytest` | – | Test runner |
| `pytest-asyncio` | – | Async test support |
| `httpx` | – | Async HTTP client for integration tests |
| `testcontainers` | – | Spin‑up temporary PostgreSQL containers in CI |


### Package layout
```
app/
├─ __init__.py
├─ main.py                     # FastAPI app, includes routers
├─ core/                       # cross‑cutting utilities
│   ├─ config.py               # Pydantic BaseSettings (DB URL, env vars, etc.)
│   ├─ db.py                   # async engine, AsyncSession, FastAPI `get_db`
│   ├─ logging.py              # structlog / JSON logger setup
│   ├─ errors.py               # custom exception classes + FastAPI handlers
│   └─ security.py             # (optional) JWT helpers, `get_current_user`
├─ features/
│   └─ leaderboard/
│       ├─ __init__.py
│       ├─ api/
│       │   └─ router.py      # APIRouter exposing the two endpoints
│       ├─ dto/
│       │   ├─ request.py     # CreateSnapshotRequest, EntryIn
│       │   └─ response.py    # SnapshotResponse, SnapshotCreatedResponse
│       ├─ entities/
│       │   └─ orm.py          # SQLAlchemy table definitions (Leaderboard, Snapshot, Entry)
│       ├─ repositories/
│       │   └─ postgres.py     # CRUD + cleanup logic (async Session)
│       ├─ use_cases/
│       │   ├─ get_latest_snapshot.py
│       │   └─ create_snapshot.py
│       └─ background/          # (empty – cleanup handled by pg_cron)
│           └─ __init__.py
├─ migrations/                 # Alembic migration scripts generated from entities/orm.py
└─ tests/
    ├─ unit/
    │   └─ features/leaderboard/   # unit tests for use‑cases & repository
    └─ integration/               # API integration tests (httpx + temporary PG)
```

*Naming conventions* – `dto/` holds Pydantic **Data Transfer Objects**; `entities/` holds the SQLAlchemy **entity** classes; `use_cases/` replaces a generic “service” layer with explicit use‑case classes (`GetLatestSnapshot`, `CreateSnapshot`).

---

## 2. Core / Cross‑Cutting Packages
| Module | Responsibility |
|--------|----------------|
| `core/config.py` | Centralised settings (`database_url`, optional feature flags). Uses `pydantic.BaseSettings`. |
| `core/db.py` | Creates the async engine (`create_async_engine` with `asyncpg`), an `async_sessionmaker`, and a FastAPI dependency `get_db` that yields an `AsyncSession`. |
| `core/logging.py` | Initialise a structured JSON logger (`structlog`). Exposes `logger = structlog.get_logger(__name__)`. |
| `core/errors.py` | Provides **generic** error handling — defines `ErrorDescription`, `CommonErrors`, `AppError` and registers a FastAPI `exception_handler` that formats errors as the **ErrorResponse** defined in the API spec. Feature‑specific error modules (e.g., `features/leaderboard/errors/errors.py`) extend `AppError`. |
| `core/security.py` *(optional)* | JWT verification, `get_current_user` dependency, role‑based checks. Not required for the current MVP but placed for future growth. |

---

## 3. Feature – Leaderboard
### 3.1 API (`features/leaderboard/api/router.py`)
* **GET** `/v1/api/leaderboards/{leaderboardName}` – Returns the most recent snapshot for the given leaderboard name. Returns **200** on success, **404** if the leaderboard does not exist or no snapshot is found, **400** for malformed inputs.
* **POST** `/v1/api/leaderboards/snapshot` – Accepts a JSON body (`CreateSnapshotRequest`) containing a list of leaderboard snapshots (each identified by `leaderboardName`). The service creates one or more `LeaderboardSnapshot` rows with a shared `fetched_at = now() UTC` and stores the entries. Returns **201 Created** with a `SnapshotCreatedResponse`. Errors: **400** (validation), **404** (leaderboard not found), **409** (snapshot conflict), **500** (unexpected).

The router depends on the specific use‑case objects via FastAPI `Depends` (see **Dependency Injection** below).

### 3.2 DTOs (`features/leaderboard/dto/`)
* `request.py` – `CreateSnapshotRequest` (list of `EntryIn`). Includes a validator that ensures ranks are unique within the payload.
* `response.py` – `SnapshotResponse` (includes nested `EntryOut` objects) and `SnapshotCreatedResponse`.
All DTOs are plain Pydantic models; `response` models set `orm_mode = True` for easy conversion from SQLAlchemy entities.

### 3.3 Entities (`features/leaderboard/entities/orm.py`)
SQLAlchemy declarative classes matching the schema from **`database_spec.md`**:
* `Leaderboard` – PK `id`, unique `name`, timestamps (`created_at`, `updated_at`).
* `LeaderboardSnapshot` – PK `id`, FK `leaderboard_id` (`ON DELETE CASCADE`), indexed `fetched_at`.
* `LeaderboardEntry` – PK `id`, FK `snapshot_id` (`ON DELETE CASCADE`), `rank` (positive integer), `player_name`, `value` (integer, NOT NULL), and a **unique constraint** on (`snapshot_id`, `rank`).

### 3.4 Repository (`features/leaderboard/repositories/postgres.py`)
Provides async methods:
* `get_latest_snapshot(leaderboard_id, from_ts?, to_ts?)` – query ordered by `fetched_at DESC`, limited to 1.
* `create_snapshot(self, snapshot: LeaderboardSnapshot)` – persists a `LeaderboardSnapshot` ORM object (with its entries) and returns the persisted entity.
* `delete_old_snapshots(self, retention_days: int = 7)` – removes snapshots older than the supplied retention period (default 7 days).
All methods receive an `AsyncSession` injected via the `core.db.get_db` dependency.

### 3.5 Errors (`features/leaderboard/errors/errors.py`)
Feature‑specific error definitions extending `AppError`:
* `LeaderboardError` – wraps `LeaderboardErrors` enum members:
  * `DUPLICATE_RANK` – HTTP 400, code `ERR_DUPLICATE_RANK`
  * `LEADERBOARD_NOT_FOUND` – HTTP 404, code `ERR_LEADERBOARD_NOT_FOUND`
  * `SNAPSHOT_NOT_FOUND` – HTTP 404, code `ERR_SNAPSHOT_NOT_FOUND`

### 3.6 Use Cases (`features/leaderboard/use_cases/`)
Each file defines a callable class that encapsulates a single business operation:
* `GetLatestSnapshot` – validates the optional time window, calls the repository, raises an appropriate `AppError` (e.g., `ERR_SNAPSHOT_NOT_FOUND` or `ERR_LEADERBOARD_NOT_FOUND`) if nothing is found, and returns the entity.
* `CreateSnapshot` – validates the existence of the target leaderboard, persists snapshots within a `UnitOfWork`, and commits the transaction after all snapshots are stored. Duplicate‑rank validation is performed by the DTO validator; DB‑level integrity errors are mapped to `ERR_DUPLICATE_RANK`.
Both use cases are injected into the router via FastAPI `Depends`.

---

## 4. Dependency Injection & Application Wiring (`app/main.py`)
```python
from fastapi import FastAPI
from app.core import config, logging  # import to initialise side‑effects
from app.features.leaderboard.api.router import router as leaderboard_router

app = FastAPI(title="Leaderboard Service", version="1.0")
app.include_router(leaderboard_router)
```
*`core.logging` is imported for its side‑effects (logger configuration). The `config` module reads environment variables (e.g., `DATABASE_URL`). The router pulls the needed use‑cases via `Depends`, which in turn receive a `LeaderboardRepository` instantiated with the async DB session.

---

## 5. Data Retention – Snapshot Cleanup
The **cleanup job** is implemented **outside the application code** using PostgreSQL's `pg_cron` extension (already defined in `database_spec.md`). The job runs daily at 02:00 UTC and executes:
```sql
DELETE FROM leaderboard_snapshot
WHERE fetched_at < (now() - interval '7 days');
```
Because `leaderboard_snapshot` has `ON DELETE CASCADE` foreign keys to `leaderboard_entry`, all dependent entries are removed automatically. This approach guarantees atomic deletion and avoids adding any background‑task code to the FastAPI process.

> **Note:** The repository still contains a `delete_old_snapshots()` method for manual or test‑only invocation, but the production system relies solely on the `pg_cron` job.

---

## 6. Testing Strategy
| Layer | Test type | Tools | Key assertions |
|-------|-----------|-------|----------------|
| **DTO validation** | Unit | `pytest`, `pydantic` | Duplicate rank → `ValidationError`; empty entry list → error. |
| **Use‑case logic** | Unit | `pytest`, `unittest.mock` | Repository mock called with correct parameters; appropriate domain exceptions raised for missing leaderboard or snapshot. |
| **Repository** | Integration | `pytest`, `testcontainers` (PostgreSQL) or Docker‑Compose | - `create_snapshot` persists rows and respects constraints.<br>- `get_latest_snapshot` returns the correct snapshot based on time window.<br>- `delete_old_snapshots` removes only rows older than 7 days. |
| **API** | Integration | `httpx.AsyncClient` against the FastAPI app (with temporary DB) | - End‑to‑end request/response matches the OpenAPI schema.<br>- Status codes & error payloads conform to `api_spec.md`.
| **Cleanup (pg_cron)** | Manual / CI verification | `psql` command in test container | Run the `DELETE` query directly and verify cascade behavior; optionally query `cron.job` to ensure the scheduled job exists. |

Test coverage should aim for **≥ 90 %** of the leaderboard feature modules.

---

## 7. Security & Validation Checklist
* **Input validation** – All request bodies are validated by Pydantic DTOs; duplicate ranks are rejected before hitting the DB.
* **SQL injection protection** – Repository uses SQLAlchemy's parameter binding; no raw string interpolation.
* **Error mapping** – `core.errors` converts internal exceptions to the **ErrorResponse** JSON structure defined in `api_spec.md` (error codes such as `ERR_INVALID_REQUEST`, `ERR_LEADERBOARD_NOT_FOUND`, `ERR_DUPLICATE_RANK`).
* **Authentication** – Not required for the MVP, but the `core.security` module is ready for JWT integration; routers can add `Depends(get_current_user)` later without code changes. |
* **Rate limiting / DoS** – Not in scope for the initial version; can be added via a FastAPI middleware or an external API gateway later. |

---

## 8. Migration / Deployment
* **Alembic** – `alembic.ini` points to the async engine URL from `core.config`. A single migration (`01_initial_leaderboard.sql`) creates the three tables, indexes, and the trigger for `updated_at` (if you keep the DB‑level trigger). |
* **Dockerfile** – Uses `python:3.11-slim` (or similar) and installs `fastapi`, `uvicorn[standard]`, `SQLAlchemy[asyncio]`, `asyncpg`, `alembic`, `structlog`, and `pydantic`. The entrypoint runs `alembic upgrade head && uvicorn app.main:app --host 0.0.0.0 --port 8000`. |
* **docker‑compose** – Defines a `postgres` service (`image: postgres:18-alpine`) with `PG_CRON` extension enabled (install `postgresql-contrib` or use a custom image). The `backend` service depends on `postgres` and shares the same network.

---

## 9. Open Questions / Future Work
* **Feature toggle** – If the leaderboard service may be disabled in some deployments, consider adding a `ENABLE_LEADERBOARD` flag in `core.config` and guard the router registration in `main.py`. |
* **Background task alternative** – For environments where `pg_cron` cannot be installed, an in‑process `asyncio` task could be added under `features/leaderboard/background/cleanup_task.py`. |
* **Read‑optimised view** – If read traffic grows, a materialised view for the latest snapshot per leaderboard could be added, with the `pg_cron` job also refreshing it. |

---

*Prepared by the Architect – 2026‑08‑10*
