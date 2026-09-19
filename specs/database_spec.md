# Database Specification – Leaderboard System

**Database:** PostgreSQL

## 1. Tables

### `leaderboard`

| Column | Type | Constraints |
|---|---|---|
| `id` | `bigint` | Primary key |
| `external_leaderboard_id` | `text` | NOT NULL, UNIQUE |
| `name` | `text` | NOT NULL, UNIQUE |
| `estimated_time_per_completion_minutes` | `integer` | NOT NULL, CHECK > 0 |
| `group_size` | `integer` | NOT NULL, CHECK > 0 |
| `created_at` | `timestamptz` | NOT NULL, server default `now()` |
| `updated_at` | `timestamptz` | NOT NULL, server default `now()`; updated by trigger/migration |

The current migration seeds leaderboard metadata including Zenith, Twisted Intruder, Aurora, Hexfall, Silver Knights Tomb variants, Godspore, Portal, Masqueraders Ruin, and Silver Knight Remnants variants.

### `leaderboard_snapshot`

| Column | Type | Constraints |
|---|---|---|
| `id` | `bigint` | Primary key |
| `leaderboard_id` | `bigint` | NOT NULL, FK → `leaderboard(id)` ON DELETE CASCADE |
| `fetched_at` | `timestamptz` | NOT NULL, server default `now()` |

### `leaderboard_entry`

| Column | Type | Constraints |
|---|---|---|
| `id` | `bigint` | Primary key |
| `snapshot_id` | `bigint` | NOT NULL, FK → `leaderboard_snapshot(id)` ON DELETE CASCADE |
| `rank` | `integer` | NOT NULL, CHECK > 0, UNIQUE with `snapshot_id` |
| `player_name` | `text` | NOT NULL |
| `value` | `integer` | NOT NULL |

### `player`

| Column | Type | Constraints |
|---|---|---|
| `id` | `bigint` | Primary key |
| `name` | `text` | NOT NULL, UNIQUE |
| `weight` | `float` | NOT NULL, server default `0`; indexed (`idx_player_weight`) |
| `created_at` | `timestamptz` | NOT NULL, server default `now()` |

Players are upserted as a side effect of snapshot ingestion. `weight` is a materialized, cross-leaderboard score that is **recomputed for every player affected by a snapshot batch inside the ingestion transaction** (see §5). It is never calculated on read. Players that have not been re-ingested since the column was introduced hold the server default `0` until their next ingestion.

### Indexes

| Index | Table | Columns | Purpose |
|---|---|---|---|
| `idx_player_weight` | `player` | `weight` | Weight leaderboard ordering (`ORDER BY weight DESC`) |
| `idx_player_name_lower` | `player` | `lower(name)` (UNIQUE) | Case-insensitive player lookup + case-insensitive uniqueness |
| `idx_leaderboard_entry_player_name_lower` | `leaderboard_entry` | `lower(player_name)` | Case-insensitive per-player entry lookups |
| `idx_leaderboard_snapshot_leaderboard_id_latest` | `leaderboard_snapshot` | `leaderboard_id`, `fetched_at DESC` | Latest-snapshot-per-leaderboard lookups |

## 2. Integrity and access behavior

Foreign keys cascade snapshot/entry deletion. Duplicate ranks are rejected both by request validation and the database unique constraint. Positive rank, estimated completion time, and group size are database-checked. Leaderboard and player names/IDs are unique.

Repositories use SQLAlchemy async sessions and parameterized expressions. The snapshot use case commits leaderboard, snapshot, entry, player, and player-weight changes as one unit of work; cache invalidation occurs after commit.

## 3. Updated timestamp trigger

The migration creates `set_updated_timestamp()` and `trg_leaderboard_updated`, which sets `leaderboard.updated_at = NOW()` before updates. The ORM also declares `onupdate=func.now()`; deployments should keep migration and ORM behavior aligned.

## 4. Migration notes

Alembic migrations are under `veda-backend/app/migrations/versions/`. The latest migrations add performance indexes, an HTTP-client-independent schema, and the `player.weight` column/index. The leaderboard-table migration recreates the table to add external IDs and metadata, so deployment must follow the migration chain and account for its destructive `downgrade()` behavior. Do not apply the old three-table-only schema as a replacement for the current migrations.

## 5. Weight computation and persistence

`player.weight` is a derived score computed by `app/core/util/weight.py`. It combines, per leaderboard the player appears on (latest entry only):

- **Effective playtime** — a segmented linear + exponential-decay curve over `value * estimated_time_per_completion_minutes`.
- **Leaderboard weight** — `15 * sqrt(group_size / 4)`.
- **Rank factor** — `1 + boost` for ranks 1/2/3 (`0.06/0.04/0.02`), `1` otherwise.
- **Diversification coefficient** — normalized Herfindahl–Hirschman index across the player's boards, penalizing concentration (max 30% penalty).

These are multiplied per entry and summed, then scaled by the diversification coefficient. During `POST /leaderboards/snapshot`, after players are upserted, the affected players' latest entries across **all** leaderboards are fetched in one batched query, weights are recomputed, and `player.weight` is bulk-updated — all within the same transaction and before commit. Redis player-cache keys are invalidated after commit.
