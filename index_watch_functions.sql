\set ON_ERROR_STOP

CREATE OR REPLACE FUNCTION index_watch.check_pg_version_bugfixed()
RETURNS BOOLEAN AS
$BODY$
BEGIN
   IF ((current_setting('server_version_num')::INTEGER >= 120010) AND 
               (current_setting('server_version_num')::INTEGER < 130000)) OR
      ((current_setting('server_version_num')::INTEGER >= 130006) AND
               (current_setting('server_version_num')::INTEGER < 140000)) OR
      (current_setting('server_version_num')::INTEGER >= 140002) 
      THEN RETURN TRUE;
      ELSE RETURN FALSE;
    END IF;
END; 
$BODY$
LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION index_watch.check_pg14_version_bugfixed()
RETURNS BOOLEAN AS
$BODY$
BEGIN
  IF (current_setting('server_version_num')::INTEGER >= 140000) AND
          (current_setting('server_version_num')::INTEGER < 140004)
       THEN RETURN FALSE; 
       ELSE RETURN TRUE;
  END IF;
END; 
$BODY$
LANGUAGE plpgsql;


DO $$
BEGIN
  IF current_setting('server_version_num')<'12'
  THEN
    RAISE 'This library works only for PostgreSQL 12 or higher!';
  ELSE 
    IF NOT index_watch.check_pg_version_bugfixed()
    THEN
       RAISE WARNING 'The database version % affected by PostgreSQL bugs which make use pg_index_watch potentially unsafe, please update to latest minor release. For additional info please see:
   https://www.postgresql.org/message-id/E1mumI4-0001Zp-PB@gemulon.postgresql.org
   and
   https://www.postgresql.org/message-id/E1n8C7O-00066j-Q5@gemulon.postgresql.org', 
       current_setting('server_version');
    END IF;
    IF NOT index_watch.check_pg14_version_bugfixed()
      THEN
         RAISE WARNING 'The database version % affected by PostgreSQL bug BUG #17485 which make use pg_index_watch unsafe, please update to latest minor release. For additional info please see:
       https://www.postgresql.org/message-id/202205251144.6t4urostzc3s@alvherre.pgsql', 
        current_setting('server_version');
    END IF;
  END IF; 
END; $$;


CREATE EXTENSION IF NOT EXISTS dblink;
ALTER EXTENSION dblink UPDATE;

--current version of code
CREATE OR REPLACE FUNCTION index_watch.version()
RETURNS TEXT AS
$BODY$
BEGIN
    RETURN '0.24';
END;
$BODY$
LANGUAGE plpgsql IMMUTABLE;



--minimum table structure version required
CREATE OR REPLACE FUNCTION index_watch._check_structure_version()
RETURNS VOID AS
$BODY$
DECLARE
  _tables_version INTEGER;
  _required_version INTEGER := 7;
BEGIN
    SELECT version INTO STRICT _tables_version FROM index_watch.tables_version;	
    IF (_tables_version<_required_version) THEN
       RAISE EXCEPTION 'Current tables version % is less than minimally required % for % code version, please update tables structure', _tables_version, _required_version, index_watch.version();
    END IF;
END;
$BODY$
LANGUAGE plpgsql;



CREATE OR REPLACE FUNCTION index_watch._check_update_structure_version() 
RETURNS VOID AS
$BODY$
DECLARE
   _tables_version INTEGER;
   _required_version INTEGER := 7;
BEGIN
   SELECT version INTO STRICT _tables_version FROM index_watch.tables_version;	
   WHILE (_tables_version<_required_version) LOOP
      EXECUTE 'SELECT index_watch._structure_version_'||_tables_version||'_'||_tables_version+1||'()';
   _tables_version := _tables_version+1;
END LOOP;
    RETURN;
END;
$BODY$
LANGUAGE plpgsql;


--update table structure version from 1 to 2
CREATE OR REPLACE FUNCTION index_watch._structure_version_1_2() 
RETURNS VOID AS
$BODY$
BEGIN
   CREATE VIEW index_watch.history AS
      SELECT date_trunc('second', entry_timestamp)::timestamp AS ts,
         datname AS db, schemaname AS schema, relname AS table, 
         indexrelname AS index, indexsize_before AS size_before, indexsize_after AS size_after,
         (indexsize_before::float/indexsize_after)::numeric(12,2) AS ratio, 
         estimated_tuples AS tuples, date_trunc('seconds', reindex_duration) AS duration 
      FROM index_watch.reindex_history ORDER BY id DESC;
   UPDATE index_watch.tables_version SET version=2;
   RETURN;
END;
$BODY$
LANGUAGE plpgsql;


