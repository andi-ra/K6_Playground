local cjson = require("cjson.safe")
local http = require("resty.http")
local redis = require("resty.redis")

local metrics = require("myedge.metrics")

local M = {}

local function getenv_number(name, default)
    local raw = os.getenv(name)
    local numeric = tonumber(raw)
    if numeric == nil then
        return default
    end
    return numeric
end

local REDIS_HOST = os.getenv("REDIS_HOST") or "redis"
local REDIS_PORT = getenv_number("REDIS_PORT", 6379)
local REDIS_CONNECT_TIMEOUT_MS = getenv_number("REDIS_CONNECT_TIMEOUT_MS", 150)
local REDIS_SEND_TIMEOUT_MS = getenv_number("REDIS_SEND_TIMEOUT_MS", 150)
local REDIS_READ_TIMEOUT_MS = getenv_number("REDIS_READ_TIMEOUT_MS", 250)
local REDIS_KEEPALIVE_TIMEOUT_MS = getenv_number("REDIS_KEEPALIVE_TIMEOUT_MS", 60000)
local REDIS_KEEPALIVE_POOL = getenv_number("REDIS_KEEPALIVE_POOL", 100)
local METADATA_BASE_URL = os.getenv("METADATA_BASE_URL") or "http://metadata:9100"
local METADATA_TIMEOUT_MS = getenv_number("METADATA_TIMEOUT_MS", 200)
local KAFKA_MOCK_URL = os.getenv("KAFKA_MOCK_URL") or "http://kafka-mock:9300/events"
local KAFKA_MOCK_TIMEOUT_MS = getenv_number("KAFKA_MOCK_TIMEOUT_MS", 250)

local function now()
    ngx.update_time()
    return ngx.now()
end

local function base_labels(trace)
    return {
        route_family = trace.route_family or "unknown",
        target_kind = trace.target_kind or "unknown",
    }
end

local function merge_labels(trace, extra)
    local labels = base_labels(trace)
    if extra ~= nil then
        for key, value in pairs(extra) do
            labels[key] = value
        end
    end
    return labels
end

local function record_metadata(trace, duration_seconds, outcome)
    metrics.increment(
        "openresty_edge_metadata_requests_total",
        merge_labels(trace, { outcome = outcome }),
        1
    )
    metrics.observe(
        "openresty_edge_metadata_duration_seconds",
        merge_labels(trace, { outcome = outcome }),
        duration_seconds
    )
end

local function record_redis_connect(trace, phase, outcome, duration_seconds)
    metrics.increment(
        "openresty_edge_redis_operations_total",
        merge_labels(trace, {
            phase = phase,
            operation = "connect",
            outcome = outcome,
        }),
        1
    )
    metrics.observe(
        "openresty_edge_redis_connect_duration_seconds",
        merge_labels(trace, {
            phase = phase,
            outcome = outcome,
        }),
        duration_seconds
    )
end

local function record_redis_command(trace, phase, operation, outcome, duration_seconds)
    metrics.increment(
        "openresty_edge_redis_operations_total",
        merge_labels(trace, {
            phase = phase,
            operation = operation,
            outcome = outcome,
        }),
        1
    )
    metrics.observe(
        "openresty_edge_redis_command_duration_seconds",
        merge_labels(trace, {
            phase = phase,
            operation = operation,
            outcome = outcome,
        }),
        duration_seconds
    )
end

local function record_kafka(trace, outcome, duration_seconds)
    metrics.increment(
        "openresty_edge_kafka_mock_events_total",
        merge_labels(trace, { outcome = outcome }),
        1
    )
    metrics.observe(
        "openresty_edge_kafka_mock_publish_duration_seconds",
        merge_labels(trace, { outcome = outcome }),
        duration_seconds
    )
end

function M.fetch_metadata(trace, args, policy)
    if trace.route_family ~= "openresty" then
        return nil
    end

    local started_at = now()
    local httpc = http.new()
    httpc:set_timeout(METADATA_TIMEOUT_MS)

    local query_string = ngx.encode_args({
        tenant = args.tenant or policy.tenant or "demo",
        title = args.title or policy.title or trace.target_kind,
        variant = args.variant or policy.variant or "720p",
        region = args.region or policy.region or "us",
        target_kind = trace.target_kind,
    })

    local response, err = httpc:request_uri(
        METADATA_BASE_URL .. "/metadata?" .. query_string,
        {
            method = "GET",
            headers = {
                ["X-OpenResty-Route-Family"] = trace.route_family,
                ["X-OpenResty-Target-Kind"] = trace.target_kind,
            },
            keepalive_timeout = 60000,
            keepalive_pool = 20,
        }
    )
    local duration_seconds = now() - started_at

    if response == nil then
        ngx.log(ngx.ERR, "metadata fetch failed for ", trace.target_kind or "unknown", ": ", err or "unknown")
        record_metadata(trace, duration_seconds, "error")
        return {
            outcome = "error",
            error = err,
            duration_seconds = duration_seconds,
            source = "metadata_error",
        }
    end

    local decoded = cjson.decode(response.body or "{}") or {}
    local outcome = response.status == 200 and "success" or "error"
    if outcome ~= "success" then
        ngx.log(ngx.ERR, "metadata fetch returned status ", response.status, " for ", trace.target_kind or "unknown")
    end
    record_metadata(trace, duration_seconds, outcome)

    return {
        outcome = outcome,
        status = response.status,
        duration_seconds = duration_seconds,
        body = decoded,
        source = decoded.source or "metadata_service",
    }
