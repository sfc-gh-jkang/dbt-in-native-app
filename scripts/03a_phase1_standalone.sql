-- Phase 1 gate: run dbt in a STANDALONE SPCS job service (no native app yet).
-- Purpose is to de-risk the /snowflake/session/token OAuth chain in isolation.
-- Inline FROM SPECIFICATION keeps the iteration loop fast.

USE ROLE ACCOUNTADMIN;
USE DATABASE WMS_SANDBOX_DB;
USE SCHEMA PUBLIC;

EXECUTE JOB SERVICE
  IN COMPUTE POOL WMS_DBT_POOL
  NAME = WMS_SANDBOX_DB.PUBLIC.DBT_RUN_1
  FROM SPECIFICATION $$
spec:
  containers:
    - name: dbt
      image: /WMS_PROVIDER_DB/IMAGES/DBT_REPO/wms-dbt:v11
      env:
        DBT_DATABASE: WMS_SANDBOX_DB
        DBT_SCHEMA: PUBLIC
        DBT_WAREHOUSE: WMS_DBT_WH
        DBT_COMMAND: run
        DBT_THREADS: "4"
$$;