--update table structure version from 2 to 3
CREATE OR REPLACE FUNCTION index_watch._structure_version_2_3() 
RETURNS VOID AS
$BODY$
BEGIN
   CREATE TABLE index_watch.index_current_state 
   (
     id bigserial primary key,
     mtime timestamptz not null default now(),
     datname name not null,
     schemaname name not null,
     relname name not null,
     indexrelname name not null,
     indexsize BIGINT not null,
     estimated_tuples BIGINT not null,
     best_ratio REAL
   );
   CREATE UNIQUE INDEX index_current_state_index on index_watch.index_current_state(datname, schemaname, relname, indexrelname);

   UPDATE index_watch.config SET value='128kB' 
   WHERE key='minimum_reliable_index_size' AND pg_size_bytes(value)<pg_size_bytes('128kB');
   
   WITH 
    _last_reindex_values AS (
    SELECT
      DISTINCT ON (datname, schemaname, relname, indexrelname)
      reindex_history.datname, reindex_history.schemaname, reindex_history.relname, reindex_history.indexrelname, entry_timestamp, estimated_tuples, indexsize_after AS indexsize
      FROM index_watch.reindex_history 
      ORDER BY datname, schemaname, relname, indexrelname, entry_timestamp DESC
    ),
    _all_history_since_reindex AS (
       --last reindexed value
       SELECT _last_reindex_values.datname, _last_reindex_values.schemaname, _last_reindex_values.relname, _last_reindex_values.indexrelname, _last_reindex_values.entry_timestamp, _last_reindex_values.estimated_tuples, _last_reindex_values.indexsize
       FROM _last_reindex_values
       UNION ALL
       --all values since reindex or from start
       SELECT index_history.datname, index_history.schemaname, index_history.relname, index_history.indexrelname, index_history.entry_timestamp, index_history.estimated_tuples, index_history.indexsize
       FROM index_watch.index_history
       LEFT JOIN _last_reindex_values USING (datname, schemaname, relname, indexrelname)
       WHERE index_history.entry_timestamp>=coalesce(_last_reindex_values.entry_timestamp, '-INFINITY'::timestamp)
    ),
    _best_values AS (
      --only valid best if reindex entry exists
      SELECT 
        DISTINCT ON (datname, schemaname, relname, indexrelname) 
        _all_history_since_reindex.*,
        _all_history_since_reindex.indexsize::real/_all_history_since_reindex.estimated_tuples::real as best_ratio
      FROM _all_history_since_reindex 
      JOIN _last_reindex_values USING (datname, schemaname, relname, indexrelname)
      WHERE _all_history_since_reindex.indexsize > pg_size_bytes('128kB')
      ORDER BY datname, schemaname, relname, indexrelname, _all_history_since_reindex.indexsize::real/_all_history_since_reindex.estimated_tuples::real
    ),
    _current_state AS (
     SELECT 
        DISTINCT ON (datname, schemaname, relname, indexrelname) 
        _all_history_since_reindex.* 
      FROM _all_history_since_reindex
      ORDER BY datname, schemaname, relname, indexrelname, entry_timestamp DESC
    )
    INSERT INTO index_watch.index_current_state 
      (mtime, datname, schemaname, relname, indexrelname, indexsize, estimated_tuples, best_ratio) 
      SELECT c.entry_timestamp, c.datname, c.schemaname, c.relname, c.indexrelname, c.indexsize, c.estimated_tuples, best_ratio
      FROM _current_state c JOIN _best_values USING (datname, schemaname, relname, indexrelname);
   DROP TABLE index_watch.index_history;
   UPDATE index_watch.tables_version SET version=3;
   RETURN;
END;
$BODY$
LANGUAGE plpgsql;



CREATE OR REPLACE FUNCTION index_watch._remote_get_indexes_indexrelid(_datname name)
RETURNS TABLE(datname name, schemaname name, relname name, indexrelname name, indexrelid OID) 
AS
$BODY$
DECLARE
    _use_toast_tables text;
BEGIN
    IF index_watch.check_pg_version_bugfixed() THEN _use_toast_tables := 'True';
    ELSE _use_toast_tables := 'False';
    END IF;
    RETURN QUERY SELECT 
      _datname, _res.schemaname, _res.relname, _res.indexrelname, _res.indexrelid
    FROM
    dblink('port='||current_setting('port')||$$ dbname='$$||_datname||$$'$$,
    format(
    $SQL$
      SELECT
          n.nspname AS schemaname
        , c.relname
        , i.relname AS indexrelname
        , x.indexrelid
      FROM pg_index x
      JOIN pg_catalog.pg_class c           ON c.oid = x.indrelid
      JOIN pg_catalog.pg_class i           ON i.oid = x.indexrelid
      JOIN pg_catalog.pg_namespace n       ON n.oid = c.relnamespace
      JOIN pg_catalog.pg_am a              ON a.oid = i.relam
      --toast indexes info
      LEFT JOIN pg_catalog.pg_class c1     ON c1.reltoastrelid = c.oid AND n.nspname = 'pg_toast'
      LEFT JOIN pg_catalog.pg_namespace n1 ON c1.relnamespace = n1.oid 
      
      WHERE 
      TRUE
      --limit reindex for indexes on tables/mviews/toast
      --AND c.relkind = ANY (ARRAY['r'::"char", 't'::"char", 'm'::"char"])
      --limit reindex for indexes on tables/mviews (skip topast until bugfix of BUG #17268)
      AND ( (c.relkind = ANY (ARRAY['r'::"char", 'm'::"char"])) OR
            ( (c.relkind = 't'::"char") AND %s )
          )
           --ignore exclusion constraints
      AND NOT EXISTS (SELECT FROM pg_constraint WHERE pg_constraint.conindid=i.oid and pg_constraint.contype='x')
      --ignore indexes for system tables and index_watch own tables
      AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'index_watch')
      --ignore indexes on toast tables of system tables and index_watch own tables
      AND (n1.nspname IS NULL OR n1.nspname NOT IN ('pg_catalog', 'information_schema', 'index_watch'))
      --skip BRIN indexes... please see bug BUG #17205 https://www.postgresql.org/message-id/flat/17205-42b1d8f131f0cf97%%40postgresql.org
      AND a.amname NOT IN ('brin') AND x.indislive IS TRUE
      
      --debug only     
      --ORDER by 1,2,3
    $SQL$, _use_toast_tables)
    )
    AS _res(schemaname name, relname name, indexrelname name, indexrelid OID)
    ;
