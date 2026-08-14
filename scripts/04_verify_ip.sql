-- ===========================================================================
-- IP LEAK PROBES  --  dbt Core in an SPCS native app
--
-- Run with the app installed and a dbt run completed. Each probe states its
-- EXPECTED result so a regression is unambiguous.
--
-- Results below were RE-VERIFIED 2026-08-13 on a full rebuild from a clean
-- account (503-model project), independently of the original 2026-08-10 run.
-- Where the two runs disagree, the 08-13 result is authoritative and the
-- discrepancy is noted.
--
-- METHODOLOGY NOTE: never count SHOW output by grepping for a leading
-- uppercase name column -- SHOW output begins with a created_on timestamp, so
-- such a grep returns 0 regardless of the real contents. That mistake produced
-- a FALSE PASS on PROBE 3 in the original run. Always use
-- SHOW ...; SELECT COUNT(*) FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
-- ===========================================================================
USE ROLE ACCOUNTADMIN;

-- PROBE 1 -- product surface works.            EXPECT: rows returned.
-- RESULT: PASS -- 151 views present in RELEASE after the 503-model run.
SHOW VIEWS IN SCHEMA WMS_ANALYTICS_APP.RELEASE;
SELECT 'release_views' AS probe, COUNT(*) AS n
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SELECT * FROM WMS_ANALYTICS_APP.RELEASE.R5_MARGIN_SUMMARY ORDER BY region;

-- PROBE 2 -- model SQL is hidden.              EXPECT: error 093051.
-- RESULT: PASS -- 093051 (42501) "GET_DDL is not allowed on the objects owned
-- by the application"
SELECT GET_DDL('VIEW','WMS_ANALYTICS_APP.RELEASE.R5_MARGIN_SUMMARY');

-- PROBE 3 -- intermediate layers invisible.
-- EXPECT: the ungranted schemas are NOT ENUMERABLE, and SHOW against them
-- ERRORS. (The original run recorded "0 objects listed" -- that was WRONG, an
-- artifact of the bad grep described above. It errors outright.)
--
-- RESULT: PASS, stronger than originally recorded.
--   SHOW SCHEMAS IN APPLICATION returns only CORE, INFORMATION_SCHEMA, RELEASE.
--   RAW / REFINEMENT / REPORTING / SERVICES do not appear at all.
--   SHOW TABLES against them -> 002043 (02000) "Object does not exist, or
--   operation cannot be performed."
SHOW SCHEMAS IN APPLICATION WMS_ANALYTICS_APP;

SHOW TABLES IN SCHEMA WMS_ANALYTICS_APP.REFINEMENT;   -- expect 002043
SHOW VIEWS  IN SCHEMA WMS_ANALYTICS_APP.REPORTING;    -- expect 002043
SHOW TABLES IN SCHEMA WMS_ANALYTICS_APP.RAW;          -- expect 002043

-- PROBE 4 -- intermediate models unreadable.
-- EXPECT: error 002003, schema does not exist or not authorized.
-- RESULT: PASS -- 002003 (02000) "Schema 'WMS_ANALYTICS_APP.REPORTING' does not
-- exist or not authorized."
SELECT * FROM WMS_ANALYTICS_APP.REPORTING.INT_ORDER_MARGIN LIMIT 2;
SELECT * FROM WMS_ANALYTICS_APP.REFINEMENT.STG_ORDERS LIMIT 2;

-- PROBE 5 -- *** THE CRITICAL ONE ***
-- Does dbt's compiled SQL leak into the consumer's QUERY_HISTORY?
-- App redaction is documented only for "queries originating from a stored
-- procedure owned by the app". A job service's queries come from a SERVICE
-- USER, so this was genuinely uncertain.
--
-- RESULT: PASS, and reproducible across two independent builds.
--   2026-08-13 in-app run  -> 713 statements, 713 blank (100%), 0 secret leaks,
--                             0 statements even mentioning "dbt"
--   standalone control     ->  55 statements,   0 blank, 1 leaks 0.8734,
--                             15 mention dbt
-- The application boundary redacts job-service query text without exception.
-- Also durable: re-querying ACCOUNT_USAGE days later, after the app, pool and
-- warehouses were dropped, still shows the text blank -- redaction is not a
-- display effect that lifts when the app goes away.
SELECT
    user_name,
    warehouse_name,
    COUNT(*)                                                    AS n,
    COUNT_IF(query_text IS NULL OR TRIM(query_text) = '')        AS blank_text,
    COUNT_IF(query_text ILIKE '%0.8734%')                        AS leaks_secret_constant,
    COUNT_IF(query_text ILIKE '%dbt%')                           AS mentions_dbt,
    MAX(LEFT(query_text, 100))                                   AS longest_visible_text
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(RESULT_LIMIT => 10000))
WHERE user_name ILIKE '%DBT_RUN%'
GROUP BY user_name, warehouse_name
ORDER BY user_name;

