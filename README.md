# dbt Core inside a Snowflake Native App (SPCS)

A working proof that **dbt Core can run inside a Snowflake Native App while keeping the
transformation logic hidden from the consumer** — models, macros, Jinja, *and* compiled SQL.

The problem this solves: an ISV has a mature dbt project encoding domain logic. They want to ship it
as a Native App so each customer runs it on their own compute and pays for it — without handing over
the transformation logic itself.

All results below were measured on the author's own Snowflake demo account and are labelled as such.
Every claim was **independently re-verified on 2026-08-13** by rebuilding the whole thing from a clean
account — image, application package, app install, 503-model dbt run, and all probes. Two claims changed
as a result and are marked below.

## Why this architecture

Two more obvious approaches were tested first. **Both are dead ends:**

| Approach | Result |
|---|---|
| `CREATE DBT PROJECT` inside a native app | **Blocked.** `93425: Feature 'CREATE DBT PROJECT' is not supported in native apps.` |
| dbt Core in a Snowpark stored procedure | **Blocked.** `dbt parse` works; `compile`/`run` fail with `250002: Connection is closed` — no egress from the procedure sandbox. |
| **dbt Core in an SPCS container in the app** | **Works.** This repo. |

The first of those is runnable rather than asserted — `core.probe_dbt_project()` attempts it three ways
and returns each error. **There is a trap in it:** the app-relative path form fails *argument
validation* before the feature gate is reached, so it reports a misleading path error instead of the
real reason:

| Form attempted | Error returned |
|---|---|
| `CREATE DBT PROJECT core.probe_a` | `93425` — feature not supported in native apps |
| `... FROM '@core.some_stage'` | `93425` — same feature gate |
| `... FROM '/dbtproj'` (app-relative) | **`1011` — "invalid URL prefix"** |

Test only the third form and you will spend your time debugging a URI that was never the problem. Note
also that the statement **parses cleanly in a setup script**, so a compile check reports success — only a
runtime attempt is evidence.

A related finding worth knowing before choosing a design: **a `DBT PROJECT` object deployed in the
consumer's own account provides no IP protection at all.** `DESCRIBE DBT PROJECT` returns a
`snow://dbt/...` URI; `LS` + `GET` against it return the **raw Jinja source**, not just compiled SQL.
This is documented behaviour — `USAGE` on a dbt project grants the right to "list or get files."

## How the logic stays hidden

Four independent mechanisms, each verified in `scripts/04_verify_ip.sql`:

1. **The dbt project is baked into the container image**, which lives in the provider's image
   repository and is bundled into the application package. Consumers cannot pull or inspect it, so no
   raw Jinja or macro source ever lands in their account.
2. **`GET_DDL` is blocked on all app-owned objects** (`093051`) — including views dbt creates.
3. **The ungranted layers are not even enumerable.** RAW / REFINEMENT / REPORTING / SERVICES are granted
   to nothing, so `SHOW SCHEMAS IN APPLICATION` returns only `CORE`, `INFORMATION_SCHEMA`, `RELEASE` —
   the others do not appear at all. `SHOW TABLES` against them errors with `002043`, and `SELECT` errors
   with `002003`. *(Corrected: the first run recorded this as "returns 0 objects." It does not — it
   errors. The original result was an artifact of a bad grep, described in Gotchas.)*
4. **The app boundary redacts job-service query text**, so compiled SQL does not reach the consumer's
   `QUERY_HISTORY`.

### The non-obvious finding

Snowflake documents redaction for *"queries originating from a stored procedure owned by the app."* A
job service's queries come from a **service user**, not a procedure — so whether dbt's compiled SQL
would leak was genuinely unclear.

Controlled A/B — the same dbt project, run once outside an app and once inside one. Counts below are
every statement each warehouse ever executed, read from `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY`:

| Service user | Context | Statements | Blank `query_text` | Leaks `0.8734` | Mentions dbt |
|---|---|---|---|---|---|
| standalone job service | **not** in an app | 55 | 0 | **1** | 15 |
| app-owned job service — 2026-08-10 build | **inside** the native app | 726 | **726 (100%)** | **0** | **0** |
| app-owned job service — 2026-08-13 rebuild | **inside** the native app | 713 | **713 (100%)** | **0** | **0** |

The application boundary redacts it without exception, across two independent builds. Outside an app the
same dbt run exposes its compiled SQL in full — including dbt's own query comments and the secret
constant from the proprietary macro. Not one statement inside the app so much as contains the string
"dbt".

The 2026-08-10 counts were also re-queried from `ACCOUNT_USAGE` **after the app, pool, and warehouses
were dropped**, so the redaction is durable in the account's permanent query record — not a transient
display effect that lifts once the app goes away.

A fourth layer found incidentally: the consumer also **cannot read the app's job-service logs**
(`SYSTEM$GET_SERVICE_LOGS` fails with *"Schema ... does not exist or not authorized"*), and dbt's
stdout contains every model name and path.

## The auth chain

This is what makes dbt-in-a-native-app possible, and the highest-risk part of the build.

SPCS injects `SNOWFLAKE_ACCOUNT` and `SNOWFLAKE_HOST` and mounts a short-lived OAuth token at
`/snowflake/session/token`. The token authenticates as the **service user**, whose primary role is the
service **owner** role — for an app-owned service that owner is the **application**, so dbt writes
into app-owned schemas.

Validated against `dbt-snowflake`'s `SnowflakeCredentials`:

- `host` is a real credentials field, passed straight through to the connector.
- `authenticator: oauth` + `token` are supported.
- `user` is **optional** under oauth — omitted here.
- **Do not set `oauth_client_id` / `oauth_client_secret`.** If either is present, dbt treats `token`
  as a *refresh* token and tries to exchange it, which fails against the SPCS token.

## Measured results

