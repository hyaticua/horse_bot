-- A tiny stand-in for the WoW client, good enough to run several copies of
-- the addon side by side in plain Lua 5.1 and pass addon messages between
-- them. Each client gets its own global environment (setfenv), saved
-- variables, timers and chat channels; the World owns the clock and the
-- message bus.

local World = {}
World.__index = World

local ADDON = "HorseBot"
local ADDON_DIR = (arg and arg[0] and arg[0]:match("^(.*)/tests/") or ".") .. "/HorseBot/"
local FILES = { "Util.lua", "Core.lua", "Horses.lua", "Sim.lua", "Ledger.lua", "Comm.lua", "Races.lua", "UI.lua" }

function World.new()
    return setmetatable({ now = 1000, clients = {}, inflight = {}, timers = {}, sent = {}, latency = 0.05 }, World)
end

--------------------------------------------------------------------------------
-- Frames: every method exists; unknown ones do nothing and return a stub
--------------------------------------------------------------------------------

local Stub = {}
local StubMT

local function newStub(client)
    return setmetatable({ _client = client, _scripts = {}, _events = {}, _shown = true, _text = "" }, StubMT)
end

local methods = {
    RegisterEvent = function(self, e) self._events[e] = true end,
    UnregisterEvent = function(self, e) self._events[e] = nil end,
    SetScript = function(self, name, fn) self._scripts[name] = fn end,
    GetScript = function(self, name) return self._scripts[name] end,
    Show = function(self)
        local was = self._shown
        self._shown = true
        if not was and self._scripts.OnShow then self._scripts.OnShow(self) end
    end,
    Hide = function(self) self._shown = false end,
    IsShown = function(self) return self._shown end,
    SetShown = function(self, v) if v then self:Show() else self:Hide() end end,
    SetText = function(self, t) self._text = t end,
    GetText = function(self) return self._text end,
    CreateTexture = function(self) return newStub(self._client) end,
    CreateFontString = function(self) return newStub(self._client) end,
}

StubMT = {
    __index = function(_, k)
        return methods[k] or function() return nil end
    end,
}
Stub.new = newStub

--------------------------------------------------------------------------------
-- Clients
--------------------------------------------------------------------------------

local Client = {}
Client.__index = Client

