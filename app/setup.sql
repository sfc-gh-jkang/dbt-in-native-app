-- ===========================================================================
-- WMS Analytics -- application setup script
--
-- IP MODEL:
--   RAW / REFINEMENT / REPORTING  -> app-owned, granted to NOTHING (invisible)
--   RELEASE (R5)                  -> granted to app_public (the product surface)
--
-- The dbt project itself lives inside the container image, which is bundled in
-- the application package. Nothing the consumer can list or GET contains the
-- models, macros, or Jinja.
-- ===========================================================================

CREATE APPLICATION ROLE IF NOT EXISTS app_public;
CREATE APPLICATION ROLE IF NOT EXISTS app_admin;
GRANT APPLICATION ROLE app_public TO APPLICATION ROLE app_admin;

-- Non-versioned: job services cannot be executed in a versioned schema.
CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS services;

-- dbt target schemas. Created up front so grants are deterministic.
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS refinement;
CREATE SCHEMA IF NOT EXISTS reporting;
CREATE SCHEMA IF NOT EXISTS release;

-- Only the RELEASE layer is ever visible to the consumer.
GRANT USAGE ON SCHEMA release TO APPLICATION ROLE app_public;
GRANT USAGE ON SCHEMA core    TO APPLICATION ROLE app_admin;

-- ---------------------------------------------------------------------------
-- Sample raw feed. In production this would be an object reference to the
-- consumer's own WMS tables; inlined here to keep the POC self-contained.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS raw.wms_orders (
    order_id     NUMBER,
    region       VARCHAR,
    amount       FLOAT,
    received_at  TIMESTAMP_NTZ,
    stocked_at   TIMESTAMP_NTZ,
    promised_at  TIMESTAMP_NTZ,
    delivered_at TIMESTAMP_NTZ
);

CREATE OR REPLACE PROCEDURE core.seed_demo_data()
RETURNS STRING LANGUAGE SQL EXECUTE AS OWNER
AS
BEGIN
  DELETE FROM raw.wms_orders;
  INSERT INTO raw.wms_orders VALUES
    (1, 'emea',   1200.00, '2026-08-01 08:00:00', '2026-08-01 14:30:00', '2026-08-03 12:00:00', '2026-08-03 10:00:00'),
    (2, ' AMER ',  850.50, '2026-08-01 09:15:00', '2026-08-01 11:45:00', '2026-08-04 12:00:00', '2026-08-05 18:00:00'),
    (3, 'APAC',   2310.75, '2026-08-02 22:00:00', '2026-08-03 06:15:00', '2026-08-06 12:00:00', NULL),
    (4, 'emea',    430.25, '2026-08-03 07:30:00', '2026-08-03 09:00:00', '2026-08-05 12:00:00', '2026-08-05 11:00:00'),
    (5, 'AMER',   1775.00, '2026-08-03 13:00:00', '2026-08-04 08:20:00', '2026-08-07 12:00:00', '2026-08-07 09:30:00');
  RETURN 'seeded 5 rows';
END;

CALL core.seed_demo_data();

-- ---------------------------------------------------------------------------
-- OBJECT REFERENCE: read the CONSUMER'S OWN table instead of seeded data.
--
-- dbt needs a stable relation to point a source at, and it cannot call
-- reference() itself. So the app owns a view, raw.orders_source, and dbt's
-- source targets that view. Swapping the view between the seeded table and
-- reference('consumer_orders') switches the whole pipeline's input without
-- touching the dbt project or rebuilding the image.
-- ---------------------------------------------------------------------------

-- Callback the consumer's binding flow (Snowsight or SQL) invokes.
-- NOTE the $$ quoting. Without it the statement is cut at the first ';' inside
-- the CASE body and the procedure is silently never created -- the app installs
-- fine and the failure only surfaces later as
-- "Unknown user-defined function <app>.CORE.REGISTER_REFERENCE".
CREATE OR REPLACE PROCEDURE core.register_reference(ref_name STRING, operation STRING, ref_or_alias STRING)
RETURNS STRING LANGUAGE SQL
AS $$
  BEGIN
    CASE (operation)
      WHEN 'ADD'    THEN SELECT SYSTEM$SET_REFERENCE(:ref_name, :ref_or_alias);
      WHEN 'REMOVE' THEN SELECT SYSTEM$REMOVE_REFERENCE(:ref_name, :ref_or_alias);
      WHEN 'CLEAR'  THEN SELECT SYSTEM$REMOVE_ALL_REFERENCES(:ref_name);
      ELSE RETURN 'unknown operation: ' || :operation;
    END CASE;
    RETURN NULL;
  END;
