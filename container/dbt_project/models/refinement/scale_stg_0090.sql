{{ config(materialized='view') }}
-- generated scale model 90
select
    order_id,
    upper(trim(region))                                             as region,
    amount,
    received_at,
    stocked_at,
    promised_at,
    delivered_at,
    {{ wms_dock_to_stock_hours('received_at', 'stocked_at') }} as dock_to_stock_hours,
    90 as bucket_id
from {{ source('raw', 'orders_source') }}
where order_id is not null
