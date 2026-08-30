# API Specification – Leaderboard & Player Service (v1.1)

*Base path:* `/v1/api`
*Content type:* `application/json`
*Timestamps:* UTC, ISO-8601

---

## 1. Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/v1/api/leaderboards` | None | List all leaderboard names |
| GET | `/v1/api/leaderboards/{leaderboardName}` | None | Latest snapshot for a leaderboard |
| POST | `/v1/api/leaderboards/snapshot` | Bearer | Batch-create snapshots (scraper only) |
| GET | `/v1/api/players/{playerName}` | None | Player profile and leaderboard entries |

---

## 2. Leaderboard DTOs

### 2.1 `EntryIn`
```json
{
  "rank": 1,
  "playerName": "Alice",
  "value": 5
}
```
*Constraints:* `rank` positive integer; `playerName` non-empty, max 16 chars, `^[a-zA-Z0-9_]+$`; `value` non-negative integer.

### 2.2 `LeaderboardSnapshotIn`
```json
{
  "leaderboardName": "global-rankings",
  "entries": [
    { "rank": 1, "playerName": "Alice", "value": 5 },
    { "rank": 2, "playerName": "Bob", "value": 3 }
  ]
}
```
*Validation:* `entries` min 1 element; ranks within a block must be unique (→ `ERR_DUPLICATE_RANK`).

### 2.3 `CreateSnapshotRequest`
```json
{
  "snapshots": [
    { "leaderboardName": "global-rankings", "entries": [ … ] },
    { "leaderboardName": "weekly-challenges", "entries": [ … ] }
  ]
}
```
*Validation:* `snapshots` min 1 element. Atomic — if any block fails, nothing is persisted.

### 2.4 `SnapshotResponse`
```json
{
  "snapshotId": 124,
  "leaderboardName": "global-rankings",
  "fetchedAt": "2026-08-08T15:07:13Z",
  "entries": [
    { "entryId": 987, "rank": 1, "playerName": "Alice", "value": 5 },
    { "entryId": 988, "rank": 2, "playerName": "Bob", "value": 3 }
  ]
}
```

### 2.5 `SnapshotCreatedResponse`
```json
{
  "snapshotIds": [124, 125],
  "fetchedAt": "2026-08-08T16:34:12Z",
  "message": "Snapshots created successfully."
}
```

### 2.6 `LeaderboardNamesResponse`
```json
{
  "leaderboardNames": ["global-rankings", "weekly-challenges"]
}
```

---

## 3. Leaderboard Endpoints

### 3.1 GET `/v1/api/leaderboards`

Returns all leaderboard names.

| Code | Body |
|------|------|
| 200 | `LeaderboardNamesResponse` |
| 500 | `ErrorResponse` |

### 3.2 GET `/v1/api/leaderboards/{leaderboardName}`

Returns the most recent snapshot for the given leaderboard.

| Code | `errorCode` | Situation |
|------|------------|-----------|
| 200 | — | `SnapshotResponse` |
| 404 | `ERR_LEADERBOARD_NOT_FOUND` | Name not in DB |
| 404 | `ERR_SNAPSHOT_NOT_FOUND` | Leaderboard exists but has no snapshots |
| 500 | `ERR_INTERNAL` | Unexpected failure |

### 3.3 POST `/v1/api/leaderboards/snapshot`

Batch-creates snapshots. Called by the scraper (server-to-server). Requires Bearer token.

**Processing flow:**
1. Validate request (Pydantic).
2. For each `LeaderboardSnapshotIn`: upsert leaderboard by name, insert snapshot and entries.
3. Upsert all unique player names into the `player` table.
4. Commit (atomic).
5. Invalidate Redis cache for all affected player names.

| Code | `errorCode` | Situation |
|------|------------|-----------|
| 201 | — | `SnapshotCreatedResponse` |
| 400 | `ERR_INVALID_REQUEST` | Malformed JSON / missing fields |
| 400 | `ERR_DUPLICATE_RANK` | Duplicate rank within a snapshot block |
| 401 | `ERR_UNAUTHORIZED` | Missing or invalid Bearer token |
| 500 | `ERR_INTERNAL` | Unexpected failure |

---

## 4. Player Endpoint

### 4.1 GET `/v1/api/players/{playerName}`

**Path parameter:** `playerName` — 1–16 chars, `^[a-zA-Z0-9_]+$`, case-insensitive.

**Behaviour:**
1. Check Redis cache (`player:{lower(name)}`). Return cached response if present.
2. Look up player by name (case-insensitive) in `player` table → 404 if not found.
3. For each leaderboard, retrieve the player's entry from the most recent snapshot containing them (`DISTINCT ON leaderboard, ORDER BY fetched_at DESC`).
4. Build and cache response. TTL defined by `CACHE_TTL_SECONDS`.

**Response (200) – `PlayerResponse`:**
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

`totalCompletions` = sum of `value` across all entries.

| Code | `errorCode` | Situation |
|------|------------|-----------|
| 200 | — | `PlayerResponse` |
| 404 | `ERR_PLAYER_NOT_FOUND` | Name not in `player` table |
| 429 | `ERR_RATE_LIMITED` | Rate limit exceeded |
| 500 | `ERR_INTERNAL` | Unexpected failure |

---

## 5. Player Creation

Players are **not created on GET**. They are upserted as a side effect of `POST /v1/api/leaderboards/snapshot` — every unique `playerName` in the payload is inserted into the `player` table (`ON CONFLICT DO NOTHING`). A player is visible on `GET /players/{name}` only after appearing in at least one posted snapshot.

---

## 6. Error Response Shape

```json
{
  "errorCode": "ERR_PLAYER_NOT_FOUND",
  "message": "Player 'Alice' does not exist.",
  "details": { "playerName": "Alice" }
}
```

---

## 7. All Error Codes

| HTTP | `errorCode` | Situation |
|------|------------|-----------|
| 400 | `ERR_INVALID_REQUEST` | Malformed JSON, missing fields |
| 400 | `ERR_DUPLICATE_RANK` | Duplicate rank in a snapshot block |
| 401 | `ERR_UNAUTHORIZED` | Missing or invalid Bearer token |
| 404 | `ERR_LEADERBOARD_NOT_FOUND` | Leaderboard name not in DB |
| 404 | `ERR_SNAPSHOT_NOT_FOUND` | Leaderboard exists but has no snapshots |
| 404 | `ERR_PLAYER_NOT_FOUND` | Player name not in `player` table |
| 429 | `ERR_RATE_LIMITED` | Rate limit exceeded |
| 500 | `ERR_INTERNAL` | Unexpected server error |

---

*Updated by the Architect – 2026-08-30*