$$;

-- Default input: the seeded table, so the app works before anything is bound.
CREATE OR REPLACE VIEW raw.orders_source AS SELECT * FROM raw.wms_orders;

-- ---------------------------------------------------------------------------
-- Validate the consumer's bound table against the source contract, BEFORE
-- anything downstream depends on it.
--
-- Why this exists: SYSTEM$SET_REFERENCE succeeds no matter what the table
-- looks like. Without this check the first symptom of a shape mismatch is a
-- bare `904 invalid identifier 'STOCKED_AT'` raised from inside the app, where
-- the consumer can see neither the view nor the model that failed. It also
-- names only the FIRST missing column, so a table missing three columns takes
-- three round trips to fix.
--
-- Probing each column separately is deliberate: it reports the complete set of
-- problems in one call.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE core.validate_consumer_source()
RETURNS STRING LANGUAGE SQL EXECUTE AS OWNER
AS
DECLARE
  required ARRAY   DEFAULT ARRAY_CONSTRUCT('order_id','region','amount',
                                           'received_at','stocked_at',
                                           'promised_at','delivered_at');
  missing  ARRAY   DEFAULT ARRAY_CONSTRUCT();
  col      STRING;
  i        INTEGER DEFAULT 0;
  n        INTEGER;
BEGIN
  -- Is anything bound at all? Distinguish "no reference" from "wrong shape",
  -- otherwise an unbound reference reports all 7 columns as missing.
  BEGIN
    SELECT COUNT(*) INTO :n FROM reference('consumer_orders');
  EXCEPTION
    WHEN OTHER THEN
      RETURN 'NOT BOUND: no table is bound to reference consumer_orders. '
          || 'Bind one with core.register_reference(''consumer_orders'', ''ADD'', '
          || 'SYSTEM$REFERENCE(''TABLE'', ''<your_db>.<your_schema>.<your_table>'', '
          || '''PERSISTENT'', ''SELECT'')).';
  END;

  WHILE (:i < ARRAY_SIZE(:required)) DO
    col := GET(:required, :i)::STRING;
    BEGIN
      EXECUTE IMMEDIATE
        'SELECT ' || :col || ' FROM reference(''consumer_orders'') WHERE 1 = 0';
    EXCEPTION
      WHEN OTHER THEN
        missing := ARRAY_APPEND(:missing, :col);
    END;
    i := :i + 1;
  END WHILE;

  IF (ARRAY_SIZE(:missing) > 0) THEN
    RETURN 'INCOMPATIBLE: the bound table is missing '
        || ARRAY_SIZE(:missing) || ' required column(s): '
        || ARRAY_TO_STRING(:missing, ', ')
        || '. Required contract is: order_id, region, amount, received_at, '
        || 'stocked_at, promised_at, delivered_at. Column order does not '
        || 'matter; names and readability do.';
  END IF;

  RETURN 'OK: bound table satisfies the source contract (' || :n || ' rows visible).';
END;

-- Point the pipeline at the consumer's bound table.
CREATE OR REPLACE PROCEDURE core.use_consumer_source()
RETURNS STRING LANGUAGE SQL EXECUTE AS OWNER
AS
DECLARE
  verdict STRING;
BEGIN
  -- Refuse to repoint the pipeline at a table that cannot feed it. Leaving the
  -- view on the seed is the safe failure: the app keeps working and says why.
  verdict := (CALL core.validate_consumer_source());
  IF (LEFT(:verdict, 3) <> 'OK:') THEN
    RETURN :verdict || ' -- orders_source left unchanged.';
  END IF;

  CREATE OR REPLACE VIEW raw.orders_source AS
    SELECT order_id, region, amount, received_at, stocked_at, promised_at, delivered_at
    FROM reference('consumer_orders');
  RETURN 'orders_source now reads reference(consumer_orders)';
EXCEPTION
  WHEN OTHER THEN
    RETURN 'ERROR ' || SQLCODE || ': ' || SQLERRM;
END;

-- Revert to seeded data.
CREATE OR REPLACE PROCEDURE core.use_seeded_source()
RETURNS STRING LANGUAGE SQL EXECUTE AS OWNER
AS
BEGIN
  CREATE OR REPLACE VIEW raw.orders_source AS SELECT * FROM raw.wms_orders;
  RETURN 'orders_source now reads the seeded table';
END;

-- Report which input is live, without exposing the view definition.
CREATE OR REPLACE PROCEDURE core.source_status()
RETURNS STRING LANGUAGE SQL EXECUTE AS OWNER
AS
DECLARE
  n INTEGER;
BEGIN
  SELECT COUNT(*) INTO :n FROM raw.orders_source;
  RETURN 'orders_source row count: ' || :n;
EXCEPTION
  WHEN OTHER THEN
    RETURN 'ERROR ' || SQLCODE || ': ' || SQLERRM;
END;




-- ---------------------------------------------------------------------------
-- DYNAMIC TABLE COMPARISON ARM.
-- Same business logic as the dbt REPORTING layer, expressed as a Snowflake
-- Dynamic Table instead of a dbt incremental model. Purpose: settle whether a
-- DT inside an application is as opaque as a dbt-built table, and what it costs.
-- The macro constants are inlined here because a DT cannot run Jinja -- which is
-- itself the central trade-off.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE core.create_dt_arm(target_lag STRING)
RETURNS STRING LANGUAGE SQL EXECUTE AS OWNER
AS
DECLARE
  wh_name STRING;
  lag_txt STRING;
  stmt    STRING;
BEGIN
  lag_txt := CASE UPPER(TRIM(:target_lag))
               WHEN '1MIN'  THEN '1 minute'
               WHEN '5MIN'  THEN '5 minutes'
               WHEN '1HOUR' THEN '1 hour'
               WHEN 'DAILY' THEN '1 day'
               ELSE NULL
             END;
  IF (:lag_txt IS NULL) THEN
    RETURN 'REJECTED: target_lag must be one of 1MIN|5MIN|1HOUR|DAILY';
  END IF;

  wh_name := (SELECT CURRENT_DATABASE()) || '_DBT_WH';
  -- Reads raw.orders_source DIRECTLY, not a dbt-built view: a fair comparison
  -- has to replace the whole DAG, so the staging normalisation is inlined too.
  -- Note what that costs in expressiveness -- the macro bodies become literals,
  -- and there is no Jinja, no ref(), no package, no tests.
  stmt := 'CREATE OR REPLACE DYNAMIC TABLE reporting.dt_order_margin'
       || ' TARGET_LAG = ''' || :lag_txt || ''''
       || ' WAREHOUSE = ' || :wh_name
       || ' AS SELECT order_id, UPPER(TRIM(region)) AS region, amount, received_at,'
       || '   DATEDIFF(''second'', received_at, stocked_at)/3600.0 AS dock_to_stock_hours,'
       || '   amount * 0.8734 * CASE WHEN UPPER(TRIM(region)) IN (''EMEA'',''APAC'') THEN 1.1927 ELSE 1.0 END AS margin_index,'
       || '   IFF(delivered_at IS NOT NULL AND delivered_at <= promised_at, 1, 0) AS otif_flag'
       || ' FROM raw.orders_source WHERE order_id IS NOT NULL';
  EXECUTE IMMEDIATE :stmt;
  RETURN 'created dynamic table reporting.dt_order_margin with TARGET_LAG ' || :lag_txt;
EXCEPTION
  WHEN OTHER THEN RETURN 'ERROR ' || SQLCODE || ': ' || SQLERRM;
END;

CREATE OR REPLACE PROCEDURE core.dt_status()
RETURNS STRING LANGUAGE SQL EXECUTE AS OWNER
AS
DECLARE
  n INTEGER;
BEGIN
  SELECT COUNT(*) INTO :n FROM reporting.dt_order_margin;
  RETURN 'dt_order_margin rows: ' || :n;
EXCEPTION
  WHEN OTHER THEN RETURN 'ERROR ' || SQLCODE || ': ' || SQLERRM;
END;

-- ---------------------------------------------------------------------------
-- RUN HISTORY + FAILURE PROPAGATION.
--
-- Two problems with scheduling a procedure that swallows its own errors:
--   1. core.run_dbt() returns 'ERROR ...' as a STRING, so a task calling it
--      always reports SUCCEEDED. A broken nightly pipeline looks green.
--   2. The consumer has no way to confirm the pipeline actually ran, because
--      the app's internals are hidden from them by design.
--
-- core.scheduled_run() is the task body: it RAISES on failure so the task
-- genuinely fails (and SUSPEND_TASK_AFTER_NUM_FAILURES can act), and every
-- attempt is written to core.run_log, which the consumer can read.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.run_log (
  run_id      STRING,
  started_at  TIMESTAMP_LTZ,
  finished_at TIMESTAMP_LTZ,
  operation   STRING,
  status      STRING,
  detail      STRING
);

CREATE OR REPLACE PROCEDURE core.scheduled_run()
RETURNS STRING LANGUAGE SQL EXECUTE AS OWNER
AS
DECLARE
  res STRING;
  rid STRING;
  t0  TIMESTAMP_LTZ;
  pipeline_failed EXCEPTION (-20001, 'Scheduled dbt run failed');
BEGIN
  rid := 'run_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDDHH24MISS');
  t0  := CURRENT_TIMESTAMP();
  res := (CALL core.run_dbt('build', ''));

  INSERT INTO core.run_log(run_id, started_at, finished_at, operation, status, detail)
  SELECT :rid, :t0, CURRENT_TIMESTAMP(), 'build',
         IFF(:res ILIKE 'ERROR%' OR :res ILIKE 'REJECTED%', 'FAILED', 'SUCCEEDED'),
         :res;

  -- Surface failure to the task. Without this the task reports SUCCEEDED and a
  -- silently broken pipeline is indistinguishable from a healthy one.
  IF (:res ILIKE 'ERROR%' OR :res ILIKE 'REJECTED%') THEN
    RAISE pipeline_failed;
  END IF;
  RETURN :res;
END;

-- Consumer-facing audit: proves the pipeline ran without exposing internals.
CREATE OR REPLACE PROCEDURE core.run_history()
RETURNS TABLE(run_id STRING, started_at TIMESTAMP_LTZ, finished_at TIMESTAMP_LTZ,
              operation STRING, status STRING, detail STRING)
LANGUAGE SQL EXECUTE AS OWNER
AS
DECLARE
  rs RESULTSET;
BEGIN
  rs := (SELECT run_id, started_at, finished_at, operation, status, detail
         FROM core.run_log ORDER BY started_at DESC LIMIT 50);
  RETURN TABLE(rs);
END;

-- ---------------------------------------------------------------------------
-- SCHEDULING. "The customer runs it on their own compute" implies automation,
-- not a human calling a procedure. A task inside the app provides that.
--
-- The cadence is an ALLOWLIST, not a cron string. A free-text cron would be
-- interpolated into CREATE TASK -- the same injection shape the dbt args
-- passthrough had. See the allowlist note on core.run_dbt.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE core.enable_schedule(cadence STRING)
RETURNS STRING LANGUAGE SQL EXECUTE AS OWNER
AS
DECLARE
  wh_name  STRING;
  cron_txt STRING;
  stmt     STRING;
BEGIN
  cron_txt := CASE UPPER(TRIM(:cadence))
                WHEN 'HOURLY'  THEN '0 * * * * UTC'
                WHEN 'DAILY'   THEN '0 2 * * * UTC'
                WHEN 'WEEKLY'  THEN '0 2 * * 1 UTC'
                WHEN 'EVERY15' THEN '*/15 * * * * UTC'
                ELSE NULL
              END;
  IF (:cron_txt IS NULL) THEN
    RETURN 'REJECTED: cadence must be one of HOURLY|DAILY|WEEKLY|EVERY15';
  END IF;

  wh_name := (SELECT CURRENT_DATABASE()) || '_DBT_WH';
  stmt := 'CREATE OR REPLACE TASK core.dbt_scheduled_build'
       || ' WAREHOUSE = ' || :wh_name
       || ' SCHEDULE = ''USING CRON ' || :cron_txt || ''''
       || ' SUSPEND_TASK_AFTER_NUM_FAILURES = 3'
       || ' AS CALL core.scheduled_run()';
  EXECUTE IMMEDIATE :stmt;
  ALTER TASK core.dbt_scheduled_build RESUME;
  RETURN 'scheduled ' || UPPER(TRIM(:cadence)) || ' (' || :cron_txt || ')';
