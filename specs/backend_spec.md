# Backend Specification – FastAPI Modular Monolith

**Runtime:** Python 3.14+; FastAPI; PostgreSQL; Redis
**ORM/migrations:** SQLAlchemy and Alembic

## 1. Architecture

The backend is a feature-oriented modular monolith. `app.main:app` wires the application; shared uration, database, cache, security, DTOs, and errors are under `app/core`; business features are under `app/features`.

```text
app/
├── main.py
├── core/
│   ├── .py constants.py dto.py errors.py
│   ├── db/{base.py,session.py,unit_of_work.py,cache.py}
│   └── security/{auth.py,rate_limiter.py}
├── features/
│   ├── leaderboard/{api,dto,entities,errors,repositories,use_cases}
│   └── player/{api,dto,entities,errors,repositories,use_cases}
└── migrations/versions/
```

## 2. Application and uration

The app is titled `Veda`, version `1.0`, and closes Redis in its lifespan shutdown handler. It installs SlowAPI middleware, application/unexpected-error handlers, and CORS with:

- `allow_origins=[settings.frontend_url]`
- `allow_methods=["GET"]`
- `allow_headers=["*"]`

Settings are loaded from environment variables/`.env`: `database_url`, `redis_url`, `frontend_url`, `shared_secret`, and optional `app_name` (default `Veda API`). The route prefix is `/api/v1`.

GET requests use `60/minute`; POST requests use `5/minute`. Player responses are cached for `3600` seconds using keys `player:{lowercase_name}`.

## 3. Endpoints

| Method | Path                                      | Auth                 | Limit     |
| ------ | ----------------------------------------- | -------------------- | --------- |
| GET    | `/api/v1/leaderboards`                    | None                 | 60/minute |
| GET    | `/api/v1/leaderboards/{leaderboard_name}` | None                 | 60/minute |
| POST   | `/api/v1/leaderboards/snapshot`           | Bearer shared secret | 5/minute  |
| GET    | `/api/v1/players`                        | None                 | 60/minute |
| GET    | `/api/v1/players/{player_name}`           | None                 | 60/minute |

No POST route is exposed to the frontend; snapshot ingestion is intended for an authenticated scraper/producer.

## 4. Leaderboard feature

`EntryIn` validates `rank > 0`, `value >= 0`, and `playerName` as 1–16 characters matching `^[a-zA-Z0-9_]+$`. `LeaderboardSnapshotIn` requires at least one entry and a 1–128 character `leaderboardName`; duplicate ranks produce `ERR_DUPLICATE_RANK` (400). `CreateSnapshotRequest` requires at least one snapshot. Pydantic accepts snake_case names and camelCase aliases and serializes aliases.

`GET /leaderboards` returns `LeaderboardsResponse`:

```json
{
  "leaderboards": [
    {
      "leaderboardId": "Zenith",
      "leaderboardName": "Celestial Zenith",
      "estimatedTimePerCompletionMinutes": 15
    }
  ]
}
```

Each leaderboard also has a persisted `groupSize` value, but it is not currently included in the response.

`GET /leaderboards/{name}` returns the latest `SnapshotResponse` with `snapshotId`, `leaderboardName`, `fetchedAt`, and entries (`entryId`, `rank`, `playerName`, `value`). Missing resources return `ERR_LEADERBOARD_NOT_FOUND` or `ERR_SNAPSHOT_NOT_FOUND`.

`POST /leaderboards/snapshot` uses one UTC timestamp for the batch, upserts leaderboard/player records, inserts snapshots and entries, commits atomically, invalidates affected player cache keys, and returns 201 with `snapshotIds`, `fetchedAt`, and `message`. It requires `Authorization: Bearer <shared_secret>`.

## 5. Player feature

`GET /players/` returns `{ "players": string[] }` in repository order. `GET /players/{player_name}` validates 1–16 alphanumeric/underscore characters and performs a case-insensitive lookup. On a cache miss it returns the player’s latest entry per leaderboard:

```json
{
  "username": "Alice",
  "totalCompletions": 8,
  "totalPlaytimeMinutes": 120,
  "entries": [
    {
      "leaderboardName": "Celestial Zenith",
      "rank": 1,
      "value": 8,
      "estimatedPlaytimeMinutes": 120
    }
  ]
}
```

`estimatedPlaytimeMinutes` is `value * estimated_time_per_completion_minutes`; totals sum the returned entries. Players are created only during snapshot ingestion. Missing players return `ERR_PLAYER_NOT_FOUND` (404).

## 6. Errors and security

Application errors serialize as `errorCode`, `message`, and optional `details`. Defined codes are `ERR_DUPLICATE_RANK` (400), `ERR_UNAUTHORIZED` (401), `ERR_LEADERBOARD_NOT_FOUND` (404), `ERR_SNAPSHOT_NOT_FOUND` (404), `ERR_PLAYER_NOT_FOUND` (404), `ERR_RATE_LIMITED` (429), and `ERR_INTERNAL` (500). FastAPI handles ordinary request validation errors; there is no dedicated `ERR_INVALID_REQUEST` mapping.

SQL uses SQLAlchemy parameter binding. Auth is a shared Bearer secret, not user/session authentication. Redis cache keys are normalized to lowercase and invalidated after successful ingestion. Unexpected exceptions are returned as HTTP 500.

## 7. Persistence and operations

The current migrations create leaderboard metadata (`external_leaderboard_id`, `name`, `estimated_time_per_completion_minutes`, `group_size`), snapshots, entries, and players. Leaderboard and player identifiers/names are unique; positive estimated time/group size and positive entry ranks are database-checked; snapshot and entry foreign keys cascade on deletion. The `updated_at` trigger is created by migration.
