#!/usr/bin/env bash
# ===========================================================================
# Two-account teardown for the dbt-in-native-app POC.
#
# Ordering matters and is NOT obvious:
#   1. CONSUMER first. The provider cannot drop an app that lives in the
#      consumer's account, and an installed app blocks dropping the package.
#   2. Unpublish before dropping listings (090553 otherwise).
#   3. Provider last.
#
# Usage:
#   ./scripts/98_teardown_all.sh                      # dry run, shows what it would drop
#   ./scripts/98_teardown_all.sh --execute            # actually drop
#   PROVIDER_CONN=x CONSUMER_CONN=y ./scripts/98_teardown_all.sh --execute
#
# Safe to re-run. Every statement is IF EXISTS.
# ===========================================================================
set -uo pipefail

PROVIDER_CONN="${PROVIDER_CONN:-my_provider_conn}"
CONSUMER_CONN="${CONSUMER_CONN:-}"          # optional; skipped when empty
EXECUTE=0
[[ "${1:-}" == "--execute" ]] && EXECUTE=1

say(){ printf '%s\n' "$*"; }
run(){ # run <conn> <sql> <label>
  local conn="$1" sql="$2" label="$3"
  if [[ $EXECUTE -eq 0 ]]; then
    say "  [dry-run] ${label}"
    return 0
  fi
  local out
  out=$(snow sql -c "$conn" -q "$sql" 2>&1)
  if grep -qiE 'error' <<<"$out"; then
    # IF EXISTS means "already gone" is success, not failure.
    say "  [warn]  ${label}"
    grep -oE '[0-9]{6} \([0-9A-Z]+\)[^|]{0,80}' <<<"$out" | head -1 | sed 's/^/          /'
  else
    say "  [ok]    ${label}"
  fi
}

say "=== dbt-in-native-app teardown ==="
say "provider: ${PROVIDER_CONN}"
say "consumer: ${CONSUMER_CONN:-<none supplied, consumer steps skipped>}"
[[ $EXECUTE -eq 0 ]] && say "MODE: dry run (pass --execute to apply)" || say "MODE: EXECUTE"
say ""

# ---------------------------------------------------------------------------
# 1. CONSUMER SIDE
# ---------------------------------------------------------------------------
if [[ -n "$CONSUMER_CONN" ]]; then
  say "--- consumer account ---"
  # Stop the schedule before dropping, so no task fires mid-teardown.
  run "$CONSUMER_CONN" \
    "CALL WMS_ANALYTICS_APP.CORE.DISABLE_SCHEDULE();" \
    "suspend scheduled task (ignore if app absent)"
  run "$CONSUMER_CONN" \
    "DROP APPLICATION IF EXISTS WMS_ANALYTICS_APP CASCADE;" \
    "drop consumer application"
  # CASCADE usually removes these; drop explicitly in case it did not.
  run "$CONSUMER_CONN" \
    "DROP COMPUTE POOL IF EXISTS WMS_ANALYTICS_APP_DBT_POOL;" \
    "drop app-created compute pool"
  run "$CONSUMER_CONN" \
    "DROP WAREHOUSE IF EXISTS WMS_ANALYTICS_APP_DBT_WH;" \
    "drop app-created warehouse"
  # The consumer-owned table the object reference pointed at. The app never
  # owned it, so dropping the app leaves it behind.
  run "$CONSUMER_CONN" \
    "DROP DATABASE IF EXISTS CUST_DATA;" \
    "drop consumer test source db (CUST_DATA)"
  say ""
fi

# ---------------------------------------------------------------------------
# 2. PROVIDER SIDE — listings before the package they pin
# ---------------------------------------------------------------------------
say "--- provider account: listings ---"
for L in WMS_ANALYTICS_ORG WMS_ANALYTICS_PRIVATE; do
  run "$PROVIDER_CONN" "ALTER LISTING IF EXISTS ${L} UNPUBLISH;" "unpublish ${L}"
  run "$PROVIDER_CONN" "DROP LISTING IF EXISTS ${L};"            "drop ${L}"
