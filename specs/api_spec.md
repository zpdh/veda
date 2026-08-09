# API Specification – Leaderboard Service (v1)

*Version:* 1.0
*Base path:* `/v1/api/leaderboards`
*Content type:* `application/json`

---

## 1. Overview
The Leaderboard Service provides two operations:
1. **GET** the *latest* snapshot for a specific leaderboard identified by its **name**.
2. **POST** a batch of snapshots for one or more leaderboards (each identified by name). The POST operation stores all supplied snapshots; the GET endpoint will always return the most recent snapshot for a given leaderboard.

All timestamps are UTC and expressed in ISO‑8601 format.

---

## 2. Endpoints

| Method | Path | Description | Request DTO | Response DTO | Success Status |
|--------|------|-------------|-------------|--------------|----------------|
| **GET** | `GET /v1/api/leaderboards/{leaderboardName}` | Retrieve the **latest** snapshot for the leaderboard identified by `leaderboardName`. | – | `SnapshotResponse` | `200 OK` |
| **POST** | `POST /v1/api/leaderboards/snapshot` | Create one or more snapshots (batch). Each snapshot belongs to a leaderboard identified by its name. | `CreateSnapshotRequest` | `SnapshotCreatedResponse` | `201 Created` |

---

## 3. DTOs (Data Transfer Objects)

### 3.1 `EntryIn`
```json
{
  "rank": 1,
  "playerName": "Alice",
   "value": 5
}
```
*Constraints*: `rank` must be a positive integer, `playerName` a non‑empty string (max 255 chars), and `value` a non‑negative integer representing the number of clears for the entry.

### 3.2 `LeaderboardSnapshotIn`
```json
{
  "leaderboardName": "global-rankings",
  "entries": [
     { "rank": 1, "playerName": "Alice", "value": 5 },
    { "rank": 2, "playerName": "Bob", "value": 3 }
  ]
}
```
*Validation rules*
- `leaderboardName` is required and must correspond to an existing row in the `leaderboard` table (unique column `name`).
- `entries` must contain **at least one** element.
- Ranks inside a single `entries` array must be unique; otherwise a `400 ERR_DUPLICATE_RANK` error is returned.

### 3.3 `CreateSnapshotRequest`
```json
{
  "snapshots": [
    {
      "leaderboardName": "global-rankings",
      "entries": [ … ]
    },
    {
      "leaderboardName": "weekly-challenges",
      "entries": [ … ]
    }
    // … more leaderboard blocks …
  ]
}
```
*Overall validation*
- The top‑level `snapshots` array must contain **at least one** `LeaderboardSnapshotIn`.
- Each block is validated independently (see 3.2).
- The whole request is **atomic** – if any block fails, **no** snapshot is persisted.

### 3.4 `SnapshotResponse`
Returned by the **GET** endpoint.
```json
{
  "snapshotId": 124,
  "leaderboardName": "global-rankings",
  "fetchedAt": "2026-08-08T15:07:13Z",
  "entries": [
    { "entryId": 987, "rank": 1, "playerName": "Alice", "value": "Zenith" },
    { "entryId": 988, "rank": 2, "playerName": "Bob", "value": "Zenith" }
  ]
}
```
If no snapshot exists for the supplied leaderboard name, the endpoint returns **404**.

### 3.5 `SnapshotCreatedResponse`
Returned by the **POST** endpoint after a successful batch insert.
```json
{
  "snapshotIds": [124, 125],
  "fetchedAt": "2026-08-08T16:34:12Z",
  "message": "Snapshots created successfully."
}
```
All snapshots in the request share the same `fetchedAt` timestamp (the server’s UTC time at request handling).

---

## 4. Errors (standardised JSON payload)
All error responses conform to the following shape (defined in the original spec):
```json
{
  "errorCode": "ERR_LEADERBOARD_NOT_FOUND",
  "message": "Leaderboard 'nonexistent' does not exist.",
  "details": {
    "leaderboardName": "nonexistent"
  }
}
```
### Enumerated `errorCode` values
| HTTP Status | `errorCode` | Situation |
|-------------|------------|-----------|
| **400** | `ERR_INVALID_REQUEST` | Malformed JSON, missing required fields, duplicate rank within a leaderboard block, empty `snapshots` array, invalid timestamps in a future GET (not applicable here). |
| **400** | `ERR_DUPLICATE_RANK` | Two or more entries in the same leaderboard block share the same rank. |
| **404** | `ERR_LEADERBOARD_NOT_FOUND` | `leaderboardName` supplied in GET or POST does not exist in the `leaderboard` table. |
| **404** | `ERR_SNAPSHOT_NOT_FOUND` | GET request found no snapshot for the existing leaderboard (i.e., the leaderboard has never been snapshotted). |
| **409** | `ERR_SNAPSHOT_CONFLICT` | Extremely rare – a snapshot with the exact same `fetchedAt` already exists for a given leaderboard (guarded for safety). |
| **500** | `ERR_INTERNAL` | Unexpected server error / DB connectivity issue. |

