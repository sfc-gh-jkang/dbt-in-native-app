-- Phase 1 provider-side setup: image repository + a standalone sandbox for
-- proving the dbt/SPCS OAuth chain BEFORE any native app is involved.
--
-- Run as ACCOUNTADMIN on the provider account.

USE ROLE ACCOUNTADMIN;

CREATE DATABASE IF NOT EXISTS WMS_PROVIDER_DB;
CREATE SCHEMA   IF NOT EXISTS WMS_PROVIDER_DB.IMAGES;

-- Provider image repository. Consumers never push here and never pull from it;
-- the image is bundled into the application package.
CREATE IMAGE REPOSITORY IF NOT EXISTS WMS_PROVIDER_DB.IMAGES.DBT_REPO;

SHOW IMAGE REPOSITORIES IN SCHEMA WMS_PROVIDER_DB.IMAGES;

-- ---------------------------------------------------------------------------
-- Phase 1 sandbox: mimics the app's internal layout using ordinary schemas so
-- we can iterate on the container quickly. Phase 2 recreates this inside the app.
-- ---------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS WMS_SANDBOX_DB;
CREATE SCHEMA   IF NOT EXISTS WMS_SANDBOX_DB.RAW;
CREATE SCHEMA   IF NOT EXISTS WMS_SANDBOX_DB.REFINEMENT;
CREATE SCHEMA   IF NOT EXISTS WMS_SANDBOX_DB.REPORTING;
CREATE SCHEMA   IF NOT EXISTS WMS_SANDBOX_DB.RELEASE;

CREATE OR REPLACE TABLE WMS_SANDBOX_DB.RAW.WMS_ORDERS (
    order_id     NUMBER,
    region       VARCHAR,
    amount       FLOAT,
    received_at  TIMESTAMP_NTZ,
    stocked_at   TIMESTAMP_NTZ,
    promised_at  TIMESTAMP_NTZ,
    delivered_at TIMESTAMP_NTZ
);

INSERT INTO WMS_SANDBOX_DB.RAW.WMS_ORDERS VALUES
  (1, 'emea',   1200.00, '2026-08-01 08:00:00', '2026-08-01 14:30:00', '2026-08-03 12:00:00', '2026-08-03 10:00:00'),
  (2, ' AMER ',  850.50, '2026-08-01 09:15:00', '2026-08-01 11:45:00', '2026-08-04 12:00:00', '2026-08-05 18:00:00'),
  (3, 'APAC',   2310.75, '2026-08-02 22:00:00', '2026-08-03 06:15:00', '2026-08-06 12:00:00', NULL),
  (4, 'emea',    430.25, '2026-08-03 07:30:00', '2026-08-03 09:00:00', '2026-08-05 12:00:00', '2026-08-05 11:00:00'),
  (5, 'AMER',   1775.00, '2026-08-03 13:00:00', '2026-08-04 08:20:00', '2026-08-07 12:00:00', '2026-08-07 09:30:00');

-- Small, short-lived pool. AUTO_SUSPEND_SECS is deliberately low: a job service
-- exits when dbt finishes, so the pool should idle down almost immediately.
CREATE COMPUTE POOL IF NOT EXISTS WMS_DBT_POOL
  MIN_NODES = 1
  MAX_NODES = 1
  INSTANCE_FAMILY = CPU_X64_XS
  AUTO_RESUME = TRUE
  AUTO_SUSPEND_SECS = 60
  COMMENT = 'the ISV dbt-in-SPCS POC. Safe to drop.';

CREATE WAREHOUSE IF NOT EXISTS WMS_DBT_WH
  WAREHOUSE_SIZE = XSMALL
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'the ISV dbt-in-SPCS POC. Safe to drop.';

-- Stage to hold the Phase 1 standalone job spec.
CREATE STAGE IF NOT EXISTS WMS_PROVIDER_DB.IMAGES.SPECS
  DIRECTORY = (ENABLE = TRUE);

SHOW COMPUTE POOLS LIKE 'WMS_DBT_POOL';
