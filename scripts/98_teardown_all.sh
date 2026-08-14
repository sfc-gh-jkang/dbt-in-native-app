#!/usr/bin/env bash
# ===========================================================================
# Teardown for the dbt-in-native-app POC, across every account it touched.
#
# WHY THIS IS WRITTEN THE WAY IT IS -- learned from running it for real:
#
#   1. It ENUMERATES, it does not guess. The first version carried a hardcoded
#      list of app names. It only happened to be complete because a test app
#      (WMS_V14_TEST) was hand-added to the list mid-session. Anything created
#      later and not added would have been silently left running, with a
#      compute pool, billing. A teardown script that needs editing to stay
#      correct is a bug, so this one asks the account what exists.
#
#   2. Pool and warehouse names are DERIVED from the app name
#      (<APP>_DBT_POOL / <APP>_DBT_WH), so enumerating apps also finds their
#      compute. CASCADE usually removes them; it is not guaranteed to, and a
#      surviving pool is the expensive failure.
#
#   3. Counting is done by parsing SHOW's JSON output, never by grepping its
#      text and never via SELECT COUNT(*) FROM RESULT_SCAN(). SHOW rows begin
#      with a created_on timestamp, so a grep anchored on a name column returns
#      a confident, wrong zero. And the RESULT_SCAN form -- which is the usual
#      advice -- needs an active warehouse: on the two accounts here that have
#      no default warehouse it failed with `000606 No active warehouse selected`
#      while plain SHOW worked. A verification step that breaks on some of the
#      accounts it is meant to check is worse than no verification.
#
#   4. Verification carries a POSITIVE CONTROL. A zero from a broken query is
#      indistinguishable from a real zero, so the run also counts objects it
#      expects to find. If the control is zero, the verdict is meaningless and
#      the script says so instead of declaring success.
#
#   5. It verifies EVERY object type on EVERY account, not just applications.
#      The first version checked only consumer apps and would have reported a
#      clean teardown while a consumer pool and database were still live.
#
#   6. Exit status is meaningful: non-zero if anything survives, so this can be
#      trusted in automation rather than read by eye.
#
# Usage:
#   ./scripts/98_teardown_all.sh                   # dry run, shows what it would drop
#   ./scripts/98_teardown_all.sh --execute         # actually drop
#   PROVIDER_CONN=x CONSUMER_CONN=y EXTRA_CONNS="azure gcp" ./scripts/98_teardown_all.sh --execute
#
# EXTRA_CONNS are only INSPECTED, never modified -- they exist so "clean
# everywhere" is a measured claim rather than an assumption.
#
# Safe to re-run. Every drop is IF EXISTS.
# ===========================================================================
set -uo pipefail

PROVIDER_CONN="${PROVIDER_CONN:-my_provider_conn}"
CONSUMER_CONN="${CONSUMER_CONN:-}"        # optional
EXTRA_CONNS="${EXTRA_CONNS:-}"            # optional, inspect-only
PREFIX="${PREFIX:-WMS}"                   # object naming prefix for this POC
EXECUTE=0
[[ "${1:-}" == "--execute" ]] && EXECUTE=1

say(){ printf '%s\n' "$*"; }
note(){ printf '  %-7s %s\n' "$1" "$2"; }

# --- count objects of a type matching a pattern ----------------------------
# Counts the rows SHOW returns, parsed as JSON. Two things this deliberately
# does NOT do:
#   - It does not grep SHOW's text output. SHOW rows begin with a created_on
#     timestamp, so a pattern anchored on a name column can never match and
#     returns a confident, wrong zero.
#   - It does not use `SELECT COUNT(*) FROM TABLE(RESULT_SCAN(...))`, which is
#     the usual advice. That SELECT needs an active warehouse, and a connection
#     without a default warehouse fails it with `000606 No active warehouse
#     selected`. Two of the accounts checked here have no default warehouse, so
#     the RESULT_SCAN form reported NA for them while SHOW worked fine.
# Prints an integer, or NA if the query itself failed.
count(){ # count <conn> <object type> <like pattern>
  snow sql -c "$1" -q "SHOW $2 LIKE '$3';" --format json 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(len(d) if isinstance(d,list) else 'NA')
except Exception:
    print('NA')"
}

# --- list object names of a type matching a pattern ------------------------
names(){ # names <conn> <object type> <like pattern>
  snow sql -c "$1" -q "SHOW $2 LIKE '$3';" --format json 2>/dev/null | python3 -c "
import json,sys
try:
    for r in json.load(sys.stdin):
        n=r.get('name')
        if n: print(n)
except Exception:
    pass"
}

