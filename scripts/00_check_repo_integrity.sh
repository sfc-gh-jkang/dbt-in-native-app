#!/usr/bin/env bash
# ===========================================================================
# Repo integrity guard. Run before publishing, and in CI.
#
# Exists because this repo shipped for days with four DISAGREEING image tags:
# 02_build_push.sh built :v1, setup.sql pulled :v11, 05_token_probe.sql said
# :v2, and the README told you to build :v2. Following the README end to end
# produced an app that installs cleanly, accepts EXECUTE JOB SERVICE, and then
# sits in PENDING forever -- the only place the real reason appears is
# SYSTEM$GET_SERVICE_STATUS ("Failed to pull image"). A README claim and a
# code default drifted apart and nothing diffed them. This does.
#
# Usage: ./scripts/00_check_repo_integrity.sh
# Exit 0 = safe to publish. Non-zero = fix before publishing.
# ===========================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
note(){ printf '  %-6s %s\n' "$1" "$2"; }

echo "=== 1. image tag agreement ==="
# Every file that names the image must name the SAME tag, and the builder's
# default must match, or a clean-room run pulls a tag it never built.
TAGS=$(grep -rhoE 'wms-dbt:v[0-9]+' --include='*.sql' --include='*.yml' . | sed 's/.*://' | sort -u)
BUILD_TAG=$(grep -oE 'TAG:-v[0-9]+' scripts/02_build_push.sh | sed 's/TAG:-//')
COUNT=$(printf '%s\n' "$TAGS" | grep -c .)
if [[ "$COUNT" -ne 1 ]]; then
  note FAIL "image is referenced with $COUNT different tags: $(echo $TAGS | tr '\n' ' ')"
  FAIL=1
elif [[ "$TAGS" != "$BUILD_TAG" ]]; then
  note FAIL "02_build_push.sh builds :$BUILD_TAG but the app pulls :$TAGS"
  FAIL=1
else
  note OK "all references and the build default agree on :$TAGS"
fi

echo "=== 2. setup.sql and manifest.yml agree ==="
# manifest.container_services.images is an ALLOWLIST. A spec that names a tag
# absent from the manifest fails at run time with 395041, not at install.
S=$(grep -oE '/WMS_PROVIDER_DB/IMAGES/DBT_REPO/wms-dbt:v[0-9]+' app/setup.sql | sort -u)
M=$(grep -oE '/WMS_PROVIDER_DB/IMAGES/DBT_REPO/wms-dbt:v[0-9]+' app/manifest.yml | sort -u)
if [[ "$S" == "$M" && -n "$S" ]]; then
  note OK "manifest allowlists exactly what the job spec requests ($S)"
else
  note FAIL "setup.sql wants [$S] but manifest allowlists [$M] -> 395041 at run time"
  FAIL=1
fi

echo "=== 3. no internal identifiers ==="
# A registry hostname is only a finding when the account prefix is REAL. The
# build script legitimately ships "<org>-<account>.registry.snowflakecomputing.com"
# as a placeholder, so match the host but exclude any line carrying a <...>
# placeholder -- otherwise the guard cries wolf on its own documentation.
#
# Two files are excluded by name and both are deliberate:
#   README.md  -- the owner line carries the maintainer's GitHub handle, which
#                 the SCM policy REQUIRES on a public repo.
#   this file  -- it necessarily contains the very tokens it searches for.
# This exclusion is why the guard appeared to pass before it was committed:
# `git ls-files` lists only TRACKED files, so an uncommitted guard never
# scanned itself. Do not read a clean run on an uncommitted tree as a pass.
SELF="scripts/$(basename "$0")"
HITS=$(git ls-files -z | xargs -0 grep -lniE \
  'sfsenorthamerica|sfcogsops|snowhouse|atlassian\.net|confluence' \
  2>/dev/null | grep -vxF -e 'README.md' -e "$SELF" || true)
REG=$(git ls-files -z \
  | xargs -0 grep -nE '[A-Za-z0-9_-]+\.registry\.snowflakecomputing\.com' 2>/dev/null \
  | grep -v '<' || true)
if [[ -z "$HITS" && -z "$REG" ]]; then
  note OK "no account locators, org names, or internal URLs in tracked files"
else
  [[ -n "$HITS" ]] && { note FAIL "internal identifiers in: $(echo $HITS | tr '\n' ' ')"; FAIL=1; }
  [[ -n "$REG" ]]  && { note FAIL "hard-coded registry host: $(echo "$REG" | head -3)"; FAIL=1; }
fi

echo "=== 4. no secret-bearing tracked files ==="
BAD=$(git ls-files | grep -iE '\.env$|\.pem$|\.key$|credentials|tfvars$|tfstate' | grep -vE '\.example$' || true)
if [[ -z "$BAD" ]]; then
  note OK "no .env / keys / credentials / tfvars / tfstate tracked"
else
  note FAIL "tracked secret-bearing files: $(echo $BAD | tr '\n' ' ')"
  FAIL=1
fi

echo "=== 5. the allowlist is still an allowlist ==="
# The IP boundary depends on run_dbt CONSTRUCTING the dbt command from a fixed
# vocabulary. If a future edit interpolates the caller's string into the spec,
# run-operation becomes reachable again and the protection is gone.
if grep -qE "DBT_COMMAND: \"' \|\| :safe_cmd" app/setup.sql; then
  note OK "DBT_COMMAND is built from the validated safe_cmd"
else
  note FAIL "DBT_COMMAND no longer derives from safe_cmd -- allowlist may be bypassable"
  FAIL=1
fi
if grep -qE "logLevel: NONE" app/setup.sql; then
  note OK "container log export is disabled (logLevel: NONE)"
else
  note FAIL "logExporters logLevel is not NONE -- container stdout will leak the DAG"
  FAIL=1
fi

echo
if [[ $FAIL -eq 0 ]]; then
  echo "PASS -- repo is internally consistent."
else
  echo "FAIL -- fix the items above before publishing."
fi
exit $FAIL
