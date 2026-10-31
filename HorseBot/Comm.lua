local _, ns = ...

-- Transport over hidden addon messages (C_ChatInfo.SendAddonMessage).
--
-- Broadcasts go to the group (PARTY/RAID/INSTANCE_CHAT), the GUILD, or a
-- shared custom chat CHANNEL that every client auto-joins, which is what lets
-- players who are not grouped together bet on the same race. Anything aimed
-- at one player (bet requests, sync replies) goes by WHISPER.
--
-- Wire format: "<protocol>^<cmd>^field^field...", at most 255 bytes. Lists
-- (horses, bets) are packed as "a,b,c;a,b,c" and split across as many
-- messages as needed.
--
-- On the mainline client (WoW Forever, Midnight) addons may not send chat or
-- addon messages, or touch chat channels, during boss encounters, Mythic+ and
-- PvP matches. The queue simply holds everything until that lockdown lifts.
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
-- The server throttles addon messages per prefix (and custom channels
-- separately); a small burst and roughly one message per second stays clear.
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

-- True while the client forbids sending (mainline only).
function Comm:Locked()
    return C_ChatInfo.InChatMessagingLockdown ~= nil and C_ChatInfo.InChatMessagingLockdown() == true
end

Comm.LOCKED_MSG = "Chat is locked during boss encounters, Mythic+ and PvP matches. Try again afterwards."

--------------------------------------------------------------------------------
-- Sending
--------------------------------------------------------------------------------

local HOME, INSTANCE = LE_PARTY_CATEGORY_HOME, LE_PARTY_CATEGORY_INSTANCE

local function groupChat()
    if IsInRaid(HOME) then return "RAID" end
    if IsInGroup(HOME) then return "PARTY" end
    if INSTANCE and IsInGroup(INSTANCE) then return "INSTANCE_CHAT" end
end

-- Resolves a scope setting to a chat type (+ target for CHANNEL).
function Comm:Resolve(scope)
    scope = scope or ns.db.settings.scope
    if scope == "AUTO" then
        local group = groupChat()
        if group then return group end
        scope = "CHANNEL"
    end
    if scope == "PARTY" or scope == "RAID" then
        -- Either means "my group": follow a party that converts to a raid.
        local group = groupChat()
        if group then return group end
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

-- onFail(reason) is called if the client refuses the message for good:
-- "offline" (whisper target not online) or "refused".
function Comm:Enqueue(text, chatType, target, onFail)
    if #text > 255 then
        ns.Debug("dropping oversized message", text:sub(1, 40))
        return
    end
    self.queue[#self.queue + 1] = { text = text, chatType = chatType, target = target, onFail = onFail }
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

-- Send results. Older clients return a boolean; newer ones an enum whose
-- members have changed spelling over time, so both forms are accepted.
local function resultIs(result, ...)
    local enum = Enum and Enum.SendAddonMessageResult
    if not enum or type(result) ~= "number" then return false end
    for i = 1, select("#", ...) do
        local v = enum[(select(i, ...))]
        if v ~= nil and result == v then return true end
    end
    return false
end

local function succeeded(result)
    if result == nil or result == true then return true end
    if result == false then return false end
    return resultIs(result, "Success")
end

function Comm:Pump()
    local now = GetTime()
    self.tokens = math.min(BURST, self.tokens + (now - (self.lastRefill or now)) * RATE)
    self.lastRefill = now
    if self:Locked() then return end
    while self.tokens >= 1 and #self.queue > 0 do
        local m = table.remove(self.queue, 1)
        local result = C_ChatInfo.SendAddonMessage(PREFIX, m.text, m.chatType, m.target)
        if resultIs(result, "AddonMessageThrottle", "AddOnMessageThrottle", "ChannelThrottle") then
            table.insert(self.queue, 1, m)
            self.tokens = 0
            return
        elseif resultIs(result, "AddOnMessageLockdown", "AddonMessageLockdown") then
            -- The lockdown began before InChatMessagingLockdown said so.
            table.insert(self.queue, 1, m)
            return
        elseif resultIs(result, "TargetOffline") then
            if m.onFail then m.onFail("offline") end
        elseif not succeeded(result) then
            ns.Debug("send refused", m.chatType, tostring(m.target), tostring(result))
            if m.onFail then m.onFail("refused") end
        end
        self.tokens = self.tokens - 1
    end
end

--------------------------------------------------------------------------------
-- Receiving
--------------------------------------------------------------------------------

function Comm:OnAddonMessage(prefix, text, channel, sender)
    -- Secret values (mainline) can be shown but not inspected; nothing in
    -- one could be used anyway. Whatever is missed is resynced later.
    if issecretvalue and (issecretvalue(prefix) or issecretvalue(text) or issecretvalue(sender)) then return end
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

-- Keeps the channel out of the chat windows. The function for this differs
-- between clients, and it is cosmetic, so failures are ignored.
local function hideChannel(name)
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local frame = _G["ChatFrame" .. i]
        if frame then
            if ChatFrame_RemoveChannel then
                pcall(ChatFrame_RemoveChannel, frame, name)
            elseif frame.RemoveChannel then
                pcall(frame.RemoveChannel, frame, name)
            elseif RemoveChatWindowChannel then
                pcall(RemoveChatWindowChannel, i, name)
            end
        end
    end
end

function Comm:JoinChannel()
    if self:Locked() then
        self.joinPending = true -- channel APIs are blocked too; retried by the ticker
        return
    end
    self.joinPending = nil
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
    self.joinPending = nil
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
        if self.joinPending and not self:Locked() then self:JoinChannel() end
        if #self.queue > 0 then self:Pump() end
    end)
    if ns.db.settings.autoJoin then
        -- Joining before the default channels (General, Trade...) would steal
        -- their numbers, so wait until those are in place.
        C_Timer.After(10, function() self:JoinChannel() end)
    end

    -- Starter and Veteran accounts are restricted from sending addon messages
    -- on the mainline client; say so up front rather than let bets time out.
    if (IsTrialAccount and IsTrialAccount()) or (IsVeteranTrialAccount and IsVeteranTrialAccount()) then
        C_Timer.After(12, function()
            ns.Print("Starter and Veteran accounts may not be allowed to send addon messages. "
                .. "You can follow races, but your bets or races may not reach anyone.")
        end)
    end
end

ns.RegisterModule(Comm)
