local _, ns = ...

local Util = {}
ns.Util = Util

local floor = math.floor

--------------------------------------------------------------------------------
-- Deterministic PRNG
--
-- Park-Miller "minimal standard" generator. Every intermediate value stays
-- below 2^53, so the arithmetic is exact in Lua's doubles and every client
-- produces the identical sequence from the same seed. math.random is shared
-- with every other addon and cannot be relied on for that.
--------------------------------------------------------------------------------

local MODULUS, MULTIPLIER = 2147483647, 16807
Util.SEED_MAX = MODULUS - 1

local RNG = {}
RNG.__index = RNG

function Util.NewRNG(seed)
    seed = floor(tonumber(seed) or 1) % MODULUS
    if seed <= 0 then seed = seed + MODULUS - 1 end
    return setmetatable({ state = seed }, RNG)
end

function RNG:Next()
    self.state = (self.state * MULTIPLIER) % MODULUS
    return self.state
end

-- Uniform integer in [lo, hi].
function RNG:Int(lo, hi)
    return lo + self:Next() % (hi - lo + 1)
end

function Util.RandomSeed()
    local t = GetTime and floor(GetTime() * 1000) or 0
    return (math.random(1, MODULUS - 2) + t) % (MODULUS - 1) + 1
end

--------------------------------------------------------------------------------
-- Strings
--------------------------------------------------------------------------------

-- Plain (non-pattern) split that keeps empty fields.
function Util.Split(s, sep)
    local out, start = {}, 1
    while true do
        local i = string.find(s, sep, start, true)
        if not i then
            out[#out + 1] = string.sub(s, start)
            return out
        end
        out[#out + 1] = string.sub(s, start, i - 1)
        start = i + #sep
    end
end

-- Strips the protocol's delimiter characters and WoW escape sequences from
-- user-provided text so it can be embedded in an addon message.
function Util.Clean(s, maxLen)
    s = tostring(s or "")
    s = s:gsub("[%^;,|%c]", "")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if maxLen and #s > maxLen then
        -- Drop a trailing partial UTF-8 sequence left behind by the cut.
        s = s:sub(1, maxLen):gsub("[\192-\255][\128-\191]*$", "")
    end
    return s
end

--------------------------------------------------------------------------------
-- Money (all amounts are integer copper)
--------------------------------------------------------------------------------

local GOLD, SILVER, COPPER = "|cffffd700g|r", "|cffc7c7cfs|r", "|cffeda55fc|r"

function Util.FormatMoney(copper, plain)
    copper = floor(copper or 0)
    local sign = ""
    if copper < 0 then sign, copper = "-", -copper end
    local g, s, c = floor(copper / 10000), floor(copper / 100) % 100, copper % 100
    local gs, ss, cs = GOLD, SILVER, COPPER
    if plain then gs, ss, cs = "g", "s", "c" end
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. gs end
    if s > 0 then parts[#parts + 1] = s .. ss end
    if c > 0 or #parts == 0 then parts[#parts + 1] = c .. cs end
    return sign .. table.concat(parts, " ")
end

-- Accepts "12", "12.5" (gold), "12g", "12g 50s", "50s 25c", ...
function Util.ParseMoney(text)
    text = tostring(text or ""):lower():gsub("%s+", "")
    if text == "" then return nil end
    local n = tonumber(text)
    if n then
        if n < 0 then return nil end
        return floor(n * 10000 + 0.5)
    end
    local total, matched = 0, false
    local rest = text:gsub("(%d+%.?%d*)([gsc])", function(num, unit)
        matched = true
        local mult = unit == "g" and 10000 or unit == "s" and 100 or 1
        total = total + tonumber(num) * mult
        return ""
    end)
    if not matched or rest ~= "" then return nil end
    return floor(total + 0.5)
end

-- Odds expressed "to 1", e.g. 3.5 -> "3.5-1".
function Util.FormatOdds(oddsToOne)
    if not oddsToOne then return "--" end
    if oddsToOne < 0 then oddsToOne = 0 end
    if oddsToOne >= 10 then return string.format("%d-1", floor(oddsToOne + 0.5)) end
    return string.format("%.1f-1", oddsToOne)
end

--------------------------------------------------------------------------------
-- Player names
--
-- CHAT_MSG_ADDON reports senders as "Name-Realm"; everything internal uses
-- that form so the same player is never tracked under two keys.
--------------------------------------------------------------------------------

function Util.FullName(name, realm)
    if not name or name == "" then return nil end
    if name:find("-", 1, true) then return name end
    if not realm or realm == "" then
        realm = GetNormalizedRealmName and GetNormalizedRealmName()
    end
    if realm and realm ~= "" then return name .. "-" .. realm:gsub("[%s%-]", "") end
    return name
end

function Util.ShortName(name)
    if not name then return "?" end
    if Ambiguate then return Ambiguate(name, "short") end
    return (name:match("^[^-]+")) or name
end

function Util.Clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end
