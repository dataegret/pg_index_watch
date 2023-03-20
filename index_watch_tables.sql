\set ON_ERROR_STOP

DO $$
BEGIN
  IF (SELECT setting FROM pg_settings WHERE name='server_version_num')<'12'
  THEN
    RAISE 'This library works only for PostgreSQL 12 or higher!';
  END IF;
END; $$;



CREATE SCHEMA IF NOT EXISTS index_watch;

--history of performed REINDEX action
CREATE TABLE index_watch.reindex_history
(
  id bigserial primary key,
  entry_timestamp timestamptz not null default now(),
  indexrelid OID,
  datid OID,
  datname name not null,
  schemaname name not null,
  relname name not null,
  indexrelname name not null,
  server_version_num integer not null default current_setting('server_version_num')::integer,
  indexsize_before BIGINT not null,
  indexsize_after BIGINT not null,
  estimated_tuples bigint not null,
  reindex_duration interval not null,
  analyze_duration interval not null
);
CREATE INDEX reindex_history_oid_index on index_watch.reindex_history(datid, indexrelid);
CREATE INDEX reindex_history_index on index_watch.reindex_history(datname, schemaname, relname, indexrelname);

--history of index sizes (not really neccessary to keep all this data but very useful for future analyzis of bloat trends
CREATE TABLE index_watch.index_current_state 
(
  id bigserial primary key,
  mtime timestamptz not null default now(),
  indexrelid OID not null,
  datid OID not null,
  datname name not null,
  schemaname name not null,
  relname name not null,
  indexrelname name not null,
  indexsize BIGINT not null,
  indisvalid BOOLEAN not null DEFAULT TRUE,
  estimated_tuples BIGINT not null,
  best_ratio REAL
);
CREATE UNIQUE INDEX index_current_state_oid_index on index_watch.index_current_state(datid, indexrelid);
CREATE INDEX index_current_state_index on index_watch.index_current_state(datname, schemaname, relname, indexrelname);

--settings table
CREATE TABLE index_watch.config
(
  id bigserial primary key,
  datname name,
  schemaname name,
  relname name,
  indexrelname name,
  key text not null,
  value text,
  comment text  
);
CREATE UNIQUE INDEX config_u1 on index_watch.config(key) WHERE datname IS NULL;
CREATE UNIQUE INDEX config_u2 on index_watch.config(key, datname) WHERE schemaname IS NULL;
CREATE UNIQUE INDEX config_u3 on index_watch.config(key, datname, schemaname) WHERE relname IS NULL;
CREATE UNIQUE INDEX config_u4 on index_watch.config(key, datname, schemaname, relname) WHERE indexrelname IS NULL;
CREATE UNIQUE INDEX config_u5 on index_watch.config(key, datname, schemaname, relname, indexrelname);
ALTER TABLE index_watch.config ADD CONSTRAINT inherit_check1 CHECK (indexrelname IS NULL OR indexrelname IS NOT NULL AND relname    IS NOT NULL);
ALTER TABLE index_watch.config ADD CONSTRAINT inherit_check2 CHECK (relname      IS NULL OR relname      IS NOT NULL AND schemaname IS NOT NULL);
ALTER TABLE index_watch.config ADD CONSTRAINT inherit_check3 CHECK (schemaname   IS NULL OR schemaname   IS NOT NULL AND datname    IS NOT NULL);


CREATE VIEW index_watch.history AS
  SELECT date_trunc('second', entry_timestamp)::timestamp AS ts,
       datname AS db, schemaname AS schema, relname AS table, 
       indexrelname AS index, pg_size_pretty(indexsize_before) AS size_before, 
       pg_size_pretty(indexsize_after) AS size_after,
       (indexsize_before::float/indexsize_after)::numeric(12,2) AS ratio, 
       pg_size_pretty(estimated_tuples) AS tuples, date_trunc('seconds', reindex_duration) AS duration 
  FROM index_watch.reindex_history ORDER BY id DESC;


--DEFAULT GLOBAL settings
INSERT INTO index_watch.config (key, value, comment) VALUES 
('index_size_threshold', '10MB', 'ignore indexes under 10MB size unless forced entries found in history'),
('index_rebuild_scale_factor', '2', 'rebuild indexes by default estimated bloat over 2x'),
('minimum_reliable_index_size', '128kB', 'small indexes not reliable to use as gauge'),
('reindex_history_retention_period','10 years', 'reindex history default retention period'),
;


--current version of table structure
CREATE TABLE index_watch.tables_version
(
	version smallint NOT NULL
);
CREATE UNIQUE INDEX tables_version_single_row ON  index_watch.tables_version((version IS NOT NULL));
INSERT INTO index_watch.tables_version VALUES(7);