function World:AddClient(name, opts)
    opts = opts or {}
    local c = setmetatable({
        world = self, name = name, realm = opts.realm or "Testrealm",
        guild = opts.guild, group = opts.group, channels = {},
        log = {}, saved = opts.saved, online = false,
    }, Client)
    c.full = name .. "-" .. c.realm
    self.clients[#self.clients + 1] = c
    return c
end

function World:Find(fullName)
    for _, c in ipairs(self.clients) do
        if c.online and c.full == fullName then return c end
    end
end

function Client:BuildEnv()
    local c, world = self, self.world
    local env = setmetatable({}, { __index = _G })
    env._G = env
    self.frames = {}
    self.env = env

    env.CreateFrame = function(_, name)
        local f = newStub(c)
        f._shown = true
        c.frames[#c.frames + 1] = f
        if name then env[name] = f end
        return f
    end
    env.UIParent = newStub(c)
    env.GameTooltip = newStub(c)
    env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) c.log[#c.log + 1] = msg end }
    env.UISpecialFrames = {}
    env.StaticPopupDialogs = {}
    env.StaticPopup_Show = function() end
    env.SlashCmdList = {}
    env.tinsert = table.insert
    env.tContains = function(t, v)
        for _, x in ipairs(t) do if x == v then return true end end
        return false
    end
    env.GameTooltip_Hide = function() end
    env.YES, env.NO = "Yes", "No"
    env.ERR_TRADE_COMPLETE = "Trade complete."
    env.NUM_CHAT_WINDOWS = 10
    env.ChatFrame_RemoveChannel = function() end
    env.geterrorhandler = function() return function(err) error(err, 0) end end
    env.Enum = { SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3 } }

    env.GetTime = function() return world.now end
    env.time = function() return 1700000000 + math.floor(world.now) end
    env.UnitName = function(unit)
        if unit == "player" then return c.name end
        if unit == "NPC" and c.tradePartner then return c.tradePartner.name, c.tradePartner.realm end
    end
    env.GetNormalizedRealmName = function() return c.realm end
    env.Ambiguate = function(n) return (n:match("^[^-]+")) end
    env.IsInGroup = function() return c.group ~= nil end
    env.IsInRaid = function() return false end
    env.IsInGuild = function() return c.guild ~= nil end
    env.GetChannelName = function(name)
        local id = c.channels[name:lower()]
        return id or 0, id and name or nil
    end
    env.JoinTemporaryChannel = function(name)
        c.channels[name:lower()] = 5
    end
    env.LeaveChannelByName = function(name) c.channels[name:lower()] = nil end
    env.SendChatMessage = function(msg, chatType)
        assert(#msg <= 255, "chat line too long")
        c.chat = c.chat or {}
        c.chat[#c.chat + 1] = { msg = msg, chatType = chatType }
    end
    env.GetTargetTradeMoney = function() return c.tradeTheirs or 0 end
    env.GetPlayerTradeMoney = function() return c.tradeMine or 0 end

    env.C_Timer = {
        After = function(delay, fn) world:AddTimer(c, delay, fn) end,
        NewTicker = function(delay, fn)
            local ticker = { cancelled = false }
            function ticker:Cancel() self.cancelled = true end
            local function tick()
                if ticker.cancelled or not c.online or c.env ~= env then return end
                fn()
                world:AddTimer(c, delay, tick)
            end
            world:AddTimer(c, delay, tick)
            return ticker
        end,
    }
    env.C_ChatInfo = {
        RegisterAddonMessagePrefix = function(p) c.prefix = p; return true end,
        SendAddonMessage = function(prefix, text, chatType, target)
            return world:Send(c, prefix, text, chatType, target)
        end,
    }
    return env
end

function Client:Login()
    local env = self:BuildEnv()
    env.HorseBotDB = self.saved
    self.ns = {}
    for _, file in ipairs(FILES) do
        local chunk = assert(loadfile(ADDON_DIR .. file))
        setfenv(chunk, env)
        chunk(ADDON, self.ns)
    end
    self.online = true
    self:Fire("ADDON_LOADED", ADDON)
    self:Fire("PLAYER_LOGIN")
    return self
end

-- Simulates /reload: saved variables survive, everything else is rebuilt.
function Client:Reload()
    self.saved = self.env.HorseBotDB
    self.online = false
    self.channels = {}
    return self:Login()
end

function Client:Logout()
    self.saved = self.env.HorseBotDB
    self.online = false
    self.channels = {}
end

function Client:Fire(event, ...)
    for _, f in ipairs(self.frames) do
        if f._events[event] and f._scripts.OnEvent then
            f._scripts.OnEvent(f, event, ...)
        end
    end
end

function Client:Trade(partner, theirs, mine)
    self.tradePartner = partner
    self:Fire("TRADE_SHOW")
    self.tradeTheirs, self.tradeMine = theirs, mine
    self:Fire("TRADE_MONEY_CHANGED")
    self:Fire("TRADE_ACCEPT_UPDATE", 1, 1)
    self:Fire("TRADE_CLOSED")
    self:Fire("UI_INFO_MESSAGE", 0, "Trade complete.")
    self.tradePartner, self.tradeTheirs, self.tradeMine = nil, nil, nil
end

function Client:Printed(pattern)
    for _, line in ipairs(self.log) do
        if line:find(pattern) then return true end
    end
    return false
end

--------------------------------------------------------------------------------
-- Bus and clock
--------------------------------------------------------------------------------

function World:AddTimer(client, delay, fn)
    self.timers[#self.timers + 1] = { at = self.now + delay, fn = fn, client = client, env = client.env }
end

local VALID = { PARTY = true, RAID = true, GUILD = true, WHISPER = true, CHANNEL = true }

function World:Send(c, prefix, text, chatType, target)
    assert(prefix == c.prefix, "prefix not registered")
    assert(#text <= 255, "addon message over 255 bytes: " .. #text)
    assert(VALID[chatType], "bad chat type " .. tostring(chatType))
    self.sent[#self.sent + 1] = { from = c, at = self.now, text = text, chatType = chatType }

    local recipients = {}
    if chatType == "WHISPER" then
        local to = self:Find(target)
        if to then recipients[1] = to end
    else
        local channelName
        if chatType == "CHANNEL" then
            for name, id in pairs(c.channels) do if id == target then channelName = name end end
            assert(channelName, "CHANNEL message to a channel the sender is not in")
        end
        for _, other in ipairs(self.clients) do
            if other.online then
                local hit = (chatType == "PARTY" or chatType == "RAID") and c.group and other.group == c.group
                    or chatType == "GUILD" and c.guild and other.guild == c.guild
                    or chatType == "CHANNEL" and other.channels[channelName] ~= nil
                if hit then recipients[#recipients + 1] = other end
            end
        end
    end
    for _, to in ipairs(recipients) do
        if not (self.drop and self.drop(to, text, chatType)) then
            self.inflight[#self.inflight + 1] = {
            at = self.now + self.latency, to = to, env = to.env,
            args = { prefix, text, chatType, c.full },
        }
        end
    end
    return 0
end

function World:Advance(seconds, step)
    step = step or 0.05
    local stop = self.now + seconds
    while self.now < stop - 1e-9 do
        self.now = self.now + step
        local progressed = true
        while progressed do
            progressed = false
            local i = 1
            while i <= #self.inflight do
                local m = self.inflight[i]
                if m.at <= self.now then
                    table.remove(self.inflight, i)
                    if m.to.online and m.to.env == m.env then
                        m.to:Fire("CHAT_MSG_ADDON", unpack(m.args))
                    end
                    progressed = true
                else
                    i = i + 1
                end
            end
            table.sort(self.timers, function(a, b) return a.at < b.at end)
            while self.timers[1] and self.timers[1].at <= self.now do
                local t = table.remove(self.timers, 1)
                -- Timers die with the session (logout or reload) that made them.
                if t.client.online and t.client.env == t.env then t.fn() end
                progressed = true
            end
        end
    end
end

World.Stub = Stub
return World
