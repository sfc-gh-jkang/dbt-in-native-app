#!/usr/bin/env bash
# Deploy the application package + app (development mode) and run dbt inside it.
set -euo pipefail

CONN="${CONN:-my_provider_conn}"
PKG="${PKG:-WMS_ANALYTICS_PKG}"
APP="${APP:-WMS_ANALYTICS_APP}"
STAGE_DB="${STAGE_DB:-WMS_PROVIDER_DB}"
STAGE_SCHEMA="${STAGE_SCHEMA:-IMAGES}"
STAGE="${STAGE:-APP_CODE}"

cd "$(dirname "$0")/.."

echo "==> creating package + stage"
snow sql -c "${CONN}" -q "
CREATE APPLICATION PACKAGE IF NOT EXISTS ${PKG};
CREATE STAGE IF NOT EXISTS ${STAGE_DB}.${STAGE_SCHEMA}.${STAGE} DIRECTORY=(ENABLE=TRUE);
"

echo "==> uploading app files"
snow sql -c "${CONN}" -q "
PUT file://$(pwd)/app/manifest.yml @${STAGE_DB}.${STAGE_SCHEMA}.${STAGE}/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT file://$(pwd)/app/setup.sql   @${STAGE_DB}.${STAGE_SCHEMA}.${STAGE}/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT file://$(pwd)/app/containers/dbt_job_spec.yaml @${STAGE_DB}.${STAGE_SCHEMA}.${STAGE}/containers/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
"

echo "==> (re)installing app in development mode"
snow sql -c "${CONN}" -q "
DROP APPLICATION IF EXISTS ${APP} CASCADE;
CREATE APPLICATION ${APP} FROM APPLICATION PACKAGE ${PKG}
  USING '@${STAGE_DB}.${STAGE_SCHEMA}.${STAGE}';
"

echo "==> done. Next: provision compute, then run dbt."