END;
$BODY$
LANGUAGE plpgsql;



--update table structure version from 3 to 4
CREATE OR REPLACE FUNCTION index_watch._structure_version_3_4() 
RETURNS VOID AS
$BODY$
DECLARE 
  _datname NAME;
BEGIN
   ALTER TABLE index_watch.reindex_history 
      ADD COLUMN indexrelid OID;
   CREATE INDEX reindex_history_oid_index on index_watch.reindex_history(datname, indexrelid);

   ALTER TABLE index_watch.index_current_state 
      ADD COLUMN indexrelid OID;
   CREATE UNIQUE INDEX index_current_state_oid_index on index_watch.index_current_state(datname, indexrelid);
   DROP INDEX IF EXISTS index_watch.index_current_state_index;
   CREATE INDEX index_current_state_index on index_watch.index_current_state(datname, schemaname, relname, indexrelname);

   -- add indexrelid values into index_current_state
   FOR _datname IN 
     SELECT DISTINCT datname FROM index_watch.index_current_state
     ORDER BY datname
   LOOP
     --update current state of ALL indexes in target database
     WITH _actual_indexes AS (
        SELECT schemaname, relname, indexrelname, indexrelid
        FROM index_watch._remote_get_indexes_indexrelid(_datname)
     )
     UPDATE index_watch.index_current_state AS i 
        SET indexrelid=_actual_indexes.indexrelid
        FROM _actual_indexes
            WHERE
                 i.schemaname=_actual_indexes.schemaname 
             AND i.relname=_actual_indexes.relname 
             AND i.indexrelname=_actual_indexes.indexrelname
             AND i.datname=_datname;
   END LOOP;
   DELETE FROM index_watch.index_current_state WHERE indexrelid IS NULL;
   ALTER TABLE index_watch.index_current_state ALTER indexrelid SET NOT NULL;
   UPDATE index_watch.tables_version SET version=4;
   RETURN;
END;
$BODY$
LANGUAGE plpgsql;


--update table structure version from 4 to 5
CREATE OR REPLACE FUNCTION index_watch._structure_version_4_5() 
RETURNS VOID AS
$BODY$
DECLARE 
  _datname NAME;
BEGIN
   ALTER TABLE index_watch.reindex_history 
      ADD COLUMN datid OID;
   DROP INDEX IF EXISTS index_watch.reindex_history_oid_index;
   CREATE INDEX reindex_history_oid_index on index_watch.reindex_history(datid, indexrelid);

   ALTER TABLE index_watch.index_current_state 
      ADD COLUMN datid OID;
   DROP INDEX IF EXISTS index_watch.index_current_state_oid_index;
   CREATE UNIQUE INDEX index_current_state_oid_index on index_watch.index_current_state(datid, indexrelid);

   -- add datid values into index_current_state
  UPDATE index_watch.index_current_state AS i 
     SET datid=p.oid
     FROM pg_database p
         WHERE i.datname=p.datname;
   DELETE FROM index_watch.index_current_state WHERE datid IS NULL;
   ALTER TABLE index_watch.index_current_state ALTER datid SET NOT NULL;
   UPDATE index_watch.tables_version SET version=5;
   RETURN;
END;
$BODY$
LANGUAGE plpgsql;


--update table structure version from 5 to 6
CREATE OR REPLACE FUNCTION index_watch._structure_version_5_6() 
RETURNS VOID AS
$BODY$
BEGIN
   ALTER TABLE index_watch.index_current_state 
      ADD COLUMN indisvalid BOOLEAN not null DEFAULT TRUE;
   UPDATE index_watch.tables_version SET version=6;
   RETURN;
END;
$BODY$
LANGUAGE plpgsql;



--update table structure version from 6 to 7
CREATE OR REPLACE FUNCTION index_watch._structure_version_6_7() 
RETURNS VOID AS
$BODY$
BEGIN
   DROP VIEW IF EXISTS index_watch.history;
   CREATE VIEW index_watch.history AS
     SELECT date_trunc('second', entry_timestamp)::timestamp AS ts,
          datname AS db, schemaname AS schema, relname AS table, 
          indexrelname AS index, pg_size_pretty(indexsize_before) AS size_before, 
          pg_size_pretty(indexsize_after) AS size_after,
          (indexsize_before::float/indexsize_after)::numeric(12,2) AS ratio, 
          pg_size_pretty(estimated_tuples) AS tuples, date_trunc('seconds', reindex_duration) AS duration 
     FROM index_watch.reindex_history ORDER BY id DESC;

   UPDATE index_watch.tables_version SET version=7;
   RETURN;
