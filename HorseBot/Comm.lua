local _, ns = ...

-- Transport over hidden addon messages (C_ChatInfo.SendAddonMessage).
--
-- Broadcasts go to the group (PARTY/RAID), the GUILD, or a shared custom chat
-- CHANNEL that every client auto-joins, which is what lets players who are not
-- grouped together bet on the same race. Anything aimed at one player (bet
-- requests, sync replies) goes by WHISPER.
--
-- Wire format: "<protocol>^<cmd>^field^field...", at most 255 bytes. Lists
-- (horses, bets) are packed as "a,b,c;a,b,c" and split across as many
-- messages as needed.
local Comm = {
    handlers = {},
    queue = {},
    tokens = 0,
    warned = {},
}
ns.Comm = Comm

local U = ns.Util

local PREFIX = "HorseBot"
local SEP = "^"
local MAX_LEN = 250
-- The server throttles addon messages per prefix; staying under a small
-- burst and roughly one message per second keeps us clear of it.
local BURST, RATE = 8, 1

Comm.PREFIX = PREFIX
Comm.MAX_LEN = MAX_LEN

function Comm:Register(cmd, fn)
    self.handlers[cmd] = fn
end

function Comm:Encode(cmd, ...)
    local parts = { tostring(ns.PROTOCOL), cmd }
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        parts[#parts + 1] = v == nil and "" or tostring(v)
    end
    return table.concat(parts, SEP)
end

--------------------------------------------------------------------------------
-- Sending
--------------------------------------------------------------------------------

-- Resolves a scope setting to a chat type (+ target for CHANNEL).
function Comm:Resolve(scope)
    scope = scope or ns.db.settings.scope
    if scope == "AUTO" then
        if IsInRaid() then return "RAID" end
        if IsInGroup() then return "PARTY" end
        scope = "CHANNEL"
    end
    if scope == "PARTY" or scope == "RAID" then
        -- Either means "my group": follow a party that converts to a raid.
        if IsInRaid() then return "RAID" end
        if IsInGroup() then return "PARTY" end
        return nil, "you are not in a group"
    elseif scope == "GUILD" then
        if IsInGuild() then return "GUILD" end
        return nil, "you are not in a guild"
    elseif scope == "CHANNEL" then
        local id = self:ChannelId()
        if id then return "CHANNEL", id end
        return nil, "not in the '" .. ns.db.settings.channelName .. "' channel yet (/hb autojoin on)"
    end
    return nil, "unknown scope " .. tostring(scope)
end

function Comm:Enqueue(text, chatType, target)
    if #text > 255 then
        ns.Debug("dropping oversized message", text:sub(1, 40))
        return
    end
    self.queue[#self.queue + 1] = { text = text, chatType = chatType, target = target }
    self:Pump()
end

-- Splits `items` across as many "<cmd>^<head...>^item;item" messages as needed.
function Comm:SendList(chatType, target, cmd, head, items)
    local prefix = self:Encode(cmd, unpack(head)) .. SEP
    local chunk = {}
    local len = #prefix
    for _, item in ipairs(items) do
        if #chunk > 0 and len + 1 + #item > MAX_LEN then
            self:Enqueue(prefix .. table.concat(chunk, ";"), chatType, target)
            chunk, len = {}, #prefix
        end
        chunk[#chunk + 1] = item
        len = len + #item + (#chunk > 1 and 1 or 0)
    end
    if #chunk > 0 then
        self:Enqueue(prefix .. table.concat(chunk, ";"), chatType, target)
    end
end

local function isThrottled(result)
    local enum = Enum and Enum.SendAddonMessageResult
    return enum and result == enum.AddonMessageThrottle
end

local function failed(result)
    if result == false then return true end
    local enum = Enum and Enum.SendAddonMessageResult
    return type(result) == "number" and enum and result ~= enum.Success
end

function Comm:Pump()
    local now = GetTime()
    self.tokens = math.min(BURST, self.tokens + (now - (self.lastRefill or now)) * RATE)
    self.lastRefill = now
    while self.tokens >= 1 and #self.queue > 0 do
        local m = table.remove(self.queue, 1)
        local result = C_ChatInfo.SendAddonMessage(PREFIX, m.text, m.chatType, m.target)
        if isThrottled(result) then
            table.insert(self.queue, 1, m)
            self.tokens = 0
            return
        end
        if failed(result) then
            ns.Debug("send failed", m.chatType, tostring(m.target), tostring(result))
        end
        self.tokens = self.tokens - 1
    end
end

--------------------------------------------------------------------------------
-- Receiving
--------------------------------------------------------------------------------

function Comm:OnAddonMessage(prefix, text, channel, sender)
    if prefix ~= PREFIX then return end
    sender = U.FullName(sender)
    if not sender or sender == ns.Me() then return end
    local fields = U.Split(text, SEP)
    local version = tonumber(fields[1])
    if version ~= ns.PROTOCOL then
        if version and version > ns.PROTOCOL and not self.warned[sender] then
            self.warned[sender] = true
            ns.Print(U.ShortName(sender) .. " is using a newer HorseBot. Update to join their races.")
        end
        return
    end
    local handler = self.handlers[fields[2]]
    if not handler then return end
    ns.Debug("recv", channel, U.ShortName(sender), text)
    local ok, err = pcall(handler, sender, channel, unpack(fields, 3))
    if not ok then
        local onError = geterrorhandler and geterrorhandler()
        if onError then onError(err) else error(err) end
    end
end

--------------------------------------------------------------------------------
-- Shared channel
--------------------------------------------------------------------------------

function Comm:ChannelId()
    local id = GetChannelName(ns.db.settings.channelName)
    if id and id > 0 then return id end
end

local function hideChannel(name)
    if not ChatFrame_RemoveChannel then return end
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local frame = _G["ChatFrame" .. i]
        if frame then ChatFrame_RemoveChannel(frame, name) end
    end
end

function Comm:JoinChannel()
    local name = ns.db.settings.channelName
    if not self:ChannelId() then
        JoinTemporaryChannel(name)
    end
    -- Joining is asynchronous; give the server a moment before using it.
    C_Timer.After(2, function()
        if self:ChannelId() then
            hideChannel(name)
            ns.Fire("CHANNEL_READY")
        end
    end)
end

function Comm:LeaveChannel()
    if self:ChannelId() then LeaveChannelByName(ns.db.settings.channelName) end
end

function Comm:SetChannel(name)
    self:LeaveChannel()
    ns.db.settings.channelName = name
    if ns.db.settings.autoJoin then self:JoinChannel() end
end

function Comm:OnLogin()
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    ns.RegisterEvent("CHAT_MSG_ADDON", function(...) self:OnAddonMessage(...) end)
    self.lastRefill = GetTime()
    self.tokens = BURST
    C_Timer.NewTicker(0.25, function()
        if #self.queue > 0 then self:Pump() end
    end)
    if ns.db.settings.autoJoin then
        -- Joining before the default channels (General, Trade...) would steal
        -- their numbers, so wait until those are in place.
        C_Timer.After(10, function() self:JoinChannel() end)
    end
end

ns.RegisterModule(Comm)
