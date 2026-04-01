local M = {}

local function starts_with(value, prefix)
    return value:sub(1, #prefix) == prefix
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

function M.request()
    local uri = ngx.var.uri or ""
    local request = {
        uri = uri,
        method = ngx.req.get_method(),
        route_family = "api",
        target_kind = "api",
        traffic_class = "api",
        track = true,
    }

    if uri == "/healthz" then
        request.route_family = "system"
        request.target_kind = "healthz"
        request.traffic_class = "system"
        request.track = false
    elseif uri == "/metrics" then
        request.route_family = "system"
        request.target_kind = "metrics"
        request.traffic_class = "system"
        request.track = false
    elseif uri == "/cache" then
        request.route_family = "admin"
        request.target_kind = "cache_purge"
        request.traffic_class = "admin"
        request.track = false
    elseif starts_with(uri, "/live/") then
        request.route_family = "live"
        request.traffic_class = "live"

        if uri:match("/master%.m3u8$") then
            request.target_kind = "live_master"
        elseif uri:match("/live%.m3u8$") then
            request.target_kind = "live_playlist"
        elseif uri:match("/seg_%d+%.ts$") then
            request.target_kind = "live_segment"
        else
            request.target_kind = "live_object"
        end
    elseif starts_with(uri, "/vod/") then
        request.route_family = "vod"
        request.traffic_class = "vod"

        if uri:match("/master%.m3u8$") then
            request.target_kind = "vod_manifest"
        elseif uri:match("/playlist%.m3u8$") then
            request.target_kind = "vod_playlist"
        elseif uri:match("/seg_%d+%.ts$") then
            request.target_kind = "vod_segment"
        else
            request.target_kind = "vod_object"
        end
    elseif starts_with(uri, "/openresty/lua/transform") then
        request.route_family = "openresty"
        request.target_kind = "lua_transform"
        request.traffic_class = "openresty"
    elseif starts_with(uri, "/openresty/lua/policy") then
        request.route_family = "openresty"
        request.target_kind = "lua_policy"
        request.traffic_class = "openresty"
    end

    return request
end

function M.build_policy_context(request, args)
    local variant = tostring(args.variant or args.profile or "720p")
    local region = tostring(args.region or "us")
    local title = tostring(args.title or args.asset or request.target_kind)
    local tenant = tostring(args.tenant or "demo")
    local entitlements = split_csv(args.entitlements or "vod,hd,edge")
    local entitlement_map = {}

    for _, entitlement in ipairs(entitlements) do
        entitlement_map[entitlement] = true
    end

    local token = tostring(args.token or "")
    local privileged = entitlement_map["uhd"] or entitlement_map["premium"] or token ~= ""
    local allow = request.route_family ~= "vod" or variant ~= "1080p" or privileged
    local decision = allow and "allow" or "challenge"

    return {
        tenant = tenant,
        title = title,
        variant = variant,
        region = region,
        entitlements = entitlements,
        cache_key = table.concat({
            request.route_family,
            tenant,
            title,
            variant,
            region,
            decision,
        }, ":"),
        decision = decision,
        source = "route_policy",
    }
end

return M
