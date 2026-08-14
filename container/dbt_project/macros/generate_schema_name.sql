{#
  Force literal custom schema names (REFINEMENT / REPORTING / RELEASE) instead of
  dbt's default "<target_schema>_<custom>" concatenation. This keeps the app's
  internal layout clean so the setup script can grant on RELEASE only.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim | upper }}
    {%- endif -%}
{%- endmacro %}