done
say ""

say "--- provider account: dev-mode test apps ---"
# Every throwaway app created during testing. Each owns a pool + warehouse.
for APP in WMS_ANALYTICS_APP WMS_ALLOWLIST_TEST WMS_REF_TEST WMS_SCALE_TEST WMS_V14_TEST \
           WMS_INC_TEST WMS_LOOKBACK WMS_COST WMS_DT; do
  run "$PROVIDER_CONN" "DROP APPLICATION IF EXISTS ${APP} CASCADE;" "drop ${APP}"
  run "$PROVIDER_CONN" "DROP COMPUTE POOL IF EXISTS ${APP}_DBT_POOL;" "drop ${APP}_DBT_POOL"
  run "$PROVIDER_CONN" "DROP WAREHOUSE IF EXISTS ${APP}_DBT_WH;"      "drop ${APP}_DBT_WH"
done
say ""

say "--- provider account: package and shared objects ---"
run "$PROVIDER_CONN" "DROP APPLICATION PACKAGE IF EXISTS WMS_ANALYTICS_PKG;" \
  "drop application package (fails if any app still installed anywhere)"
run "$PROVIDER_CONN" "DROP COMPUTE POOL IF EXISTS WMS_DBT_POOL;"   "drop standalone WMS_DBT_POOL"
run "$PROVIDER_CONN" "DROP COMPUTE POOL IF EXISTS WMS_PROBE_POOL;" "drop WMS_PROBE_POOL"
run "$PROVIDER_CONN" "DROP WAREHOUSE IF EXISTS WMS_DBT_WH;"        "drop WMS_DBT_WH"
run "$PROVIDER_CONN" "DROP DATABASE IF EXISTS WMS_SANDBOX_DB;"     "drop WMS_SANDBOX_DB"
run "$PROVIDER_CONN" "DROP DATABASE IF EXISTS WMS_CUSTOMER_DATA;"  "drop stand-in consumer source db"
run "$PROVIDER_CONN" "DROP DATABASE IF EXISTS WMS_PROVIDER_DB;"    "drop WMS_PROVIDER_DB (image repo + stages)"
say ""

# ---------------------------------------------------------------------------
# 3. VERIFY — never trust the drops, and never trust ACCOUNT_USAGE here
#    (it lags up to ~2h; SHOW is authoritative).
# ---------------------------------------------------------------------------
if [[ $EXECUTE -eq 1 ]]; then
  say "--- verification (SHOW, not ACCOUNT_USAGE: it lags ~2h) ---"
  for spec in "APPLICATIONS:apps" "COMPUTE POOLS:pools" "WAREHOUSES:warehouses" \
              "DATABASES:databases" "LISTINGS:listings"; do
    obj="${spec%%:*}"; label="${spec##*:}"
    n=$(snow sql -c "$PROVIDER_CONN" \
         -q "SHOW ${obj} LIKE 'WMS%'; SELECT COUNT(*) AS n FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));" \
         2>/dev/null | grep -oE '^\| [0-9]+' | tr -d '| ' | head -1)
    say "  provider ${label} matching WMS%: ${n:-?}"
  done
  if [[ -n "$CONSUMER_CONN" ]]; then
    n=$(snow sql -c "$CONSUMER_CONN" \
         -q "SHOW APPLICATIONS LIKE 'WMS%'; SELECT COUNT(*) AS n FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));" \
         2>/dev/null | grep -oE '^\| [0-9]+' | tr -d '| ' | head -1)
    say "  consumer apps matching WMS%: ${n:-?}"
  fi
  say ""
  say "Anything non-zero above is still live and still billable. Common causes:"
  say "  - package drop refused because an app is installed in another account"
  say "  - a version still held as PREVIOUS_VERSION in FINALIZING state"
  say "    (check SNOWFLAKE.DATA_SHARING_USAGE.APPLICATION_STATE)"
fi

say "=== teardown complete ==="
