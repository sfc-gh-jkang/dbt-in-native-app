{{ config(materialized='view') }}

-- REFINEMENT layer. Normalises the raw WMS feed.
-- Deliberately NOT granted to any application role.

select
    order_id,
    upper(trim(region))                                             as region,
    amount,
    received_at,
    stocked_at,
    promised_at,
    delivered_at,
    {{ wms_dock_to_stock_hours('received_at', 'stocked_at') }} as dock_to_stock_hours
from {{ source('raw', 'orders_source') }}
where order_id is not null