END;
$BODY$
LANGUAGE plpgsql;



--convert patterns from psql format to like format
CREATE OR REPLACE FUNCTION index_watch._pattern_convert(_var text)
RETURNS TEXT AS
$BODY$
BEGIN
    --replace * with .*
    _var := replace(_var, '*', '.*');
    --replace ? with .
    _var := replace(_var, '?', '.');

    RETURN  '^('||_var||')$';
END;
$BODY$
LANGUAGE plpgsql STRICT IMMUTABLE;


CREATE OR REPLACE FUNCTION index_watch.get_setting(_datname text, _schemaname text, _relname text, _indexrelname text, _key TEXT)
RETURNS TEXT AS
$BODY$
DECLARE
    _value TEXT;
BEGIN	
    PERFORM index_watch._check_structure_version();
    --RAISE NOTICE 'DEBUG: |%|%|%|%|', _datname, _schemaname, _relname, _indexrelname;
    SELECT _t.value INTO _value FROM (
      --per index setting 	
      SELECT 1 AS priority, value FROM index_watch.config WHERE 
        _key=config.key 
	AND (_datname      OPERATOR(pg_catalog.~) index_watch._pattern_convert(config.datname)) 
	AND (_schemaname   OPERATOR(pg_catalog.~) index_watch._pattern_convert(config.schemaname)) 
	AND (_relname      OPERATOR(pg_catalog.~) index_watch._pattern_convert(config.relname)) 
	AND (_indexrelname OPERATOR(pg_catalog.~) index_watch._pattern_convert(config.indexrelname)) 
	AND config.indexrelname IS NOT NULL
	AND TRUE
      UNION ALL
      --per table setting
      SELECT 2 AS priority, value FROM index_watch.config WHERE
        _key=config.key
        AND (_datname      OPERATOR(pg_catalog.~) index_watch._pattern_convert(config.datname))
        AND (_schemaname   OPERATOR(pg_catalog.~) index_watch._pattern_convert(config.schemaname))
        AND (_relname      OPERATOR(pg_catalog.~) index_watch._pattern_convert(config.relname))
        AND config.relname IS NOT NULL
        AND config.indexrelname IS NULL
      UNION ALL
      --per schema setting
      SELECT 3 AS priority, value FROM index_watch.config WHERE
        _key=config.key
        AND (_datname      OPERATOR(pg_catalog.~) index_watch._pattern_convert(config.datname))
        AND (_schemaname   OPERATOR(pg_catalog.~) index_watch._pattern_convert(config.schemaname))
        AND config.schemaname IS NOT NULL
        AND config.relname IS NULL
      UNION ALL
      --per database setting
      SELECT 4 AS priority, value FROM index_watch.config WHERE
        _key=config.key
        AND (_datname      OPERATOR(pg_catalog.~) index_watch._pattern_convert(config.datname))
        AND config.datname IS NOT NULL
        AND config.schemaname IS NULL
      UNION ALL
      --global setting
      SELECT 5 AS priority, value FROM index_watch.config WHERE
        _key=config.key
        AND config.datname IS NULL
    ) AS _t
    WHERE value IS NOT NULL
    ORDER BY priority
    LIMIT 1;
    RETURN _value;
END;
$BODY$
LANGUAGE plpgsql STABLE;


CREATE OR REPLACE FUNCTION index_watch.set_or_replace_setting(_datname text, _schemaname text, _relname text, _indexrelname text, _key TEXT, _value text, _comment text)
RETURNS VOID AS
$BODY$
BEGIN
    PERFORM index_watch._check_structure_version();
    IF _datname IS NULL       THEN
      INSERT INTO index_watch.config (datname, schemaname, relname, indexrelname, key, value, comment) 
      VALUES (_datname, _schemaname, _relname, _indexrelname, _key, _value, _comment)
      ON CONFLICT (key) WHERE datname IS NULL DO UPDATE SET value=EXCLUDED.value, comment=EXCLUDED.comment;
    ELSIF _schemaname IS NULL THEN
      INSERT INTO index_watch.config (datname, schemaname, relname, indexrelname, key, value, comment) 
      VALUES (_datname, _schemaname, _relname, _indexrelname, _key, _value, _comment)
      ON CONFLICT (key, datname) WHERE schemaname IS NULL DO UPDATE SET value=EXCLUDED.value, comment=EXCLUDED.comment;
    ELSIF _relname IS NULL    THEN
      INSERT INTO index_watch.config (datname, schemaname, relname, indexrelname, key, value, comment) 
      VALUES (_datname, _schemaname, _relname, _indexrelname, _key, _value, _comment)
      ON CONFLICT (key, datname, schemaname) WHERE relname IS NULL DO UPDATE SET value=EXCLUDED.value, comment=EXCLUDED.comment;
    ELSIF _indexrelname IS NULL THEN
      INSERT INTO index_watch.config (datname, schemaname, relname, indexrelname, key, value, comment) 
      VALUES (_datname, _schemaname, _relname, _indexrelname, _key, _value, _comment)
      ON CONFLICT (key, datname, schemaname, relname) WHERE indexrelname IS NULL DO UPDATE SET value=EXCLUDED.value, comment=EXCLUDED.comment;
    ELSE
      INSERT INTO index_watch.config (datname, schemaname, relname, indexrelname, key, value, comment) 
      VALUES (_datname, _schemaname, _relname, _indexrelname, _key, _value, _comment)
      ON CONFLICT (key, datname, schemaname, relname, indexrelname) DO UPDATE SET value=EXCLUDED.value, comment=EXCLUDED.comment;    
    END IF;
    RETURN;