EXCEPTION
  WHEN OTHER THEN RETURN 'ERROR ' || SQLCODE || ': ' || SQLERRM;
END;

CREATE OR REPLACE PROCEDURE core.disable_schedule()
RETURNS STRING LANGUAGE SQL EXECUTE AS OWNER
AS
BEGIN
  ALTER TASK IF EXISTS core.dbt_scheduled_build SUSPEND;
  RETURN 'schedule suspended';
EXCEPTION
  WHEN OTHER THEN RETURN 'ERROR ' || SQLCODE || ': ' || SQLERRM;
END;

-- ---------------------------------------------------------------------------
-- Compute pool + warehouse, both named after the app instance so multiple
-- installs never collide.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE core.provision_compute()
RETURNS STRING LANGUAGE SQL EXECUTE AS OWNER
AS
DECLARE
  pool_name STRING;
  wh_name   STRING;
BEGIN
  pool_name := (SELECT CURRENT_DATABASE()) || '_DBT_POOL';
  wh_name   := (SELECT CURRENT_DATABASE()) || '_DBT_WH';

  CREATE COMPUTE POOL IF NOT EXISTS IDENTIFIER(:pool_name)
    MIN_NODES = 1
    MAX_NODES = 1
    INSTANCE_FAMILY = CPU_X64_XS
    AUTO_RESUME = TRUE
    AUTO_SUSPEND_SECS = 60;

  CREATE WAREHOUSE IF NOT EXISTS IDENTIFIER(:wh_name)
    WAREHOUSE_SIZE = XSMALL
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE;

  RETURN 'provisioned ' || :pool_name || ' and ' || :wh_name;
