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
			Url=opts.Url, Method=opts.Method,
			Headers=opts.Headers, Body=opts.Body,
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
		Url=url, Method="POST", Headers=getHeaders(),
		Body=HttpService:JSONEncode(payload),
	})
	if not ok then return false, "Network error: "..tostring(res) end
	if res.StatusCode ~= 200 and res.StatusCode ~= 201 then
		return false, "Server error ("..res.StatusCode..")"
	end
	local p, body = pcall(HttpService.JSONDecode, HttpService, res.Body)
	if not p then return false, "Invalid response" end
	return true, body
end

-- ─── HWID ──────────────────────────────────────────────────

local function getHWID()
	local ok, id = pcall(function()
		return game:GetService("RbxAnalyticsService"):GetClientId()
	end)
	return ok and id or tostring(game:GetService("Players").LocalPlayer.UserId)
end

-- ─── INIT ──────────────────────────────────────────────────

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

-- ─── validate ──────────────────────────────────────────────
--[[
  Check if a key is valid. Does NOT activate or set HWID.
  Use redeem() for first-time activation.

  Returns { valid=true } or { valid=false, reason="..." }
]]
function Kuau.validate(key)
	assertInit()
	if not key or key == "" then return { valid=false, reason="No key provided" } end

	local hwid = getHWID()

	local url = _cfg.url.."/rest/v1/kuau_keys"
		.."?select=hwid,expiry,revoked,blacklisted,activated"
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

	-- If activated, enforce HWID
	if r.activated and r.hwid and r.hwid ~= "" then
		if r.hwid ~= hwid then return { valid=false, reason="HWID mismatch" } end
	end

	return { valid=true }
end

-- ─── redeem ────────────────────────────────────────────────
--[[
  First-time activation. Call this when a player enters their key.
  - Validates the key
  - Locks it to the player's HWID via the Edge Function (service key)
  - Marks it as activated
  If already activated, checks HWID matches.

  Returns { valid=true } or { valid=false, reason="..." }
]]
function Kuau.redeem(key)
	assertInit()
	if not key or key == "" then return { valid=false, reason="No key provided" } end

	local hwid = getHWID()

	-- Routes through Edge Function so the service key does the DB write.
	-- Anon key cannot write — this is the correct way to activate.
	local ok, data = httpPost(_cfg.url.."/functions/v1/kuau-serve", {
		action = "redeem",
		key    = key,
		hwid   = hwid,
	})

	if not ok then return { valid=false, reason=data } end
	if not data.valid then return { valid=false, reason=data.reason or "Invalid key" } end

	return {
		valid             = true,
		already_activated = data.already_activated or false,
		hwid              = hwid,
	}
end

-- ─── fetchScript ───────────────────────────────────────────
--[[
  Redeem key + fetch script from private storage in one call.
  Returns { valid=true, script="..." } or { valid=false, reason="..." }
]]
function Kuau.fetchScript(key, scriptName)
	assertInit()
	if not key or key == ""             then return { valid=false, reason="No key provided"    } end
	if not scriptName or scriptName==""  then return { valid=false, reason="No script specified" } end

	local hwid = getHWID()

	local ok, data = httpPost(_cfg.url.."/functions/v1/kuau-serve", {
		key=key, scriptName=scriptName, hwid=hwid
	})

	if not ok          then return { valid=false, reason=data                         } end
	if not data.valid  then return { valid=false, reason=data.reason or "Invalid key" } end
	if not data.script then return { valid=false, reason="No script returned"         } end

	return { valid=true, script=data.script }
end

-- ─── getTime ───────────────────────────────────────────────

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

-- ─── getHWID ───────────────────────────────────────────────
--[[
  Returns the player's HWID and copies it to clipboard.
  Useful so players can send you their HWID if needed.
]]
function Kuau.getHWID()
	local hwid = getHWID()
	local cboard = setclipboard or toclipboard or set_clipboard or (Clipboard and Clipboard.set)
	if cboard then
		pcall(cboard, hwid)
		print("[Kuau] HWID copied to clipboard:", hwid)
	else
		print("[Kuau] HWID:", hwid)
	end
	return hwid
end

return Kuau
