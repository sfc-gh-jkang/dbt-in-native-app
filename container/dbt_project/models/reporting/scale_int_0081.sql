{{
  config(
    materialized='incremental',
    unique_key='row_key',
    incremental_strategy='merge'
  )
}}
-- generated scale model 81
select
    order_id || '-' || 81                          as row_key,
    order_id,
    region,
    amount,
    received_at,
    dock_to_stock_hours,
    {{ wms_margin_index('amount', 'region') }} as margin_index,
    {{ wms_otif_flag('promised_at', 'delivered_at') }} as otif_flag,
    current_timestamp()                              as _loaded_at
from {{ ref('scale_stg_0081') }}
{% if is_incremental() %}
  where received_at >= (select coalesce(max(received_at), '1900-01-01'::timestamp) from {{ this }}) - interval '3 days'
{% endif %}
