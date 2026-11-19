{# Every model goes in the profile's dataset (riot_mart) as it is, with no target prefix. #}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {{ custom_schema_name | trim if custom_schema_name else target.schema }}
{%- endmacro %}
