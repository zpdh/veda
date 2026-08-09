# Database Specification – Leaderboard System

**PostgreSQL 18 (Docker)**

This document defines the relational schema for the leaderboard feature and the maintenance job that removes old snapshots.

---

## 1. Tables & Columns

### `leaderboard`
| Column      | Type               | Constraints |
|------------|--------------------|-------------|
| `id`       | `bigserial`        | Primary Key |
| `name`     | `text`             | `NOT NULL`, `UNIQUE` |
| `created_at` | `timestamptz`    | `NOT NULL` – default `now()` |
| `updated_at` | `timestamptz`    | `NOT NULL` – default `now()` (updated via trigger) |

### `leaderboard_snapshot`
| Column          | Type        | Constraints |
|----------------|------------|--------------|
| `id`           | `bigserial` | Primary Key |
| `leaderboard_id` | `bigint`   | `NOT NULL`, foreign key → `leaderboard(id)` **ON DELETE CASCADE** |
| `fetched_at`   | `timestamptz` | `NOT NULL` |

### `leaderboard_entry`
| Column      | Type        | Constraints |
|------------|-------------|-------------|
| `id`       | `bigserial` | Primary Key |
| `snapshot_id` | `bigint`    | `NOT NULL`, foreign key → `leaderboard_snapshot(id)` **ON DELETE CASCADE** |
| `rank`     | `integer`   | `NOT NULL`, `CHECK (rank > 0)`, **UNIQUE(`snapshot_id`, `rank`)** |
| `player_name` | `text`    | `NOT NULL` |
| `value`    | `integer`    | `NOT NULL` |

---

## 2. Indexes
```sql
CREATE INDEX idx_snapshot_fetched_at ON leaderboard_snapshot (fetched_at);
CREATE INDEX idx_entry_snapshot_id ON leaderboard_entry (snapshot_id);
```
These indexes support fast lookup for the cleanup job and for retrieving entries of a particular snapshot.

---

## 3. Triggers – keep `updated_at` in sync
```sql
CREATE OR REPLACE FUNCTION set_updated_timestamp()
RETURNS TRIGGER AS $$
BEGIN
   NEW.updated_at = NOW();
   RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_leaderboard_updated
BEFORE UPDATE ON leaderboard
FOR EACH ROW EXECUTE FUNCTION set_updated_timestamp();
```
The trigger fires on every `UPDATE` of a leaderboard row, ensuring `updated_at` always reflects the latest modification.

---

## 4. Automatic Cleanup (Option A)
We will use PostgreSQL's `pg_cron` extension to run a daily job that deletes snapshots older than 7 days; cascade rules automatically remove dependent `leaderboard_entry` rows.

### 4.1 Enable the extension (run once as a super‑user)
```sql
CREATE EXTENSION IF NOT EXISTS pg_cron;
```

### 4.2 Schedule the cleanup job
```sql
SELECT cron.schedule(
    'daily_snapshot_cleanup',               -- job name
    '0 2 * * *',                            -- run daily at 02:00 UTC
    $$
        DELETE FROM leaderboard_snapshot
        WHERE fetched_at < (now() - interval '7 days');
    $$
);
```
The `DELETE` statement uses the `idx_snapshot_fetched_at` index, making the operation fast even with many rows.

### 4.3 Alternative (host‑side cron) – if `pg_cron` cannot be installed
```bash
# Example command that could be placed in a host cron (run daily)
psql -U <user> -d <database> -c "
    DELETE FROM leaderboard_snapshot
    WHERE fetched_at < (now() - interval '7 days');
"
```
The same `DELETE` statement works identically; the only difference is who schedules it.

---

## 5. Data‑integrity Guarantees
* **Referential integrity** – foreign keys with `ON DELETE CASCADE` prevent orphan rows.
* **Unique ranking per snapshot** – the `UNIQUE(snapshot_id, rank)` constraint ensures a player cannot occupy the same rank twice within a snapshot.
* **Positive rank** – `CHECK (rank > 0)` guarantees logical ordering.
* **Timestamp handling** – all timestamps are stored as `timestamptz` (UTC). Applications should always send UTC timestamps to avoid timezone drift.

---

## 6. Validation Checklist
1. **Schema creation** – apply the DDL and verify tables/constraints (`\d+ leaderboard*`).
2. **Insert/Update flow** –
   * Insert a leaderboard, a snapshot, and several entries.
   * Update the leaderboard name and confirm `updated_at` changed.
   * Attempt to insert a duplicate rank for the same snapshot – expect an error.
3. **Cleanup job** –
   * Create one snapshot with `fetched_at = now() - interval '8 days'` and another with `now()`.
   * Manually run the `DELETE` statement and ensure only the old snapshot (and its entries) disappear.
   * Verify the scheduled `pg_cron` job appears in `SELECT * FROM cron.job;`.
4. **Performance sanity** – run `EXPLAIN ANALYZE` on the delete query with a few thousand rows; confirm it uses the `idx_snapshot_fetched_at` index.

---

## 7. Future Considerations
* If snapshot volume grows dramatically, consider **range partitioning** on `fetched_at` (Option B) to make cleanup a simple `DROP PARTITION`.
* Add a **soft‑delete flag** on `leaderboard` if accidental cascade deletions become a risk.
* Log deletion activity (e.g., using `RAISE LOG` inside a stored procedure) for audit trails.

---

*Document authored by the Architect – 2026‑08‑08*