--  kuau.luau — host publicly on GitHub (raw URL)
--  DO NOT put credentials here. They are passed in by loader.

local Kuau = {}
local _cfg = { url = "", anon = "" }

local HttpService = (cloneref or function(x) return x end)(game:GetService("HttpService"))

local function httpRequest(opts)
	if syn and syn.request then
		return syn.request(opts)
	elseif http_request then
		return http_request(opts)
	elseif http and http.request then
		return http.request(opts)
	elseif request then
		return request(opts)
	else
		return HttpService:RequestAsync({
			Url     = opts.Url,
			Method  = opts.Method,
			Headers = opts.Headers,
			Body    = opts.Body,
		})
	end
end

local function getHeaders()
	return {
		["apikey"]        = _cfg.anon,
		["Authorization"] = "Bearer " .. _cfg.anon,
		["Content-Type"]  = "application/json",
	}
end

local function urlEncode(str)
	return (str:gsub("([^%w%-%.%_%~ ])", function(c)
		return string.format("%%%02X", string.byte(c))
	end):gsub(" ", "+"))
end

local function parseISO8601(str)
	if not str then return nil end
	local y, mo, d, h, mi, s = str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
	if not y then return nil end
	return os.time({ year=tonumber(y), month=tonumber(mo), day=tonumber(d),
	                 hour=tonumber(h), min=tonumber(mi), sec=tonumber(s) })
end

local function httpGet(url)
	local ok, res = pcall(httpRequest, { Url=url, Method="GET", Headers=getHeaders() })
	if not ok then return false, "Network error: "..tostring(res) end
	if res.StatusCode ~= 200 then return false, "Server error ("..res.StatusCode..")" end
	local p, body = pcall(HttpService.JSONDecode, HttpService, res.Body)
	if not p then return false, "Invalid response" end
	return true, body
end

local function httpPost(url, payload)
	local ok, res = pcall(httpRequest, {
		Url     = url,
		Method  = "POST",
		Headers = getHeaders(),
		Body    = HttpService:JSONEncode(payload),
	})
	if not ok then return false, "Network error: "..tostring(res) end
	if res.StatusCode ~= 200 and res.StatusCode ~= 201 then
		return false, "Server error ("..res.StatusCode..")"
	end
	local p, body = pcall(HttpService.JSONDecode, HttpService, res.Body)
	if not p then return false, "Invalid response" end
	return true, body
end

function Kuau.init(cfg)
	assert(type(cfg) == "table",        "[Kuau] init() expects a table")
	assert(cfg.url  and cfg.url  ~= "", "[Kuau] missing url")
	assert(cfg.anon and cfg.anon ~= "", "[Kuau] missing anon key")
	_cfg.url  = cfg.url
	_cfg.anon = cfg.anon
end

local function assertInit()
	assert(_cfg.url ~= "", "[Kuau] Call Kuau.init() before using Kuau.")
end

function Kuau.validate(key, hwid)
	assertInit()
	if not key or key == "" then return { valid=false, reason="No key provided" } end

	local url = _cfg.url.."/rest/v1/kuau_keys"
		.."?select=hwid,expiry,revoked,blacklisted"
		.."&key=eq."..urlEncode(key)
		.."&limit=1"

	local ok, data = httpGet(url)
	if not ok then return { valid=false, reason=data } end
	if type(data) ~= "table" or #data == 0 then return { valid=false, reason="Key not found" } end

	local r = data[1]
	if r.blacklisted then return { valid=false, reason="Key is blacklisted"  } end
	if r.revoked     then return { valid=false, reason="Key has been revoked" } end

	if r.expiry then
		local t = parseISO8601(r.expiry)
		if t and os.time() > t then return { valid=false, reason="Key has expired" } end
	end

	if r.hwid and r.hwid ~= "" then
		if not hwid or hwid == "" then return { valid=false, reason="HWID required" } end
		if r.hwid ~= hwid         then return { valid=false, reason="HWID mismatch" } end
	end

	return { valid=true }
end

function Kuau.fetchScript(key, scriptName, hwid)
	assertInit()
	if not key or key == ""             then return { valid=false, reason="No key provided"    } end
	if not scriptName or scriptName==""  then return { valid=false, reason="No script specified" } end

	local ok, data = httpPost(_cfg.url.."/functions/v1/kuau-serve", {
		key=key, scriptName=scriptName, hwid=hwid or ""
	})

	if not ok          then return { valid=false, reason=data                         } end
	if not data.valid  then return { valid=false, reason=data.reason or "Invalid key" } end
	if not data.script then return { valid=false, reason="No script returned"         } end

	return { valid=true, script=data.script }
end

function Kuau.getTime(key)
	assertInit()
	if not key or key == "" then return { error="No key provided" } end

	local url = _cfg.url.."/rest/v1/kuau_keys"
		.."?select=expiry,revoked,blacklisted"
		.."&key=eq."..urlEncode(key)
		.."&limit=1"

	local ok, data = httpGet(url)
	if not ok or type(data)~="table" or #data==0 then return { error="Key not found" } end

	local r = data[1]
	if r.blacklisted or r.revoked then return { error="Key is not active" } end
	if not r.expiry then return { permanent=true } end

	local expireTime = parseISO8601(r.expiry)
	if not expireTime then return { error="Could not parse expiry" } end

	local rem = expireTime - os.time()
	if rem <= 0 then return { expired=true } end

	return {
		days=math.floor(rem/86400), hours=math.floor((rem%86400)/3600),
		minutes=math.floor((rem%3600)/60), seconds=rem%60, total_seconds=rem,
	}
end

return Kuau