---

## 5. Endpoint Details

### 5.1 GET – Latest Snapshot
**Path**: `GET /v1/api/leaderboards/{leaderboardName}`

**Path parameter**
- `leaderboardName` (string, case‑sensitive) – the unique name of the leaderboard.

**Responses**
| Code | Meaning | Body |
|------|---------|------|
| `200 OK` | Snapshot found | `SnapshotResponse` |
| `404 Not Found` | Leaderboard does not exist **or** no snapshot stored for it | `ErrorResponse` (`ERR_LEADERBOARD_NOT_FOUND` or `ERR_SNAPSHOT_NOT_FOUND`) |
| `500 Internal Server Error` | Unexpected failure | `ErrorResponse` |

*The GET endpoint never creates or modifies data; it simply returns the most recent snapshot (`ORDER BY fetched_at DESC LIMIT 1`).*

---

### 5.2 POST – Batch Snapshot Creation
**Path**: `POST /v1/api/leaderboards/snapshot`

**Request body** – `CreateSnapshotRequest` (see §3.3).

**Processing flow**
1. Validate JSON schema (Pydantic).  
2. Resolve every `leaderboardName` to its internal `id` (single `SELECT id FROM leaderboard WHERE name = ANY(:names)`).  
3. If any name cannot be resolved, abort with `404 ERR_LEADERBOARD_NOT_FOUND`.  
4. Begin a single database transaction.  
5. Insert a `leaderboard_snapshot` row for each leaderboard (all rows share the same `fetched_at = now() UTC`).  
6. Bulk‑insert all associated `leaderboard_entry` rows, respecting the `UNIQUE(snapshot_id, rank)` constraint.  
7. Commit.  
8. Return the list of generated snapshot IDs in the order the leaderboards were supplied.

**Responses**
| Code | Meaning | Body |
|------|---------|------|
| `201 Created` | All snapshots stored successfully | `SnapshotCreatedResponse` |
| `400 Bad Request` | Validation failure (duplicate rank, empty entries, malformed JSON) | `ErrorResponse` (`ERR_INVALID_REQUEST` / `ERR_DUPLICATE_RANK`) |
| `404 Not Found` | One or more supplied `leaderboardName`s do not exist | `ErrorResponse` (`ERR_LEADERBOARD_NOT_FOUND`) |
| `409 Conflict` | Snapshot conflict (rare) | `ErrorResponse` (`ERR_SNAPSHOT_CONFLICT`) |
| `500 Internal Server Error` | Unexpected failure | `ErrorResponse` |

*The operation is atomic – either every snapshot is persisted or none are.*

---

## 6. Example Calls
### 6.1 GET latest snapshot
```
GET /v1/api/leaderboards/global-rankings HTTP/1.1
Accept: application/json
```
**Response (200)**
```json
{
  "snapshotId": 124,
  "leaderboardName": "global-rankings",
  "fetchedAt": "2026-08-08T15:07:13Z",
  "entries": [
    { "entryId": 987, "rank": 1, "playerName": "Alice" },
    { "entryId": 988, "rank": 2, "playerName": "Bob" }
  ]
}
```
---
### 6.2 POST batch snapshot
```
POST /v1/api/leaderboards/snapshot HTTP/1.1
Content-Type: application/json
Accept: application/json

{
  "snapshots": [
    {
      "leaderboardName": "global-rankings",
      "entries": [
        { "rank": 1, "playerName": "Alice" },
        { "rank": 2, "playerName": "Bob" }
      ]
    },
    {
      "leaderboardName": "weekly-challenges",
      "entries": [
        { "rank": 1, "playerName": "Carol" },
        { "rank": 2, "playerName": "Dave" }
      ]
    }
  ]
}
```
**Response (201)**
```json
{
  "snapshotIds": [124, 125],
  "fetchedAt": "2026-08-08T16:34:12Z",
  "message": "Snapshots created successfully."
}
```
---
### 6.3 POST error – unknown leaderboard
```json
{
  "errorCode": "ERR_LEADERBOARD_NOT_FOUND",
  "message": "Leaderboard 'unknown-lb' does not exist.",
  "details": { "leaderboardName": "unknown-lb" }
}
```
---

## 7. Notes & Recommendations
* **GET endpoint is read‑only** – it always returns the *most recent* snapshot; older snapshots remain in the database for historical analysis or debugging.
* **POST endpoint is designed for bulk ingestion** – useful when an external system pushes a full state dump for many leaderboards at once.
* The database cleanup (deleting snapshots older than 7 days) continues to be handled by the PostgreSQL `pg_cron` job defined in `database_spec.md`.
* All timestamps are stored as `timestamptz` (`UTC`) and returned in ISO‑8601 format.

---

*Document authored by the Architect – 2026‑08‑08*