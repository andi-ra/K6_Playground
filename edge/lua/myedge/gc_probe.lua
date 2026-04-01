local M = {}

function M.capture(fn)
    local before_kb = collectgarbage("count")
    ngx.update_time()
    local started_at = ngx.now()
    local results = { fn() }
    local after_kb = collectgarbage("count")
    ngx.update_time()

    return {
        results = results,
        before_kb = before_kb,
        after_kb = after_kb,
        delta_kb = after_kb - before_kb,
        duration_seconds = ngx.now() - started_at,
    }
end

return M
