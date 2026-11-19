select * from {{ source('riot_fact', 'participant_frame') }}
