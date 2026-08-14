-- ===========================================================================
-- TEARDOWN. Drops everything the POC created, in dependency order.
-- Run this when finished -- live compute pools bill credits.
--
-- CROSS-ACCOUNT ORDER MATTERS. If you installed the app into a separate
-- CONSUMER account, the provider cannot drop that app -- it lives in the
-- consumer's account. Tear down in this order:
--   1. CONSUMER account: DROP APPLICATION <app> CASCADE;  then drop the
--      app-created pool + warehouse if they survive the cascade.
--   2. PROVIDER account: run this script.
-- Dropping the application package while a consumer app still exists will
-- fail, and so will dropping a version a consumer still holds -- including
-- one retained as its PREVIOUS_VERSION in FINALIZING state. Check
-- SNOWFLAKE.DATA_SHARING_USAGE.APPLICATION_STATE if a drop is refused.
-- ===========================================================================
USE ROLE ACCOUNTADMIN;

-- Listing first: a published listing pins the application package.
-- A PUBLISHED listing cannot be dropped directly (090553) -- unpublish first.
-- Cover BOTH shapes: the EXTERNAL private listing and the ORGANIZATION listing.
-- If you followed the cross-region path in the README you created the ORG one.
ALTER LISTING IF EXISTS WMS_ANALYTICS_PRIVATE UNPUBLISH;
DROP LISTING IF EXISTS WMS_ANALYTICS_PRIVATE;
ALTER LISTING IF EXISTS WMS_ANALYTICS_ORG UNPUBLISH;
DROP LISTING IF EXISTS WMS_ANALYTICS_ORG;

-- Dev-mode throwaway apps (allowlist test, object-reference test), if present.
DROP APPLICATION IF EXISTS WMS_ALLOWLIST_TEST CASCADE;
DROP COMPUTE POOL IF EXISTS WMS_ALLOWLIST_TEST_DBT_POOL;
DROP WAREHOUSE    IF EXISTS WMS_ALLOWLIST_TEST_DBT_WH;
DROP APPLICATION IF EXISTS WMS_REF_TEST CASCADE;
DROP COMPUTE POOL IF EXISTS WMS_REF_TEST_DBT_POOL;
DROP WAREHOUSE    IF EXISTS WMS_REF_TEST_DBT_WH;

-- Stand-in "consumer" source database used for the object-reference test.
DROP DATABASE IF EXISTS WMS_CUSTOMER_DATA;

-- App next: this releases the app-owned pool and warehouse.
DROP APPLICATION IF EXISTS WMS_ANALYTICS_APP CASCADE;
DROP APPLICATION PACKAGE IF EXISTS WMS_ANALYTICS_PKG;

-- App-created account-level objects (CASCADE above usually removes these;
-- dropped explicitly in case the app was removed without cascade).
DROP COMPUTE POOL IF EXISTS WMS_ANALYTICS_APP_DBT_POOL;
DROP WAREHOUSE    IF EXISTS WMS_ANALYTICS_APP_DBT_WH;

-- Phase 1 standalone sandbox + token probe pool.
DROP COMPUTE POOL IF EXISTS WMS_DBT_POOL;
DROP COMPUTE POOL IF EXISTS WMS_PROBE_POOL;
DROP WAREHOUSE    IF EXISTS WMS_DBT_WH;
DROP DATABASE     IF EXISTS WMS_SANDBOX_DB;

-- Provider side (image repo + app stage). Drop last.
DROP DATABASE IF EXISTS WMS_PROVIDER_DB;

-- Confirm nothing is left running.
SHOW COMPUTE POOLS LIKE 'WMS_%';
SHOW WAREHOUSES LIKE 'WMS_%';
