#!/usr/bin/env python3
"""
Generate a realistic ~500-model dbt DAG for the scale / token-lifetime test.

Mirrors the the ISV shape: 3 layers, macro-heavy, ref() chained.
  refinement (view)      -> reads raw.orders_source (app-owned view: seeded table or reference())
  reporting  (incremental) -> refs refinement
  release    (view)      -> refs reporting

Files are written as scale_*.sql alongside the hand-written demo models so a
plain `dbt run` exercises the whole graph. Use --clean to remove them.

Usage:
  python3 scripts/generate_models.py --refinement 150 --reporting 200 --release 150
  python3 scripts/generate_models.py --clean
"""
import argparse
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent / "container" / "dbt_project" / "models"
LAYERS = ("refinement", "reporting", "release")

REFINEMENT = """{{{{ config(materialized='view') }}}}
-- generated scale model {idx}
select
    order_id,
    upper(trim(region))                                             as region,
    amount,
    received_at,
    stocked_at,
    promised_at,
    delivered_at,
    {{{{ wms_dock_to_stock_hours('received_at', 'stocked_at') }}}} as dock_to_stock_hours,
    {idx} as bucket_id
from {{{{ source('raw', 'orders_source') }}}}
where order_id is not null
"""

REPORTING = """{{{{
  config(
    materialized='incremental',
    unique_key='row_key',
    incremental_strategy='merge'
  )
}}}}
-- generated scale model {idx}
select
    order_id || '-' || {idx}                          as row_key,
    order_id,
    region,
    amount,
    received_at,
    dock_to_stock_hours,
    {{{{ wms_margin_index('amount', 'region') }}}} as margin_index,
    {{{{ wms_otif_flag('promised_at', 'delivered_at') }}}} as otif_flag,
    current_timestamp()                              as _loaded_at
from {{{{ ref('{parent}') }}}}
{{% if is_incremental() %}}
  where received_at >= (select coalesce(max(received_at), '1900-01-01'::timestamp) from {{{{ this }}}}) - interval '3 days'
{{% endif %}}
"""

RELEASE = """{{{{ config(materialized='view') }}}}
-- generated scale model {idx}
select
    region,
    count(*)                    as order_count,
    round(sum(amount), 2)       as gross_amount,
    round(sum(margin_index), 2) as margin_index_total,
    round(100.0 * sum(otif_flag) / nullif(count(*), 0), 1) as otif_pct
from {{{{ ref('{parent}') }}}}
group by region
"""


def clean() -> int:
    n = 0
    for layer in LAYERS:
        for f in (ROOT / layer).glob("scale_*.sql"):
            f.unlink()
            n += 1
    return n


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--refinement", type=int, default=150)
    p.add_argument("--reporting", type=int, default=200)
    p.add_argument("--release", type=int, default=150)
    p.add_argument("--clean", action="store_true")
    a = p.parse_args()

    if a.clean:
        print(f"removed {clean()} generated models")
        return 0

    clean()
    for layer in LAYERS:
        (ROOT / layer).mkdir(parents=True, exist_ok=True)

    for i in range(a.refinement):
        (ROOT / "refinement" / f"scale_stg_{i:04d}.sql").write_text(
            REFINEMENT.format(idx=i)
        )

    for i in range(a.reporting):
        parent = f"scale_stg_{i % max(a.refinement, 1):04d}"
        (ROOT / "reporting" / f"scale_int_{i:04d}.sql").write_text(
            REPORTING.format(idx=i, parent=parent)
        )

    for i in range(a.release):
        parent = f"scale_int_{i % max(a.reporting, 1):04d}"
        (ROOT / "release" / f"scale_r5_{i:04d}.sql").write_text(
            RELEASE.format(idx=i, parent=parent)
        )

    total = a.refinement + a.reporting + a.release
    print(f"generated {total} models "
          f"({a.refinement} refinement / {a.reporting} reporting / {a.release} release)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
