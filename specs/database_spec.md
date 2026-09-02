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
| `created_at` | `timestamptz` | NOT NULL, server default `now()` |

Players are upserted as a side effect of snapshot ingestion.

## 2. Integrity and access behavior

Foreign keys cascade snapshot/entry deletion. Duplicate ranks are rejected both by request validation and the database unique constraint. Positive rank, estimated completion time, and group size are database-checked. Leaderboard and player names/IDs are unique.

Repositories use SQLAlchemy async sessions and parameterized expressions. The snapshot use case commits leaderboard, snapshot, entry, and player changes as one unit of work; cache invalidation occurs after commit.

## 3. Updated timestamp trigger

The migration creates `set_updated_timestamp()` and `trg_leaderboard_updated`, which sets `leaderboard.updated_at = NOW()` before updates. The ORM also declares `onupdate=func.now()`; deployments should keep migration and ORM behavior aligned.

## 4. Migration notes

Alembic migrations are under `veda-backend/app/migrations/versions/`. The latest leaderboard migration recreates the leaderboard table to add external IDs and metadata, so deployment must follow the migration chain and account for its destructive `downgrade()` behavior. Do not apply the old three-table-only schema as a replacement for the current migrations.
