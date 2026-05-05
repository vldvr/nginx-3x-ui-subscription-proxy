local http = require "resty.http"

local user_agent   = ngx.var.http_user_agent or ""
local accept_header = ngx.var.http_accept   or ""
local is_browser   = string.match(user_agent:lower(), "mozilla") or
                     string.match(accept_header:lower(), "text/html")

local servers_str = os.getenv("SERVERS")
if not servers_str then
    ngx.log(ngx.ERR, "SERVERS env not set")
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

local servers = {}
for s in string.gmatch(servers_str, "[^%s]+") do
    table.insert(servers, s)
end

-- build canonical subscription URL
-- SITE_URL env overrides everything (useful behind a reverse proxy on port 443)
local function build_sub_url(sub_id)
    local site_url = os.getenv("SITE_URL")
    if site_url and site_url ~= "" then
        return site_url:gsub("/$", "") .. "/sub/" .. sub_id
    end
    local host  = os.getenv("SITE_HOST") or "localhost"
    local port  = os.getenv("SITE_PORT") or "1337"
    local proto = (os.getenv("TLS_MODE") == "on") and "https" or "http"
    -- omit port when it matches the scheme default
    if (proto == "https" and port == "443") or (proto == "http" and port == "80") then
        return proto .. "://" .. host .. "/sub/" .. sub_id
    end
    return proto .. "://" .. host .. ":" .. port .. "/sub/" .. sub_id
end

-- helper: case-insensitive header lookup
local function hdr(res, name)
    return res.headers[name] or res.headers[name:lower()] or
           res.headers[name:upper()]
end

-- helper: first non-empty value across upstreams
local function first_of(collected)
    for _, v in ipairs(collected) do
        if v and v ~= "" then return v end
    end
end

