# pg_index_watch

Utility for automatic rebuild of bloated indexes in PostgreSQL  
(a-la smart autovacuum, but for index bloat).

**Code version:** `1.09` (`SELECT index_watch.version();`)  
**Table structure version:** `12` (`SELECT version FROM index_watch.tables_version;`)  
**License:** BSD 3-Clause

---

## Table of contents

1. [Purpose](#purpose)
2. [How it works](#how-it-works)
3. [Requirements](#requirements)
4. [Installation](#installation)
5. [First run](#first-run)
6. [Scheduled runs](#scheduled-runs)
7. [Dry-run and force modes](#dry-run-and-force-modes)
8. [Reindex decision flow](#reindex-decision-flow)
9. [Configuration](#configuration)
10. [Monitoring and history](#monitoring-and-history)
11. [API reference](#api-reference)
12. [Limitations](#limitations)
13. [Upgrade](#upgrade)
14. [Support](#support)
15. [Todo](#todo)

---

## Purpose

Uncontrolled index bloat on frequently updated tables is a known issue in PostgreSQL.
Built-in autovacuum does not reliably shrink indexes, regardless of its settings.

**pg_index_watch** watches index bloat across local databases and rebuilds indexes
with `REINDEX INDEX CONCURRENTLY` when estimated bloat exceeds a configurable threshold.

---

## How it works

PostgreSQL 12+ provides `REINDEX CONCURRENTLY` — a mostly lock-free way to rebuild indexes.
The remaining problem is deciding **when** an index is bloated enough to rebuild.

pg_index_watch uses a simple and cheap signal that does **not** require `pgstattuple`:

1. Index size (`pg_relation_size`)
2. Estimated number of index tuples (`pg_class.reltuples`, kept up to date by autovacuum/autoanalyze)

For a healthy index the ratio *size / tuples* is roughly stable. After a clean rebuild the
tool stores this ratio as `best_ratio`. Later it estimates bloat as:

```text
estimated_bloat ≈ current_index_size / (best_ratio × current_tuples)
```

If `estimated_bloat` is at least `index_rebuild_scale_factor` (default **2×**) and the index
is large enough (`index_size_threshold`, default **10MB**), the index is rebuilt.

### Architecture (important)

- Install the schema into a **control database** (usually `postgres`).
- `index_watch.periodic` connects to **other** local databases via **`dblink`** and does **not**
  process the control database itself (`datname <> current_database()`).
- State, history, and config live in the control database under schema `index_watch`.
- Rebuilds are done remotely: `REINDEX INDEX CONCURRENTLY` over `dblink`.

If you need indexes in the control database monitored as well, either install into a dedicated
empty utility database, or run targeted `do_reindex` against that database from another place —
by default **the DB where you call `periodic` is skipped**.

---

## Requirements

### PostgreSQL version

- **Minimum:** PostgreSQL **12+**
- Prefer the **latest minor** of your major version.

Some older minors are unsafe or blocked:

| Version range | Behavior |
|---------------|----------|
| PostgreSQL **14.0 – 14.3** | `periodic` **refuses to run** (BUG #17485) |
| Older 12.x / 13.x before known bloat/REINDEX fixes | Warning at load / run time; update minor |

See also:

- https://www.postgresql.org/message-id/E1mumI4-0001Zp-PB@gemulon.postgresql.org
- https://www.postgresql.org/message-id/E1n8C7O-00066j-Q5@gemulon.postgresql.org
- https://www.postgresql.org/message-id/202205251144.6t4urostzc3s@alvherre.pgsql

### Privileges and access

- Superuser access to the control database (to install schema, use `dblink`, reindex remotely).
- Ability to connect **passwordlessly** (peer/`~/.pgpass`/etc.) as that superuser to **all**
  local databases you want managed, e.g.:

  ```bash
  psql -U postgres -d some_db -c 'SELECT 1'
  ```

- `psql` is enough for install and cron; root/sudo is **not** required.
- Extension **`dblink`** is created automatically when loading functions.

### Recommendations

- If resources allow, set non-zero `max_parallel_maintenance_workers` (value depends on the host).
- Plan for WAL and replication lag during large concurrent reindexes.
- For standby feedback / lag control:
  - PostgreSQL 12: consider `wal_keep_segments` (legacy) **or** better use a replication slot / archive;
  - PostgreSQL 13+: prefer `wal_keep_size` and/or replication slots, not `wal_keep_segments`.
- Do **not** schedule heavy `pg_dump` / long maintenance at the same time as `periodic`.

### Operational impact of `REINDEX CONCURRENTLY`

- Temporary disk usage roughly **up to ~2×** the index size while rebuilding.
- Significant WAL generation; can increase replica lag.
- Still takes a short exclusive lock at the end of the concurrent reindex.
- Only one `index_watch.periodic` run at a time (advisory lock); a second concurrent run errors.

---

## Installation

As the PostgreSQL superuser (typically `postgres`):

```bash
git clone https://github.com/dataegret/pg_index_watch
cd pg_index_watch

# create table structure (in the control database)
psql -1 -d postgres -f index_watch_tables.sql

# load functions / procedures
psql -1 -d postgres -f index_watch_functions.sql
```

Verify:

```bash
psql -1 -d postgres -c "SELECT index_watch.version();"
psql -1 -d postgres -c "SELECT version FROM index_watch.tables_version;"
```

---

## First run

### Default behavior (important)

On the **first** real run, indexes larger than `index_size_threshold` (default **10MB**) that have
**no baseline** (`best_ratio IS NULL`) are treated as candidates and will be rebuilt.

That initial pass can take **hours or days** on large clusters. Prefer a **manual** first run
on multi-TB systems and watch the log.

```bash
nohup psql -d postgres -qt -c "CALL index_watch.periodic(TRUE);" >> index_watch.log 2>&1 &
```

After baselines exist, only indexes that still look bloated (after confirmation — see below)
are rebuilt.

### Alternative: set baselines without mass reindex

If you know indexes are fresh (e.g. right after `pg_restore`, or newly created large indexes),
populate current ratios as the baseline **without** reindexing:

```sql
-- one database
SELECT index_watch.do_force_populate_index_stats('my_db', NULL, NULL, NULL);

-- one table
SELECT index_watch.do_force_populate_index_stats('my_db', 'public', 'orders', NULL);

-- one index
SELECT index_watch.do_force_populate_index_stats('my_db', 'public', 'orders', 'orders_pkey');
```

You still need a stats collection pass (e.g. `CALL index_watch.periodic(FALSE);`) so
`index_current_state` is filled for that database before force-populate is useful in normal flow;
`do_force_populate_index_stats` itself connects and records stats for the given scope.

---

## Scheduled runs

Run daily (or hourly on write-heavy systems) as the DB superuser. Skip standbys:

```cron
00 00 * * *  psql -d postgres -AtqXc "select not pg_is_in_recovery();" | grep -qx t || exit; psql -d postgres -qt -c "CALL index_watch.periodic(TRUE);"
```

Notes:

- Avoid overlapping with `pg_dump` and other long maintenance windows.
- A second overlapping `periodic` fails with an advisory-lock error by design.

---

## Dry-run and force modes

```sql
PROCEDURE index_watch.periodic(
  real_run BOOLEAN DEFAULT FALSE,
  force    BOOLEAN DEFAULT FALSE
)
```

| Call | Effect |
|------|--------|
| `CALL index_watch.periodic();` or `periodic(FALSE)` | Connect to each eligible DB, **refresh stats only** (`index_current_state`). **No REINDEX.** |
| `CALL index_watch.periodic(TRUE);` | Stats + bloat-based reindex with ANALYZE confirmation (normal production mode). |
| `CALL index_watch.periodic(TRUE, TRUE);` | Stats + **force** reindex path: rebuild suitable indexes without ANALYZE confirmation. |

Targeted rebuild for one DB / schema / table / index:

```sql
-- bloated indexes only, with confirmation
CALL index_watch.do_reindex('my_db', NULL, NULL, NULL, FALSE);

-- one table
CALL index_watch.do_reindex('my_db', 'public', 'orders', NULL, FALSE);

-- force rebuild of matching indexes (respects skip / still uses work list; no confirm ANALYZE)
CALL index_watch.do_reindex('my_db', 'public', 'orders', NULL, TRUE);
```

---

## Reindex decision flow

On fast-growing tables a high estimated bloat often comes from **stale `pg_class.reltuples`**,
not real bloat. To avoid unnecessary `REINDEX CONCURRENTLY`, normal mode confirms candidates
before rebuilding.

### Normal mode (`force = FALSE`, default for production `periodic(TRUE)`)

1. **Collect candidates** from `index_watch.index_current_state`  
   (size ≥ threshold, not skipped, bloat ≥ scale factor **or** `best_ratio` unknown).
2. **Refresh stats per table** — for each distinct **non-TOAST** table that has at least one
   candidate, run **one** `ANALYZE` on that table, then refresh index stats for that table via `dblink`.
3. **Re-evaluate** — recompute estimated bloat; mark indexes that no longer exceed the threshold
   as skipped.
4. **Reindex** — `REINDEX INDEX CONCURRENTLY` only for remaining work items (worst bloat first).

Indexes skipped at step 3 are written to `index_watch.reindex_history` with `skipped = TRUE`
(`reindex_duration` / `analyze_duration` zero). Review them via `index_watch.history`.

### Force mode (`force = TRUE`)

The ANALYZE confirmation step is **skipped**. Suitable indexes are rebuilt according to the
force work-list rules (still not processing objects with `skip = true` in normal candidate
filters where applicable; force includes indexes that would otherwise be selected under `_force`).

### Work set table

The current/last reindex work set is stored in **`index_watch.reindex_work`** (UNLOGGED):

- Truncated at the start of each `periodic(TRUE)` run (when `real_run` is true).
- Repopulated as databases are processed.
- Columns include `estimated_bloat_before`, post-ANALYZE `estimated_bloat`, and `reindex_skipped`.

UNLOGGED means the table is for **live debugging**, not durable audit — use `reindex_history` /
`history` for history.

```bash
# indexes that were actually reindexed (or still pending reindex in the last work set)
psql -1 -d postgres -c "SELECT * FROM index_watch.reindex_work WHERE NOT reindex_skipped ORDER BY estimated_bloat DESC NULLS FIRST;"

# indexes skipped after ANALYZE confirmation
psql -1 -d postgres -c "SELECT * FROM index_watch.reindex_work WHERE reindex_skipped ORDER BY estimated_bloat_before DESC NULLS FIRST;"
```

After each successful reindex the tool also runs `ANALYZE` on the parent table (except TOAST)
to refresh statistics post-rebuild.

### Crash safety for invalid concurrent leftovers

If a previous run was interrupted during `REINDEX CONCURRENTLY`, the next `periodic` tries to
drop leftover invalid `*_ccnew` indexes recorded in `index_watch.current_processed_index`.

---

## Configuration

Settings live in `index_watch.config` and are resolved by **most specific match wins**:

1. per **index**
2. per **table**
3. per **schema**
4. per **database**
5. **global** (all NULL scope columns)

Name fields support simple wildcards: `*` → any chars, `?` → single char  
(converted to POSIX regex internally).

### Keys and defaults

| Key | Default | Meaning |
|-----|---------|---------|
| `index_size_threshold` | `10MB` | Ignore smaller indexes in normal bloat selection |
| `index_rebuild_scale_factor` | `2` | Rebuild when estimated bloat ≥ this factor |
| `minimum_reliable_index_size` | `128kB` | Below this, size/tuples is not trusted as a `best_ratio` baseline |
| `reindex_history_retention_period` | `10 years` | How long to keep rows in `reindex_history` |
| `skip` | (unset / false) | If `true`, do not process this DB/schema/table/index |

Built-in skip rules (installed with tables):

| Scope | Key | Value | Reason |
|-------|-----|-------|--------|
| any DB / schema `repack` | `skip` | `true` | pg_repack internals |
| any DB / `pgq.event_*` tables | `skip` | `true` | pgq transient tables |

### Examples

```sql
-- global: rebuild only when bloat ≥ 2.5×
SELECT index_watch.set_or_replace_setting(
  NULL, NULL, NULL, NULL,
  'index_rebuild_scale_factor', '2.5',
  'stricter global threshold'
);

-- skip an entire database
SELECT index_watch.set_or_replace_setting(
  'reporting', NULL, NULL, NULL,
  'skip', 'true',
  'reporting is archived / read-mostly'
);

-- raise size threshold for one busy table
SELECT index_watch.set_or_replace_setting(
  'app', 'public', 'events', NULL,
  'index_size_threshold', '100MB',
  'only large indexes on events'
);

-- skip one index
SELECT index_watch.set_or_replace_setting(
  'app', 'public', 'events', 'events_created_at_idx',
  'skip', 'true',
  'rebuilt manually / special case'
);

-- read effective setting for an index
SELECT index_watch.get_setting(
  'app', 'public', 'events', 'events_pkey',
  'index_rebuild_scale_factor'
);

-- inspect all config rows
SELECT * FROM index_watch.config ORDER BY id;
```

---

## Monitoring and history

History is updated during real runs (`periodic(TRUE)` / `do_reindex`).

### Human-readable history view

```bash
psql -1 -d postgres -c "SELECT * FROM index_watch.history LIMIT 20;"

# only indexes skipped after ANALYZE confirmation
psql -1 -d postgres -c "SELECT * FROM index_watch.history WHERE skipped ORDER BY ts DESC LIMIT 20;"
```

`index_watch.history` columns (view over `reindex_history`):

| Column | Meaning |
|--------|---------|
| `ts` | Event time |
| `db` / `schema` / `table` / `index` | Object identity |
| `size_before` / `size_after` | Pretty sizes |
| `ratio` | size_before / size_after |
| `tup_b_anlz` / `tup_a_anlz` | Estimated tuples before/after ANALYZE (pretty) |
| `skipped` | `true` if not reindexed after confirmation |
| `duration` | Reindex duration |

### Current bloat estimates

Requires that `periodic` (or equivalent stats collection) has run; otherwise data is stale/missing.

```bash
psql -1 -d postgres -c \
  "SELECT * FROM index_watch.get_index_bloat_estimates('DB_NAME')
   ORDER BY estimated_bloat DESC NULLS LAST
   LIMIT 40;"
```

`estimated_bloat IS NULL` usually means **no baseline yet** — those indexes are high priority
on the next real run (unless you force-populate baselines).

---

## API reference

### `index_watch.version()`

```text
FUNCTION index_watch.version() RETURNS TEXT
```

Installed **code** version.

### `index_watch.check_update_structure_version()`

```text
FUNCTION index_watch.check_update_structure_version() RETURNS VOID
```

Migrates table structure up to the version required by the loaded code.
Also runs automatically at the start of `periodic`.

### `index_watch.get_setting(...)`

```text
FUNCTION index_watch.get_setting(
  _datname text, _schemaname text, _relname text, _indexrelname text,
  _key TEXT
) RETURNS TEXT
```

Resolved setting value for the given scope and key.

### `index_watch.set_or_replace_setting(...)`

```text
FUNCTION index_watch.set_or_replace_setting(
  _datname text, _schemaname text, _relname text, _indexrelname text,
  _key TEXT, _value text, _comment text
) RETURNS VOID
```

Insert or replace a setting at the given scope (see [Configuration](#configuration)).

### `index_watch.get_index_bloat_estimates(...)`

```text
FUNCTION index_watch.get_index_bloat_estimates(_datname name)
RETURNS TABLE(
  datname name, schemaname name, relname name, indexrelname name,
  indexsize bigint, estimated_bloat real
)
```

Current estimated bloat for one database from `index_current_state`.

### `index_watch.do_force_populate_index_stats(...)`

```text
FUNCTION index_watch.do_force_populate_index_stats(
  _datname name, _schemaname name, _relname name, _indexrelname name
) RETURNS VOID
```

Force-record current size/tuples ratio as `best_ratio` (when index is large enough)
**without** reindexing. Useful after restore or for known-clean indexes.

### `index_watch.do_reindex(...)`

```text
PROCEDURE index_watch.do_reindex(
  _datname name, _schemaname name, _relname name, _indexrelname name,
  _force BOOLEAN DEFAULT FALSE
)
```

Reindex bloated indexes in the given scope (NULL = wildcard for that level).
In normal mode runs per-table ANALYZE confirmation; see [Reindex decision flow](#reindex-decision-flow).

### `index_watch.periodic(...)`

```text
PROCEDURE index_watch.periodic(
  real_run BOOLEAN DEFAULT FALSE,
  force BOOLEAN DEFAULT FALSE
)
```

For each eligible local database (except the control DB):

1. Check PG bugfix gates and take an advisory lock
2. Optionally migrate structure + cleanup old history / invalid `_ccnew` leftovers
3. Refresh index stats
4. If `real_run`, call `do_reindex(..., force)`

---

## Limitations

### Not reindexed (hardcoded)

- Schemas `pg_catalog`, `information_schema`, `index_watch`
- **BRIN** indexes (PostgreSQL bug #17205 related safety)
- Indexes backing **exclusion** constraints
- Indexes on **temporary** relations
- TOAST indexes on unsafe PG minors (on fixed minors, TOAST may be included)
- Objects with config `skip = true`
- Indexes smaller than `index_size_threshold` in normal (non-force) selection
- The **control database** itself is not visited by `periodic`

### Other constraints

- Local cluster only (remote databases are not supported yet).
- Relies on `reltuples` quality; confirmation ANALYZE mitigates false positives but is not magic.
- Bloat estimate is a **heuristic** (very good for btree-like growth patterns; not a page-level survey).
- `reindex_work` is UNLOGGED — not a durable log.

---

## Upgrade

As the PostgreSQL superuser, from the git checkout:

```bash
cd pg_index_watch
git pull

# 1) load updated code FIRST (migrations live in this file)
psql -1 -d postgres -f index_watch_functions.sql

# 2) apply table structure migrations
psql -1 -d postgres -c "SELECT index_watch.check_update_structure_version();"
```

Structure migration also runs automatically on the next `index_watch.periodic`, but
**`index_watch_functions.sql` must be loaded first**.

Verify:

```bash
psql -1 -d postgres -c "SELECT index_watch.version();"
psql -1 -d postgres -c "SELECT version FROM index_watch.tables_version;"
psql -1 -d postgres -c "SELECT to_regclass('index_watch.reindex_work');"
```

`version()` is the **code** version; `tables_version` is the **schema** version — both matter.

---

## Support

- Open a GitHub issue on the project repository
- Email: maxim.boguk@dataegret.com
- Telegram: https://t.me/pg_index_watch_support

---

## Todo

- Support watching remote databases
- Improve inline code comments
- Optional: more recipes (Patroni/HA scheduling, per-DB maintenance windows)

---

## License

BSD 3-Clause. See [`LICENSE`](LICENSE) and [`COPYRIGHT`](COPYRIGHT).
