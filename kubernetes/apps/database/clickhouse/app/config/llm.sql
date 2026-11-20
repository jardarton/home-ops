-- Applied on every start; keep statements idempotent.
CREATE DATABASE IF NOT EXISTS llm;

-- Each request message once, keyed by the first 16 bytes of the SHA-256 of
-- its exact bytes. Agents resend the whole conversation on every request, so
-- exchanges reference messages here instead of repeating them. The plugin may
-- send a message again after a restart; merges collapse the copies.
CREATE TABLE IF NOT EXISTS llm.messages
(
    id UUID,
    first_seen DateTime64(3, 'UTC'),
    body String CODEC(ZSTD(3))
)
ENGINE = ReplacingMergeTree
ORDER BY id;

-- One row per model execution captured by the cli-proxy-api capture plugin.
-- When request_messages_at > 0, request is the body with its message array
-- removed at that byte offset, and request_messages lists the array's
-- messages; llm.request rebuilds the body. Otherwise request is the
-- whole body. Sorting by session keeps a session's requests adjacent, and
-- request bodies use 64 MiB compression blocks so ZSTD finds what repeats
-- between them (tools, system prompt). Other columns keep the default block
-- size, since every column buffers a full block during merges.
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
    request_messages_at UInt32,
    request_messages Array(UUID),
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
ALTER TABLE llm.exchanges ADD COLUMN IF NOT EXISTS request_messages_at UInt32 AFTER request;
ALTER TABLE llm.exchanges ADD COLUMN IF NOT EXISTS request_messages Array(UUID) AFTER request_messages_at;

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

-- One exchange with its request body rebuilt from llm.messages:
--   SELECT request FROM llm.request(id = '<request_id>')
CREATE OR REPLACE VIEW llm.request AS
WITH
    ex AS (
        SELECT request_id, session_id, started_at, model, outcome,
            request, request_messages_at, request_messages, response
        FROM llm.exchanges
        WHERE request_id = {id:String}
        LIMIT 1
    ),
    parts AS (
        SELECT n, id
        FROM ex
        ARRAY JOIN request_messages AS id, arrayEnumerate(request_messages) AS n
    ),
    messages AS (
        SELECT arrayStringConcat(arrayMap(x -> x.2, arraySort(groupArray((p.n, b.body)))), ',') AS joined
        FROM parts AS p
        INNER JOIN
        (
            SELECT id, any(body) AS body
            FROM llm.messages
            WHERE id IN (SELECT id FROM parts)
            GROUP BY id
        ) AS b ON p.id = b.id
    )
SELECT
    request_id, session_id, started_at, model, outcome,
    if(request_messages_at = 0, request,
        concat(substring(request, 1, request_messages_at), '[', joined, ']',
            substring(request, request_messages_at + 1))) AS request,
    response
FROM ex CROSS JOIN messages;

-- A session's last successful exchange, whose request carries the whole
-- conversation so far: SELECT request, response FROM llm.transcript(session = '<session_id>')
CREATE OR REPLACE VIEW llm.transcript AS
WITH
    ex AS (
        SELECT request_id, session_id, started_at, model, outcome,
            request, request_messages_at, request_messages, response
        FROM llm.exchanges
        WHERE session_id = {session:String} AND outcome = 'succeeded'
        ORDER BY started_at DESC
        LIMIT 1
    ),
    parts AS (
        SELECT n, id
        FROM ex
        ARRAY JOIN request_messages AS id, arrayEnumerate(request_messages) AS n
    ),
    messages AS (
        SELECT arrayStringConcat(arrayMap(x -> x.2, arraySort(groupArray((p.n, b.body)))), ',') AS joined
        FROM parts AS p
        INNER JOIN
        (
            SELECT id, any(body) AS body
            FROM llm.messages
            WHERE id IN (SELECT id FROM parts)
            GROUP BY id
        ) AS b ON p.id = b.id
    )
SELECT
    request_id, session_id, started_at, model, outcome,
    if(request_messages_at = 0, request,
        concat(substring(request, 1, request_messages_at), '[', joined, ']',
            substring(request, request_messages_at + 1))) AS request,
    response
FROM ex CROSS JOIN messages;

-- One row per session; llm.transcript returns the conversation.
CREATE OR REPLACE VIEW llm.transcripts AS
SELECT
    session_id,
    min(started_at) AS first_at,
    max(started_at) AS last_at,
    count() AS exchanges,
    argMax(model, started_at) AS model
FROM llm.exchanges
WHERE session_id != '' AND outcome = 'succeeded'
GROUP BY session_id;
