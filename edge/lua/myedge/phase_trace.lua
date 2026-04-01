local classify = require("myedge.classify")
local external_io = require("myedge.external_io")
local gc_probe = require("myedge.gc_probe")
local metrics = require("myedge.metrics")

local M = {}

local function parse_upstream_response_time(raw_value)
    if raw_value == nil or raw_value == "" or raw_value == "-" then
        return nil
    end

    local total = 0
    local saw_value = false
    for token in tostring(raw_value):gmatch("[^,%s]+") do
        local numeric = tonumber(token)
        if numeric ~= nil then
            total = total + numeric
            saw_value = true
        end
    end

    if not saw_value then
        return nil
    end

    return total
end

function M.begin()
    local request = classify.request()
    local args = ngx.req.get_uri_args()
    local sample = gc_probe.capture(function()
        local policy = classify.build_policy_context(request, args)
        local trace = {
            route_family = request.route_family,
            target_kind = request.target_kind,
            traffic_class = request.traffic_class,
            method = request.method,
            track = request.track,
        }
        local metadata = external_io.fetch_metadata(trace, args, policy)
        local redis_sample = external_io.redis_roundtrip(trace, "access", {
            tenant = policy.tenant,
            title = policy.title,
            variant = policy.variant,
            decision = policy.decision,
            metadata_source = metadata and metadata.source or "none",
        })

        return {
            policy = policy,
            metadata = metadata,
            redis_sample = redis_sample,
        }
    end)
    local result = sample.results[1]
    local policy = result.policy
    local metadata = result.metadata
    local redis_sample = result.redis_sample

    ngx.ctx.edge_trace = {
        request_started_at = ngx.req.start_time(),
        route_family = request.route_family,
        target_kind = request.target_kind,
        traffic_class = request.traffic_class,
        method = request.method,
        track = request.track,
        policy_decision = policy.decision,
        policy_source = policy.source,
        policy_tenant = policy.tenant,
        policy_title = policy.title,
        policy_variant = policy.variant,
        metadata_outcome = metadata and metadata.outcome or nil,
        metadata_source = metadata and metadata.source or "none",
        metadata_error = metadata and metadata.error or nil,
        metadata_fetch_duration_seconds = metadata and metadata.duration_seconds or nil,
        metadata_id = metadata and metadata.body and metadata.body.metadata_id or nil,
        access_duration_seconds = sample.duration_seconds,
        access_gc_before_kb = sample.before_kb,
        access_gc_after_kb = sample.after_kb,
        access_gc_delta_kb = sample.delta_kb,
        redis_access_outcome = redis_sample and redis_sample.outcome or nil,
        redis_access_error = redis_sample and redis_sample.error or nil,
        redis_access_connect_seconds = redis_sample and redis_sample.connect_duration_seconds or nil,
        redis_access_command_seconds = redis_sample and redis_sample.command_duration_seconds or nil,
    }
end

function M.apply_response_headers()
    local trace = ngx.ctx.edge_trace
    if not trace then
        return
    end

    ngx.update_time()
    local header_started_at = ngx.now()
    ngx.header["X-OpenResty-Route-Family"] = trace.route_family
    ngx.header["X-OpenResty-Target-Kind"] = trace.target_kind

    if ngx.header["X-Traffic-Class"] == nil then
        ngx.header["X-Traffic-Class"] = trace.traffic_class
    end

    if trace.access_duration_seconds ~= nil then
        ngx.header["X-OpenResty-Lua-Access-Ms"] = string.format("%.3f", trace.access_duration_seconds * 1000.0)
    end

    if trace.content_duration_seconds ~= nil then
        ngx.header["X-OpenResty-Lua-Content-Ms"] = string.format("%.3f", trace.content_duration_seconds * 1000.0)
    end

    if trace.metadata_fetch_duration_seconds ~= nil then
        ngx.header["X-OpenResty-Metadata-Outcome"] = trace.metadata_outcome
        ngx.header["X-OpenResty-Metadata-Fetch-Ms"] = string.format("%.3f", trace.metadata_fetch_duration_seconds * 1000.0)
    end

    if trace.redis_access_outcome ~= nil then
        ngx.header["X-OpenResty-Redis-Access-Outcome"] = trace.redis_access_outcome
    end

    if trace.redis_access_error ~= nil then
        ngx.header["X-OpenResty-Redis-Access-Error"] = trace.redis_access_error
    end

    if trace.redis_access_connect_seconds ~= nil then
        ngx.header["X-OpenResty-Redis-Access-Connect-Ms"] = string.format("%.3f", trace.redis_access_connect_seconds * 1000.0)
    end

    if trace.redis_access_command_seconds ~= nil then
        ngx.header["X-OpenResty-Redis-Access-Command-Ms"] = string.format("%.3f", trace.redis_access_command_seconds * 1000.0)
    end

    if trace.redis_content_connect_seconds ~= nil then
        ngx.header["X-OpenResty-Redis-Content-Outcome"] = trace.redis_content_outcome
        ngx.header["X-OpenResty-Redis-Content-Connect-Ms"] = string.format("%.3f", trace.redis_content_connect_seconds * 1000.0)
    end

    if trace.redis_content_command_seconds ~= nil then
        ngx.header["X-OpenResty-Redis-Content-Command-Ms"] = string.format("%.3f", trace.redis_content_command_seconds * 1000.0)
    end

    if trace.redis_content_error ~= nil then
        ngx.header["X-OpenResty-Redis-Content-Error"] = trace.redis_content_error
    end

    local gc_delta = trace.content_gc_delta_kb or trace.access_gc_delta_kb
    if gc_delta ~= nil then
        ngx.header["X-OpenResty-Lua-GC-Delta-Kb"] = string.format("%.3f", gc_delta)
    end

    external_io.schedule_header_filter_redis(trace)
    ngx.update_time()
    trace.header_filter_duration_seconds = ngx.now() - header_started_at
    ngx.header["X-OpenResty-Header-Filter-Ms"] = string.format("%.3f", trace.header_filter_duration_seconds * 1000.0)
