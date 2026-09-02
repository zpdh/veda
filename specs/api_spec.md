# API Specification – Veda Leaderboards and Players

**Base path:** `/api/v1` · **Content type:** `application/json` · **Timestamps:** UTC ISO-8601

## 1. Endpoint index

| Method | Path                                      | Auth                 | Rate limit | Response                        |
| ------ | ----------------------------------------- | -------------------- | ---------- | ------------------------------- |
| GET    | `/api/v1/leaderboards`                    | None                 | 60/minute  | `LeaderboardsResponse`          |
| GET    | `/api/v1/leaderboards/{leaderboard_name}` | None                 | 60/minute  | `SnapshotResponse`              |
| POST   | `/api/v1/leaderboards/snapshot`           | Bearer shared secret | 5/minute   | `SnapshotCreatedResponse` (201) |
| GET    | `/api/v1/players/`                        | None                 | 60/minute  | `AllPlayersResponse`            |
| GET    | `/api/v1/players/{player_name}`           | None                 | 60/minute  | `PlayerResponse`                |

## 2. Leaderboard ingestion

```json
{
  "snapshots": [
    {
      "leaderboardName": "Celestial Zenith",
      "entries": [{ "rank": 1, "playerName": "Alice", "value": 8 }]
    }
  ]
}
```

Constraints: `snapshots` and each `entries` array contain at least one item; `rank` is an integer > 0; `value` is an integer >= 0; `playerName` is 1–16 characters matching `^[a-zA-Z0-9_]+$`; `leaderboardName` is 1–128 characters. Ranks must be unique within each snapshot block.

The endpoint requires `Authorization: Bearer <shared_secret>`. Processing is validated, upserted/inserted in one unit of work, committed, then affected player cache keys are deleted. All snapshots share one `fetchedAt` timestamp.

Response:

```json
{
  "snapshotIds": [124],
  "fetchedAt": "2026-09-02T15:07:13Z",
  "message": "Snapshots created successfully."
}
```

## 3. Leaderboards

`GET /api/v1/leaderboards` returns:

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

`GET /api/v1/leaderboards/{leaderboard_name}` returns:

```json
{
  "snapshotId": 124,
  "leaderboardName": "Celestial Zenith",
  "fetchedAt": "2026-09-02T15:07:13Z",
  "entries": [{ "entryId": 987, "rank": 1, "playerName": "Alice", "value": 8 }]
}
```

The leaderboard name is passed as a path value. The backend’s current route does not declare additional path validation. Errors: 404 `ERR_LEADERBOARD_NOT_FOUND` when the leaderboard is absent, 404 `ERR_SNAPSHOT_NOT_FOUND` when it has no snapshot, 429 `ERR_RATE_LIMITED`, and 500 `ERR_INTERNAL`.

## 4. Players

`GET /api/v1/players/` returns repository-order names:

```json
{ "players": ["Alice", "Bob"] }
```

`GET /api/v1/players/{player_name}` accepts 1–16 characters matching `^[a-zA-Z0-9_]+$`; lookup is case-insensitive.

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

Each entry is the player’s latest result per leaderboard. Playtime is `value * estimatedTimePerCompletionMinutes`; totals sum returned entries. Players are created by snapshot ingestion, not GET. Missing players return 404 `ERR_PLAYER_NOT_FOUND`.

## 5. Error format

```json
{
  "errorCode": "ERR_PLAYER_NOT_FOUND",
  "message": "Player Alice does not exist.",
  "details": { "playerName": "Alice" }
}
```

Defined application codes: `ERR_DUPLICATE_RANK` (400), `ERR_UNAUTHORIZED` (401), `ERR_LEADERBOARD_NOT_FOUND` (404), `ERR_SNAPSHOT_NOT_FOUND` (404), `ERR_PLAYER_NOT_FOUND` (404), `ERR_RATE_LIMITED` (429), and `ERR_INTERNAL` (500). Standard FastAPI validation responses remain framework-generated.
