#!/usr/bin/env python3
"""
Token-lifetime probe for dbt-in-SPCS.

THE RISK BEING TESTED
  entrypoint.sh writes profiles.yml ONCE at container start, embedding the OAuth
  token read from /snowflake/session/token at t=0. Snowflake refreshes that file
  every few minutes and each token is valid for up to ~1 hour. So a long dbt run
  (the ISV have 450-750 models) that needs to open a NEW connection after the
  original token expires could fail to authenticate.

WHAT THIS MEASURES
  Every interval, in a loop out to --minutes:
    1. Has the token FILE content changed since t=0?  (does it actually rotate?)
    2. Can a NEW connection be opened with the ORIGINAL t=0 token?  (stale token)
    3. Can a NEW connection be opened with the token re-read RIGHT NOW?  (fresh)
    4. Does a connection opened at t=0 and held open still work?  (long-lived)

  (2) failing while (3) succeeds is the smoking gun: it proves profiles.yml must
  be regenerated per dbt invocation rather than written once.
"""
import os
import sys
import time
import hashlib
import datetime

import snowflake.connector

TOKEN_FILE = "/snowflake/session/token"


def read_token() -> str:
    with open(TOKEN_FILE) as f:
        return f.read()


def digest(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()[:12]


def connect(token: str):
    return snowflake.connector.connect(
        host=os.environ["SNOWFLAKE_HOST"],
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        token=token,
        authenticator="oauth",
        warehouse=os.environ.get("DBT_WAREHOUSE"),
        database=os.environ.get("DBT_DATABASE"),
        login_timeout=60,
        network_timeout=60,
    )


def probe(token: str) -> str:
    try:
        conn = connect(token)
        try:
            cur = conn.cursor()
            cur.execute("select 1")
            cur.fetchone()
            return "OK"
        finally:
            conn.close()
    except Exception as e:
        return f"FAIL({type(e).__name__}: {str(e)[:110]})"


def reuse(conn) -> str:
    try:
        cur = conn.cursor()
        cur.execute("select current_timestamp()")
        cur.fetchone()
        return "OK"
    except Exception as e:
        return f"FAIL({type(e).__name__}: {str(e)[:110]})"


def main() -> int:
    minutes = int(os.environ.get("PROBE_MINUTES", "75"))
    interval = int(os.environ.get("PROBE_INTERVAL_SECS", "300"))

    original = read_token()
    print(f"[probe] t=0 token len={len(original)} sha={digest(original)}", flush=True)
    print(f"[probe] running for {minutes} min, sampling every {interval}s", flush=True)

    # Connection opened at t=0 and deliberately held open for the whole run.
    try:
        held = connect(original)
        print("[probe] long-lived connection opened at t=0", flush=True)
    except Exception as e:
        print(f"[probe] FATAL could not open initial connection: {e}", flush=True)
        return 1

    start = time.time()
    print(f"{'elapsed_min':>11} | {'file_changed':>12} | {'stale_token':>11} | "
          f"{'fresh_token':>11} | held_open", flush=True)
    print("-" * 100, flush=True)

    while True:
        elapsed = (time.time() - start) / 60.0
        current = read_token()
        changed = "YES" if digest(current) != digest(original) else "no"

        stale_result = probe(original)
        fresh_result = probe(current)
        held_result = reuse(held)

        stamp = datetime.datetime.utcnow().strftime("%H:%M:%S")
        print(f"{elapsed:11.1f} | {changed:>12} | {stale_result[:11]:>11} | "
              f"{fresh_result[:11]:>11} | {held_result[:40]}   ({stamp}Z)", flush=True)

        # Full detail whenever the stale token stops working -- the key event.
        if not stale_result.startswith("OK"):
            print(f"[probe] *** STALE TOKEN FAILED at {elapsed:.1f} min ***", flush=True)
            print(f"[probe]     stale: {stale_result}", flush=True)
            print(f"[probe]     fresh: {fresh_result}", flush=True)
            print(f"[probe]     held : {held_result}", flush=True)
            if fresh_result.startswith("OK"):
                print("[probe] CONCLUSION: profiles.yml MUST be regenerated "
                      "per invocation (fresh works, stale does not).", flush=True)
                held.close()
                return 0

        if elapsed >= minutes:
            print(f"[probe] reached {minutes} min with stale token still valid.", flush=True)
            break

        time.sleep(interval)

    held.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