-- ── VPN CLIENT PATH ────────────────────────────────────────────────────────
if not is_browser then
    local httpc = http.new()
    local configs = {}

    local meta = { upload = 0, download = 0, total = 0, expire = 0 }
    local collected = {
        routing_enable  = {},
        profile_title   = {},
        update_interval = {},
        web_page_url    = {},
        support_url     = {},
        announce        = {},
        routing         = {},
    }

    for _, base_url in ipairs(servers) do
        local url = base_url .. ngx.var.sub_id
        local res, err = httpc:request_uri(url, {
            method     = "GET",
            ssl_verify = false,
            headers    = {
                ["User-Agent"] = user_agent ~= "" and user_agent
                                 or "Mihomo/1.18 ClashMeta/1.18",
            },
        })

        if res and res.status == 200 then
            -- Subscription-Userinfo
            local ui = hdr(res, "Subscription-Userinfo") or ""
            local up  = tonumber(string.match(ui, "upload=(%d+)"))   or 0
            local dl  = tonumber(string.match(ui, "download=(%d+)")) or 0
            local tot = tonumber(string.match(ui, "total=(%d+)"))    or 0
            local exp = tonumber(string.match(ui, "expire=(%d+)"))   or 0
            meta.upload   = meta.upload   + up
            meta.download = meta.download + dl
            meta.total    = meta.total    + tot
            if exp > 0 and (meta.expire == 0 or exp < meta.expire) then
                meta.expire = exp
            end

            -- collect per-upstream headers
            local function push(key, h)
                local v = hdr(res, h)
                if v and v ~= "" then
                    table.insert(collected[key], v)
                end
            end

            push("routing_enable",  "Routing-Enable")
            push("profile_title",   "Profile-Title")
            push("update_interval", "Profile-Update-Interval")
            push("web_page_url",    "Profile-Web-Page-Url")
            push("support_url",     "Support-Url")
            push("announce",        "Announce")
            push("routing",         "Routing")

            -- decode and collect configs
            local decoded = ngx.decode_base64(res.body)
            if decoded then
                table.insert(configs, decoded)
            else
                ngx.log(ngx.ERR, "base64 decode failed for ", url)
            end
        else
            ngx.log(ngx.ERR, "upstream error ", url, ": ",
                    err or (res and tostring(res.status) or "nil"))
        end
    end

    if #configs == 0 then
        ngx.status = ngx.HTTP_BAD_GATEWAY
        ngx.say("No configs available")
        return
    end

    -- Routing-Enable: true if any upstream says true
    local routing_enable = false
    for _, v in ipairs(collected.routing_enable) do
        if v:lower() == "true" then routing_enable = true; break end
    end

    -- Profile-Update-Interval: minimum across upstreams
    local update_interval
    for _, v in ipairs(collected.update_interval) do
        local n = tonumber(v)
        if n and (not update_interval or n < update_interval) then
            update_interval = n
        end
    end

    -- Profile-Web-Page-Url: prefer value that looks like a clean external URL
    -- (not an x-ui panel URL containing port 2096)
    local web_page_url
    for _, v in ipairs(collected.web_page_url) do
        if not string.find(v, ":2096") then
            web_page_url = v; break
        end
    end
    -- fallback to proxy's own sub URL
    if not web_page_url then
        web_page_url = build_sub_url(ngx.var.sub_id)
    end

    -- set response headers
    ngx.header["Content-Type"]            = "text/plain; charset=utf-8"
    ngx.header["Content-Disposition"]     = 'attachment; filename="' .. ngx.var.sub_id .. '.txt"'
    ngx.header["Subscription-Userinfo"]   = string.format(
        "upload=%d; download=%d; total=%d; expire=%d",
        meta.upload, meta.download, meta.total, meta.expire)
    ngx.header["Profile-Update-Interval"] = tostring(update_interval or 12)
    ngx.header["Profile-Web-Page-Url"]    = web_page_url
    ngx.header["Routing-Enable"]          = routing_enable and "true" or "false"

    local pt = first_of(collected.profile_title)
    ngx.header["Profile-Title"] = pt and pt ~= "" and pt
        or ("base64:" .. ngx.encode_base64("wkiseven.t.me"))

    local su = first_of(collected.support_url)
    if su then ngx.header["Support-Url"] = su end

    local ann = first_of(collected.announce)
    if ann then ngx.header["Announce"] = ann end

    local rt = first_of(collected.routing)
    if rt then ngx.header["Routing"] = rt end

    ngx.print(ngx.encode_base64(table.concat(configs)))
    return
end

-- ── BROWSER PATH ───────────────────────────────────────────────────────────
local function extract_subscription_data(html)
    local data = {}
    local tmpl = string.find(html, '<template[^>]+id="subscription%-data"[^>]*>')
    if tmpl then
        local tend = string.find(html, '</template>', tmpl)
        if tend then
            local tag = string.sub(html, tmpl, tend)
            data.sid          = string.match(tag, 'data%-sid="([^"]*)"')          or ""
            data.downloadbyte = tonumber(string.match(tag, 'data%-downloadbyte="([^"]*)"') or "0") or 0
            data.uploadbyte   = tonumber(string.match(tag, 'data%-uploadbyte="([^"]*)"')   or "0") or 0
            data.totalbyte    = tonumber(string.match(tag, 'data%-totalbyte="([^"]*)"')    or "0") or 0
            data.expire       = string.match(tag, 'data%-expire="([^"]*)"') or "0"
            data.lastonline   = string.match(tag, 'data%-lastonline="([^"]*)"') or "0"
        end
    end
    local links_raw = string.match(html,
        '<textarea[^>]+id="subscription%-links"[^>]*>([^<]*)</textarea>')
    if links_raw then
        data.links = links_raw:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
    end
    local title = string.match(html, '<title>([^–<]+)')
    if title then data.server_name = title:match("^%s*(.-)%s*$") end
    return data
end

local function format_bytes(b)
    if b >= 1073741824 then return string.format("%.2f GB", b / 1073741824)
    elseif b >= 1048576 then return string.format("%.2f MB", b / 1048576)
    elseif b >= 1024    then return string.format("%.2f KB", b / 1024)
    else return string.format("%d B", b) end
