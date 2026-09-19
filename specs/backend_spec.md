# Backend Specification – FastAPI Modular Monolith

**Runtime:** Python 3.14+; FastAPI; PostgreSQL; Redis
**ORM/migrations:** SQLAlchemy and Alembic

## 1. Architecture

The backend is a feature-oriented modular monolith. `app.main:app` wires the application; shared uration, database, cache, security, DTOs, and errors are under `app/core`; business features are under `app/features`.

```text
app/
├── main.py
├── core/
│   ├── .py constants.py dto.py errors.py config.py http.py
│   ├── db/{base.py,session.py,unit_of_work.py,cache.py}
│   ├── security/{auth.py,rate_limiter.py}
│   └── util/weight.py
├── features/
│   ├── leaderboard/{api,dto,entities,errors,repositories,use_cases}
│   └── player/{api,dto,entities,errors,external,repositories,use_cases}
└── migrations/versions/
```

## 2. Application and uration

The app is titled `Veda`, version `1.0`. It installs SlowAPI middleware, application/unexpected-error handlers, and CORS with:

- `allow_origins=[settings.frontend_url]`
- `allow_methods=["GET"]`
- `allow_headers=["*"]`

Settings are loaded from environment variables/`.env`: `database_url`, `redis_url`, `frontend_url`, `shared_secret`, and optional `app_name` (default `Veda API`). The route prefix is `/api/v1`.

A single module-level `httpx.AsyncClient` is provided via `app.core.http.get_http_client` and injected into external clients (e.g. `MonumentaClient`) so connections are pooled. GET requests use `60/minute`; POST requests use `5/minute`. Player responses are cached for `3600` seconds using keys `player:{lowercase_name}`; achievements are cached for `600` seconds.

## 3. Endpoints

| Method | Path                                      | Auth                 | Limit     |
| ------ | ----------------------------------------- | -------------------- | --------- |
| GET    | `/api/v1/leaderboards`                    | None                 | 60/minute |
| GET    | `/api/v1/leaderboards/weight`             | None                 | 60/minute |
| GET    | `/api/v1/leaderboards/{leaderboard_name}` | None                 | 60/minute |
| POST   | `/api/v1/leaderboards/snapshot`           | Bearer shared secret | 5/minute  |
| GET    | `/api/v1/players`                        | None                 | 60/minute |
| GET    | `/api/v1/players/{player_name}`           | None                 | 60/minute |
| GET    | `/api/v1/players/achievements/{player_name}` | None              | 60/minute |

No POST route is exposed to the frontend; snapshot ingestion is intended for an authenticated scraper/producer. The `/leaderboards/weight` route is registered before `/leaderboards/{leaderboard_name}` so the literal path is not captured as a leaderboard name.

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

`POST /leaderboards/snapshot` uses one UTC timestamp for the batch, upserts player records, inserts snapshots and entries, recomputes and persists weights for affected players, commits atomically, invalidates affected player cache keys, and returns 201 with `snapshotIds`, `fetchedAt`, and `message`. It requires `Authorization: Bearer <shared_secret>`.

### Weight leaderboard

`GET /leaderboards/weight` returns all players ranked by their persisted `weight` descending (ties broken by name ascending):

```json
{
  "entries": [
    { "rank": 1, "playerName": "Alice", "weight": 482.13 },
    { "rank": 2, "playerName": "Bob", "weight": 401.7 }
  ]
}
```

`rank` is the 1-based position in the returned order and `weight` is rounded to 2 decimals. The endpoint is not paginated and reads directly from the indexed `player.weight` column; no per-request weight calculation occurs. A player who has not been re-ingested since the `weight` column was introduced appears with `0` until their next ingestion.

## 5. Player feature

`GET /players/` returns `{ "players": string[] }` in repository order. `GET /players/{player_name}` validates 1–16 alphanumeric/underscore characters and performs a case-insensitive lookup. On a cache miss it returns the player’s latest entry per leaderboard:

```json
{
  "username": "Alice",
  "weight": 482.13,
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

`weight` is the persisted `player.weight` value (rounded to 2 decimals), not recomputed on read. `estimatedPlaytimeMinutes` is `value * estimated_time_per_completion_minutes`; totals sum the returned entries. Players are created only during snapshot ingestion. Missing players return `ERR_PLAYER_NOT_FOUND` (404).

`GET /players/achievements/{player_name}` fetches progress from the Monumenta API via the shared HTTP client and returns:

```json
{
  "username": "Alice",
  "achievementCount": 900,
  "achievementCountTotal": 1362
}
```

Results are cached for `600` seconds under `achievements:{lowercase_name}`. The total is a hard-coded constant (no API exposes it).

## 6. Errors and security

Application errors serialize as `errorCode`, `message`, and optional `details`. Defined codes are `ERR_DUPLICATE_RANK` (400), `ERR_UNAUTHORIZED` (401), `ERR_LEADERBOARD_NOT_FOUND` (404), `ERR_SNAPSHOT_NOT_FOUND` (404), `ERR_PLAYER_NOT_FOUND` (404), `ERR_RATE_LIMITED` (429), and `ERR_INTERNAL` (500). FastAPI handles ordinary request validation errors; there is no dedicated `ERR_INVALID_REQUEST` mapping.

SQL uses SQLAlchemy parameter binding. Auth is a shared Bearer secret, not user/session authentication. Redis cache keys are normalized to lowercase and invalidated after successful ingestion. Unexpected exceptions are returned as HTTP 500.

## 7. Persistence and operations

The current migrations create leaderboard metadata (`external_leaderboard_id`, `name`, `estimated_time_per_completion_minutes`, `group_size`), snapshots, entries, and players (including the persisted `weight`). Leaderboard and player identifiers/names are unique; positive estimated time/group size and positive entry ranks are database-checked; snapshot and entry foreign keys cascade on deletion. The `updated_at` trigger is created by migration. Performance indexes cover `player.weight`, `lower(leaderboard_entry.player_name)`, and `(leaderboard_snapshot.leaderboard_id, fetched_at DESC)`.

Weight is materialized on `player.weight` and recomputed for affected players during snapshot ingestion (see §5). Aggregate player fields (`totalCompletions`, `totalPlaytimeMinutes`) are derived on read from the player's latest per-leaderboard entries and are intentionally not persisted.