END;
$BODY$
LANGUAGE plpgsql;


DROP FUNCTION IF EXISTS index_watch._remote_get_indexes_info(name,name,name,name);
CREATE OR REPLACE FUNCTION index_watch._remote_get_indexes_info(_datname name, _schemaname name, _relname name, _indexrelname name)
RETURNS TABLE(datid OID, indexrelid OID, datname name, schemaname name, relname name, indexrelname name, indisvalid BOOLEAN, indexsize BIGINT, estimated_tuples BIGINT) 
AS
$BODY$
DECLARE
   _use_toast_tables text;
BEGIN
    IF index_watch.check_pg_version_bugfixed() THEN _use_toast_tables := 'True';
    ELSE _use_toast_tables := 'False';
    END IF;
    RETURN QUERY SELECT 
      d.oid as datid, _res.indexrelid, _datname, _res.schemaname, _res.relname, _res.indexrelname, _res.indisvalid, _res.indexsize
      -- zero tuples clamp up 1 tuple (or bloat estimates will be infinity with all division by zero fun in multiple places)
      , greatest (1, indexreltuples)
      -- don't do relsize/relpage correction, that logic found to be way  too smart for his own good
      -- greatest (1, (CASE WHEN relpages=0 THEN indexreltuples ELSE relsize*indexreltuples/(relpages*current_setting('block_size')) END AS estimated_tuples))
    FROM
    dblink('port='||current_setting('port')||$$ dbname='$$||_datname||$$'$$,
    format($SQL$
      SELECT
          x.indexrelid
        , n.nspname AS schemaname
        , c.relname
        , i.relname AS indexrelname
        , x.indisvalid
        , i.reltuples::BIGINT AS indexreltuples
        , pg_catalog.pg_relation_size(i.oid)::BIGINT AS indexsize        
        --debug only
        --, pg_namespace.nspname
        --, c3.relname,
        --, am.amname        
      FROM pg_index x
      JOIN pg_catalog.pg_class c           ON c.oid = x.indrelid
      JOIN pg_catalog.pg_class i           ON i.oid = x.indexrelid
      JOIN pg_catalog.pg_namespace n       ON n.oid = c.relnamespace
      JOIN pg_catalog.pg_am a              ON a.oid = i.relam
      --toast indexes info
      LEFT JOIN pg_catalog.pg_class c1     ON c1.reltoastrelid = c.oid AND n.nspname = 'pg_toast'
      LEFT JOIN pg_catalog.pg_namespace n1 ON c1.relnamespace = n1.oid 
      
      WHERE TRUE
      --limit reindex for indexes on tables/mviews/toast
      --AND c.relkind = ANY (ARRAY['r'::"char", 't'::"char", 'm'::"char"])
      --limit reindex for indexes on tables/mviews (skip topast until bugfix of BUG #17268)
      AND ( (c.relkind = ANY (ARRAY['r'::"char", 'm'::"char"])) OR
            ( (c.relkind = 't'::"char") AND %s )
          )
      --ignore exclusion constraints
      AND NOT EXISTS (SELECT FROM pg_constraint WHERE pg_constraint.conindid=i.oid and pg_constraint.contype='x')
      --ignore indexes for system tables and index_watch own tables
      AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'index_watch')
      --ignore indexes on toast tables of system tables and index_watch own tables
      AND (n1.nspname IS NULL OR n1.nspname NOT IN ('pg_catalog', 'information_schema', 'index_watch'))
      --skip BRIN indexes... please see bug BUG #17205 https://www.postgresql.org/message-id/flat/17205-42b1d8f131f0cf97%%40postgresql.org
      AND a.amname NOT IN ('brin') AND x.indislive IS TRUE
      
      --debug only     
      --ORDER by 1,2,3
    $SQL$, _use_toast_tables)
    )
    AS _res(indexrelid OID, schemaname name, relname name, indexrelname name, indisvalid BOOLEAN, indexreltuples BIGINT, indexsize BIGINT), 
    pg_database AS d
    WHERE 
    d.datname=_datname
    AND
    (_schemaname IS NULL   OR _res.schemaname=_schemaname)
    AND
    (_relname IS NULL      OR _res.relname=_relname)
    AND
    (_indexrelname IS NULL OR _res.indexrelname=_indexrelname)
    ;
END;
$BODY$
LANGUAGE plpgsql;