END;

-- ---------------------------------------------------------------------------
-- Run dbt. Builds the job spec inline so the app's own database and warehouse
-- names (unknown at image build time) can be injected as env vars.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE core.run_dbt(operation STRING, target_layer STRING)
RETURNS STRING LANGUAGE SQL EXECUTE AS OWNER
AS
DECLARE
  pool_name  STRING;
  wh_name    STRING;
  db_name    STRING;
  job_name   STRING;
  spec_text  STRING;
  safe_cmd   STRING;
  safe_args  STRING;
  stmt       STRING;
  pool_state STRING DEFAULT '';
  waited     INTEGER DEFAULT 0;
BEGIN
  db_name   := (SELECT CURRENT_DATABASE());
  pool_name := :db_name || '_DBT_POOL';
  wh_name   := :db_name || '_DBT_WH';
  job_name  := 'services.dbt_run_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDDHH24MISS');

  -- ==================================================================
  -- IP PROTECTION, layer 2: ALLOWLIST. Do not filter flags -- a blacklist
  -- loses. `run-operation` executes arbitrary project macros WITH THE
  -- APPLICATION'S PRIVILEGES, and `compile` materialises every compiled
  -- model; neither is a flag, so no amount of --debug filtering helps.
  -- The string that reaches the container is CONSTRUCTED from a fixed
  -- vocabulary below and is never echoed from the caller.
  --
  -- This runs BEFORE provisioning: a rejected call must not create compute.
  -- ==================================================================
  safe_cmd := CASE LOWER(TRIM(:operation))
                WHEN 'build'    THEN 'build'
                WHEN 'run'      THEN 'run'
                WHEN 'test'     THEN 'test'
                WHEN 'seed'     THEN 'seed'
                WHEN 'snapshot' THEN 'snapshot'
                ELSE NULL
              END;
  IF (:safe_cmd IS NULL) THEN
    RETURN 'REJECTED: operation must be one of build|run|test|seed|snapshot. '
        || 'Free-form dbt commands are not accepted (run-operation and compile '
        || 'are deliberately unreachable).';
  END IF;

  -- Optional layer selector. Validated against a closed set, then the
  -- --select expression is BUILT here rather than passed through.
  safe_args := '';
  IF (:target_layer IS NOT NULL AND TRIM(:target_layer) <> '') THEN
    IF (LOWER(TRIM(:target_layer)) NOT IN ('refinement','reporting','release')) THEN
      RETURN 'REJECTED: layer must be one of refinement|reporting|release';
    END IF;
    safe_args := '--select ' || LOWER(TRIM(:target_layer)) || '.*';
  END IF;

  -- ==================================================================
  -- FIRST-RUN SELF-PROVISIONING.
  -- A freshly installed app owns no compute, so a consumer's first call used
  -- to fail with `2003 Compute pool ... does not exist or not authorized` --
  -- an error that reads like a permissions problem and is not their fault.
  -- provision_compute() is idempotent (CREATE ... IF NOT EXISTS), so calling
  -- it unconditionally costs one metadata check on every subsequent run.
  -- ==================================================================
  CALL core.provision_compute();

  -- A pool created seconds ago is STARTING, and submitting a job to it fails.
  -- SUSPENDED needs no wait: AUTO_RESUME brings it up when the job lands.
  WHILE (:waited < 300) DO
    EXECUTE IMMEDIATE 'SHOW COMPUTE POOLS LIKE ''' || :pool_name || '''';
    SELECT COALESCE(MAX("state"), '') INTO :pool_state
      FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
    IF (:pool_state <> 'STARTING') THEN
      BREAK;
    END IF;
    CALL SYSTEM$WAIT(15);
    waited := :waited + 15;
  END WHILE;

  IF (:pool_state = 'STARTING') THEN
    RETURN 'PENDING: compute pool ' || :pool_name || ' is still starting after '
        || :waited || 's. Nothing was run and nothing is broken -- call this '
        || 'procedure again in a minute.';
  END IF;

  spec_text :=
    'spec:\n' ||
    '  containers:\n' ||
    '    - name: dbt\n' ||
    '      image: /WMS_PROVIDER_DB/IMAGES/DBT_REPO/wms-dbt:v11\n' ||
    '      env:\n' ||
    '        DBT_DATABASE: "' || :db_name || '"\n' ||
    '        DBT_WAREHOUSE: "' || :wh_name || '"\n' ||
    '        DBT_SCHEMA: PUBLIC\n' ||
    '        DBT_COMMAND: "' || :safe_cmd || '"\n' ||
    '        DBT_ARGS: "' || :safe_args || '"\n' ||
    '        DBT_THREADS: "4"\n' ||
    -- IP PROTECTION, layer 1 of 2: container stdout is NOT covered by application query
    -- redaction, and the consumer's event table is an object they own and can always
    -- read. At --debug this exports the compiled SQL and the macro constants verbatim.
    -- NONE stops the export at the source. Values: INFO (default) | ERROR | NONE.
    '  logExporters:\n' ||
    '    eventTableConfig:\n' ||
    '      logLevel: NONE\n';

  -- Parameter order is fixed: IN COMPUTE POOL, then spec, then NAME.
  stmt := 'EXECUTE JOB SERVICE IN COMPUTE POOL ' || :pool_name ||
          ' NAME = ' || :job_name ||
          ' FROM SPECIFICATION $$' || :spec_text || '$$';

  EXECUTE IMMEDIATE :stmt;

  -- dbt creates the R5 objects at runtime, so grant after the run.
  GRANT SELECT ON ALL VIEWS  IN SCHEMA release TO APPLICATION ROLE app_public;
  GRANT SELECT ON ALL TABLES IN SCHEMA release TO APPLICATION ROLE app_public;

  RETURN 'dbt ' || :safe_cmd || ' completed as ' || :job_name;
EXCEPTION
  WHEN OTHER THEN
    RETURN 'ERROR ' || SQLCODE || ': ' || SQLERRM;
END;

-- ---------------------------------------------------------------------------
-- Probe: is CREATE DBT PROJECT usable inside a native app?
--
-- Runnable evidence for the claim in the README. A syntax/compile check is NOT
-- sufficient: the statement PARSES cleanly in a setup script, which yields a
-- false positive. Only a runtime attempt proves it. Three forms are tried so the
-- feature gate can be distinguished from argument validation.
--
-- Verified 2026-08-13:
--   A(bare)    93425: Feature 'CREATE DBT PROJECT' is not supported in native apps
--   B(stage)   93425: same feature-gate error
--   C(apppath)  1011: SQL compilation error: invalid URL prefix found in: '/dbtproj'
--
-- C is the trap: the app-relative path form fails argument validation BEFORE the
-- feature gate is reached, so it reports a misleading path error. Testing only
-- that form leads you to debug your URI instead of learning the feature is
-- blocked outright.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE core.probe_dbt_project()
RETURNS STRING LANGUAGE SQL EXECUTE AS OWNER
AS
DECLARE
  out STRING DEFAULT '';
BEGIN
  BEGIN
    EXECUTE IMMEDIATE 'CREATE DBT PROJECT core.probe_a';
    out := out || 'A(bare) UNEXPECTED-SUCCESS; ';
  EXCEPTION WHEN OTHER THEN
    out := out || 'A(bare) ' || SQLCODE || ': ' || SQLERRM || ' | ';
  END;

  BEGIN
    EXECUTE IMMEDIATE 'CREATE DBT PROJECT core.probe_b FROM ''@core.nonexistent_stage''';
    out := out || 'B(stage) UNEXPECTED-SUCCESS; ';
  EXCEPTION WHEN OTHER THEN
    out := out || 'B(stage) ' || SQLCODE || ': ' || SQLERRM || ' | ';
  END;

  BEGIN
    EXECUTE IMMEDIATE 'CREATE DBT PROJECT core.probe_c FROM ''/dbtproj''';
    out := out || 'C(apppath) UNEXPECTED-SUCCESS';
  EXCEPTION WHEN OTHER THEN
    out := out || 'C(apppath) ' || SQLCODE || ': ' || SQLERRM;
  END;

  RETURN out;