run(){ # run <conn> <sql> <label>
  local conn="$1" sql="$2" label="$3" out
  if [[ $EXECUTE -eq 0 ]]; then note "dry-run" "$label"; return 0; fi
  out=$(snow sql -c "$conn" -q "$sql" 2>&1)
  if grep -qiE 'error|[0-9]{6} \(' <<<"$out"; then
    # IF EXISTS means "already gone" is success. A real refusal shows here and
    # will also be caught by verification, which is what gates the exit code.
    note "warn" "$label"
    grep -oE '[0-9]{6} \([0-9A-Z]+\)[^|]{0,70}' <<<"$out" | head -1 | sed 's/^/          /'
  else
    note "ok" "$label"
  fi
}

say "=== dbt-in-native-app teardown ==="
say "  provider: ${PROVIDER_CONN}"
say "  consumer: ${CONSUMER_CONN:-<none supplied, consumer steps skipped>}"
say "  inspect:  ${EXTRA_CONNS:-<none>}"
say "  prefix:   ${PREFIX}%"
[[ $EXECUTE -eq 0 ]] && say "  MODE: dry run (pass --execute to apply)" || say "  MODE: EXECUTE"
say ""

# ---------------------------------------------------------------------------
# 1. CONSUMER FIRST.
#    The provider cannot drop an app living in the consumer's account, and an
#    installed app blocks dropping the package. Dropping the consumer app also
#    releases the version it pinned -- observed to free the release-channel slot
#    on the very next poll, where waiting on a timer never would have.
# ---------------------------------------------------------------------------
if [[ -n "$CONSUMER_CONN" ]]; then
  say "--- consumer account ---"
  for APP in $(names "$CONSUMER_CONN" "APPLICATIONS" "${PREFIX}%"); do
    # Stop the schedule first so nothing fires mid-teardown. The procedure may
    # not exist on older versions; a warn here is harmless.
    run "$CONSUMER_CONN" "CALL ${APP}.CORE.DISABLE_SCHEDULE();" "suspend schedule in ${APP}"
    run "$CONSUMER_CONN" "DROP APPLICATION IF EXISTS ${APP} CASCADE;" "drop application ${APP}"
    run "$CONSUMER_CONN" "DROP COMPUTE POOL IF EXISTS ${APP}_DBT_POOL;" "drop ${APP}_DBT_POOL"
    run "$CONSUMER_CONN" "DROP WAREHOUSE IF EXISTS ${APP}_DBT_WH;"      "drop ${APP}_DBT_WH"
  done
  # Sweep any prefixed compute/warehouses the loop above did not name, e.g. an
  # app already dropped by hand that left its pool behind.
  for P in $(names "$CONSUMER_CONN" "COMPUTE POOLS" "${PREFIX}%"); do
    run "$CONSUMER_CONN" "DROP COMPUTE POOL IF EXISTS ${P};" "drop orphaned pool ${P}"
  done
  for W in $(names "$CONSUMER_CONN" "WAREHOUSES" "${PREFIX}%"); do
    run "$CONSUMER_CONN" "DROP WAREHOUSE IF EXISTS ${W};" "drop orphaned warehouse ${W}"
  done
  # The table the object reference pointed at is CONSUMER-owned. The app never
  # owned it, so dropping the app leaves it behind, still paying for storage.
  run "$CONSUMER_CONN" "DROP DATABASE IF EXISTS CUST_DATA;" "drop consumer reference source (CUST_DATA)"
  say ""
fi

# ---------------------------------------------------------------------------
# 2. PROVIDER: listings before the package they pin.
#    A published listing must be UNPUBLISHed before it can be dropped.
# ---------------------------------------------------------------------------
say "--- provider: listings ---"
FOUND_LISTING=0
for L in $(names "$PROVIDER_CONN" "LISTINGS" "${PREFIX}%"); do
  FOUND_LISTING=1
  run "$PROVIDER_CONN" "ALTER LISTING IF EXISTS ${L} UNPUBLISH;" "unpublish ${L}"
  run "$PROVIDER_CONN" "DROP LISTING IF EXISTS ${L};"            "drop ${L}"
done
[[ $FOUND_LISTING -eq 0 ]] && note "none" "no ${PREFIX}% listings"
say ""

say "--- provider: applications and their derived compute ---"
FOUND_APP=0
for APP in $(names "$PROVIDER_CONN" "APPLICATIONS" "${PREFIX}%"); do
  FOUND_APP=1
  run "$PROVIDER_CONN" "DROP APPLICATION IF EXISTS ${APP} CASCADE;"  "drop ${APP}"
  run "$PROVIDER_CONN" "DROP COMPUTE POOL IF EXISTS ${APP}_DBT_POOL;" "drop ${APP}_DBT_POOL"
  run "$PROVIDER_CONN" "DROP WAREHOUSE IF EXISTS ${APP}_DBT_WH;"      "drop ${APP}_DBT_WH"
done
[[ $FOUND_APP -eq 0 ]] && note "none" "no ${PREFIX}% applications"
say ""

