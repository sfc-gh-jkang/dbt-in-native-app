#!/usr/bin/env bash
# Build and push the dbt container image for SPCS (linux/amd64).
#
# ORDERING IS CRITICAL: `snow spcs image-registry login` must run BEFORE the
# buildx builder is created, otherwise the builder does not inherit registry
# credentials. Do NOT use `--load` or plain `docker build` -- the build host is
# arm64 and SPCS requires amd64, so this must be a buildx cross-build with --push.
set -euo pipefail

CONN="${CONN:-my_provider_conn}"
REPO_URL="${REPO_URL:-<org>-<account>.registry.snowflakecomputing.com/wms_provider_db/images/dbt_repo}"
IMAGE_NAME="${IMAGE_NAME:-wms-dbt}"
TAG="${TAG:-v11}"
BUILDER="${BUILDER:-dbt_app_builder}"

FULL="${REPO_URL}/${IMAGE_NAME}:${TAG}"
cd "$(dirname "$0")/../container"

echo "==> 1/3 registry login (must precede builder creation)"
snow spcs image-registry login -c "${CONN}"

echo "==> 2/3 buildx builder"
docker buildx inspect "${BUILDER}" >/dev/null 2>&1 || docker buildx create --name "${BUILDER}" --use
docker buildx use "${BUILDER}"

echo "==> 3/3 cross-build linux/amd64 and push -> ${FULL}"
docker buildx build \
  --platform linux/amd64 \
  --push \
  -t "${FULL}" \
  .

echo "==> done: ${FULL}"
echo "    spec image path (NO registry hostname): /WMS_PROVIDER_DB/IMAGES/DBT_REPO/${IMAGE_NAME}:${TAG}"