| What | Result |
|---|---|
| 3-model demo project (view + incremental merge + view) | 17.1s, 549 macros resolved |
| **503-model scale test** (150 refinement / 200 incremental / 150 release) | **2m32s – 3m41s** across three independent builds on `CPU_X64_XS` + `XSMALL`, 4 threads. The 2m32s run is the current code (allowlist + object references + `logExporters`), re-measured after the rewrite; 151 RELEASE views reproduced exactly on every build. Both issued exactly **713 SQL statements**; SQL wall clock was 3m02s on the slower run. The balance is container start plus dbt's own project parse before any SQL is issued. |
| Consumer-visible objects after the scale run | exactly **151** views in RELEASE — reproduced exactly on both builds; upstream schemas are not enumerable |
| **OAuth token expiry boundary** | **61.1 min** — see below |
| Cost of the 503-model run | **0.070 credits** (~$0.21) — 7% pool, 93% warehouse; see [Cost](#cost) |

### Verified in a real consumer account (2026-08-13)

Every result above was originally produced with the app in **development mode in the provider's own
account** — the one mode that permits `DEBUG_MODE` and `DISABLE_APPLICATION_REDACTION`, and therefore
the weakest possible place to claim that redaction works. That gap is now closed. The app was
published as an organizational listing, installed into a **separate account in a different region**
(us-east-1 → us-west-2, same org), and the pipeline was run there by the consumer.

| Probe (run as ACCOUNTADMIN in the consumer account) | Result |
|---|---|
| `SHOW SCHEMAS IN APPLICATION` | only `CORE, INFORMATION_SCHEMA, RELEASE` — `RAW`/`REFINEMENT`/`REPORTING`/`SERVICES` are not enumerable |
| `SELECT` from `RELEASE.R5_MARGIN_SUMMARY` | **works** — 3 rows, the intended product |
| `GET_DDL` on that same working view | **`093051` GET_DDL is not allowed on the objects owned by the application** |
| `GET_DDL` / `SELECT` on `REPORTING` / `REFINEMENT` | `002003` schema does not exist or not authorized |
| `SHOW TABLES IN SCHEMA ...REPORTING` | `002043` |
| `view_definition` for the RELEASE view the consumer *can* query | empty |
| **dbt query text in the consumer's own `QUERY_HISTORY`** | **13 of 13 statements blank, 0 secret leaks** (app ran as service user `DBT_RUN_...` on `WMS_ANALYTICS_APP_DBT_WH`) |
| `SYSTEM$GET_SERVICE_LOGS` on the dbt job | `002003` — `SERVICES` schema not authorized |
| **the consumer's own event table** | ⚠️ **dbt's stdout IS readable here** — see below |
| `SHOW COMPUTE POOLS` | pool **is** visible (`WMS_ANALYTICS_APP_DBT_POOL`, owning app shown) — correct and desirable, since the consumer pays for it |
| `SNOWFLAKE.ACCOUNT_USAGE.SERVICES` | job services **are** listed (name, `SERVICES` schema, pool, timestamps) — no `spec` column exists in this view, so no image path or env vars |

So the consumer gets the RELEASE layer and the compute bill, and gets neither the macros, the compiled
SQL, nor the business logic.

#### Re-verified on a clean install with the fix in place (2026-08-14)

The table above was produced on `V3`, before the event-table leak was closed and before object
references existed. To prove the whole thing still holds as a package a customer would actually
receive, the consumer app was **dropped and reinstalled from the listing at `V13`** — the version
with `logLevel: NONE`, the subcommand allowlist, references and scheduling — and every probe re-run.

| Probe | `V13` result |
|---|---|
| Install path | `CREATE APPLICATION … FROM LISTING '<ULL>'` — installed at `V13` patch 0 |
| Privileges requested | `CREATE COMPUTE POOL`, `CREATE WAREHOUSE`, `EXECUTE TASK` — all three granted |
| `SHOW SCHEMAS IN APPLICATION` | 3 — `CORE, INFORMATION_SCHEMA, RELEASE` |
| `SHOW VIEWS IN SCHEMA …RELEASE` | 151 views, product surface intact |
| `GET_DDL` on a working RELEASE view | `093051` |
| `SELECT` from `REFINEMENT.STG_ORDERS` | `002003` |
| Image repositories visible | 2 in the account, **neither belongs to the app** — the provider's `DBT_REPO` is not among them |
| **Query text, `ACCOUNT_USAGE.QUERY_HISTORY`** | every job-service user **100% blank**, 0 secret constants, 0 statements even mentioning `dbt` |
| Broad secret sweep, all users but mine | **0 hits** |
| **Event table, filtered to the dbt job** | **0 rows** — while the same account's event table took **38,410 events** in the same 3-hour window |
| `SHOW TASKS IN APPLICATION` | **0** — the schedule is not enumerable either |
| `SHOW DYNAMIC TABLES IN APPLICATION` | **0** |
| Allowlist: `run-operation`, `compile`, `build; rm -rf /`, bad layer, layer injection | all 5 **REJECTED** |
| Unknown schedule cadence | **REJECTED** |

The event-table row deserves emphasis, because it is the one probe where "zero" could just mean
"nothing was logging". It doesn't: the consumer's event table was demonstrably alive and ingesting
38,410 events over the window in which the app's dbt job contributed exactly none.

That the task and the dynamic table are both invisible is why `core.run_history()` exists. If the
consumer cannot enumerate the task, the app has to hand them an audit surface deliberately —
otherwise a schedule that silently stopped firing is undetectable from their side.

### ⚠️ The event table leaks the DAG, and is one flag away from leaking the SQL

**This corrects an earlier claim in this repo that "dbt's own logs are unreadable to the consumer."**
That was inferred from `SYSTEM$GET_SERVICE_LOGS` returning `002003`, which is true but not sufficient —
the event table is an entirely separate path, it is the consumer's *own* object, and container stdout
lands in it. On the consumer account `EVENT_TABLE` was the default `snowflake.telemetry.events`, and a
plain `SELECT` returned 32 app log lines. Verbatim:

```
Found 3 models, 1 source, 549 macros
1 of 3 START sql view model        REFINEMENT.stg_orders ......... [RUN]
1 of 3 OK created sql view model   REFINEMENT.stg_orders ......... [SUCCESS 1 in 0.73s]
2 of 3 START sql incremental model REPORTING.int_order_margin .... [RUN]
2 of 3 OK created sql incremental  REPORTING.int_order_margin .... [SUCCESS 5 in 4.38s]
3 of 3 START sql view model        RELEASE.r5_margin_summary ..... [RUN]
```

Measured against the same 32 lines: **0** lines containing `create or replace` or `select`, **0**
containing `merge into`, **0** containing the secret marker or the proprietary constants.

So what actually leaks is **structure, not logic**: model count, macro count, every model name, its
schema, its materialization, its row count and its runtime — including for the `REFINEMENT` and
`REPORTING` layers that `SHOW SCHEMAS IN APPLICATION` and `GET_DDL` deliberately hide. For a
450–750 model WMS/TMS project, that is a complete inventory of the transformation design's shape.
Whether that counts as IP is a business judgement, but it should be a conscious decision rather than
a surprise.

The sharper risk is the margin — and it is not theoretical. Re-running the identical app with a single
extra argument, `run_dbt('run','--debug')`, took the same app from 32 log lines to **261**, and the
consumer's event table then contained:

```
    amount * 0.8734
    * CASE WHEN region IN ('EMEA', 'APAC') THEN 1.1927 ELSE 1.0 END
On model.wms_analytics.int_order_margin: merge into WMS_ANALYTICS_APP.REPORTING.int_order_margin as DBT_INTERNAL_DEST
```

Counted over those 261 lines: **2** lines carrying the proprietary constants, **1** `merge into`, **3**
`create or replace`, **5** `select`. That is the `wms_margin_index` macro — both secret weights and the
exact business rule — plus compiled DML against the hidden `REPORTING` layer, fully reconstructible by
the consumer.

**This is the one genuine hole in the architecture.** Everything else here holds: query text is
redacted, `GET_DDL` is blocked, ungranted schemas are invisible. But container stdout is *not* covered
by application redaction, and it lands in an object the consumer owns and can always read. A single
CLI flag — or one provider support-debugging session that ships with `--debug` left on — converts
"structure leaks" into "the IP leaks".

Treat container log verbosity as a **security control**, not a diagnostic convenience.

### How to close it — two layers, both tested

**Layer 1 — the platform control, and the one that actually matters.**
[`spec.logExporters`](https://docs.snowflake.com/en/developer-guide/snowpark-container-services/specification-reference)
governs what container stdout/stderr Snowflake exports to the event table. `logLevel: NONE` stops it at
the source. Added to the job spec built by `core.run_dbt`:

```yaml
  logExporters:
    eventTableConfig:
      logLevel: NONE     # INFO (default) | ERROR | NONE
```

Measured on the consumer account, event rows per dbt job:

| Job | App version | Invocation | Event rows | Secret lines |
|---|---|---|---|---|
| `DBT_RUN_...091256` | v1 | `run_dbt('build','')` | 24 | 0 |
| `DBT_RUN_...095432` | v1 | forced failure | 8 | 0 |
| `DBT_RUN_...100217` | v1 | `run_dbt('run','--debug')` | **229** | **2** |
| `DBT_RUN_...102449` | **v2** | `run_dbt('run','')` | **0** | **0** |

The v2 job is confirmed present in `ACCOUNT_USAGE.SERVICES` and its dbt run produced correct RELEASE
output, so it genuinely executed — it simply exported nothing. Re-checked after a further 90s to rule
out event-table latency: still 0.

**Layer 2 — remove the caller's ability to ask.** `core.run_dbt(dbt_command, dbt_args)` passes
`dbt_args` through to the container, which means the **consumer** can request `--debug` against the
provider's own logic. That is the wrong shape for a procedure exposed to `app_admin`. Either drop the
passthrough or reject verbosity flags:

```sql
-- Check BOTH parameters -- see the bypass note below.
IF (:dbt_command ILIKE '%--debug%' OR :dbt_command ILIKE '%--log-level%'
    OR :dbt_command ILIKE '%log-level-file%' OR :dbt_command ILIKE '%--print%'
    OR :dbt_args    ILIKE '%--debug%' OR :dbt_args    ILIKE '%--log-level%'
    OR :dbt_args    ILIKE '%log-level-file%' OR :dbt_args    ILIKE '%--print%') THEN
  RETURN 'REJECTED: verbosity flags are not permitted (IP protection)';
END IF;
```

Verified from the consumer: `CALL ...RUN_DBT('run','--debug')` now returns
`REJECTED: verbosity flags are not permitted (IP protection)`.

**The first version of that guard was bypassable, and that is the useful part.** It checked only
`dbt_args`, so the consumer simply moved the flag to the other parameter —
`run_dbt('run --debug','')` — and it ran. The entrypoint expands `dbt ${DBT_COMMAND} ${DBT_ARGS}`
unquoted, so word-splitting hands `--debug` to dbt either way. (Note it is *word*-splitting only:
`;` inside the variable is passed as a literal argument, not a command separator, so this is argument
injection and **not** shell injection — tested with `run_dbt('bogus; exit 0','')`, which failed rather
than exiting 0.)

That accident produced the cleanest possible test of the two layers, because layer 1 was left in place
while layer 2 was fully defeated:

| Job | Version | Invocation | Layer 2 | Event rows | Secret lines |
|---|---|---|---|---|---|
| `...100217` | v1 | `run_dbt('run','--debug')` | absent | **229** | **2** |
| `...102449` | v2 | `run_dbt('run','')` | held | 0 | 0 |
| `...104032` | v2 | `run_dbt('run --debug','')` | **BYPASSED** | **0** | **0** |
| `...111632` | v3 | `run_dbt('run','')` | held | 0 | 0 |

`...104032` is confirmed present in `ACCOUNT_USAGE.SERVICES` and its call returned
`dbt run --debug completed`, so dbt genuinely ran at debug verbosity with the guard defeated — and
still exported nothing. **Layer 1 is the load-bearing control; layer 2 is convenience.** Build the
`logExporters` line in from the first version and treat any app-code guard as secondary.

The guard now checks both parameters. Verified on v3 from the consumer: `('run','--debug')` REJECTED,
`('run --debug','')` REJECTED, `('run','')` still runs normally and exports 0 rows.

### Flags are the wrong boundary — allowlist the subcommand

Blacklisting verbosity flags is a losing game, because the dangerous surface is not flags at all. Both
of these were reachable through the original passthrough:

| Reachable via passthrough | Why it matters |
|---|---|
| `dbt compile` | materialises every compiled model inside the container |
| **`dbt run-operation <macro>`** | **executes arbitrary project macros with the APPLICATION's privileges** |

`run-operation` is the serious one and no flag filter can catch it. Suppressing stdout does not help
either, because the concern is the *side effects*, not the output — a real 450–750 model project will
contain operational macros that run DDL, DML or grants, and the consumer can invoke any of them.

So `core.run_dbt` no longer accepts free text. It takes an **operation** validated against a closed
vocabulary and an optional **layer** validated against a closed set, and the string that reaches the
container is *constructed* from those, never echoed from the caller:

```sql
CREATE OR REPLACE PROCEDURE core.run_dbt(operation STRING, target_layer STRING)
...
  safe_cmd := CASE LOWER(TRIM(:operation))
                WHEN 'build' THEN 'build'  WHEN 'run'      THEN 'run'
                WHEN 'test'  THEN 'test'   WHEN 'seed'     THEN 'seed'
                WHEN 'snapshot' THEN 'snapshot' ELSE NULL END;
  IF (:safe_cmd IS NULL) THEN RETURN 'REJECTED: operation must be one of ...'; END IF;

  safe_args := '';
  IF (TRIM(:target_layer) <> '') THEN
    IF (LOWER(TRIM(:target_layer)) NOT IN ('refinement','reporting','release')) THEN
      RETURN 'REJECTED: layer must be one of refinement|reporting|release';
    END IF;
    safe_args := '--select ' || LOWER(TRIM(:target_layer)) || '.*';
  END IF;
```

Tested on a v4 install (dev mode on the provider — the allowlist is pure procedure logic, and
consumer-side redaction was already established separately):

| Call | Result |
|---|---|
| `('run-operation','wms_margin_index')` | REJECTED |
| `('compile','')` | REJECTED |
| `('show','--inline SELECT 1')` | REJECTED |
| `('run --debug','')` | REJECTED |
| `('run','--debug')` | REJECTED (layer validation) |
| `('docs','generate')` | REJECTED |
| `('build','../../etc')` | REJECTED |
| `('build','')` | **runs** — correct RELEASE output |
| `('run','release')` | **runs** — layer selector works |

The positive control matters as much as the rejections: an allowlist that also blocks the legitimate
path is just an outage.

**Two methodology traps caught while doing this** — both would have produced a false pass:

1. **Probes run before dbt has built anything are meaningless.** The first pass ran `GET_DDL` and
   `SELECT` *before* the dbt build, and got "does not exist" — which is indistinguishable from
   redaction. Re-running after the build is what produced the real `093051`. Always assert the object
   is queryable first, then prove the DDL is still unobtainable.
2. **A query-history search matches its own SQL.** Grepping `QUERY_HISTORY` for
   `PROPRIETARY_SECRET_MARKER` reported "2 leaks" — both were the probe queries themselves, plus a
   third matching the literal `0.8734`. Always exclude your own session/warehouse, or group by
   `warehouse_name`/`user_name` and read only the app's rows.

### OAuth token expiry: confirmed at ~61 minutes

`container/token_probe.py` (run via `scripts/05_token_probe.sql`) sampled every 5 minutes for 75:

| elapsed | token file rotated | stale t=0 token | freshly-read token | connection held since t=0 |
|---|---|---|---|---|
| 0.0 | no | OK | OK | OK |
| 10.2 | **YES** | OK | OK | OK |
| 20.4 – 56.0 | YES | OK | OK | OK |
| **61.1** | YES | **FAIL** | **OK** | **OK** |

Failure mode: `390318 (08001): Failed to connect to DB ... OAuth access token expired`.

Independently corroborated by billing: the probe pool consumed 0.0625 credits, which at
`CPU_X64_XS`'s 0.06 cr/hr is 62.5 minutes of node time — consistent with a probe that ran to the 61.1
minute mark and then exited, measured through a completely separate system from the probe's own logs.

Three separate conclusions:

1. The token file **rotates roughly every 10 minutes**, but rotation is *not* invalidation — the
   original token keeps working until the ~60 minute mark.
2. A connection **opened before expiry survives indefinitely**. This is why `reuse_connections: true`
   matters.
3. A **new** connection with a stale token fails while a freshly re-read token succeeds.

### …but a long dbt run is not actually at risk (tested)

The obvious worry is a dbt run that outlives its token and then needs a new connection. Measured from
`QUERY_HISTORY`, that does not happen — **dbt front-loads every connection it will ever use:**

| Run | SQL duration | Distinct sessions | All created by | Statements per session |
|---|---|---|---|---|
| 503 models, `threads: 4` | 125s | **4** | **t + 2s** | 183 / 176 / 184 / 170 |
| 3 models, `threads: 4` | 7s | 3 | t + 0s | 5 / 4 / 4 |

dbt opens one session per thread within the first two seconds and reuses them for the entire run. Since
connections established before expiry survive indefinitely (conclusion 2), **a single monolithic run of
any length is safe** — there is no late connection for a stale token to break.

So the mitigation that matters is narrow: regenerate `profiles.yml` **per container start**, which the
entrypoint already does by construction, since every `EXECUTE JOB SERVICE` is a fresh container reading
the token file at t=0. Nothing further is required.

### Chunking works, but do not do it for token reasons

Chunking by layer was the originally-proposed mitigation. It **does** work — verified with three
separate invocations, each building exactly its own layer and nothing else:

| Invocation | `CREATE_VIEW` | `CREATE_TABLE_AS_SELECT` | `DROP` | `SHOW` |
|---|---|---|---|---|
| `RUN_DBT('run','refinement')` | **1** | 0 | 0 | 7 |
| `RUN_DBT('run','reporting')` | 0 | **1** | 1 | 7 |
| `RUN_DBT('run','release')` | **1** | 0 | 0 | 7 |

(dbt exits 0 on "nothing to do", so a passing exit code proves nothing — the statement-type counts are
what confirm each chunk did real, correct work.)

But it costs you. Each invocation carries **7 `SHOW` statements of relation-cache introspection plus a
full container start**, regardless of how few models it builds. And if the chunks are spaced far enough
apart for the pool to suspend, each one incurs its own **5-minute compute-node minimum** (see
[Cost](#cost)). Back-to-back chunks share a single pool session; chunks on separate schedules do not.

Chunk for restartability or scheduling reasons if you want them. Do not chunk to dodge token expiry —
that risk is not real.

## Reading the consumer's own tables (object references)

Seeding source data inside the app keeps the POC self-contained, but it is not the product. A real ISV
transforms **the consumer's own tables**, which means an
[object reference](https://docs.snowflake.com/en/developer-guide/native-apps/requesting-refs): the app
declares what it needs, the consumer binds one of their objects to it, and the app reads it through
`reference('<name>')`.

**The design problem:** dbt needs a stable relation to point a `source` at, and it cannot call
`reference()` itself. **The fix:** the app owns a view, and dbt's source targets that view. Swapping
what the view selects from switches the entire pipeline's input with no change to the dbt project and
no image rebuild.

```yaml
# manifest.yml -- only SELECT is requested; the app never writes to consumer data
references:
  - consumer_orders:
      label: "Your WMS orders table"
      privileges: [SELECT]
      object_type: TABLE
      multi_valued: false
      register_callback: core.register_reference
```

```sql
-- the app's swappable input
CREATE OR REPLACE VIEW raw.orders_source AS SELECT * FROM raw.wms_orders;   -- default: seeded

-- core.use_consumer_source() repoints it:
CREATE OR REPLACE VIEW raw.orders_source AS
  SELECT order_id, region, amount, received_at, stocked_at, promised_at, delivered_at
  FROM reference('consumer_orders');
```

The consumer binds it with one call (Snowsight offers a UI for the same thing):

```sql
CALL <app>.CORE.REGISTER_REFERENCE('CONSUMER_ORDERS', 'ADD',
     SYSTEM$REFERENCE('TABLE', '<their_db>.<their_schema>.<their_table>', 'PERSISTENT', 'SELECT'));
```

### Verified end to end

A 7-row table in a separate database stood in for the consumer's data (deliberately different from the
5 seeded rows so the two are impossible to confuse). After binding and `use_consumer_source()`,
`source_status()` went from `row count: 5` to `row count: 7`, and a full `dbt build` produced:

| REGION | ORDER_COUNT | GROSS_AMOUNT | OTIF_PCT | | independent SQL over the source table |
|---|---|---|---|---|---|
| AMER | 2 | 12000.00 | 100.0 | = | 2 / 12000.00 / 100.0 |
| APAC | 2 | 9900.00 | 50.0 | = | 2 / 9900.00 / 50.0 |
| EMEA | 3 | 12400.00 | 66.7 | = | 3 / 12400.00 / 66.7 |

Every figure matches an aggregate computed independently against the source table, so dbt genuinely
read through the reference rather than falling back to seeded data.

**The reference does not weaken the IP boundary:**

| Probe | Result |
|---|---|
| `GET_DDL` on the reference-backed view | `002003` — `RAW` is not authorized, the view is not even reachable |
| `SHOW SCHEMAS IN APPLICATION` | still only `CORE, INFORMATION_SCHEMA, RELEASE` |
| privileges actually granted to the app | `SELECT` only |
| consumer's source table after the run | unchanged — 7 rows, ids 901–907 |

### A cost-control gap the consumer will notice

The app creates its own compute pool, and the app **owns** it — so the consumer cannot suspend it:

```
Insufficient privileges to operate on compute_pool 'WMS_REF_TEST_DBT_POOL'.
Your primary role ACCOUNTADMIN or one of your secondary roles must have
OPERATE granted on COMPUTE POOL WMS_REF_TEST_DBT_POOL.
```

That is awkward for a design whose whole pitch is "the customer runs it on their own compute and pays
for it": they can *see* the pool (it appears in their `SHOW COMPUTE POOLS`) and they are billed for it,
but the only blunt instrument they have is dropping the application. A provider shipping this should
either grant `OPERATE` on the pool to a consumer role, or expose a `suspend_compute()` procedure to
`app_admin`, so the customer can stop paying without uninstalling. Not fixed in this POC — recorded as
a design requirement.

That last row matters commercially: the app reads the customer's data and writes only inside its own
application objects. The customer can verify that themselves from `SHOW REFERENCES`.

### Two traps worth knowing

**The callback procedure must be `$$`-quoted.** Written as a bare `AS BEGIN ... END;`, the statement is
cut at the first `;` inside the `CASE` body. The app then installs **successfully** with the procedure
silently missing, and the only symptom appears later, at bind time:
`Unknown user-defined function <app>.CORE.REGISTER_REFERENCE`. Procedures defined *after* it in the
same script are created normally, so nothing looks wrong. Reproduced outside the app as
`001003 ... syntax error line 6 at position 77 unexpected '<EOF>'`.

**There is a second version cap.** Separate from the 2-versions-per-release-channel limit, an
application package allows only **2 registered versions that are not in any release channel**
(`512023`). `ALTER APPLICATION PACKAGE ... DEREGISTER VERSION <v>` frees a slot.

## Incremental models: the bug a single run cannot reveal

The POC's incremental model was **silently broken**, and it took a second run against changed source
data to expose it. This is the single most valuable thing the re-test found.

```sql
-- WRONG. received_at is a business timestamp; _loaded_at is wall-clock load time.
where received_at > (select coalesce(max(_loaded_at), '1900-01-01'::timestamp) from {{ this }})
```

Because `_loaded_at` is `current_timestamp()` at load, it is always *later* than any real
`received_at`, so after the first run the predicate is permanently false. The model builds correctly
once, then silently stops ingesting anything — no error, no warning, `dbt build` exits 0. The same
pattern had been stamped into all **200** generated scale models by `generate_models.py`, so the
entire incremental surface of the POC was a no-op on re-runs.

Symptom as observed: `REFINEMENT.STG_ORDERS` (a view) correctly showed 10 source rows while
`REPORTING.INT_ORDER_MARGIN` (the incremental table) sat at 5 rows with ids 1–5 — stale seeded data,
several runs later.

The fix is to compare like for like, which also means projecting the watermark column:

```sql
select order_id, region, amount,
       received_at,                      -- must be projected to be comparable
       ...
{% if is_incremental() %}
  where received_at > (select coalesce(max(received_at), '1900-01-01'::timestamp) from {{ this }})
{% endif %}
```

Verified across runs against a bound consumer table:

| Step | Source rows | `INT_ORDER_MARGIN` |
|---|---|---|
| Run A (first build) | 7 | **7 rows, ids 901–907** |
| insert 3 new rows | 10 | — |
| Run B (incremental) | 10 | **10 rows, ids 901–910** |

**Takeaway for anyone reviewing a dbt project for an ISV app:** an incremental model that is only ever
exercised on a fresh database will pass every test you throw at it. Always run it twice with changed
source data, and assert the row count, not just the exit code.

## Scheduling

"The customer runs it on their own compute" implies automation, not someone calling a procedure. The
app creates a task, and the cadence is an **allowlist** rather than a cron string — a free-text cron
would be interpolated into `CREATE TASK`, which is the same injection shape the dbt args passthrough
had.

```sql
CALL <app>.CORE.ENABLE_SCHEDULE('EVERY15');   -- HOURLY | DAILY | WEEKLY | EVERY15
CALL <app>.CORE.DISABLE_SCHEDULE();
```

Requires `GRANT EXECUTE TASK ON ACCOUNT TO APPLICATION <app>`, declared in the manifest. Verified: a
raw cron string (`*/1 * * * *`) is rejected; `EVERY15` produces a real task reported by
`SHOW TASKS` as `state=started`, `schedule=USING CRON */15 * * * * UTC`; and the task **fired on the
boundary and completed** — `TASK_HISTORY` shows `SUCCEEDED @ 2026-08-13 14:19:38`.

### Getting the schedule right is the easy half

A working cron proves nothing about whether the scheduled run is *correct*. Three things matter more
than the cadence, and all three were wrong in the first cut.

**1. A swallowed error makes a broken pipeline look healthy.** `core.run_dbt()` catches its exception
and *returns* `'ERROR ...'` as a string. A task calling it therefore always reports `SUCCEEDED`, so a
nightly pipeline can fail for weeks while `TASK_HISTORY` stays green and
`SUSPEND_TASK_AFTER_NUM_FAILURES` never trips. The task body is now `core.scheduled_run()`, which
inspects the result, writes it to `core.run_log`, and **raises** on failure:

```sql
IF (:res ILIKE 'ERROR%' OR :res ILIKE 'REJECTED%') THEN RAISE pipeline_failed; END IF;
```

The task also carries `SUSPEND_TASK_AFTER_NUM_FAILURES = 3` so a persistently broken pipeline stops
burning credits instead of retrying forever.

**2. The consumer needs to see that it ran.** Everything about the app is hidden from them by design,
which includes the evidence that the pipeline is healthy. `core.run_history()` exposes
`core.run_log` (run id, start, finish, status, detail) to `app_admin` — an audit trail that proves
liveness without revealing any logic.

**3. A bare high-watermark silently drops data — measured, not theorised.** With
`where received_at > (select max(received_at) from {{ this }})`, a scheduled run misses anything that
arrives out of order. Both cases below were injected into a bound consumer table and the run reported
success each time:

| Event | Bare `>` watermark | 3-day lookback + `merge` |
|---|---|---|
| New row, newer than watermark | captured | captured |
| **Late arrival** — inserted now, `received_at` before the watermark | **silently dropped** | **captured** |
| **Restatement** — amount corrected on a row inside the window | **silently dropped** | **captured** (`222222.00`) |
| **Restatement older than the window** | silently dropped | **still dropped** (`5000.00`) |

The fix is a trailing window rather than a strict inequality, which combined with `merge` on
`unique_key` makes each run idempotent:

```sql
where received_at >= (select coalesce(max(received_at), '1900-01-01'::timestamp)
                      from {{ this }}) - interval '{{ var("lookback_days", 3) }} days'
```

**The remaining gap is real and worth stating to a customer:** a correction older than the lookback is
still missed. Order 901 (`received_at` Aug 1, watermark Aug 10) stayed at its old value through
repeated runs. If the source can be corrected arbitrarily far back — which a WMS or TMS certainly can —
the watermark has to be an `updated_at`/CDC column, not a business timestamp, and the lookback becomes a
safety net rather than the mechanism. Sizing the window is a data-quality decision, not a technical one:
too short silently loses corrections, too long re-reads the warehouse every run.

### Frequency is a cost decision, because of the 5-minute floor

An SPCS compute node bills a **5-minute minimum per start**, and a scheduled run starts the pool from
suspended every time. So pool cost scales with *how often you fire*, not with how long the job takes:

| Cadence | Fires/day | Node-minutes/day (5-min floor) | Pool credits/day @ `CPU_X64_XS` |
|---|---|---|---|
| `EVERY15` | 96 | 480 | ~0.48 |
| `HOURLY` | 24 | 120 | ~0.12 |
| `DAILY` | 1 | 5 | ~0.005 |

A 2m32s job on a 15-minute cadence pays the floor 96 times a day for ~4 hours of billed node time to do
~4 hours of nothing. Pick the slowest cadence the business actually needs; do not default to frequent.

## Cost

Every figure in this section is either a **list rate** from the
[Snowflake Service Consumption Table](https://www.snowflake.com/legal-files/CreditConsumptionTable.pdf)
(effective 2026-08-10) or a **measurement** from this account's `ACCOUNT_USAGE`. Projections are
labelled as such. Dollar figures assume **$3.00/credit** — Enterprise, AWS US East 1 — from Table 2(a);
substitute your own rate.

### Per run, measured

Measured **2026-08-10** on a 3-model and a 503-model project, both against 5 source rows:

| Component | 3 models | 503 models |
|---|---|---|
| Compute pool (`CPU_X64_XS`) | 0.00503 cr | 0.00502 cr |
| Warehouse (`XSMALL`) compute | 0.02325 cr | 0.06488 cr |
| **Total** | **0.0283 cr** | **0.0699 cr** |

A 503-model dbt run costs about **$0.21**. Fitting both points gives, for trivial data volumes:

```
credits per run ≈ 0.028 + 0.000083 × (number of models)
```

**The compute pool is 7% of the run cost.** The warehouse is 93%. The pool is not the thing to optimize.

> **These two numbers are the low end, and a later re-measurement disagreed with them.** They were
> taken on a project without incremental models and with the app reading its own seed. Re-measured
> **2026-08-14** on the current code with an object reference bound, a single full build drew
> **0.0476 warehouse credits** — and the incremental run drew considerably more, for the reason in
> the next section. Treat the table above as a floor for a trivial project, not as a forecast, and
> use the per-run statement counts below when sizing anything real.

### An incremental run cost *more* than a full rebuild

Re-measured on a clean `WMS_COST` install with the object reference bound, attributing every
statement to its run via `INFORMATION_SCHEMA.QUERY_HISTORY` filtered on the job's service user:

| Run | Wall clock | Statements | Warehouse SQL-seconds |
|---|---|---|---|
| Full `dbt build` | 144 s | 441 | 248.6 |
| Incremental (2 new rows) | 240 s | **1919** | **772.1** |

The incremental run did **3× the SQL work of a full rebuild** to process two rows. That is not a
measurement error, and it is worth understanding before anyone promises a customer that incremental
is the cheap option.

The cause is structural, not a bug in these models. An incremental model has to do more per model
than a full one: check whether the relation exists, describe it, compare schemas, build a temp
relation, then `MERGE`. On tiny data the fixed per-model overhead dominates completely, and there
are 200 of them. A full `CREATE OR REPLACE TABLE AS SELECT` is a single statement per model.

The practical reading: **incremental pays off on data volume, not on model count.** At these
volumes it is strictly worse. Agilitics should decide per model, and the crossover point is a
function of rows-rebuilt-per-run versus models-in-the-project — not something to apply globally
because it sounds cheaper.

### Dynamic tables: cheaper when idle, but they cannot go incremental behind a reference

The obvious alternative to running dbt in a container is to let Snowflake maintain the outputs.
`core.create_dt_arm()` builds the same reporting logic as a dynamic table so the two can be
compared directly. Two findings, both measured.

**IP protection is unaffected.** A dynamic table inside an app is hidden by exactly the same
mechanism as a view: `002003` from an ungranted schema, nothing through `INFORMATION_SCHEMA`, and
`SHOW DYNAMIC TABLES IN APPLICATION` returns **0 rows** to the consumer. The application boundary is
object-type agnostic, so choosing dynamic tables does not forfeit the IP story. Its
`DYNAMIC_TABLE_REFRESH_HISTORY` is also unreadable outside a provider debug session — a detail worth
knowing, because it means the *provider* needs `SYSTEM$BEGIN_DEBUG_APPLICATION` to see refresh
behaviour at all, and the consumer never can.

**Idle refreshes are genuinely free.** With `TARGET_LAG = 1 minute` and no upstream change, 17
consecutive refreshes logged `refresh_action = NO_DATA`, `SUCCEEDED`, ~1 s each — and warehouse
credits did not move at six decimal places. A no-op refresh is a metadata check; it does not resume
the warehouse. Contrast the dbt arm, where every scheduled run pays the 5-minute compute-node
minimum whether the data changed or not.

**But every refresh that does touch data is a full recompute.** This is the finding that matters:

```
refresh_mode        = FULL
refresh_mode_reason = SQL compilation error: base table of Dynamic Table to automatically
                      enable CHANGE_TRACKING ... does not exist or not authorized
```

Incremental refresh requires Snowflake to turn on `CHANGE_TRACKING` on the base table. Here the base
table is **the consumer's table, reached through an object reference that grants only `SELECT`**. The
app cannot enable change tracking on someone else's table, so the dynamic table silently degrades to
`FULL` and stays there. Measured cost of one data-changing refresh: **0.0238 credits** — 1.8 s of
actual work wrapped in the warehouse's 60-second minimum.

So the comparison is not "dynamic tables are cheaper", it is a shape difference:

| | dbt in SPCS | Dynamic table behind a reference |
|---|---|---|
| Idle cost | 5-min node minimum per scheduled run | ~0 (`NO_DATA` refresh) |
| Cost when data changes | one run, incremental or full as you choose | full recompute, every time |
| Incremental possible? | yes, you control the predicate | **no** — change tracking is unavailable |
| Logic hidden? | yes | yes, same mechanism |
| Refresh history visible to consumer? | services appear in `ACCOUNT_USAGE` | no |

Dynamic tables win for **sparse, unpredictable arrivals** — you pay nothing between changes. dbt in
SPCS wins where **the data changes on most runs and the tables are big enough that a full recompute
hurts**, because it is the only one of the two that can actually do incremental work over consumer
data. Getting incremental dynamic tables would mean asking the consumer to grant more than `SELECT`,
which weakens the whole point of the reference model.

### The pool cannot be made smaller

`CPU_X64_XS` is the floor on both size and price. Three 1-vCPU / 6-GiB families exist:

| Family | cr/hr | Note |
|---|---|---|
| `GEN_ARM_G1_2` | 0.057 | ARM, AWS only — needs a `linux/arm64` image |
| `CPU_X64_XS` | **0.060** | used here |
| `GEN_X64_G2_2` | 0.064 | current-gen x86, *more* expensive |

Nothing smaller exists — `SHOW COMPUTE POOL INSTANCE FAMILIES` returns no smaller family, and
`INSTANCE_FAMILY = CPU_X64_XXS` is rejected outright. ARM saves 5% (~$0.55/month at hourly runs) and
costs you a multi-arch build. The container requested 0.5 vCPU / 1 GiB and still pushed 503 models
through in 3m41s, so the smallest node has headroom to spare.

### Compute nodes have a 5-minute minimum charge

This is the single most important cost fact for this architecture, and it is **contractual, not
incidental**. From the Consumption Table:

> when a Compute Node (except for Postgres Compute) is started or resumed, a minimum of **five
> minutes'** worth of Platform Credits will be consumed. Thereafter … charged on a per second basis.

Confirmed both ways. All four dbt runs billed exactly 0.005 cr = **precisely 5.00 minutes** of node
time, whether the job took 17 seconds or 3m41s. Across every pool in this account, the charge
distribution has a hard wall at 0.005000 — 16 separate hourly buckets sit exactly on it, and the only
values below it are continuation buckets for pools already running across an hour boundary.

Two consequences:

1. **Sub-5-minute dbt runs are free beyond the floor.** Adding models costs warehouse credits, not pool
   credits, until a run exceeds 5 minutes.
2. **Above ~12 runs/hour, stop suspending the pool.** 0.005 cr per cold start × 8,760 runs/month equals
   the 43.8 cr/month of simply leaving a `CPU_X64_XS` node up. Past that crossover, `AUTO_SUSPEND_SECS`
   is costing you money.

### Where the warehouse cost actually goes

The 503-model run issued **713 statements** in 182s of wall clock:

| Statement type | n | Total time | Compile | Execute |
|---|---|---|---|---|
| `CREATE_TABLE_AS_SELECT` | 201 | 353.6s | 132.9s | 220.1s |
| `CREATE_VIEW` | 302 | 224.5s | 118.2s | 106.3s |
| `DROP` | 201 | 67.9s | 67.5s | **0.4s** |
| `SHOW` | 9 | 4.7s | 2.7s | 2.0s |

Three things fall out of this:

- **Compilation is 49% of all statement time** (321.3s of 650.7s). On a many-small-models project against
  small data, you are paying mostly for planning, not computation. This is a property of model *count*,
  not data volume.
- **201 `DROP` statements consumed 67.9s of warehouse time to do 0.4s of work** — 10% of statement time
  is dbt's drop-then-create relation churn, essentially all compile overhead.
- **Zero queuing.** `queued_overload_time` was 0.00s across all 713 statements, so `XSMALL` was never the
  bottleneck at 4 threads.

### Raising dbt threads is the real lever (projected)

650.7s of statement time compressed into 182s of wall clock is an effective concurrency of **3.58x** at
`threads: 4` — near-linear, with no queuing. The warehouse bills wall clock, not statement time.

Projecting ideal scaling to `threads: 8` puts wall clock near 91s; adding the observed ~52s
auto-suspend tail gives ~0.040 cr against the measured 0.065 cr, or roughly **40% off the warehouse
line**. **This is a projection, not a measurement** — it was not tested, and real scaling will fall short
of linear. The zero-queuing result is what makes it worth trying.

### Monthly, per consumer

503-model project, trivial data volumes, $3/credit:

| Frequency | Pool | Warehouse | Total | $/mo |
|---|---|---|---|---|
| Daily | 0.15 cr | 1.95 cr | 2.1 cr | ~$6 |
| 4×/day | 0.61 cr | 7.9 cr | 8.5 cr | ~$26 |
| Hourly | 3.65 cr | 47.4 cr | 51 cr | ~$153 |
| *Pool left running 24×7 (anti-pattern)* | 43.8 cr | — | 43.8 cr | ~$131 |

That last row is why this app uses `EXECUTE JOB SERVICE` and not a long-running `SERVICE`. A job service
exits when dbt exits and the pool auto-suspends; an always-on service would cost more in idle pool than
all the actual transformation work combined. The token probe demonstrated this incidentally — 61 minutes
of continuous pool time burned 0.0625 cr, **12× a full 503-model dbt run**.

### Caveats

- **The warehouse number is a floor, not a forecast.** 0.065 cr was 503 models against 5 rows —
  effectively pure per-statement overhead. Real data volumes move the warehouse line and only the
  warehouse line; the pool stays at 0.005/run.
- **Cloud services was 143% of warehouse compute** on the 503-model run (0.093 cr vs 0.065 cr) — a direct
  consequence of the compile-heavy profile above. It is normally absorbed by the daily
  [Cloud Services Adjustment](https://docs.snowflake.com/en/user-guide/cost-understanding-compute)
  (free up to 10% of daily warehouse credits), but a many-small-models app in an otherwise-idle consumer
  account may not have enough warehouse usage to absorb it. Note that per the Consumption Table, cloud
  services attributable to **SPCS compute does not contribute to that adjustment** at all.
- **Provider runtime cost is zero.** Each consumer's app provisions its own pool and warehouse in their
  own account — the entire point of the architecture. The provider pays only image-repository storage
  (a ~0.5–1 GB image is cents per month), plus the same again per replicated region for cross-cloud
  auto-fulfillment.
- **Data transfer is not free for SPCS.** Same-region SPCS data transfer on AWS is $3.07/TB (Table 4(a)),
  where non-SPCS same-region transfer is $0.00. Negligible here, but it scales with data volume moved
  through the container. A daily adjustment caps it at 10% of SPCS compute cost.

## Layout

```
container/
  Dockerfile              # python:3.11-slim + dbt-core + dbt-snowflake; project COPY'd in
  entrypoint.sh           # the auth chain: token -> profiles.yml -> dbt
  token_probe.py          # OAuth expiry investigation (DBT_MODE=token_probe)
  dbt_project/
    macros/proprietary_macros.sql  # stand-in "IP": secret constants + metric definitions
    models/refinement/    # view        -> ungranted
    models/reporting/     # incremental -> ungranted
    models/release/       # view        -> granted (the consumer-facing surface)
app/
  manifest.yml            # manifest_version 2; CREATE COMPUTE POOL + CREATE WAREHOUSE
  setup.sql               # schemas, grants, provision_compute(), run_dbt()
  containers/dbt_job_spec.yaml
scripts/
  00_check_repo_integrity.sh # pre-publish guard: tag/manifest/allowlist agreement
  01_provider_setup.sql     # image repo + standalone sandbox
  02_build_push.sh          # buildx cross-build to linux/amd64
  03a_phase1_standalone.sql # de-risk the OAuth chain with no app involved
  03_deploy_app.sh          # package + install in development mode
  04_verify_ip.sql          # the IP probes, with recorded results
  05_token_probe.sql        # launch the 75-minute token probe
  06_publish_listing.sql    # cross-account publish via private listing
  generate_models.py        # generate the 500-model scale test
  98_teardown_all.sh        # two-account teardown, dry-run by default
  99_teardown.sql           # drop everything (live pools bill credits)
```

## Run it

Set your own connection name and image repository first — the scripts use placeholders, not real
identifiers.

```bash
snow sql -c <conn> -f scripts/01_provider_setup.sql
./scripts/02_build_push.sh                                # builds and pushes wms-dbt:v11
./scripts/00_check_repo_integrity.sh                      # tag/manifest/allowlist agreement
snow sql -c <conn> -f scripts/03a_phase1_standalone.sql   # gate: prove OAuth works
./scripts/03_deploy_app.sh
# No provisioning step: run_dbt() creates the pool and warehouse on first call
# and waits for the pool to leave STARTING. First run therefore takes ~3 min.
# run_dbt(operation, target_layer) -- both allowlisted; see "allowlist the subcommand"
snow sql -c <conn> -q "CALL WMS_ANALYTICS_APP.CORE.RUN_DBT('build','');"
snow sql -c <conn> -q "CALL WMS_ANALYTICS_APP.CORE.RUN_DBT('run','release');"
snow sql -c <conn> -q "CALL WMS_ANALYTICS_APP.CORE.PROBE_DBT_PROJECT();"  # proves CREATE DBT PROJECT is blocked
snow sql -c <conn> -f scripts/04_verify_ip.sql
snow sql -c <conn> -f scripts/99_teardown.sql
```

To point the pipeline at your own table instead of the seed, bind a reference and let the app check
the shape before it repoints anything:

```bash
snow sql -c <conn> -q "CALL WMS_ANALYTICS_APP.CORE.REGISTER_REFERENCE('consumer_orders','ADD',
  SYSTEM\$REFERENCE('TABLE','<db>.<schema>.<table>','PERSISTENT','SELECT'));"
snow sql -c <conn> -q "CALL WMS_ANALYTICS_APP.CORE.VALIDATE_CONSUMER_SOURCE();"  # names every missing column
snow sql -c <conn> -q "CALL WMS_ANALYTICS_APP.CORE.USE_CONSUMER_SOURCE();"       # refuses if incompatible
```

The 500 scale-test models are already committed, so the steps above build the full project as-is.
Regenerate only if you want different counts:

```bash
python3 scripts/generate_models.py --refinement 150 --reporting 200 --release 150
./scripts/02_build_push.sh   # builds wms-dbt:v11, the tag every other file expects
```

## Gotchas

- **`BIND SERVICE ENDPOINT` is not required** for a job-service-only app. `CREATE COMPUTE POOL` and
  `CREATE WAREHOUSE` suffice — and `CREATE WAREHOUSE` *is* mandatory because the container issues SQL.
- **Job services cannot run in a versioned schema** — hence the non-versioned `services` schema.
- **`EXECUTE JOB SERVICE` parameter order is fixed:** compute pool, then spec, then `NAME`.
- **The spec is static YAML but the app's database/warehouse names aren't known at image build time.**
  Solved by building the spec inline in `core.run_dbt()` via
  `EXECUTE IMMEDIATE ... FROM SPECIFICATION`, which works inside an app (docs only show
  `SPECIFICATION_FILE`). `SNOWFLAKE_DATABASE` is also auto-injected as a fallback.
- **Build host may be arm64; SPCS is amd64** — use `docker buildx build --platform linux/amd64 --push`.
  Registry login must happen **before** the buildx builder is created.
- **`CREATE OR REPLACE APPLICATION` is a syntax error** — `DROP ... CASCADE` then `CREATE`.
- **dbt's default `generate_schema_name` concatenates** `<target>_<custom>`; overridden in
  `macros/generate_schema_name.sql` so schemas are literal.
- Grants on dbt-created objects must happen **after** the run — `run_dbt()` does this.
- **Release channels change the version syntax.** With channels enabled, `ADD VERSION USING '@stage'`
  fails (`512020`); use `REGISTER VERSION`, then `MODIFY RELEASE CHANNEL ... ADD VERSION`, then
  `SET DEFAULT RELEASE DIRECTIVE`.
- **A release channel holds a maximum of 2 versions** (`512004`: "There are 2 versions added to the
  release channel 'DEFAULT', the maximum allowed"). Shipping a third means dropping one first.
- **The verb to free a channel slot is `DROP VERSION`, not `REMOVE VERSION`.** `MODIFY RELEASE CHANNEL
  DEFAULT REMOVE VERSION V2` is a syntax error (`001003`), and so are the plausible-looking
  `DEREGISTER VERSION V2 FROM RELEASE CHANNEL DEFAULT` / `REGISTER VERSION V13 TO RELEASE CHANNEL
  DEFAULT`. The two working forms are `MODIFY RELEASE CHANNEL <ch> ADD VERSION <v>` and
  `MODIFY RELEASE CHANNEL <ch> DROP VERSION <v>`; `DEREGISTER VERSION <v>` (no channel clause) is for
  versions not in any channel.
- **`DROP VERSION` from a channel is asynchronous, and a consumer holding the version pins it.** After
  issuing the drop, `SHOW RELEASE CHANNELS` still listed `V2` — because the consumer held it as
  `PREVIOUS_VERSION`. It is not a time-based wait: dropping the consumer's app released the slot on the
  very next poll. Check `SNOWFLAKE.DATA_SHARING_USAGE.APPLICATION_STATE` for
  `PREVIOUS_VERSION_STATE`; while it reads `FINALIZING` the version cannot be released at all.
- **A consumer installs an org listing with `FROM LISTING`, not `FROM APPLICATION PACKAGE`.**
  `CREATE APPLICATION x FROM APPLICATION PACKAGE "ORGDATACLOUD$INTERNAL$<name>"` fails with `002003`
  "Application package does not exist or not authorized", and `SHOW APPLICATION PACKAGES` in the
  consumer account returns 0 rows — the ULL is not a package there. The working form is
  `CREATE APPLICATION x FROM LISTING 'ORGDATACLOUD$INTERNAL$<name>'`.
- **`SHOW AVAILABLE LISTINGS LIKE '%WMS%'` silently ignores the filter** and returns every listing the
  account can see (627 here). Filter client-side on `title` or `global_name` instead.
- **`SHOW RELEASE DIRECTIVES` reports the target in columns named `version` and `patch`** — not
  `target_version`/`target_patch`. Reading the wrong names returns `None` and looks like the directive
  failed to set when it actually succeeded.
- **`SYSTEM$TRIGGER_LISTING_REFRESH` needs its `$` escaped in a double-quoted shell string**, or bash
  expands `$TRIGGER_LISTING_REFRESH` to empty and Snowflake reports `002139` on `SYSTEM`.
- **`core.provision_compute()` runs itself now, but know why it exists.** A fresh install owns no
  compute, so the first `run_dbt()` used to fail with `2003` "Compute pool … does not exist or not
  authorized" — an error that reads like a permissions problem and isn't the consumer's fault.
  `run_dbt()` now calls `provision_compute()` itself (idempotent) and waits out the `STARTING` state,
  so a brand-new app goes from install to results in one call. Measured end to end on a fresh
  consumer install: **192 s**, of which ~2 min is pool creation. Two ordering details matter: the
  subcommand allowlist is validated **before** provisioning, so a rejected call never creates
  billable compute; and `SUSPENDED` is not waited on, because `AUTO_RESUME` handles it when the job
  lands.
- **Validate the object-reference contract at bind time.** `SYSTEM$SET_REFERENCE` succeeds against a
  table of any shape — the mismatch surfaces later, from inside the app, as a bare
  `904 invalid identifier 'STOCKED_AT'`, naming only the *first* missing column. `core.validate_consumer_source()`
  probes each required column separately and reports the whole set at once, and distinguishes
  "nothing bound" from "wrong shape" (without that check, an unbound reference reports all 7 columns
  as missing). `use_consumer_source()` calls it and **refuses** rather than repointing the pipeline at
  a table that can't feed it, leaving the seed live so the app keeps working and says why.
- **Do not trust a row count to tell you which source is live.** `source_status()` returning 5 rows
  looked like a successful switch to a consumer table that also had 5 rows — the view had silently
  never been repointed. Use a sentinel value the seed cannot produce.
- **The image tag in `setup.sql` and `manifest.yml` must both exist in the registry, and the repo is
  where this rots.** Both files referenced `wms-dbt:v2` long after that tag was gone (live tags were
  v4, v5, v7, v8, v10, v11); every working deploy had been made from an out-of-tree copy with the tag
  substituted, so the repo was not deployable as checked in. The failure is quiet and slow: the app
  installs, `EXECUTE JOB SERVICE` is accepted, and the job sits in `PENDING` for as long as you let
  it. `SYSTEM$GET_SERVICE_STATUS` is the only thing that says why — `"message":"Failed to pull image"`.
  `SHOW SERVICES` just says `PENDING`. Verify the tag exists with
  `snow spcs image-repository list-images DBT_REPO --database … --schema …` before blaming the pool.
- **`DYNAMIC_TABLE_REFRESH_HISTORY` on an app-owned dynamic table returns zero rows outside a debug
  session.** It is not empty — wrap the query in `SYSTEM$BEGIN_DEBUG_APPLICATION('<app>')` in the same
  session and the rows appear. Reading it without the debug session produced a contradiction (15
  refreshes one minute, none the next) that looked like the table had been dropped.
- **A teardown script with a hardcoded object list is a bug.** The first version of
  `98_teardown_all.sh` named the apps to drop. It was only complete because a test app was
  hand-added to the list mid-session; anything created afterwards would have been left running with
  a compute pool attached, quietly billing. It now enumerates `SHOW APPLICATIONS LIKE 'WMS%'` and
  derives each app's pool and warehouse from its name, so it cannot go stale. It also swept only
  consumer *applications* during verification, and would have declared a clean teardown while a
  consumer pool and database were still live.
- **`SELECT COUNT(*) FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))` is the standard way to count `SHOW`
  output, and it fails on any connection with no default warehouse** — `000606 No active warehouse
  selected`. Plain `SHOW` needs no warehouse; the `SELECT` over its result does. Two of the four demo
  accounts checked here have no default warehouse, so the RESULT_SCAN form returned nothing for them
  while `SHOW` worked fine. Counting the length of `SHOW ... --format json` avoids both traps: it is
  structured (unlike grepping the text, where a pattern anchored on the name column can never match
  because every row starts with `created_on`) and it needs no warehouse.
- **Put a positive control in any "it's all gone" check.** A zero from a broken query is
  indistinguishable from a real zero. The teardown counts objects it *expects* to find on each
  account first, and if that control is zero or errors it reports `INCONCLUSIVE` and exits 2 rather
  than claiming success. That control is what caught the warehouse bug above — the affected accounts
  would otherwise have reported a confident, meaningless "0 objects remaining".
- **Dropping a version from a release channel is deferred, not immediate.** `MODIFY RELEASE CHANNEL ...
  DROP VERSION` returns success, but re-running it says `512011` "was already set to be dropped" while
  `ADD VERSION` still fails with `512004`. There are two distinct causes and they need different
  responses: if no consumer holds the version it clears on its own in about a minute, so retry the add
  (scripted release automation needs a retry loop). If a consumer app still references it — including as
  its `PREVIOUS_VERSION` — retrying will never succeed, and the slot frees the moment that app is
  upgraded past it or dropped. Check `APPLICATION_STATE` before assuming it is the first case.
- **Consumer apps installed from a listing auto-upgrade to the release directive.** After pointing
  DEFAULT at a new version, the installed consumer app moved v1→v2→v3 on its own with no consumer
  action and no second Get; an explicit `ALTER APPLICATION ... UPGRADE` returned "Application is on
  latest version, upgrade skipped." v1→v2 took a couple of minutes, v2→v3 under a minute.
- **You cannot drop a version any consumer app is still using — including as its *previous* version.**
  `DROP VERSION` fails with "Cannot drop version 'V2' because it is in use by one or more applications
  (example consumer account '...')". The error names the diagnostic view, and it is worth using:
  `SNOWFLAKE.DATA_SHARING_USAGE.APPLICATION_STATE` showed `CURRENT_VERSION = V3` but
  `PREVIOUS_VERSION = V2` with `PREVIOUS_VERSION_STATE = FINALIZING`. The retained previous version is
  what pins the slot, and it stayed `FINALIZING` for over 10 minutes after the upgrade completed.
  **Combined with the 2-version cap this is a real release-management constraint:** with only two slots
  and one held by the previous version, a provider cannot ship a third version until finalization
  clears — and a customer who never upgrades holds a slot indefinitely. Plan releases around
  `APPLICATION_STATE`, not around what `SHOW VERSIONS` says.
- **Do not grep command output for `added`/`dropped` to confirm a channel change.** The max-versions
  error text itself contains "There are 2 versions **added** to the release channel", so a naive
  `grep -qi "added"` reports success on failure. Verify against state:
  `SHOW RELEASE CHANNELS IN APPLICATION PACKAGE ...` and read the `versions` array.
- **The manifest's `container_services.images` list is an allowlist.** If the job spec references an
  image tag that is not declared in the manifest of that version, the job fails with
  `395041 Invalid image specified in service spec: image '...' does not exist in current application
  version`. Bumping the tag in `setup.sql` alone is not enough — bump it in `manifest.yml` too.
- **`DEBUG_MODE` does not exist for `manifest_version: 2`.** `ALTER APPLICATION ... SET DEBUG_MODE`
  returns `093362 Cannot use debug mode on an application when manifest version is 2 or above. Please
  use session debugging.` The replacement is
  [`SYSTEM$BEGIN_DEBUG_APPLICATION`](https://docs.snowflake.com/en/sql-reference/functions/system_begin_debug_application),
  which is session-scoped — call it and your queries in the **same session**. Note the documented
  named-argument form `execution_mode => 'AS_APPLICATION'` fails with `000945`; positional
  (`SYSTEM$BEGIN_DEBUG_APPLICATION('<app>', 'AS_APPLICATION')`) works. This is how a provider inspects
  hidden schemas like `REPORTING` and `SERVICES` on a dev-mode install.
- **`SYSTEM$GET_SERVICE_LOGS` only works while the container is RUNNING.** For a completed job service
  it returns `000005 Unable to retrieve logs, Please run SHOW SERVICE CONTAINERS IN SERVICE to check
  that container dbt is running`. Its `tail lines` argument also caps at 1000 (`395032`).
  **Consequence of `logExporters: NONE`:** you have no post-hoc logs at all — not as the consumer, and
  not as the provider. Catch failures live, or ship a provider-only debug build at `INFO`/`ERROR`. Do
  not discover this during an incident.
- **A published listing cannot be dropped** (`090553`) — `ALTER LISTING ... UNPUBLISH` first, and
  tear the listing down *before* the application package.
- `SHOW EXTERNAL LISTINGS` is not valid syntax — it is `SHOW LISTINGS`.
- **Minimum charges are asymmetric between warehouses and compute pools.** A warehouse bills a 1-minute
  minimum per resume; an SPCS compute node bills a **5-minute** minimum per start. Tuning
  `AUTO_SUSPEND_SECS` below 60 buys nothing for short job-service runs — the 5-minute floor dominates.
  (An Interactive Warehouse, for contrast, carries a **60-minute** minimum — do not reach for one here.)
- **Counting `SHOW` output by grepping for a leading uppercase name column gives false results** —
  `SHOW` output begins with a `created_on` timestamp. Use
  `SHOW ...; SELECT COUNT(*) FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))`.
- **Publishing an application package as an organizational listing has three separate syntax traps.**
  `refresh_type: SUB_DATABASE` fails with `090685 Application listings require sub db and reference
  usage replication` — app listings need `SUB_DATABASE_WITH_REFERENCE_USAGE`. That refresh type then
  rejects a schedule: `090893 Refresh schedule must be empty when reference usage is used`, so
  `refresh_schedule` must be omitted entirely. And the consumer installs by the **ULL**
  (`ORGDATACLOUD$INTERNAL$<listing_name>`, from the `uniform_listing_locator` column), not the
  marketplace `global_name` — using the latter fails with `003005`.
- **`SYSTEM$TRIGGER_LISTING_REFRESH` takes two arguments, and the first is the object type**, not the
  listing: `SYSTEM$TRIGGER_LISTING_REFRESH('LISTING','<listing_name>')`. It is also a useful
  diagnostic — the `in N region(s)` in its return value tells you how many regions the product has
  actually been fulfilled to, which is how the fulfillment deadlock below was confirmed.
- **`ALTER APPLICATION PACKAGE ... ENABLE REPLICATION TO ACCOUNTS` is not valid syntax.** That form
  exists for databases only; an application package reaches another region via listing
  auto-fulfillment.

## Known limitations

- ~~**Single-account, development mode.**~~ **CLOSED 2026-08-13** — see "Verified in a real consumer
  account" above. Redaction no longer rests on development-mode behaviour.
- **Cross-region consumer install: completed, but the first one needs a consumer-side click.** Three
  publishing attempts (us-east-1 → us-west-2, same org). The first two never became installable; the
  cause chain is now identified, and it is not the architecture:
  1. With `DISTRIBUTION = EXTERNAL`, adding a version to the DEFAULT or ALPHA release channel starts
     the [automated security scan](https://docs.snowflake.com/en/developer-guide/native-apps/security-run-scan),
     and the version sat at `review_status: NOT_REVIEWED`. Setting `DISTRIBUTION = INTERNAL` removes
     the scan entirely for same-org distribution — but did **not** make the app installable, so the
     scan was never the only blocker.
  2. The real blocker is fulfillment. Per the
     [auto-fulfillment docs](https://docs.snowflake.com/en/collaboration/provider-listings-auto-fulfillment),
     *"Private listings are auto-fulfilled after the specified consumers get your listing."*
     `SYSTEM$TRIGGER_LISTING_REFRESH('LISTING','<listing>')` confirmed this exactly:
     `Successfully triggered refresh for LISTING '...' in 0 region(s)` — the product had never been
     fulfilled to any remote region, even with `auto_fulfillment` and `access_regions` both correctly
     persisted in the stored manifest.
  3. That is a deadlock on the SQL path: fulfillment starts when the consumer *gets* the listing, but
     `CREATE APPLICATION ... FROM LISTING` resolves the listing locally first and so fails with
     `003005 Data exchange listing ... does not exist` until fulfillment has already happened. The
     consumer's **Get** in Snowsight is what breaks the cycle; there is no provider-side SQL to force
     a first fulfillment.
  4. Once the consumer clicked **Get**, fulfillment completed in **~24 minutes** and everything after
     it was scriptable: `CREATE APPLICATION ... FROM LISTING <ULL>` succeeded, the app installed, and
     the pipeline ran. Snowsight shows *"Getting App Ready — this will take at least 10 minutes"*.

  Practical guidance: the Get is **per region, not per version** — once a region is warm, later
  versions and patches auto-refresh with no further clicks, so a persistent cross-region test consumer
  needs exactly one manual Get ever. Prefer a same-region consumer account when the point is to test
  the app rather than the distribution path. If you must stay cross-region and cannot pre-warm, the
  click is drivable with Playwright/browser automation.
- **Image immutability**: model changes require a new app version, so dbt updates flow through the app
  release channel rather than being deployed independently.
- Raw source data is seeded inside the app **by default** so the POC is self-contained, but the
  production shape is implemented and tested — see
  [Reading the consumer's own tables](#reading-the-consumers-own-tables-object-references).
  `core.use_consumer_source()` switches the pipeline to `reference('consumer_orders')`.
- The macros here are a deliberately simple stand-in for real domain logic. Snapshots, custom
  materializations, and hooks were not exercised.

## Repository Owner

- **Owner:** John Kang (john.kang@snowflake.com / [@sfc-gh-jkang](https://github.com/sfc-gh-jkang))
- **Access requests:** Email the owner, or open an issue
- **License:** Apache-2.0

This is a personal proof-of-concept, not a Snowflake product or an officially supported reference
architecture. Behaviour of preview features may change.
