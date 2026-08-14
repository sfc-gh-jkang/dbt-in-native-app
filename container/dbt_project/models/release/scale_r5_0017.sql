{{ config(materialized='view') }}
-- generated scale model 17
select
    region,
    count(*)                    as order_count,
    round(sum(amount), 2)       as gross_amount,
    round(sum(margin_index), 2) as margin_index_total,
    round(100.0 * sum(otif_flag) / nullif(count(*), 0), 1) as otif_pct
from {{ ref('scale_int_0017') }}
group by region
