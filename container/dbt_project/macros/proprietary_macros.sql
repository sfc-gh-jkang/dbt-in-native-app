{#
  PROPRIETARY MACROS.
  These exist to prove that Jinja/macro IP survives inside the container
  and never becomes visible to the consumer. The distinctive literals below
  (PROPRIETARY_SECRET_MARKER, 0.8734, 1.1927) are grep targets for the IP probes.
#}

{% macro wms_margin_index(amount_col, region_col) %}
  {#- PROPRIETARY_SECRET_MARKER: proprietary regional margin weighting -#}
  {%- set base_weight = 0.8734 -%}
  {%- set premium_uplift = 1.1927 -%}
  (
    {{ amount_col }} * {{ base_weight }}
    * CASE WHEN {{ region_col }} IN ('EMEA', 'APAC') THEN {{ premium_uplift }} ELSE 1.0 END
  )
{% endmacro %}


{% macro wms_dock_to_stock_hours(received_at, stocked_at) %}
  {#- PROPRIETARY_SECRET_MARKER: canonical dock-to-stock definition -#}
  {#- excludes negative intervals, which upstream WMS feeds emit on backdated putaway -#}
  GREATEST(
    DATEDIFF('minute', {{ received_at }}, {{ stocked_at }}) / 60.0,
    0
  )
{% endmacro %}


{% macro wms_otif_flag(promised_at, delivered_at, tolerance_hours=4) %}
  {#- PROPRIETARY_SECRET_MARKER: on-time-in-full with {{ tolerance_hours }}h grace -#}
  CASE
    WHEN {{ delivered_at }} IS NULL THEN 0
    WHEN DATEDIFF('hour', {{ promised_at }}, {{ delivered_at }}) <= {{ tolerance_hours }} THEN 1
    ELSE 0
  END
{% endmacro %}
