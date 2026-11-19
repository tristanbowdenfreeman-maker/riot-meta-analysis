{# Fails on any value outside [min_value, max_value]. NULLs pass (not_null covers those). #}
{% test between(model, column_name, min_value, max_value) %}
select {{ column_name }}
from {{ model }}
where {{ column_name }} < {{ min_value }} or {{ column_name }} > {{ max_value }}
{% endtest %}
