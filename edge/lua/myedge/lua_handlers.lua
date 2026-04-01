local cjson = require("cjson.safe")

local classify = require("myedge.classify")
local external_io = require("myedge.external_io")
local gc_probe = require("myedge.gc_probe")

local M = {}

local function clamp(value, minimum, maximum)
    local numeric_value = tonumber(value)
    if numeric_value == nil then
        return minimum
    end
    if numeric_value < minimum then
        return minimum
    end
    if numeric_value > maximum then
        return maximum
    end
    return math.floor(numeric_value)
end

local function split_csv(value)
    local items = {}
    for part in tostring(value or ""):gmatch("[^,]+") do
        local normalized = part:gsub("^%s+", ""):gsub("%s+$", "")
        if normalized ~= "" then
            items[#items + 1] = normalized
        end
    end
    return items
end

local function attach_content_probe(sample, decision, source, redis_sample)
    local trace = ngx.ctx.edge_trace or {}
    trace.content_duration_seconds = sample.duration_seconds
    trace.content_gc_before_kb = sample.before_kb
    trace.content_gc_after_kb = sample.after_kb
    trace.content_gc_delta_kb = sample.delta_kb
    trace.redis_content_outcome = redis_sample and redis_sample.outcome or nil
    trace.redis_content_error = redis_sample and redis_sample.error or nil
    trace.redis_content_connect_seconds = redis_sample and redis_sample.connect_duration_seconds or nil
    trace.redis_content_command_seconds = redis_sample and redis_sample.command_duration_seconds or nil

    if decision ~= nil then
        trace.policy_decision = decision
    end

    if source ~= nil then
        trace.policy_source = source
    end

    ngx.ctx.edge_trace = trace
end

function M.handle_transform()
    local args = ngx.req.get_uri_args()
    local request = classify.request()
    local trace = ngx.ctx.edge_trace or {}

    local sample = gc_probe.capture(function()
        local repeat_count = clamp(args["repeat"] or 48, 8, 256)
        local width = clamp(args.width or 6, 2, 20)
        local seed = tostring(args.seed or "movie1")
        local rows = {}

        for index = 1, repeat_count do
            local pieces = {}
            for column = 1, width do
                pieces[#pieces + 1] = string.format("%s-%03d-%02d", seed, index, column)
            end

            rows[#rows + 1] = {
                id = index,
                route_family = request.route_family,
                target_kind = request.target_kind,
                checksum = ngx.crc32_short(table.concat(pieces, "|")),
                preview = table.concat(pieces, ":"),
                field_count = width,
            }
        end

        local payload = {
            experiment = "openresty_transform",
            generated_at = ngx.now(),
            repeat_count = repeat_count,
            width = width,
            rows = rows,
        }

        local encoded = assert(cjson.encode(payload))
        if args.decode == "1" then
            local decoded = assert(cjson.decode(encoded))
            decoded.roundtrip = true
            encoded = assert(cjson.encode(decoded))
        end

        local redis_sample = external_io.redis_roundtrip({
            route_family = request.route_family,
            target_kind = request.target_kind,
        }, "content", {
            tenant = trace.policy_tenant or "demo",
            title = seed,
            variant = tostring(width),
            decision = "transform",
            metadata_source = trace.metadata_source or "none",
        })

        return {
            body = encoded,
            redis_sample = redis_sample,
        }
    end)

    local result = sample.results[1]
    attach_content_probe(sample, "transform", "content", result.redis_sample)
    ngx.header["Content-Type"] = "application/json"
    ngx.header["Cache-Control"] = "no-store"
    ngx.header["X-Traffic-Class"] = "openresty"
    ngx.header["X-Media-Class"] = "lua-transform"
    ngx.say(result.body)
end

function M.handle_policy()
    local args = ngx.req.get_uri_args()
    local request = classify.request()
    local cache = ngx.shared.edge_runtime_cache
    local trace = ngx.ctx.edge_trace or {}

    local sample = gc_probe.capture(function()
        local policy = classify.build_policy_context(request, args)
        local entitlements = split_csv(args.entitlements or "vod,hd,edge")
        local cache_key = policy.cache_key
        local cached = cache:get(cache_key)

        if cached then
            local decoded = cjson.decode(cached)
            if decoded then
                decoded.source = "shared_dict"
                decoded.cache_hit = true
                return {
                    policy = decoded,
                    redis_sample = external_io.redis_roundtrip({
                        route_family = request.route_family,
                        target_kind = request.target_kind,
                    }, "content", {
                        tenant = decoded.tenant,
                        title = decoded.title,
                        variant = decoded.variant,
                        decision = decoded.decision,
                        metadata_source = trace.metadata_source or "none",
                    }),
                }
            end
        end

        policy.source = "computed"
        policy.cache_hit = false
        policy.entitlements = entitlements
        cache:set(cache_key, assert(cjson.encode(policy)), 30)
        local redis_sample = external_io.redis_roundtrip({
            route_family = request.route_family,
            target_kind = request.target_kind,
        }, "content", {
            tenant = policy.tenant,
            title = policy.title,
            variant = policy.variant,
            decision = policy.decision,
            metadata_source = trace.metadata_source or "none",
        })

        return {
            policy = policy,
            redis_sample = redis_sample,
        }
    end)

    local result = sample.results[1]
    local policy = result.policy
    attach_content_probe(sample, policy.decision, policy.source, result.redis_sample)

    ngx.header["Content-Type"] = "application/json"
    ngx.header["Cache-Control"] = "no-store"
    ngx.header["X-Traffic-Class"] = "openresty"
    ngx.header["X-Media-Class"] = "lua-policy"
    ngx.say(assert(cjson.encode({
        experiment = "openresty_policy",
        decision = policy.decision,
        source = policy.source,
        cache_hit = policy.cache_hit,
        cache_key = policy.cache_key,
        tenant = policy.tenant,
        title = policy.title,
        variant = policy.variant,
        region = policy.region,
        entitlements = policy.entitlements,
    })))
end

return M