END;

GRANT USAGE ON PROCEDURE core.provision_compute()             TO APPLICATION ROLE app_admin;
GRANT USAGE ON PROCEDURE core.run_dbt(STRING, STRING)         TO APPLICATION ROLE app_admin;
GRANT USAGE ON PROCEDURE core.seed_demo_data()                TO APPLICATION ROLE app_admin;
GRANT USAGE ON PROCEDURE core.probe_dbt_project()             TO APPLICATION ROLE app_admin;
GRANT USAGE ON PROCEDURE core.use_consumer_source()           TO APPLICATION ROLE app_admin;
GRANT USAGE ON PROCEDURE core.validate_consumer_source()      TO APPLICATION ROLE app_admin;
GRANT USAGE ON PROCEDURE core.use_seeded_source()             TO APPLICATION ROLE app_admin;
GRANT USAGE ON PROCEDURE core.source_status()                 TO APPLICATION ROLE app_admin;
GRANT USAGE ON PROCEDURE core.register_reference(STRING, STRING, STRING) TO APPLICATION ROLE app_admin;
GRANT USAGE ON PROCEDURE core.enable_schedule(STRING)         TO APPLICATION ROLE app_admin;
GRANT USAGE ON PROCEDURE core.disable_schedule()              TO APPLICATION ROLE app_admin;
GRANT USAGE ON PROCEDURE core.scheduled_run()                 TO APPLICATION ROLE app_admin;
GRANT USAGE ON PROCEDURE core.run_history()                   TO APPLICATION ROLE app_admin;
GRANT USAGE ON PROCEDURE core.create_dt_arm(STRING)           TO APPLICATION ROLE app_admin;
GRANT USAGE ON PROCEDURE core.dt_status()                     TO APPLICATION ROLE app_admin;