end

function M.finish()
    local trace = ngx.ctx.edge_trace
    metrics.set_gauge("openresty_edge_lua_heap_kb", { worker = tostring(ngx.worker.id()) }, collectgarbage("count"))

    if not trace or not trace.track then
        return
    end

    local labels = {
        route_family = trace.route_family,
        target_kind = trace.target_kind,
    }

    ngx.update_time()
    local log_started_at = ngx.now()
    metrics.increment("openresty_edge_requests_total", {
        route_family = trace.route_family,
        target_kind = trace.target_kind,
        method = trace.method,
    }, 1)
    metrics.increment("openresty_edge_responses_total", {
        route_family = trace.route_family,
        target_kind = trace.target_kind,
        status = tostring(ngx.status),
    }, 1)

    local cache_status = ngx.var.upstream_cache_status
    if cache_status ~= nil and cache_status ~= "" and cache_status ~= "-" then
        metrics.increment("openresty_edge_cache_status_total", {
            route_family = trace.route_family,
            target_kind = trace.target_kind,
            cache_status = cache_status,
        }, 1)
    end

    local request_duration = tonumber(ngx.var.request_time)
    if request_duration == nil then
        request_duration = math.max(ngx.now() - (trace.request_started_at or ngx.req.start_time()), 0)
    end
    metrics.observe("openresty_edge_request_duration_seconds", labels, request_duration)

    local upstream_response_seconds = parse_upstream_response_time(ngx.var.upstream_response_time)
    if upstream_response_seconds ~= nil then
        metrics.observe("openresty_edge_upstream_response_seconds", labels, upstream_response_seconds)
    end

    if trace.access_duration_seconds ~= nil then
        metrics.observe("openresty_edge_lua_access_duration_seconds", labels, trace.access_duration_seconds)
    end

    if trace.content_duration_seconds ~= nil then
        metrics.observe("openresty_edge_lua_content_duration_seconds", labels, trace.content_duration_seconds)
    end

    if trace.header_filter_duration_seconds ~= nil then
        metrics.observe("openresty_edge_header_filter_duration_seconds", labels, trace.header_filter_duration_seconds)
    end

    if trace.access_gc_before_kb ~= nil then
        metrics.observe("openresty_edge_lua_gc_before_kb", labels, trace.access_gc_before_kb)
        metrics.observe("openresty_edge_lua_gc_after_kb", labels, trace.access_gc_after_kb)
        metrics.observe("openresty_edge_lua_gc_delta_kb", labels, trace.access_gc_delta_kb)
    end

    if trace.content_gc_before_kb ~= nil then
        metrics.observe("openresty_edge_lua_content_gc_before_kb", labels, trace.content_gc_before_kb)
        metrics.observe("openresty_edge_lua_content_gc_after_kb", labels, trace.content_gc_after_kb)
        metrics.observe("openresty_edge_lua_content_gc_delta_kb", labels, trace.content_gc_delta_kb)
    end

    if trace.policy_decision ~= nil and trace.policy_source ~= nil then
        metrics.increment("openresty_edge_policy_decisions_total", {
            route_family = trace.route_family,
            target_kind = trace.target_kind,
            decision = trace.policy_decision,
            source = trace.policy_source,
        }, 1)
    end

    external_io.schedule_kafka_publish(trace, {
        route_family = trace.route_family,
        target_kind = trace.target_kind,
        status = ngx.status,
        request_time_seconds = request_duration,
        metadata_source = trace.metadata_source,
        metadata_fetch_ms = trace.metadata_fetch_duration_seconds and trace.metadata_fetch_duration_seconds * 1000.0 or nil,
        redis_access_connect_ms = trace.redis_access_connect_seconds and trace.redis_access_connect_seconds * 1000.0 or nil,
        redis_access_command_ms = trace.redis_access_command_seconds and trace.redis_access_command_seconds * 1000.0 or nil,
        redis_content_connect_ms = trace.redis_content_connect_seconds and trace.redis_content_connect_seconds * 1000.0 or nil,
        redis_content_command_ms = trace.redis_content_command_seconds and trace.redis_content_command_seconds * 1000.0 or nil,
        header_filter_ms = trace.header_filter_duration_seconds and trace.header_filter_duration_seconds * 1000.0 or nil,
        lua_access_ms = trace.access_duration_seconds and trace.access_duration_seconds * 1000.0 or nil,
        lua_content_ms = trace.content_duration_seconds and trace.content_duration_seconds * 1000.0 or nil,
        lua_gc_delta_kb = trace.content_gc_delta_kb or trace.access_gc_delta_kb,
    })

    ngx.update_time()
    metrics.observe("openresty_edge_lua_log_duration_seconds", labels, ngx.now() - log_started_at)
end

return M
