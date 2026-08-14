{{ config(materialized='view') }}

-- RELEASE (R5) layer. This is the ONLY layer granted to the consumer.
-- Power BI would point here. Shape and data are visible by design;
-- the derivation above it is not.

select
    region,
    count(*)                                as order_count,
    round(sum(amount), 2)                   as gross_amount,
    round(sum(margin_index), 2)             as margin_index_total,
    round(avg(dock_to_stock_hours), 2)      as avg_dock_to_stock_hours,
    round(100.0 * sum(otif_flag) / nullif(count(*), 0), 1) as otif_pct
from {{ ref('int_order_margin') }}
group by region