-- Broad marker sweep across ALL query history.  EXPECT: only your own probes.
-- RESULT: PASS -- only the analyst's own SELECTs matched.
SELECT user_name, role_name, LEFT(query_text, 120) AS query_text_visible, start_time
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(RESULT_LIMIT => 1000))
WHERE query_text ILIKE '%0.8734%'
   OR query_text ILIKE '%1.1927%'
   OR query_text ILIKE '%PROPRIETARY_SECRET_MARKER%'
   OR query_text ILIKE '%dock_to_stock%'
ORDER BY start_time DESC;

-- PROBE 6 -- container image not enumerable.   EXPECT: 0 image repositories.
-- RESULT: PASS -- 0.
SHOW IMAGE REPOSITORIES IN APPLICATION WMS_ANALYTICS_APP;
SELECT 'image_repos' AS probe, COUNT(*) AS n
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- PROBE 7 -- is CREATE DBT PROJECT available inside the app?
-- EXPECT: 93425, feature not supported in native apps.
-- RESULT: PASS -- see core.probe_dbt_project() in app/setup.sql for the three
-- forms tried and the misleading 1011 path error that the app-relative form
-- returns instead of the feature gate.
CALL WMS_ANALYTICS_APP.CORE.PROBE_DBT_PROJECT();

-- ============================================================================
-- PROBE 8 -- THE ONE THAT ACTUALLY FAILS AT DEFAULT SETTINGS.
--
-- Everything above tests the SQL surface. Container stdout is NOT covered by
-- application query redaction, and it lands in the CONSUMER'S OWN event table,
-- which they can always read. If the job spec does not set
-- spec.logExporters.eventTableConfig.logLevel = NONE, dbt's output is exposed:
-- at default INFO you leak the whole model/layer inventory, and at --debug you
-- leak the compiled SQL and macro constants verbatim.
--
-- Run this on the CONSUMER account after a dbt run.
--   EXPECT with logLevel NONE : app_log_lines = 0
--   EXPECT without it (INFO)  : tens of lines; with --debug, hundreds + secrets
--
-- METHODOLOGY NOTE: the marker predicates below match THIS QUERY'S OWN TEXT if
-- you run it against QUERY_HISTORY. That is not the case here (we read the event
-- table, not query history) -- but when sweeping query history for a secret,
-- always exclude your own session/warehouse or you will report your own probe
-- as a leak. That false positive happened during this project.
-- ============================================================================
SELECT
    COALESCE(REGEXP_SUBSTR(resource_attributes::STRING, 'DBT_RUN_[0-9]+'), '<other>') AS dbt_job,
    COUNT(*)                                                                         AS app_log_lines,
    COUNT_IF(value::STRING ILIKE '%0.8734%' OR value::STRING ILIKE '%1.1927%')        AS leaks_secret_constant,
    COUNT_IF(value::STRING ILIKE '%merge into%')                                      AS leaks_compiled_dml,
    COUNT_IF(value::STRING ILIKE '%REFINEMENT.%' OR value::STRING ILIKE '%REPORTING.%') AS leaks_hidden_layer_names
FROM SNOWFLAKE.TELEMETRY.EVENTS
WHERE timestamp > DATEADD('hour', -3, CURRENT_TIMESTAMP())
  AND resource_attributes::STRING ILIKE '%DBT_RUN%'
GROUP BY 1
ORDER BY 1;

-- PROBE 9 -- the app's job services ARE visible in ACCOUNT_USAGE, unlike
-- SHOW SERVICES IN APPLICATION (which returns nothing). No spec column exists
-- in this view, so no image path or env vars leak -- but do not claim the
-- consumer "cannot see the services", because they can see that they ran.
SELECT service_name, service_catalog, service_schema, compute_pool_name, is_job
FROM SNOWFLAKE.ACCOUNT_USAGE.SERVICES
WHERE service_name ILIKE 'DBT_RUN%'
ORDER BY created DESC;