end

local function format_date(ts)
    local n = tonumber(ts)
    if not n or n == 0 then return "∞" end
    if n > 1e12 then n = n / 1000 end
    return os.date("%Y-%m-%d %H:%M", n)
end

local function generate_browser_ui(combined_data, sub_id)
    local sub_url = build_sub_url(sub_id)

    local total_dl, total_ul = 0, 0
    local latest_online, earliest_expire = 0, math.huge
    local server_links = {}

    for i, d in ipairs(combined_data) do
        total_dl = total_dl + (d.downloadbyte or 0)
        total_ul = total_ul + (d.uploadbyte   or 0)
        local lo = tonumber(d.lastonline) or 0
        if lo > latest_online then latest_online = lo end
        local exp = tonumber(d.expire) or 0
        if exp > 0 and exp < earliest_expire then earliest_expire = exp end
        if d.links and d.links ~= "" then
            for link in string.gmatch(d.links, "[^\r\n]+") do
                if link:match("%S") then
                    local name = string.match(link, "#([^#]+)$")
                    if name then
                        name = name:gsub("%%(%x%x)", function(h)
                            return string.char(tonumber(h, 16)) end)
                        name = name:match("^%s*(.-)%s*$")
                    else
                        name = d.server_name or ("Server " .. i)
                    end
                    table.insert(server_links, {name = name, url = link})
                end
            end
        end
    end

    local used_fmt   = format_bytes(total_dl + total_ul)
    local dl_fmt     = format_bytes(total_dl)
    local ul_fmt     = format_bytes(total_ul)
    local expire_fmt = (earliest_expire == math.huge) and "∞" or format_date(earliest_expire)

    local links_html = ""
    for _, lk in ipairs(server_links) do
        links_html = links_html .. string.format(
            '<li><span class="lname">%s</span>'
            .. '<button onclick="copy(\'%s\')" title="Copy">⧉</button></li>\n',
            lk.name:gsub('"', '&quot;'),
            lk.url:gsub("'", "\\'"):gsub('"', '&quot;'))
    end

    return string.format([[
<!DOCTYPE html><html lang="ru"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Подписка · %s</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;
     background:#0f1117;color:#e2e8f0;min-height:100vh;
     display:flex;flex-direction:column;align-items:center;padding:32px 16px}
h1{font-size:1.1rem;font-weight:600;color:#94a3b8;margin-bottom:24px}
.card{background:#1e2030;border:1px solid #2d3148;border-radius:16px;
      padding:28px;width:100%%;max-width:480px;margin-bottom:16px}
.stats{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin-bottom:20px}
.stat{background:#161824;border-radius:10px;padding:14px 16px}
.stat-label{font-size:.7rem;color:#64748b;text-transform:uppercase;letter-spacing:.06em;margin-bottom:4px}
.stat-value{font-size:1.1rem;font-weight:700;color:#e2e8f0}
.stat-value.used{color:#60a5fa}.stat-value.expire{color:#34d399}
.qr-wrap{display:flex;justify-content:center;margin-bottom:20px}
canvas{border-radius:10px;background:#fff;padding:10px}
.url-box{font-family:monospace;font-size:.72rem;color:#64748b;
         background:#161824;border-radius:8px;padding:10px 14px;
         word-break:break-all;margin-bottom:16px}
.btn{width:100%%;padding:12px;border:none;border-radius:10px;font-size:.95rem;
     font-weight:600;cursor:pointer;transition:.15s}
.btn-copy{background:#3b82f6;color:#fff;margin-bottom:10px}
.btn-copy:hover{background:#2563eb}
details{margin-top:16px}
summary{font-size:.85rem;color:#64748b;cursor:pointer;user-select:none;padding:6px 0}
summary:hover{color:#94a3b8}
ul.links{list-style:none;margin-top:10px;display:flex;flex-direction:column;gap:6px;
         max-height:260px;overflow-y:auto}
ul.links li{display:flex;align-items:center;justify-content:space-between;
            background:#161824;border-radius:8px;padding:8px 12px;gap:8px}
.lname{font-size:.78rem;color:#94a3b8;flex:1;overflow:hidden;
       text-overflow:ellipsis;white-space:nowrap}
ul.links button{flex-shrink:0;background:transparent;border:1px solid #334155;
                color:#64748b;border-radius:6px;padding:3px 8px;
                cursor:pointer;font-size:.8rem;transition:.15s}
ul.links button:hover{border-color:#3b82f6;color:#3b82f6}
.toast{position:fixed;bottom:24px;left:50%%;transform:translateX(-50%%);
       background:#22c55e;color:#fff;padding:10px 22px;border-radius:8px;
       font-size:.88rem;display:none;pointer-events:none}
</style>
<script src="/qrcode.min.js"></script>
</head><body>
<h1>Подписка &nbsp;·&nbsp; %s</h1>
<div class="card">
  <div class="stats">
    <div class="stat"><div class="stat-label">Использовано</div><div class="stat-value used">%s</div></div>
    <div class="stat"><div class="stat-label">↓ Загрузка</div><div class="stat-value">%s</div></div>
    <div class="stat"><div class="stat-label">↑ Отдача</div><div class="stat-value">%s</div></div>
    <div class="stat"><div class="stat-label">Истекает</div><div class="stat-value expire">%s</div></div>
  </div>
  <div class="qr-wrap"><div id="qr"></div></div>
  <div class="url-box">%s</div>
  <button class="btn btn-copy" onclick="copyMain()">📋 Скопировать ссылку подписки</button>
  <details><summary>Конфиги (%d шт.)</summary>
    <ul class="links">%s</ul>
  </details>
</div>
<div class="toast" id="toast">Скопировано!</div>
<script>
const SUB='%s';
new QRCode(document.getElementById('qr'),{text:SUB,width:180,height:180,colorDark:'#000000',colorLight:'#ffffff',correctLevel:QRCode.CorrectLevel.M});
function copyMain(){copy(SUB)}
function copy(t){
  navigator.clipboard?navigator.clipboard.writeText(t):
    (Object.assign(document.createElement('textarea'),{value:t}).select(),
     document.execCommand('copy'));
  const el=document.getElementById('toast');
  el.style.display='block';setTimeout(()=>el.style.display='none',2000);
}
</script></body></html>]],
        sub_id, sub_id,
        used_fmt, dl_fmt, ul_fmt, expire_fmt,
        sub_url,
        #server_links, links_html,
        sub_url)
end

local httpc = http.new()
local combined_data = {}

for _, base_url in ipairs(servers) do
    local url = base_url .. ngx.var.sub_id
    local res, err = httpc:request_uri(url, {
        method = "GET",
        ssl_verify = false,
        headers = {
            ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                          .. "AppleWebKit/537.36 (KHTML, like Gecko) "
                          .. "Chrome/124.0 Safari/537.36",
            ["Accept"] = "text/html,application/xhtml+xml;q=0.9,*/*;q=0.8",
        },
    })
    if res and res.status == 200 then
        local d = extract_subscription_data(res.body)
        if d.sid and d.sid ~= "" then
            table.insert(combined_data, d)
        end
    else
        ngx.log(ngx.ERR, "browser upstream error ", url, ": ",
                err or (res and tostring(res.status) or "nil"))
    end
end

if #combined_data > 0 then
    ngx.header["Content-Type"] = "text/html; charset=utf-8"
    ngx.print(generate_browser_ui(combined_data, ngx.var.sub_id))
else
    ngx.status = ngx.HTTP_BAD_GATEWAY
    ngx.header["Content-Type"] = "text/html; charset=utf-8"
    ngx.print('<html><body style="font-family:sans-serif;text-align:center;margin-top:80px">'
           .. '<h2>Нет данных подписки</h2><p>Проверь sub_id и попробуй снова.</p>'
           .. '</body></html>')
end
