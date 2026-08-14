#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# dbt Core entrypoint for Snowpark Container Services.
#
# THE AUTH CHAIN (this is the part that makes dbt-in-a-native-app possible):
#   SPCS injects SNOWFLAKE_ACCOUNT + SNOWFLAKE_HOST as env vars and mounts a
#   short-lived OAuth token at /snowflake/session/token. The token authenticates
#   as the *service user*, whose primary role is the service OWNER role. For a
#   service owned by a native app, that owner is the APPLICATION -- so dbt can
#   write to app-owned schemas.
#
# Verified against dbt-snowflake SnowflakeCredentials:
#   - `host` is a real credentials field, passed straight to the connector.
#   - `authenticator: oauth` + `token` are supported.
#   - `user` is OPTIONAL when authenticator is oauth -- so we omit it.
#   - We MUST NOT set oauth_client_id / oauth_client_secret. If either is set,
#     dbt treats `token` as a REFRESH token and tries to exchange it, which
#     fails against the SPCS token.
# ---------------------------------------------------------------------------
set -euo pipefail

TOKEN_FILE="/snowflake/session/token"
PROFILES_DIR="/tmp/dbt_profiles"
PROJECT_DIR="/app/dbt_project"

DBT_COMMAND="${DBT_COMMAND:-run}"
DBT_ARGS="${DBT_ARGS:-}"
DBT_THREADS="${DBT_THREADS:-4}"

# Inside a native app the app's database name is not known at image build time.
# SPCS auto-injects SNOWFLAKE_DATABASE, so fall back to it when DBT_DATABASE is
# not explicitly supplied in the spec.
DBT_DATABASE="${DBT_DATABASE:-${SNOWFLAKE_DATABASE:-}}"

log() { echo "[dbt-entrypoint] $*"; }

# --- preflight -------------------------------------------------------------
if [[ ! -f "${TOKEN_FILE}" ]]; then
  log "FATAL: ${TOKEN_FILE} not found. Not running inside SPCS?"
  exit 1
fi
: "${SNOWFLAKE_ACCOUNT:?SNOWFLAKE_ACCOUNT not set by SPCS}"
: "${SNOWFLAKE_HOST:?SNOWFLAKE_HOST not set by SPCS}"
: "${DBT_DATABASE:?DBT_DATABASE must be supplied in the service spec}"
: "${DBT_WAREHOUSE:?DBT_WAREHOUSE must be supplied in the service spec}"

TOKEN="$(cat "${TOKEN_FILE}")"
if [[ -z "${TOKEN}" ]]; then
  log "FATAL: token file is empty (0 bytes). Service may need a restart."
  exit 1
fi

log "account=${SNOWFLAKE_ACCOUNT} host=${SNOWFLAKE_HOST}"
log "database=${DBT_DATABASE} warehouse=${DBT_WAREHOUSE} threads=${DBT_THREADS}"
log "token length=${#TOKEN}"

# --- alternate mode: token-lifetime probe ----------------------------------
# Set DBT_MODE=token_probe to run the OAuth token expiry investigation instead
# of dbt. See container/token_probe.py.
if [[ "${DBT_MODE:-dbt}" == "token_probe" ]]; then
  log "MODE=token_probe -- running token lifetime probe instead of dbt"
  exec python3 /app/token_probe.py
fi

# --- generate profiles.yml -------------------------------------------------
# Written to /tmp (the image itself stays immutable and secret-free).
mkdir -p "${PROFILES_DIR}"
cat > "${PROFILES_DIR}/profiles.yml" <<PROFILE
wms_analytics:
  target: prod
  outputs:
    prod:
      type: snowflake
      account: "${SNOWFLAKE_ACCOUNT}"
      host: "${SNOWFLAKE_HOST}"
      authenticator: oauth
      token: "${TOKEN}"
      database: "${DBT_DATABASE}"
      schema: "${DBT_SCHEMA:-PUBLIC}"
      warehouse: "${DBT_WAREHOUSE}"
      threads: ${DBT_THREADS}
      client_session_keep_alive: true
      reuse_connections: true
PROFILE

log "profiles.yml written (token redacted from logs)"

# --- run dbt ---------------------------------------------------------------
cd "${PROJECT_DIR}"

set +e
# shellcheck disable=SC2086
dbt ${DBT_COMMAND} \
    --project-dir "${PROJECT_DIR}" \
    --profiles-dir "${PROFILES_DIR}" \
    --target prod \
    ${DBT_ARGS}
DBT_EXIT=$?
set -e

# Never leave the token on disk, even in an ephemeral container.
shred -u "${PROFILES_DIR}/profiles.yml" 2>/dev/null || rm -f "${PROFILES_DIR}/profiles.yml"

log "dbt ${DBT_COMMAND} exited ${DBT_EXIT}"
exit ${DBT_EXIT}