end

function M.redis_roundtrip(trace, phase, payload)
    if trace.route_family ~= "openresty" then
        return nil
    end

    local red = redis:new()
    red:set_timeouts(REDIS_CONNECT_TIMEOUT_MS, REDIS_SEND_TIMEOUT_MS, REDIS_READ_TIMEOUT_MS)

    local connect_started_at = now()
    local ok, connect_err = red:connect(REDIS_HOST, REDIS_PORT)
    local connect_duration_seconds = now() - connect_started_at
    local connect_outcome = ok and "success" or "error"
    record_redis_connect(trace, phase, connect_outcome, connect_duration_seconds)

    if not ok then
        ngx.log(ngx.ERR, "redis connect failed in phase ", phase, " for ", trace.target_kind or "unknown", ": ", connect_err or "unknown")
        return {
            phase = phase,
            connect_duration_seconds = connect_duration_seconds,
            command_duration_seconds = 0,
            outcome = "connect_error",
            error = connect_err,
        }
    end

    local aggregate_command_seconds = 0
    local state_key = table.concat({
        "openresty",
        payload.tenant or "demo",
        payload.title or trace.target_kind,
        payload.variant or "720p",
        phase,
    }, ":")

    local function run(operation, fn)
        local started_at = now()
        local result, err = fn()
        local duration_seconds = now() - started_at
        aggregate_command_seconds = aggregate_command_seconds + duration_seconds
        local outcome = err and "error" or "success"
        if err ~= nil then
            ngx.log(ngx.ERR, "redis ", operation, " failed in phase ", phase, " for ", trace.target_kind or "unknown", ": ", err)
        end
        record_redis_command(trace, phase, operation, outcome, duration_seconds)
        return result, err
    end

    local last_error = nil
    local responses = {}

    local result, err = run("ping", function()
        return red:ping()
    end)
    responses.ping = result
    if err ~= nil then
        last_error = err
    end

    result, err = run("incr", function()
        return red:incr(state_key .. ":count")
    end)
    responses.counter = result
    if err ~= nil then
        last_error = err
    end

    result, err = run("hmset", function()
        return red:hmset(
            state_key .. ":hash",
            "decision", payload.decision or "allow",
            "tenant", payload.tenant or "demo",
            "title", payload.title or trace.target_kind,
            "variant", payload.variant or "720p",
            "metadata_source", payload.metadata_source or "none"
        )
    end)
    responses.hmset = result
    if err ~= nil then
        last_error = err
    end

    result, err = run("hgetall", function()
        return red:hgetall(state_key .. ":hash")
    end)
    responses.hgetall = result
    if err ~= nil then
        last_error = err
    end

    red:set_keepalive(REDIS_KEEPALIVE_TIMEOUT_MS, REDIS_KEEPALIVE_POOL)

    return {
        phase = phase,
        connect_duration_seconds = connect_duration_seconds,
        command_duration_seconds = aggregate_command_seconds,
        outcome = last_error == nil and "success" or "error",
        error = last_error,
        responses = responses,
    }
end

function M.schedule_header_filter_redis(trace)
    if trace == nil or trace.route_family ~= "openresty" then
        return
    end

    local snapshot = {
        route_family = trace.route_family,
        target_kind = trace.target_kind,
        tenant = trace.policy_tenant,
        title = trace.policy_title,
        variant = trace.policy_variant,
        decision = trace.policy_decision,
        metadata_source = trace.metadata_source,
    }

    local ok, err = ngx.timer.at(0, function(premature, data)
        if premature then
            return
        end
        M.redis_roundtrip(data, "header_filter_timer", data)
    end, snapshot)

    if not ok then
        ngx.log(ngx.ERR, "failed to schedule header-filter redis probe: ", err or "unknown")
    end
end

function M.schedule_kafka_publish(trace, event)
    if trace == nil or trace.route_family ~= "openresty" then
        return
    end

    local snapshot = {
        route_family = trace.route_family,
        target_kind = trace.target_kind,
    }

    local ok, err = ngx.timer.at(0, function(premature, labels, payload)
        if premature then
            return
        end

        local httpc = http.new()
        httpc:set_timeout(KAFKA_MOCK_TIMEOUT_MS)
        local started_at = now()
        local response, publish_err = httpc:request_uri(
            KAFKA_MOCK_URL,
            {
                method = "POST",
                body = cjson.encode(payload),
                headers = {
                    ["Content-Type"] = "application/json",
                },
                keepalive_timeout = 60000,
                keepalive_pool = 20,
            }
        )
        local duration_seconds = now() - started_at
        local outcome = response ~= nil and response.status < 500 and "success" or "error"

        if response == nil then
            ngx.log(ngx.ERR, "failed to publish kafka-mock event: ", publish_err or "unknown")
        elseif response.status >= 500 then
            ngx.log(ngx.ERR, "kafka-mock returned status ", response.status)
        end

        record_kafka(labels, outcome, duration_seconds)
    end, snapshot, event)

    if not ok then
        ngx.log(ngx.ERR, "failed to schedule kafka-mock publish: ", err or "unknown")
    end
end

return M
