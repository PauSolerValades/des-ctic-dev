# Dataset Creation

## General Metrics (per simulation )
To analyze data we can have several sub datasets. What we need post wise is
- run_id (pk)
- post_id (pk)
- author_id
- total_reposts
- total_likes
- conversion_rate: (likes + reposts) / interactions
- average_active_users
- boredom_ended_sessions
- check whatever are we computing irl in the simulation

## Root Lifetime Post Analysis
About just lifetime analysis we have to create all the lifetime actual gaps.
- run_id (pk)
- post_id (pk)
- parent_id (pk): where the post came from
- repost_timestamp: when the repost came.
- global_gap: t[n] - t[n-1]
- topology_gap: parent_timestamp - this post repost

## Real Lifetime Dataset 
This are the important metrics per posts to check out.

From this dataset we will obtain all the following lifetime data:
- run_id
- post_id
- T_50
- T_95
- T_99
- time_to_peak: how much time passes from the most reposted time
- author_degree (useful to have here)

## Cascade Dataset
About cascade general metrics we can measure the following:
- run_id
- post_id
- cascade_depth
- cascade_size (cardinal)
- max_out_degree:
- structural_virality


## Sessions Dataset
- run_id
- user_id
- start_time
- end_time
- %_time_online
- average_session_duration
- boredom_ended_session
- out_degree
- total_actions
- total_likes
- total_reposts
- total_creation
- num_session
- ended_by_boredom

We have to use the cascades raw data to create a cascade dataset in a parquet file. Every row will be a cascade, and will have the following features.

