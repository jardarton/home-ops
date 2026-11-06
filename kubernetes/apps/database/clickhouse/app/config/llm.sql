-- Applied on every start; keep statements idempotent.
CREATE DATABASE IF NOT EXISTS llm;

-- One row per model execution captured by the cli-proxy-api capture plugin.
-- Sorting by session keeps a session's requests adjacent. Each repeats the
-- conversation so far, so request bodies use 64 MiB compression blocks: ZSTD
-- finds the repetition only within a block. Other columns keep the default
-- block size, since every column buffers a full block during merges.
CREATE TABLE IF NOT EXISTS llm.exchanges
(
    request_id String,
    trace_id String,
    started_at DateTime64(3, 'UTC'),
    completed_at DateTime64(3, 'UTC'),
    duration_ms UInt64 MATERIALIZED toUInt64(greatest(0, dateDiff('millisecond', started_at, completed_at))),
    session_id String,
    parent_session_id String,
    client_type LowCardinality(String),
    agent_name LowCardinality(String),
    node_kind LowCardinality(String),
    is_subagent Bool,
    is_fork Bool,
    is_compaction Bool,
    source_format LowCardinality(String),
    to_format LowCardinality(String),
    requested_model LowCardinality(String),
    model LowCardinality(String),
    stream Bool,
    outcome LowCardinality(String),
    status_code UInt16,
    error String,
    user_agent LowCardinality(String),
    request_headers Map(LowCardinality(String), String),
    response_headers Map(LowCardinality(String), String),
    request String CODEC(ZSTD(9)) SETTINGS (min_compress_block_size = 67108864, max_compress_block_size = 67108864),
    upstream_request String CODEC(ZSTD(9)) SETTINGS (min_compress_block_size = 67108864, max_compress_block_size = 67108864),
    response String CODEC(ZSTD(3)),
    response_raw String CODEC(ZSTD(3)),
    assembled Bool,
    truncated Bool,
    plugin_version LowCardinality(String)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(started_at)
ORDER BY (session_id, started_at)
-- A merge holds up to a block of request data per part it reads.
SETTINGS max_parts_to_merge_at_once = 4;

-- Bring a table created with older settings up to date. These change metadata
-- only; existing parts are recompressed as they merge.
ALTER TABLE llm.exchanges
    MODIFY COLUMN request String CODEC(ZSTD(9)) SETTINGS (min_compress_block_size = 67108864, max_compress_block_size = 67108864);
ALTER TABLE llm.exchanges
    MODIFY COLUMN upstream_request String CODEC(ZSTD(9)) SETTINGS (min_compress_block_size = 67108864, max_compress_block_size = 67108864);
ALTER TABLE llm.exchanges RESET SETTING max_compress_block_size;
ALTER TABLE llm.exchanges MODIFY SETTING max_parts_to_merge_at_once = 4;

-- One row per upstream call (retries included). Joins exchanges on trace_id.
CREATE TABLE IF NOT EXISTS llm.usage
(
    timestamp DateTime64(3, 'UTC'),
    request_id String,
    trace_id String,
    session_id String,
    parent_session_id String,
    provider LowCardinality(String),
    executor_type LowCardinality(String),
    model LowCardinality(String),
    alias LowCardinality(String),
    response_model LowCardinality(String),
    principal LowCardinality(String),
    access_provider LowCardinality(String),
    auth_id LowCardinality(String),
    auth_index LowCardinality(String),
    auth_type LowCardinality(String),
    source LowCardinality(String),
    reasoning_effort LowCardinality(String),
    service_tier LowCardinality(String),
    response_service_tier LowCardinality(String),
    generate Bool,
    stream Bool,
    latency_ms UInt32,
    ttft_ms UInt32,
    failed Bool,
    fail_status UInt16,
    fail_body String,
    input_tokens UInt64,
    output_tokens UInt64,
    reasoning_tokens UInt64,
    cached_tokens UInt64,
    cache_read_tokens UInt64,
    cache_creation_tokens UInt64,
    total_tokens UInt64
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp, session_id);

CREATE VIEW IF NOT EXISTS llm.session_stats AS
SELECT
    session_id,
    min(timestamp) AS first_at,
    max(timestamp) AS last_at,
    uniqExact(trace_id) AS requests,
    count() AS upstream_calls,
    countIf(failed) AS failed_calls,
    groupUniqArray(model) AS models,
    groupUniqArray(principal) AS principals,
    sum(input_tokens) AS input_tokens,
    sum(output_tokens) AS output_tokens,
    sum(reasoning_tokens) AS reasoning_tokens,
    sum(cache_read_tokens) AS cache_read_tokens,
    sum(cache_creation_tokens) AS cache_creation_tokens,
    sum(total_tokens) AS total_tokens
FROM llm.usage
WHERE session_id != ''
GROUP BY session_id;

-- The last request of a session carries its whole conversation so far.
CREATE VIEW IF NOT EXISTS llm.transcripts AS
SELECT
    session_id,
    min(started_at) AS first_at,
    max(started_at) AS last_at,
    count() AS exchanges,
    argMax(model, started_at) AS model,
    argMax(request, started_at) AS last_request,
    argMax(response, started_at) AS last_response
FROM llm.exchanges
WHERE session_id != '' AND outcome = 'succeeded'
GROUP BY session_id;