CREATE OR REPLACE FUNCTION index_watch._record_indexes_info(_datname name, _schemaname name, _relname name, _indexrelname name) 
RETURNS VOID 
AS
$BODY$
BEGIN
  --merge index data fetched from the database and index_current_state
  --now keep info about all potentially interesting indexes (even small ones)
  --we can do it now because we keep exactly one entry in index_current_state per index (without history)
  WITH _actual_indexes AS (
     SELECT datid, indexrelid, datname, schemaname, relname, indexrelname, indisvalid, indexsize, estimated_tuples
     FROM index_watch._remote_get_indexes_info(_datname, _schemaname, _relname, _indexrelname)
  ),
  _old_indexes AS (
       DELETE FROM index_watch.index_current_state AS i 
       WHERE NOT EXISTS (
           SELECT FROM _actual_indexes
           WHERE
               i.datid=_actual_indexes.datid 
	        AND i.indexrelid=_actual_indexes.indexrelid
        )
        AND i.datname=_datname
        AND (_schemaname IS NULL   OR i.schemaname=_schemaname)
        AND (_relname IS NULL      OR i.relname=_relname)
        AND (_indexrelname IS NULL OR i.indexrelname=_indexrelname)
  )
  --todo: think of use database+OID instead of (datname, schemaname, relname, indexrelname) for index identification in the future
  --todo: do something with ugly code duplication in index_watch._reindex_index and index_watch._record_indexes_info
  INSERT INTO index_watch.index_current_state AS i
  (datid, indexrelid, datname, schemaname, relname, indexrelname, indisvalid, indexsize, estimated_tuples, best_ratio)
  --best_ratio estimation are NULL for the NEW index entries because we don't have any bloat information for it
  SELECT datid, indexrelid, datname, schemaname, relname, indexrelname, indisvalid, indexsize, estimated_tuples,
    NULL AS best_ratio
  FROM _actual_indexes
  ON CONFLICT (datid,indexrelid)
  DO UPDATE SET
    mtime=now(),
    datname=EXCLUDED.datname,
    schemaname=EXCLUDED.schemaname,
    relname=EXCLUDED.relname,
    indexrelname=EXCLUDED.indexrelname,
    indisvalid=EXCLUDED.indisvalid,
    indexsize=EXCLUDED.indexsize,
    estimated_tuples=EXCLUDED.estimated_tuples,
    best_ratio=
      CASE WHEN (EXCLUDED.indexsize < pg_size_bytes(index_watch.get_setting(EXCLUDED.datname, EXCLUDED.schemaname, EXCLUDED.relname, EXCLUDED.indexrelname, 'minimum_reliable_index_size')))
      --if the new index size less than minimum_reliable_index_size - we cannot use it's size and tuples as reliable gauge for the best_ratio
      --so keep old best_ratio value instead as best guess
      THEN i.best_ratio
      -- set best_value as least from current value and new one
      ELSE least(i.best_ratio, EXCLUDED.indexsize::real/EXCLUDED.estimated_tuples::real)
      END;
END;
$BODY$
LANGUAGE plpgsql;



CREATE OR REPLACE FUNCTION index_watch._cleanup_old_records() RETURNS VOID AS
$BODY$
BEGIN
    --TODO replace with fast distinct implementation
    WITH 
        rels AS MATERIALIZED (SELECT DISTINCT datname, schemaname, relname, indexrelname FROM index_watch.reindex_history),
        age_limit AS MATERIALIZED (SELECT *, now()-index_watch.get_setting(datname,schemaname,relname,indexrelname,  'reindex_history_retention_period')::interval AS max_age FROM rels)
    DELETE FROM index_watch.reindex_history 
        USING age_limit 
        WHERE 
            reindex_history.datname=age_limit.datname 
            AND reindex_history.schemaname=age_limit.schemaname
            AND reindex_history.relname=age_limit.relname
            AND reindex_history.indexrelname=age_limit.indexrelname
            AND reindex_history.entry_timestamp<age_limit.max_age;
    --clean index_current_state for not existing databases
    DELETE FROM index_watch.index_current_state WHERE datid NOT IN (
      SELECT oid FROM pg_database
      WHERE
        NOT datistemplate
        AND datallowconn
        --AND datname<>current_database()
        AND index_watch.get_setting(datname, NULL, NULL, NULL, 'skip')::boolean IS DISTINCT FROM TRUE
    );

    RETURN;
END;
$BODY$
LANGUAGE plpgsql;




CREATE OR REPLACE FUNCTION index_watch.get_index_bloat_estimates(_datname name)
RETURNS TABLE(datname name, schemaname name, relname name, indexrelname name, indexsize bigint, estimated_bloat real) 
AS
$BODY$
DECLARE
   _datid OID;
