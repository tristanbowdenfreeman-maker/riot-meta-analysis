select * from {{ source('riot_fact', 'match_ban') }}
