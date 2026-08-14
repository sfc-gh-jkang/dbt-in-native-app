{{
  config(
    materialized='incremental',
    unique_key='order_id',
    incremental_strategy='merge'
  )
}}

-- REPORTING layer. Incremental, exercises is_incremental() so the POC proves
-- dbt runtime branching works in-container. NOT granted to any application role.

select
    order_id,
    region,
    amount,
    received_at,          -- the incremental watermark; must be projected to be comparable
    dock_to_stock_hours,
    promised_at,
    delivered_at,
    {{ wms_margin_index('amount', 'region') }} as margin_index,
    {{ wms_otif_flag('promised_at', 'delivered_at') }} as otif_flag,
    current_timestamp()                              as _loaded_at
from {{ ref('stg_orders') }}

{% if is_incremental() %}
  -- LOOKBACK WINDOW, not a bare high-watermark. A strict '>' silently drops
  -- (a) late arrivals -- rows inserted now with an older received_at -- and
  -- (b) restatements -- corrections to rows already loaded. Both were measured
  -- being dropped. Re-scanning a trailing window and MERGEing on unique_key
  -- makes the run idempotent and catches both, at the cost of re-reading that
  -- window every run.
  -- LIMITATION: a restatement OLDER than the window is still missed. If the
  -- source can be corrected arbitrarily far back, you need an updated_at /
  -- CDC column and should filter on that instead of received_at.
  where received_at >= (select coalesce(max(received_at), '1900-01-01'::timestamp)
                        from {{ this }}) - interval '{{ var("lookback_days", 3) }} days'
{% endif %}