BEGIN
  PERFORM index_watch._check_structure_version();
  SELECT oid FROM pg_database d WHERE d.datname = _datname INTO _datid;
  -- compare current size to tuples ratio with the the best value
  RETURN QUERY 
  SELECT _datname, i.schemaname, i.relname, i.indexrelname, i.indexsize,
  (i.indexsize::real/(i.best_ratio*estimated_tuples::real)) AS estimated_bloat
  FROM index_watch.index_current_state AS i
  WHERE i.datid = _datid 
    -- AND indisvalid IS TRUE 
    --skip too small indexes to have any interest
    AND i.indexsize >= pg_size_bytes(index_watch.get_setting(i.datname, i.schemaname, i.relname, i.indexrelname, 'index_size_threshold'))
    --skip indexes set to skip
    AND index_watch.get_setting(i.datname, i.schemaname, i.relname, i.indexrelname, 'skip')::boolean IS DISTINCT FROM TRUE
    -- AND index_watch.get_setting (for future configurability)
  --NULLS FIRST because indexes listed with NULL in estimated bloat going to be reindexed on next cron run
  --start from maximum bloated indexes
  ORDER BY estimated_bloat DESC NULLS FIRST;
END;
$BODY$
LANGUAGE plpgsql STRICT;




CREATE OR REPLACE FUNCTION index_watch._reindex_index(_datname name, _schemaname name, _relname name, _indexrelname name) 
RETURNS VOID 
AS
$BODY$
DECLARE
  _indexsize_before BIGINT;
  _indexsize_after  BIGINT;
  _timestamp        TIMESTAMP;
  _reindex_duration INTERVAL;
  _analyze_duration INTERVAL :='0s';
  _estimated_tuples BIGINT;
  _indexrelid OID;
  _datid OID;
  _indisvalid BOOLEAN;
BEGIN

  --RAISE NOTICE 'working with %.%.% %', _datname, _schemaname, _relname, _indexrelname;

  --get initial actual index size and verify that the index indeed exists in the target database
  --PS: english articles are driving me mad periodically
  SELECT indexsize INTO _indexsize_before
  FROM index_watch._remote_get_indexes_info(_datname, _schemaname, _relname, _indexrelname)
  WHERE indisvalid IS TRUE;
  --index doesn't exist anymore
  IF NOT FOUND THEN
    RETURN;
  END IF;
  
  --perform reindex index
  _timestamp := pg_catalog.clock_timestamp ();
  PERFORM dblink('port='||current_setting('port')||$$ dbname='$$||_datname||$$'$$, 'REINDEX INDEX CONCURRENTLY '||pg_catalog.quote_ident(_schemaname)||'.'||pg_catalog.quote_ident(_indexrelname));
  _reindex_duration := pg_catalog.clock_timestamp ()-_timestamp;
  
  --analyze 
  --skip analyze for toast tables
  IF (_schemaname != 'pg_toast') THEN
    _timestamp := clock_timestamp ();
    PERFORM dblink('port='||current_setting('port')||$$ dbname='$$||_datname||$$'$$, 'ANALYZE '||pg_catalog.quote_ident(_schemaname)||'.'||pg_catalog.quote_ident(_relname));
     _analyze_duration := pg_catalog.clock_timestamp ()-_timestamp;
  END IF;
 
  --get final index size
  SELECT datid, indexrelid, indisvalid, indexsize, estimated_tuples INTO STRICT _datid, _indexrelid, _indisvalid, _indexsize_after, _estimated_tuples
  FROM index_watch._remote_get_indexes_info(_datname, _schemaname, _relname, _indexrelname);
  
  --log reindex action
  INSERT INTO index_watch.reindex_history
  (datid, indexrelid, datname, schemaname, relname, indexrelname, indexsize_before, indexsize_after, estimated_tuples, reindex_duration, analyze_duration)
  VALUES 
  (_datid, _indexrelid, _datname, _schemaname, _relname, _indexrelname, _indexsize_before, _indexsize_after, _estimated_tuples, _reindex_duration, _analyze_duration);
  
  --update current_state... insert action here not possible in normal course of action 
  --but better keep it as possible option in case of someone decide to call _reindex_index directly
  --todo: do something with ugly code duplication in index_watch._reindex_index and index_watch._record_indexes_info
  INSERT INTO index_watch.index_current_state AS i
  (datid, indexrelid, datname, schemaname, relname, indexrelname, indisvalid, indexsize, estimated_tuples, best_ratio)
  VALUES (_datid, _indexrelid, _datname, _schemaname, _relname, _indexrelname, _indisvalid, _indexsize_after, _estimated_tuples,
    CASE
    WHEN _indexsize_after < pg_size_bytes(index_watch.get_setting(_datname, _schemaname, _relname, _indexrelname, 'minimum_reliable_index_size'))
    --if index size after reindex are too small (less than minimum_reliable_index_size) we cannot use it to estimate best_ratio
    THEN NULL
    ELSE _indexsize_after::real/_estimated_tuples::real
    END
  )
  ON CONFLICT (datid, indexrelid)
  DO UPDATE SET
    mtime=now(),
    indisvalid=EXCLUDED.indisvalid,
    indexsize=EXCLUDED.indexsize,
    estimated_tuples=EXCLUDED.estimated_tuples,
    best_ratio=
      CASE WHEN (EXCLUDED.indexsize < pg_size_bytes(index_watch.get_setting(EXCLUDED.datname, EXCLUDED.schemaname, EXCLUDED.relname, EXCLUDED.indexrelname, 'minimum_reliable_index_size')))
      --if the new index size less than minimum_reliable_index_size - we cannot use it's size and tuples as reliable gauge for the best_ratio
      --so keep old best_ratio value instead as best guess
      THEN i.best_ratio
      -- else set new best_value uncoditionally
      ELSE EXCLUDED.indexsize::real/EXCLUDED.estimated_tuples::real
      END;
  RETURN;
