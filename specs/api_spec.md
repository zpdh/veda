# API Specification – Leaderboard, Player & Config Service

**Source of truth:** `veda-backend/` implementation
**Base path:** `/api/v1`
**Content type:** `application/json`
**Timestamps:** UTC ISO-8601 values where returned by the API

---

## 1. Endpoints

| Method | Path | Auth | Rate limit | Description |
|---|---|---|---|---|
| GET | `/api/v1/leaderboards` | None | 60/minute | List leaderboard names |
| GET | `/api/v1/leaderboards/{leaderboard_name}` | None | 60/minute | Return the latest leaderboard snapshot |
| POST | `/api/v1/leaderboards/snapshot` | Bearer shared secret | 5/minute | Batch-create snapshots |
| GET | `/api/v1/players/{player_name}` | None | 60/minute | Return a player profile and entries |
| GET | `/api/v1/config/` | None | 60/minute | Return static scraper configuration |

---

## 2. Leaderboard request models

### `EntryIn`

```json
{
  "rank": 1,
  "playerName": "Alice",
  "value": 5
}
```

Constraints:

- `rank`: integer greater than zero.
- `playerName`: 1–16 characters matching `^[a-zA-Z0-9_]+$`.
- `value`: integer greater than or equal to zero.

### `LeaderboardSnapshotIn`

```json
{
  "leaderboardName": "global-rankings",
  "entries": [
    { "rank": 1, "playerName": "Alice", "value": 5 },
    { "rank": 2, "playerName": "Bob", "value": 3 }
  ]
}
```

`leaderboardName` must be 1–128 characters and match `^[a-zA-Z0-9 _.-]+$`. `entries` must contain at least one entry. Ranks must be unique within the block; duplicate ranks raise `ERR_DUPLICATE_RANK`.

### `CreateSnapshotRequest`

```json
{
  "snapshots": [
    { "leaderboardName": "global-rankings", "entries": [/* entries */] },
    { "leaderboardName": "weekly-challenges", "entries": [/* entries */] }
  ]
}
```

`snapshots` must contain at least one snapshot. The request models accept Python field names as well as the documented camelCase aliases.

---

## 3. Leaderboard response models

### `SnapshotResponse`

```json
{
  "snapshotId": 124,
  "leaderboardName": "global-rankings",
  "fetchedAt": "2026-08-31T15:07:13Z",
  "entries": [
    { "entryId": 987, "rank": 1, "playerName": "Alice", "value": 5 }
  ]
}
```

### `SnapshotCreatedResponse`

```json
{
  "snapshotIds": [124, 125],
  "fetchedAt": "2026-08-31T16:34:12Z",
  "message": "Snapshots created successfully."
}
```

The POST operation uses the same `fetchedAt` value for every snapshot in the request and returns HTTP 201 after the database transaction commits.

### `LeaderboardNamesResponse`

```json
{
  "leaderboardNames": ["global-rankings", "weekly-challenges"]
}
```

---

## 4. Leaderboard endpoints

### `GET /api/v1/leaderboards`

Returns `LeaderboardNamesResponse` with HTTP 200.

### `GET /api/v1/leaderboards/{leaderboard_name}`

Returns the latest `SnapshotResponse` with HTTP 200.

| Code | Error code | Situation |
|---:|---|---|
| 404 | `ERR_LEADERBOARD_NOT_FOUND` | The name is not in the database. |
| 404 | `ERR_SNAPSHOT_NOT_FOUND` | The leaderboard exists but has no snapshot. |
| 429 | `ERR_RATE_LIMITED` | GET rate limit exceeded. |
| 500 | `ERR_INTERNAL` | Unexpected server failure. |

### `POST /api/v1/leaderboards/snapshot`

Requires an `Authorization` header with a Bearer token equal to the configured `shared_secret`.

Processing order:

1. Validate the request models.
2. Upsert each leaderboard.
3. Insert each snapshot and its entries.
4. Upsert unique player names.
5. Commit the unit of work.
6. Delete affected Redis player-cache keys.

| Code | Error code | Situation |
|---:|---|---|
| 201 | — | Snapshots created successfully. |
| 400 | `ERR_DUPLICATE_RANK` | Duplicate rank within a snapshot block. |
| 401 | `ERR_UNAUTHORIZED` | Missing or invalid Bearer token. |
| 429 | `ERR_RATE_LIMITED` | POST rate limit exceeded. |
| 500 | `ERR_INTERNAL` | Unexpected server failure. |

FastAPI request validation errors are handled by the framework unless an application error is raised by the request model. The application explicitly defines `ERR_DUPLICATE_RANK`; no separate application `ERR_INVALID_REQUEST` handler is defined.

---

## 5. Player endpoint

### `GET /api/v1/players/{player_name}`

`player_name` must be 1–16 characters matching `^[a-zA-Z0-9_]+$`. Lookup is case-insensitive.

The endpoint first checks Redis using `player:{lower(player_name)}`. On a cache miss, it looks up the player and returns one entry per leaderboard from the most recent snapshot containing that player. The response is then cached for `CACHE_TTL_SECONDS` (currently 3600 seconds).

```json
{
  "username": "Alice",
  "totalCompletions": 8,
  "entries": [
    { "leaderboardName": "global-rankings", "rank": 1, "value": 5 },
    { "leaderboardName": "weekly-challenges", "rank": 3, "value": 3 }
  ]
}
```

`totalCompletions` is the sum of `value` across returned entries. Players are not created by GET; they are upserted during snapshot ingestion.

| Code | Error code | Situation |
|---:|---|---|
| 200 | — | Player profile returned. |
| 404 | `ERR_PLAYER_NOT_FOUND` | Name is not in the player table. |
| 429 | `ERR_RATE_LIMITED` | GET rate limit exceeded. |
| 500 | `ERR_INTERNAL` | Unexpected server failure. |

---

## 6. Config endpoint

### `GET /api/v1/config/`

Returns HTTP 200 with the following shape:

```json
{
  "config": [
    { "leaderboardName": "Zenith Clears", "leaderboardId": "Zenith", "pages": 50 },
    { "leaderboardName": "Silver Knights Tomb", "leaderboardId": "SKT", "pages": 50 },
    { "leaderboardName": "P.O.R.T.A.L. Strike", "leaderboardId": "Portal", "pages": 50 }
  ]
}
```

Each config item contains `leaderboardName`, `leaderboardId`, and `pages`.

---

## 7. Error response

Application errors use this shape:

```json
{
  "errorCode": "ERR_PLAYER_NOT_FOUND",
  "message": "Player 'Alice' does not exist.",
  "details": { "playerName": "Alice" }
}
```

`details` is optional and may be `null` or omitted depending on the response model serialization.

### Application error codes

| HTTP | Error code | Defined situation |
|---:|---|---|
| 400 | `ERR_DUPLICATE_RANK` | Duplicate rank in a snapshot block. |
| 401 | `ERR_UNAUTHORIZED` | Missing or invalid snapshot Bearer token. |
| 404 | `ERR_LEADERBOARD_NOT_FOUND` | Leaderboard does not exist. |
| 404 | `ERR_SNAPSHOT_NOT_FOUND` | Leaderboard has no snapshots. |
| 404 | `ERR_PLAYER_NOT_FOUND` | Player does not exist. |
| 429 | `ERR_RATE_LIMITED` | Configured rate limit exceeded. |
| 500 | `ERR_INTERNAL` | Unexpected server exception. |

---

*Updated from the backend implementation on 2026-08-31.*