say "--- provider: application packages ---"
# Must come after every app anywhere is gone, or the drop is refused.
FOUND_PKG=0
for P in $(names "$PROVIDER_CONN" "APPLICATION PACKAGES" "${PREFIX}%"); do
  FOUND_PKG=1
  run "$PROVIDER_CONN" "DROP APPLICATION PACKAGE IF EXISTS ${P};" "drop package ${P}"
done
[[ $FOUND_PKG -eq 0 ]] && note "none" "no ${PREFIX}% packages"
say ""

say "--- provider: remaining compute, warehouses, databases ---"
for P in $(names "$PROVIDER_CONN" "COMPUTE POOLS" "${PREFIX}%"); do
  run "$PROVIDER_CONN" "DROP COMPUTE POOL IF EXISTS ${P};" "drop pool ${P}"
done
for W in $(names "$PROVIDER_CONN" "WAREHOUSES" "${PREFIX}%"); do
  run "$PROVIDER_CONN" "DROP WAREHOUSE IF EXISTS ${W};" "drop warehouse ${W}"
done
# Databases last: apps and packages also appear in SHOW DATABASES, so dropping
# them here first would race the app/package drops above.
for D in $(names "$PROVIDER_CONN" "DATABASES" "${PREFIX}%"); do
  run "$PROVIDER_CONN" "DROP DATABASE IF EXISTS ${D};" "drop database ${D}"
done
say ""

# ---------------------------------------------------------------------------
# 3. VERIFY. SHOW is authoritative; ACCOUNT_USAGE lags up to ~2h and will tell
#    you an object still exists long after it is gone (and vice versa).
# ---------------------------------------------------------------------------
LEFTOVER=0
CONTROL_OK=1

verify_account(){ # verify_account <conn> <label> <role: provider|consumer|other>
  local conn="$1" label="$2" role="$3" n ctl
  say "  ${label} (${conn})"
  # POSITIVE CONTROL: prove the counting path works on this connection before
  # believing any zero it produces.
  ctl=$(count "$conn" "DATABASES" '%')
  if [[ "$ctl" == "NA" || "$ctl" -eq 0 ]]; then
    note "BROKEN" "control count returned '${ctl}' -- cannot trust zeros from this account"
    CONTROL_OK=0
    return
  fi
  note "control" "${ctl} databases visible, so a zero below means absent"
  for spec in "APPLICATIONS:apps" "APPLICATION PACKAGES:packages" \
              "COMPUTE POOLS:pools" "WAREHOUSES:warehouses" \
              "DATABASES:databases" "LISTINGS:listings"; do
    n=$(count "$conn" "${spec%%:*}" "${PREFIX}%")
    if [[ "$n" == "NA" ]]; then
      note "??" "${spec##*:}: query failed"
      LEFTOVER=$((LEFTOVER+1))
    elif [[ "$n" -ne 0 ]]; then
      note "LEFT" "${spec##*:}: ${n} remaining -- $(names "$conn" "${spec%%:*}" "${PREFIX}%" | tr '\n' ' ')"
      LEFTOVER=$((LEFTOVER+n))
    else
      note "clean" "${spec##*:}: 0"
    fi
  done
  # CUST_DATA does not carry the prefix, so it needs its own check.
  if [[ "$role" == "consumer" ]]; then
    n=$(count "$conn" "DATABASES" 'CUST_DATA')
    [[ "$n" == "0" ]] && note "clean" "CUST_DATA: 0" \
      || { note "LEFT" "CUST_DATA: ${n} remaining"; LEFTOVER=$((LEFTOVER+1)); }
  fi
}

say "--- verification (SHOW; ACCOUNT_USAGE lags ~2h and is not used here) ---"
verify_account "$PROVIDER_CONN" "PROVIDER" provider
[[ -n "$CONSUMER_CONN" ]] && verify_account "$CONSUMER_CONN" "CONSUMER" consumer
for X in $EXTRA_CONNS; do verify_account "$X" "INSPECT-ONLY" other; done
say ""

if [[ $CONTROL_OK -eq 0 ]]; then
  say "RESULT: INCONCLUSIVE -- a positive control failed, so the zeros above prove nothing."
  say "        Fix connectivity and re-run before believing this account is clean."
  exit 2
elif [[ $LEFTOVER -eq 0 ]]; then
  say "RESULT: CLEAN -- nothing matching ${PREFIX}% remains on any checked account."
  exit 0
else
  say "RESULT: ${LEFTOVER} object(s) still live and still billable. Common causes:"
  say "  - package drop refused because an app is still installed somewhere"
  say "  - a version held as PREVIOUS_VERSION while a consumer app exists;"
  say "    dropping that app releases it immediately (waiting does not)"
  say "  - a compute pool that CASCADE did not remove"
  exit 1
fi
