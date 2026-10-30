local ADDON_NAME, ns = ...

ns.VERSION = "0.1.0"
-- Bump when the wire format or the race simulation changes in a way that
-- would make two clients disagree. Clients ignore messages from other versions.
ns.PROTOCOL = 1

_G.HorseBot = ns

local DEFAULTS = {
    settings = {
        scope = "AUTO",               -- AUTO | PARTY | RAID | GUILD | CHANNEL
        channelName = "HorseBotRaces",
        autoJoin = true,              -- join the shared channel on login
        chatAnnounce = true,          -- print race news to the chat frame
        autoWatch = true,             -- open the track when a race you bet on starts
        debug = false,
    },
    hostDefaults = {
        name = "",
        horses = 6,
        furlongs = 6,
        minBet = 10000,               -- 1g
        maxBet = 1000000,             -- 100g
        cut = 0,                      -- house take, percent
        scope = "AUTO",
    },
    races = {},
    ledger = {},
    history = {},
    raceCounter = 0,
}

local function applyDefaults(dst, src)
    for k, v in pairs(src) do
        if dst[k] == nil then
            if type(v) == "table" then
                dst[k] = {}
                applyDefaults(dst[k], v)
            else
                dst[k] = v
            end
        elseif type(v) == "table" and type(dst[k]) == "table" and next(v) then
            applyDefaults(dst[k], v)
        end
    end
end

--------------------------------------------------------------------------------
-- Output
--------------------------------------------------------------------------------

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffd4a017HorseBot|r: " .. tostring(msg))
end

function ns.Debug(...)
    if ns.db and ns.db.settings.debug then
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        ns.Print("|cff888888" .. table.concat(parts, " ") .. "|r")
    end
end

-- Short feedback for the main window's status line; also echoed to chat when
-- the window is closed so the player never misses a rejected bet.
function ns.Status(msg)
    ns.Fire("STATUS", msg)
    if not (ns.UI and ns.UI:IsShown()) then ns.Print(msg) end
end

--------------------------------------------------------------------------------
-- Internal callbacks (module -> UI)
--------------------------------------------------------------------------------

local listeners = {}

function ns.On(event, fn)
    listeners[event] = listeners[event] or {}
    table.insert(listeners[event], fn)
end

function ns.Fire(event, ...)
    local list = listeners[event]
    if not list then return end
    for i = 1, #list do list[i](...) end
end

--------------------------------------------------------------------------------
-- Game events
--------------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local eventHandlers = {}

function ns.RegisterEvent(event, fn)
    if not eventHandlers[event] then
        eventHandlers[event] = {}
        eventFrame:RegisterEvent(event)
    end
    table.insert(eventHandlers[event], fn)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    local list = eventHandlers[event]
    for i = 1, #list do list[i](...) end
end)

local modules = {}

function ns.RegisterModule(module)
    table.insert(modules, module)
end

ns.RegisterEvent("ADDON_LOADED", function(name)
    if name ~= ADDON_NAME then return end
    HorseBotDB = HorseBotDB or {}
    applyDefaults(HorseBotDB, DEFAULTS)
    ns.db = HorseBotDB
    for _, m in ipairs(modules) do
        if m.OnInit then m:OnInit() end
    end
end)

ns.RegisterEvent("PLAYER_LOGIN", function()
    for _, m in ipairs(modules) do
        if m.OnLogin then m:OnLogin() end
    end
end)

local me
function ns.Me()
    if not me then
        local name = UnitName("player")
        local realm = GetNormalizedRealmName and GetNormalizedRealmName()
        if not (realm and realm ~= "") then
            return ns.Util.FullName(name) -- realm not known yet; don't cache
        end
        me = ns.Util.FullName(name, realm)
    end
    return me
end

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

local SCOPES = { auto = "AUTO", party = "PARTY", raid = "RAID", guild = "GUILD", channel = "CHANNEL" }

local function help()
    ns.Print("v" .. ns.VERSION .. " commands:")
    ns.Print("  /hb  - open the race book")
    ns.Print("  /hb host  - set up a new race")
    ns.Print("  /hb ledger  - who owes whom")
    ns.Print("  /hb refresh  - ask hosts nearby for their races")
    ns.Print("  /hb scope auto|party|raid|guild|channel  - where new races are broadcast")
    ns.Print("  /hb channel <name>  - shared channel for races outside your group")
    ns.Print("  /hb autojoin on|off, /hb announce on|off, /hb debug on|off")
end

local function onOff(arg, current)
    if arg == "on" then return true elseif arg == "off" then return false end
    return not current
end

SLASH_HORSEBOT1 = "/hb"
SLASH_HORSEBOT2 = "/horsebot"
SlashCmdList.HORSEBOT = function(input)
    local cmd, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    local s = ns.db.settings
    if cmd == "" or cmd == "show" then
        ns.UI:Toggle()
    elseif cmd == "host" or cmd == "new" then
        ns.UI:ShowHostPanel()
    elseif cmd == "ledger" then
        ns.UI:ShowLedger()
    elseif cmd == "refresh" then
        ns.Races:Discover()
        ns.Print("Asking for open races...")
    elseif cmd == "scope" then
        local scope = SCOPES[rest:lower()]
        if not scope then return ns.Print("Scope must be auto, party, raid, guild or channel.") end
        s.scope = scope
        ns.db.hostDefaults.scope = scope
        ns.Print("New races will be broadcast to: " .. scope)
    elseif cmd == "channel" then
        local name = ns.Util.Clean(rest, 31):gsub("%s", "")
        if name == "" then return ns.Print("Current channel: " .. s.channelName) end
        ns.Comm:SetChannel(name)
        ns.Print("Shared channel is now: " .. name)
    elseif cmd == "autojoin" then
        s.autoJoin = onOff(rest, s.autoJoin)
        if s.autoJoin then ns.Comm:JoinChannel() else ns.Comm:LeaveChannel() end
        ns.Print("Auto-join channel: " .. (s.autoJoin and "on" or "off"))
    elseif cmd == "announce" then
        s.chatAnnounce = onOff(rest, s.chatAnnounce)
        ns.Print("Chat announcements: " .. (s.chatAnnounce and "on" or "off"))
    elseif cmd == "debug" then
        s.debug = onOff(rest, s.debug)
        ns.Print("Debug: " .. (s.debug and "on" or "off"))
    else
        help()
    end
end
