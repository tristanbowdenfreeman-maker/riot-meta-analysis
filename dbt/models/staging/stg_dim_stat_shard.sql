select * from {{ source('riot_dim', 'stat_shard') }}
