local M = {}

local dict = ngx.shared.prometheus_metrics

local registry = {
    order = {},
    defs = {},
}

local function register(definition)
    registry.order[#registry.order + 1] = definition.name
    registry.defs[definition.name] = definition
end

register({
    name = "openresty_edge_worker_starts_total",
    type = "counter",
    help = "Number of OpenResty worker initializations observed by the lab.",
    labels = { "worker" },
})

register({
    name = "openresty_edge_requests_total",
    type = "counter",
    help = "Total tracked requests handled by OpenResty edge.",
    labels = { "route_family", "target_kind", "method" },
})

register({
    name = "openresty_edge_responses_total",
    type = "counter",
    help = "Total tracked responses handled by OpenResty edge.",
    labels = { "route_family", "target_kind", "status" },
})

register({
    name = "openresty_edge_cache_status_total",
    type = "counter",
    help = "Edge cache outcomes by route family and target kind.",
    labels = { "route_family", "target_kind", "cache_status" },
})

register({
    name = "openresty_edge_policy_decisions_total",
    type = "counter",
    help = "Policy decisions emitted by Lua access/content logic.",
    labels = { "route_family", "target_kind", "decision", "source" },
})

register({
    name = "openresty_edge_request_duration_seconds",
    type = "histogram",
    help = "End-to-end request duration observed at the edge.",
    labels = { "route_family", "target_kind" },
    buckets = { 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5 },
})

register({
    name = "openresty_edge_upstream_response_seconds",
    type = "histogram",
    help = "Upstream response time reported by Nginx/OpenResty.",
    labels = { "route_family", "target_kind" },
    buckets = { 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5 },
})

register({
    name = "openresty_edge_lua_access_duration_seconds",
    type = "histogram",
    help = "Lua access-phase duration.",
    labels = { "route_family", "target_kind" },
    buckets = { 0.00005, 0.0001, 0.00025, 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05 },
})

register({
    name = "openresty_edge_lua_log_duration_seconds",
    type = "histogram",
    help = "Lua log-phase duration.",
    labels = { "route_family", "target_kind" },
    buckets = { 0.00001, 0.00005, 0.0001, 0.00025, 0.0005, 0.001, 0.0025, 0.005, 0.01 },
})

register({
    name = "openresty_edge_lua_content_duration_seconds",
    type = "histogram",
    help = "Lua content-phase duration for synthetic OpenResty endpoints.",
    labels = { "route_family", "target_kind" },
    buckets = { 0.0001, 0.00025, 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5 },
})

register({
    name = "openresty_edge_header_filter_duration_seconds",
    type = "histogram",
    help = "Header-filter phase duration.",
    labels = { "route_family", "target_kind" },
    buckets = { 0.00001, 0.00005, 0.0001, 0.00025, 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05 },
})

register({
    name = "openresty_edge_metadata_requests_total",
    type = "counter",
    help = "Metadata fetch attempts issued by Lua.",
    labels = { "route_family", "target_kind", "outcome" },
})

register({
    name = "openresty_edge_metadata_duration_seconds",
    type = "histogram",
    help = "Metadata fetch duration from Lua.",
    labels = { "route_family", "target_kind", "outcome" },
    buckets = { 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1 },
})

register({
    name = "openresty_edge_redis_operations_total",
    type = "counter",
    help = "Redis operations issued by Lua, including connect attempts.",
    labels = { "route_family", "target_kind", "phase", "operation", "outcome" },
})

register({
    name = "openresty_edge_redis_connect_duration_seconds",
    type = "histogram",
    help = "Redis connect duration by phase.",
    labels = { "route_family", "target_kind", "phase", "outcome" },
    buckets = { 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1 },
})

register({
    name = "openresty_edge_redis_command_duration_seconds",
    type = "histogram",
    help = "Redis command/response duration by phase and operation.",
    labels = { "route_family", "target_kind", "phase", "operation", "outcome" },
    buckets = { 0.0001, 0.00025, 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1 },
})

register({
    name = "openresty_edge_kafka_mock_events_total",
    type = "counter",
    help = "Events published to the Kafka-mock sink.",
    labels = { "route_family", "target_kind", "outcome" },
})

register({
    name = "openresty_edge_kafka_mock_publish_duration_seconds",
    type = "histogram",
    help = "Kafka-mock publish duration from async Lua timers.",
    labels = { "route_family", "target_kind", "outcome" },
    buckets = { 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1 },
})

register({
    name = "openresty_edge_lua_gc_before_kb",
    type = "histogram",
    help = "Lua heap size before access-phase policy work.",
    labels = { "route_family", "target_kind" },
    buckets = { 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192 },
})

register({
    name = "openresty_edge_lua_gc_after_kb",
    type = "histogram",
    help = "Lua heap size after access-phase policy work.",
    labels = { "route_family", "target_kind" },
    buckets = { 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192 },
})

register({
    name = "openresty_edge_lua_gc_delta_kb",
    type = "histogram",
    help = "Lua heap delta during access-phase policy work.",
    labels = { "route_family", "target_kind" },
    buckets = { -256, -128, -64, -32, -16, -8, -4, 0, 4, 8, 16, 32, 64, 128, 256 },
})

register({
    name = "openresty_edge_lua_content_gc_before_kb",
    type = "histogram",
    help = "Lua heap size before content-phase synthetic work.",
    labels = { "route_family", "target_kind" },
    buckets = { 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192 },
})

register({
    name = "openresty_edge_lua_content_gc_after_kb",
    type = "histogram",
    help = "Lua heap size after content-phase synthetic work.",
    labels = { "route_family", "target_kind" },
    buckets = { 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192 },
})

register({
    name = "openresty_edge_lua_content_gc_delta_kb",
    type = "histogram",
    help = "Lua heap delta during content-phase synthetic work.",
    labels = { "route_family", "target_kind" },
    buckets = { -256, -128, -64, -32, -16, -8, -4, 0, 4, 8, 16, 32, 64, 128, 256, 512, 1024 },
})

register({
    name = "openresty_edge_lua_heap_kb",
    type = "gauge",
    help = "Latest Lua heap sample per OpenResty worker.",
    labels = { "worker" },
})

local function normalize_label_value(value)
    local string_value = tostring(value or "none")
    if string_value == "" then
        return "none"
    end
    return string_value
end

local function split_key(key)
    local parts = {}
    for part in key:gmatch("[^|]+") do
        parts[#parts + 1] = part
    end
    return parts
end

local function escaped(value)
    return tostring(value)
        :gsub("\\", "\\\\")
        :gsub("\n", "\\n")
        :gsub("\"", "\\\"")
end

local function build_label_suffix(label_names, label_values, extra_name, extra_value)
    local labels = {}

    for index, label_name in ipairs(label_names or {}) do
        labels[#labels + 1] = label_name .. "=\"" .. escaped(label_values[index]) .. "\""
    end

    if extra_name ~= nil then
        labels[#labels + 1] = extra_name .. "=\"" .. escaped(extra_value) .. "\""
    end

    if #labels == 0 then
        return ""
    end

    return "{" .. table.concat(labels, ",") .. "}"
end

local function counter_key(metric_name, label_names, labels)
    local parts = { "counter", metric_name }
    for _, label_name in ipairs(label_names or {}) do
        parts[#parts + 1] = normalize_label_value(labels[label_name])
    end
    return table.concat(parts, "|")
end

local function gauge_key(metric_name, label_names, labels)
    local parts = { "gauge", metric_name }
    for _, label_name in ipairs(label_names or {}) do
        parts[#parts + 1] = normalize_label_value(labels[label_name])
    end
    return table.concat(parts, "|")
end

local function histogram_prefix(metric_name, label_names, labels)
    local parts = { "histogram", metric_name }
    for _, label_name in ipairs(label_names or {}) do
        parts[#parts + 1] = normalize_label_value(labels[label_name])
    end
    return table.concat(parts, "|")
end

local function incr(key, delta)
    local value, err = dict:incr(key, delta)
    if value then
        return value
    end

    local ok, add_err = dict:add(key, delta)
    if ok then
        return delta
    end

    value, err = dict:incr(key, delta)
    if value then
        return value
    end

    ngx.log(ngx.ERR, "failed to increment metric key ", key, ": ", err or add_err or "unknown")
    return nil
end

local function observe_histogram(metric_name, label_names, labels, value)
    local definition = registry.defs[metric_name]
    if not definition then
        return
    end

    local prefix = histogram_prefix(metric_name, label_names, labels)
    incr(prefix .. "|count", 1)
    incr(prefix .. "|sum", value)

    local matched = false
    for _, bucket in ipairs(definition.buckets) do
        if value <= bucket then
            matched = true
            incr(prefix .. "|bucket|" .. tostring(bucket), 1)
        end
    end

    if matched or value > definition.buckets[#definition.buckets] then
        incr(prefix .. "|bucket|+Inf", 1)
    end
end

function M.init()
    local worker = tostring(ngx.worker.id())
    incr(counter_key("openresty_edge_worker_starts_total", { "worker" }, { worker = worker }), 1)
    dict:set(gauge_key("openresty_edge_lua_heap_kb", { "worker" }, { worker = worker }), collectgarbage("count"))
end

function M.increment(metric_name, labels, delta)
    local definition = registry.defs[metric_name]
    incr(counter_key(metric_name, definition.labels, labels), delta or 1)
end

function M.observe(metric_name, labels, value)
    local definition = registry.defs[metric_name]
    observe_histogram(metric_name, definition.labels, labels, tonumber(value) or 0)
end

function M.set_gauge(metric_name, labels, value)
    local definition = registry.defs[metric_name]
    dict:set(gauge_key(metric_name, definition.labels, labels), tonumber(value) or 0)
end

function M.collect()
    ngx.header.content_type = "text/plain; version=0.0.4; charset=utf-8"

    local worker = tostring(ngx.worker.id())
    M.set_gauge("openresty_edge_lua_heap_kb", { worker = worker }, collectgarbage("count"))

    local keys = dict:get_keys(0)
    table.sort(keys)

    local lines = {}

    for _, metric_name in ipairs(registry.order) do
        local definition = registry.defs[metric_name]
        lines[#lines + 1] = "# HELP " .. metric_name .. " " .. definition.help
        lines[#lines + 1] = "# TYPE " .. metric_name .. " " .. definition.type

        for _, key in ipairs(keys) do
            local parts = split_key(key)
            local kind = parts[1]
            local current_metric_name = parts[2]

            if current_metric_name == metric_name then
                if definition.type == "counter" and kind == "counter" then
                    local label_values = {}
                    for index = 1, #definition.labels do
                        label_values[index] = parts[2 + index]
                    end
                    lines[#lines + 1] = metric_name
                        .. build_label_suffix(definition.labels, label_values)
                        .. " "
                        .. tostring(dict:get(key))
                elseif definition.type == "gauge" and kind == "gauge" then
                    local label_values = {}
                    for index = 1, #definition.labels do
                        label_values[index] = parts[2 + index]
                    end
                    lines[#lines + 1] = metric_name
                        .. build_label_suffix(definition.labels, label_values)
                        .. " "
                        .. tostring(dict:get(key))
                elseif definition.type == "histogram" and kind == "histogram" then
                    local label_values = {}
                    for index = 1, #definition.labels do
                        label_values[index] = parts[2 + index]
                    end

                    local suffix_type = parts[3 + #definition.labels]
                    if suffix_type == "bucket" then
                        local le = parts[4 + #definition.labels]
                        lines[#lines + 1] = metric_name .. "_bucket"
                            .. build_label_suffix(definition.labels, label_values, "le", le)
                            .. " "
                            .. tostring(dict:get(key))
                    elseif suffix_type == "sum" then
                        lines[#lines + 1] = metric_name .. "_sum"
                            .. build_label_suffix(definition.labels, label_values)
                            .. " "
                            .. tostring(dict:get(key))
                    elseif suffix_type == "count" then
                        lines[#lines + 1] = metric_name .. "_count"
                            .. build_label_suffix(definition.labels, label_values)
                            .. " "
                            .. tostring(dict:get(key))
                    end
                end
            end
        end
    end

    ngx.print(table.concat(lines, "\n"))
end

return M
