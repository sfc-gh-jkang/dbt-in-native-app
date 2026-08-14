-- Token-lifetime probe. Runs STANDALONE (token behaviour is an SPCS property,
-- not app-specific) on a dedicated pool so it cannot contend with the scale test.
-- Long-running: ~75 minutes.

USE ROLE ACCOUNTADMIN;

CREATE COMPUTE POOL IF NOT EXISTS WMS_PROBE_POOL
  MIN_NODES = 1
  MAX_NODES = 1
  INSTANCE_FAMILY = CPU_X64_XS
  AUTO_RESUME = TRUE
  AUTO_SUSPEND_SECS = 60
  COMMENT = 'the ISV token-lifetime probe. Safe to drop.';

EXECUTE JOB SERVICE
  IN COMPUTE POOL WMS_PROBE_POOL
  NAME = WMS_SANDBOX_DB.PUBLIC.TOKEN_PROBE
  FROM SPECIFICATION $$
spec:
  containers:
    - name: dbt
      image: /WMS_PROVIDER_DB/IMAGES/DBT_REPO/wms-dbt:v11
      env:
        DBT_MODE: token_probe
        DBT_DATABASE: WMS_SANDBOX_DB
        DBT_WAREHOUSE: WMS_DBT_WH
        PROBE_MINUTES: "75"
        PROBE_INTERVAL_SECS: "300"
$$;