END;
$BODY$
LANGUAGE plpgsql STRICT;



CREATE OR REPLACE PROCEDURE index_watch.do_reindex(_datname name, _schemaname name, _relname name, _indexrelname name, _force BOOLEAN DEFAULT FALSE) 
AS
$BODY$
DECLARE
  _index RECORD;
BEGIN
  PERFORM index_watch._check_structure_version();
  
  FOR _index IN 
    SELECT datname, schemaname, relname, indexrelname, indexsize, estimated_bloat
    -- index_size_threshold check logic moved to get_index_bloat_estimates
    -- force switch mean ignore index_rebuild_scale_factor and reindex all suitable indexes
    -- indexes too small (less than index_size_threshold) or manually set to skip in config will be ignored even with force switch
    -- todo: think about it someday
    FROM index_watch.get_index_bloat_estimates(_datname)
    WHERE
      (_schemaname IS NULL OR schemaname=_schemaname)
      AND
      (_relname IS NULL OR relname=_relname)
      AND
      (_indexrelname IS NULL OR indexrelname=_indexrelname)
      AND
      (_force OR 
          (
              estimated_bloat IS NULL 
              OR estimated_bloat >= index_watch.get_setting(datname, schemaname, relname, indexrelname, 'index_rebuild_scale_factor')::float
          )
      )
    LOOP
       PERFORM index_watch._reindex_index(_index.datname, _index.schemaname, _index.relname, _index.indexrelname);
       COMMIT;
    END LOOP;
  RETURN;
END;
$BODY$
LANGUAGE plpgsql;



CREATE OR REPLACE FUNCTION index_watch._check_lock() 
RETURNS bigint AS
$BODY$
DECLARE 
  _id bigint;
  _is_not_running boolean;
BEGIN
  SELECT oid FROM pg_namespace WHERE nspname='index_watch' INTO _id; 
  SELECT pg_try_advisory_lock(_id) INTO _is_not_running;
  IF NOT _is_not_running THEN 
      RAISE 'The previous launch of the index_watch.periodic is still running.';
  END IF;
  RETURN _id;
END;
$BODY$
LANGUAGE plpgsql;


DROP PROCEDURE IF EXISTS index_watch.periodic(BOOLEAN);
CREATE OR REPLACE PROCEDURE index_watch.periodic(real_run BOOLEAN DEFAULT FALSE, force BOOLEAN DEFAULT FALSE) AS
$BODY$
DECLARE 
  _datname NAME;
  _schemaname NAME;
  _relname NAME;
  _indexrelname NAME;
  _id bigint;
BEGIN
    IF NOT index_watch.check_pg14_version_bugfixed()
      THEN
         RAISE 'The database version % affected by PostgreSQL bug BUG #17485 which make use pg_index_watch unsafe, please update to latest minor release. For additional info please see:
       https://www.postgresql.org/message-id/202205251144.6t4urostzc3s@alvherre.pgsql', 
        current_setting('server_version');
    END IF;
    SELECT index_watch._check_lock() INTO _id;
    IF NOT index_watch.check_pg_version_bugfixed()
    THEN
        RAISE WARNING 'The database version % affected by PostgreSQL bugs which make use pg_index_watch potentially unsafe, please update to latest minor release. For additional info please see:
   https://www.postgresql.org/message-id/E1mumI4-0001Zp-PB@gemulon.postgresql.org
   and
   https://www.postgresql.org/message-id/E1n8C7O-00066j-Q5@gemulon.postgresql.org', 
      current_setting('server_version');
    END IF;

    PERFORM index_watch._check_update_structure_version();
    COMMIT;
    PERFORM index_watch._cleanup_old_records();
    COMMIT;

    FOR _datname IN 
      SELECT datname FROM pg_database 
      WHERE 
        NOT datistemplate 
        AND datallowconn 
        AND datname<>current_database()
        AND index_watch.get_setting(datname, NULL, NULL, NULL, 'skip')::boolean IS DISTINCT FROM TRUE
      ORDER BY datname
    LOOP
      --update current state of ALL indexes in target database
      PERFORM index_watch._record_indexes_info(_datname, NULL, NULL, NULL);
      COMMIT;
      --if real_run isn't set - do nothing else
      IF (real_run) THEN      
        CALL index_watch.do_reindex(_datname, NULL, NULL, NULL, force);
        COMMIT;
      END IF;
    END LOOP;

    FOR _datname, _schemaname, _relname, _indexrelname IN 
      SELECT datname, schemaname, relname, indexrelname FROM index_watch.index_current_state
      WHERE indisvalid IS FALSE
    LOOP
      RAISE WARNING 'Not valid index % on %.% found in %.', 
      _indexrelname,  _schemaname, _relname, _datname;
    END LOOP;

    PERFORM pg_advisory_unlock(_id);
END;
$BODY$
LANGUAGE plpgsql;

