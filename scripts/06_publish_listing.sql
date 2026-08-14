-- ===========================================================================
-- TEST 2: true two-account provider/consumer test.
--
-- Every earlier IP probe ran with the app in DEVELOPMENT MODE in the provider's
-- own account -- which is precisely the mode that permits DEBUG_MODE and
-- DISABLE_APPLICATION_REDACTION, so it is the weakest place to claim redaction
-- works. This publishes a real version via a private listing to a SEPARATE
-- account where the app is NOT in development mode.
--
-- Provider: <PROVIDER_ACCOUNT> (<ORG>.<PROVIDER_ACCOUNT_NAME>) AWS_US_EAST_1
-- Consumer: <CONSUMER_ACCOUNT> (<ORG>.<CONSUMER_ACCOUNT_NAME>) AWS_US_WEST_2
--
-- Cross-region, so Cross-Cloud Auto-Fulfillment must replicate the container
-- image. CCAF for SPCS native apps is AWS/Azure only -- both accounts are AWS.
--
-- NOTE: this package has release channels ENABLED, so REGISTER VERSION is
-- required; ADD VERSION USING '@stage' is rejected.
-- ===========================================================================
USE ROLE ACCOUNTADMIN;

ALTER APPLICATION PACKAGE WMS_ANALYTICS_PKG
  REGISTER VERSION v1 USING '@WMS_PROVIDER_DB.IMAGES.APP_CODE';

ALTER APPLICATION PACKAGE WMS_ANALYTICS_PKG
  MODIFY RELEASE CHANNEL DEFAULT
  ADD VERSION v1;

ALTER APPLICATION PACKAGE WMS_ANALYTICS_PKG
  MODIFY RELEASE CHANNEL DEFAULT
  SET DEFAULT RELEASE DIRECTIVE
  VERSION = v1
  PATCH = 0;

SHOW VERSIONS IN APPLICATION PACKAGE WMS_ANALYTICS_PKG;

CREATE EXTERNAL LISTING IF NOT EXISTS WMS_ANALYTICS_PRIVATE
  APPLICATION PACKAGE WMS_ANALYTICS_PKG
  AS $$
title: "WMS Analytics"
subtitle: "Packaged WMS transformation pipeline"
description: |
  Runs the the ISV WMS transformation pipeline inside your account on your
  own compute. Exposes only the certified R5 reporting layer.
listing_terms:
  type: "OFFLINE"
auto_fulfillment:
  refresh_type: SUB_DATABASE_WITH_REFERENCE_USAGE
targets:
  accounts: ["<ORG>.<CONSUMER_ACCOUNT_NAME>"]
$$
  PUBLISH = TRUE;

SHOW EXTERNAL LISTINGS LIKE 'WMS_ANALYTICS_PRIVATE';
