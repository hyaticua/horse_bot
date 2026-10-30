local _, ns = ...

local U, Races, Sim, Horses, Ledger = ns.Util, ns.Races, ns.Sim, ns.Horses, ns.Ledger

local UI = {}
ns.UI = UI

local HORSE_ICON = "Interface\\Icons\\Ability_Mount_RidingHorse"
local STATE_COLORS = {
    OPEN = "|cff40ff40", CLOSED = "|cffffd040", RUNNING = "|cff40c0ff",
    FINISHED = "|cffa0a0a0", CANCELLED = "|cffff5050",
}

local function colorState(state)
    return (STATE_COLORS[state] or "|cffffffff") .. (state or "?") .. "|r"
end

--------------------------------------------------------------------------------
-- Widget helpers
--------------------------------------------------------------------------------

local function Text(parent, template, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    fs:SetJustifyH(justify or "LEFT")
    return fs
end

local function Button(parent, label, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end

local function Input(parent, width)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(width, 20)
    e:SetAutoFocus(false)
    e:SetScript("OnEscapePressed", e.ClearFocus)
    e:SetScript("OnEnterPressed", e.ClearFocus)
    return e
end

local function Window(name, title, width, height)
    local f = CreateFrame("Frame", name, UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(width, height)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f.title = Text(f, "GameFontHighlight", "CENTER")
    f.title:SetPoint("TOP", 0, -5)
    f.title:SetText(title)
    tinsert(UISpecialFrames, name)
    f:Hide()
    return f
end

local function Tooltip(owner, lines)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    for i, line in ipairs(lines) do
        if i == 1 then GameTooltip:SetText(line) else GameTooltip:AddLine(line, 1, 1, 1, true) end
    end
    GameTooltip:Show()
end

local function compactMoney(copper)
    if copper >= 10000 then
        local g = copper / 10000
        return (g == math.floor(g) and string.format("%dg", g) or string.format("%.1fg", g))
    end
    return U.FormatMoney(copper, true)
end

--------------------------------------------------------------------------------
-- Race book (main window)
--------------------------------------------------------------------------------

local MAIN_W, MAIN_H = 610, 450
local LIST_ROWS = 8
local main, selectedId

local COLUMNS = { -- x offset, width, header, justify
    { 16, 108, "Horse" }, { 126, 26, "SPD", "CENTER" }, { 154, 26, "STA", "CENTER" },
    { 182, 26, "CON", "CENTER" }, { 210, 24, "RUN", "CENTER" }, { 236, 40, "ML", "RIGHT" },
    { 280, 40, "Tote", "RIGHT" }, { 324, 36, "Mine", "RIGHT" },
}

local function selectedRace()
    return selectedId and Races:Get(selectedId)
end

local function createListRow(parent, i)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(168, 32)
    row:SetPoint("TOPLEFT", 14, -50 - (i - 1) * 34)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.name = Text(row, "GameFontNormalSmall")
    row.name:SetPoint("TOPLEFT", 6, -4)
    row.name:SetPoint("RIGHT", -4, 0)
    row.info = Text(row, "GameFontHighlightSmall")
    row.info:SetPoint("BOTTOMLEFT", 6, 4)
    row.info:SetPoint("RIGHT", -4, 0)
    row:SetScript("OnClick", function(self)
        selectedId = self.raceId
        UI:Refresh()
    end)
    return row
end

local function createHorseRow(parent, i)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(406, 20)
    row:SetPoint("TOPLEFT", 194, -124 - (i - 1) * 21)
    row:EnableMouse(true)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.04 or 0.08)
    row.swatch = row:CreateTexture(nil, "ARTWORK")
    row.swatch:SetSize(10, 14)
    row.swatch:SetPoint("LEFT", 2, 0)
    row.cols = {}
    for c, col in ipairs(COLUMNS) do
        local fs = Text(row, "GameFontHighlightSmall", col[4])
        fs:SetPoint("LEFT", col[1], 0)
        fs:SetWidth(col[2])
        fs:SetWordWrap(false)
        row.cols[c] = fs
    end
    row.bet = Button(row, "Bet", 42, function() UI:BetOn(i) end)
    row.bet:SetHeight(18)
    row.bet:SetPoint("RIGHT", -2, 0)
    row:SetScript("OnEnter", function(self) UI:HorseTooltip(self, i) end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    return row
end

function UI:CreateMain()
    main = Window("HorseBotFrame", "HorseBot - Race Book", MAIN_W, MAIN_H)

    local header = Text(main, "GameFontNormal")
    header:SetPoint("TOPLEFT", 16, -32)
    header:SetText("Races")

    main.list = {}
    for i = 1, LIST_ROWS do main.list[i] = createListRow(main, i) end
    main.empty = Text(main, "GameFontDisableSmall")
    main.empty:SetPoint("TOPLEFT", 20, -56)
    main.empty:SetWidth(160)
    main.empty:SetText("No races yet.\n\nHost one, or wait for someone nearby to open one.")

    local host = Button(main, "Host a race", 168, function() UI:ShowHostPanel() end)
    host:SetPoint("BOTTOMLEFT", 14, 40)
    local ledger = Button(main, "Ledger", 82, function() UI:ShowLedger() end)
    ledger:SetPoint("BOTTOMLEFT", 14, 14)
    local refresh = Button(main, "Refresh", 84, function()
        Races:Discover()
        ns.Status("Asked nearby hosts for their races.")
    end)
    refresh:SetPoint("LEFT", ledger, "RIGHT", 2, 0)

    -- Detail panel
    main.title = Text(main, "GameFontNormalLarge")
    main.title:SetPoint("TOPLEFT", 196, -32)
    main.title:SetPoint("RIGHT", -16, 0)
    main.info = Text(main, "GameFontHighlightSmall")
    main.info:SetPoint("TOPLEFT", 196, -56)
    main.info:SetPoint("RIGHT", -16, 0)
    main.pool = Text(main, "GameFontHighlightSmall")
    main.pool:SetPoint("TOPLEFT", 196, -74)
    main.pool:SetPoint("RIGHT", -16, 0)

    main.colHeaders = CreateFrame("Frame", nil, main)
    main.colHeaders:SetSize(406, 16)
    main.colHeaders:SetPoint("TOPLEFT", 194, -104)
    for _, col in ipairs(COLUMNS) do
        local fs = Text(main.colHeaders, "GameFontNormalSmall", col[4])
        fs:SetPoint("LEFT", col[1], 0)
        fs:SetWidth(col[2])
        fs:SetText(col[3])
    end

    main.rows = {}
    for i = 1, Horses.MAX do main.rows[i] = createHorseRow(main, i) end

    main.stakeLabel = Text(main, "GameFontNormalSmall")
    main.stakeLabel:SetPoint("TOPLEFT", 196, -302)
    main.stakeLabel:SetText("Stake")
    main.stake = Input(main, 80)
    main.stake:SetPoint("LEFT", main.stakeLabel, "RIGHT", 10, 0)
    main.stake:SetText("1")
    main.stakeHint = Text(main, "GameFontDisableSmall")
    main.stakeHint:SetPoint("LEFT", main.stake, "RIGHT", 6, 0)

    main.watch = Button(main, "Watch", 70, function()
        local race = selectedRace()
        if race then UI:ShowTrack(race.id) end
    end)
    main.watch:SetPoint("TOPRIGHT", -16, -298)

    main.mine = Text(main, "GameFontHighlightSmall")
    main.mine:SetPoint("TOPLEFT", 196, -326)
    main.mine:SetPoint("RIGHT", -16, 0)
    main.mine:SetJustifyV("TOP")
    main.mine:SetHeight(42)

    -- Host controls
    main.hostBar = CreateFrame("Frame", nil, main)
    main.hostBar:SetSize(406, 24)
    main.hostBar:SetPoint("BOTTOMLEFT", 194, 38)
    main.closeBtn = Button(main.hostBar, "Close bets", 96, function()
        local race = selectedRace()
        if race then Races:Close(race) end
    end)
    main.closeBtn:SetPoint("LEFT", 0, 0)
    main.startBtn = Button(main.hostBar, "Start race", 96, function()
        local race = selectedRace()
        if race then Races:Start(race) end
    end)
    main.startBtn:SetPoint("LEFT", main.closeBtn, "RIGHT", 4, 0)
    main.shoutBtn = Button(main.hostBar, "Post odds", 96, function()
        local race = selectedRace()
        if race then UI:PostOdds(race) end
    end)
    main.shoutBtn:SetPoint("LEFT", main.startBtn, "RIGHT", 4, 0)
    main.cancelBtn = Button(main.hostBar, "Cancel", 96, function()
        local race = selectedRace()
        if race then StaticPopup_Show("HORSEBOT_CANCEL_RACE", race.name, nil, race.id) end
    end)
    main.cancelBtn:SetPoint("LEFT", main.shoutBtn, "RIGHT", 4, 0)

    main.status = Text(main, "GameFontDisableSmall")
    main.status:SetPoint("BOTTOMLEFT", 196, 18)
    main.status:SetPoint("RIGHT", -16, 0)

    main:SetScript("OnShow", function() UI:Refresh() end)
end

function UI:IsShown()
    return main and main:IsShown()
end

function UI:Toggle()
    if not main then self:CreateMain() end
    if main:IsShown() then main:Hide() else main:Show() end
end

function UI:Show(raceId)
    if not main then self:CreateMain() end
    if raceId then selectedId = raceId end
    main:Show()
    self:Refresh()
end

function UI:Refresh()
    if not (main and main:IsShown()) then return end
    local list = Races:List()
    if not selectedRace() or not Races:IsComplete(selectedRace()) then
        selectedId = list[1] and list[1].id
    end

    main.empty:SetShown(#list == 0)
    for i, row in ipairs(main.list) do
        local race = list[i]
        if race then
            row.raceId = race.id
            row.name:SetText(race.name)
            local pool = Races:Totals(race)
            row.info:SetText(colorState(race.state) .. "  " .. U.ShortName(race.host) .. "  " .. compactMoney(pool))
            if race.id == selectedId then row.bg:SetColorTexture(1, 0.82, 0, 0.18)
            else row.bg:SetColorTexture(1, 1, 1, 0.05) end
            row:Show()
        else
            row:Hide()
        end
    end

    self:RefreshDetail(selectedRace())
end

function UI:RefreshDetail(race)
    local show = race ~= nil
    for _, region in ipairs({ main.title, main.info, main.pool, main.colHeaders, main.stakeLabel,
        main.stake, main.stakeHint, main.mine, main.watch }) do
        region:SetShown(show)
    end
    main.hostBar:SetShown(show and Races:IsHost(race))
    if not show then
        for _, row in ipairs(main.rows) do row:Hide() end
        return
    end

    main.title:SetText(race.name)
    main.info:SetText(string.format("Host %s  |  %d furlongs  |  %s  |  bets %s - %s%s",
        U.ShortName(race.host), race.furlongs, colorState(race.state),
        U.FormatMoney(race.minBet), U.FormatMoney(race.maxBet),
        race.cut > 0 and ("  |  cut " .. race.cut .. "%") or ""))

    local pool, byHorse = Races:Totals(race)
    local mine = {}
    for _, bet in ipairs(Races:MyBets(race)) do mine[bet.horse] = (mine[bet.horse] or 0) + bet.amount end
    local count = 0
    for _, bet in pairs(race.bets) do if not bet.void then count = count + 1 end end
    main.pool:SetText(string.format("Pool %s from %d bet%s", U.FormatMoney(pool), count, count == 1 and "" or "s"))

    local open = race.state == Races.OPEN
    local winner = race.result and race.result.order[1]
    for i, row in ipairs(main.rows) do
        local h = race.horses[i]
        if h and i <= race.numHorses then
            row.swatch:SetColorTexture(Horses.Color(i))
            local c = row.cols
            c[1]:SetText((i == winner and "|cffffd700" or "") .. i .. ". " .. h.name)
            c[2]:SetText(h.spd)
            c[3]:SetText(h.sta)
            c[4]:SetText(h.con)
            c[5]:SetText(Horses.STYLE_SHORT[h.style] or "?")
            c[6]:SetText(U.FormatOdds(Races:MorningLine(h)))
            c[7]:SetText(U.FormatOdds(Races:ToteOdds(race, i)))
            c[8]:SetText(mine[i] and compactMoney(mine[i]) or "")
            row.bet:SetShown(open)
            row:Show()
        else
            row:Hide()
        end
    end

    main.stakeHint:SetText(open and "gold (e.g. 5, 2g 50s)" or "")
    main.stake:SetShown(open)
    main.stakeLabel:SetShown(open)
    main.watch:SetShown(race.seed ~= nil and (race.state == Races.RUNNING or race.state == Races.FINISHED))

    -- Summary of the player's own position
    local lines = {}
    local myBets = Races:MyBets(race)
    if #myBets > 0 then
        local staked, payout = 0, 0
        for _, bet in ipairs(myBets) do
            staked = staked + bet.amount
            payout = payout + (bet.payout or 0)
        end
        if race.result then
            lines[1] = string.format("You staked %s and collect %s.", U.FormatMoney(staked), U.FormatMoney(payout))
        else
            lines[1] = "You staked " .. U.FormatMoney(staked) .. ". If your horse wins, at current odds:"
            local parts = {}
            for horse, stake in pairs(mine) do
                parts[#parts + 1] = race.horses[horse].name .. " " .. U.FormatMoney(Races:ProjectedReturn(race, horse, stake))
            end
            table.sort(parts)
            lines[2] = table.concat(parts, ",  ")
        end
    elseif race.result then
        local h = race.horses[race.result.order[1]]
        lines[1] = "Won by " .. Horses.ColoredName(h) .. "."
    end
    if race.state == Races.CANCELLED then lines = { "This race was cancelled. All bets were refunded." } end
    main.mine:SetText(table.concat(lines, "\n"))

    if Races:IsHost(race) then
        main.closeBtn:SetEnabled(race.state == Races.OPEN)
        main.startBtn:SetEnabled(race.state == Races.OPEN or race.state == Races.CLOSED)
        main.cancelBtn:SetEnabled(race.state == Races.OPEN or race.state == Races.CLOSED)
        main.shoutBtn:SetEnabled(race.state == Races.OPEN)
    end
end

function UI:HorseTooltip(owner, i)
    local race = selectedRace()
    local h = race and race.horses[i]
    if not h then return end
    local _, byHorse = Races:Totals(race)
    Tooltip(owner, {
        Horses.ColoredName(h),
        string.format("Speed %d   Stamina %d   Consistency %d", h.spd, h.sta, h.con),
        (Horses.STYLE_NAMES[h.style] or "?") .. ": " .. (Horses.STYLE_HELP[h.style] or ""),
        string.format("Morning line %s (%.1f%% to win over %d furlongs)",
            U.FormatOdds(Races:MorningLine(h)), (h.ml or 0) / 10, race.furlongs),
        "Money on this horse: " .. U.FormatMoney(byHorse[i] or 0),
    })
end

function UI:BetOn(horse)
    local race = selectedRace()
    if not race then return end
    local amount = U.ParseMoney(main.stake:GetText())
    main.stake:ClearFocus()
    local ok, err = Races:PlaceBet(race, horse, amount)
    if not ok then return ns.Status(err) end
    if Races:IsHost(race) then
        ns.Status(string.format("Bet placed: %s on %s.", U.FormatMoney(amount), race.horses[horse].name))
    else
        ns.Status(string.format("Sending %s on %s to %s...", U.FormatMoney(amount),
            race.horses[horse].name, U.ShortName(race.host)))
    end
end

-- Human-readable odds for players without the addon. Called from a click, so
-- the hardware-event restriction on public chat is satisfied.
function UI:PostOdds(race)
    local chatType = IsInRaid() and "RAID" or IsInGroup() and "PARTY" or "SAY"
    local head = string.format("[HorseBot] %s - %df - bets %s to %s. Odds:", race.name, race.furlongs,
        U.FormatMoney(race.minBet, true), U.FormatMoney(race.maxBet, true))
    SendChatMessage(head, chatType)
    local line = ""
    for i = 1, race.numHorses do
        local h = race.horses[i]
        local odds = Races:ToteOdds(race, i) or Races:MorningLine(h)
        local part = string.format("%d %s %s", i, h.name, U.FormatOdds(odds))
        if #line + #part + 3 > 250 then
            SendChatMessage(line, chatType)
            line = ""
        end
        line = line == "" and part or (line .. " | " .. part)
    end
    if line ~= "" then SendChatMessage(line, chatType) end
end

StaticPopupDialogs["HORSEBOT_CANCEL_RACE"] = {
    text = "Cancel '%s'? Every bet is refunded.",
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, raceId)
        local race = Races:Get(raceId)
        if race then Races:Cancel(race) end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

--------------------------------------------------------------------------------
-- Host panel
--------------------------------------------------------------------------------

local hostPanel
local SCOPE_ORDER = { "AUTO", "PARTY", "RAID", "GUILD", "CHANNEL" }
local SCOPE_HELP = {
    AUTO = "Your group if you have one, otherwise the shared channel.",
    PARTY = "Your party or raid.",
    RAID = "Your party or raid.",
    GUILD = "Everyone in your guild running HorseBot.",
    CHANNEL = "Anyone on the shared channel - no group needed.",
}

local function cycle(list, current, step)
    for i, v in ipairs(list) do
        if v == current then return list[(i - 1 + step) % #list + 1] end
    end
    return list[1]
end

function UI:CreateHostPanel()
    local f = Window("HorseBotHostFrame", "Host a race", 300, 318)
    hostPanel = f
    local d = ns.db.hostDefaults

    local function label(text, y)
        local fs = Text(f, "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", 18, y)
        fs:SetText(text)
        return fs
    end

    label("Race name", -38)
    f.name = Input(f, 160)
    f.name:SetPoint("TOPLEFT", 120, -34)
    f.name:SetMaxLetters(24)

    label("Horses", -66)
    f.horses = Text(f, "GameFontHighlight", "CENTER")
    f.horses:SetPoint("TOPLEFT", 150, -66)
    f.horses:SetWidth(40)
    local minus = Button(f, "-", 26, function()
        d.horses = math.max(Horses.MIN, d.horses - 1); UI:RefreshHostPanel()
    end)
    minus:SetPoint("TOPLEFT", 120, -61)
    local plus = Button(f, "+", 26, function()
        d.horses = math.min(Horses.MAX, d.horses + 1); UI:RefreshHostPanel()
    end)
    plus:SetPoint("TOPLEFT", 194, -61)

    label("Distance", -94)
    f.distance = Button(f, "", 100, function(_, mouse)
        d.furlongs = cycle(Races.DISTANCES, d.furlongs, mouse == "RightButton" and -1 or 1)
        UI:RefreshHostPanel()
    end)
    f.distance:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    f.distance:SetPoint("TOPLEFT", 120, -89)

    label("Min bet (gold)", -122)
    f.minBet = Input(f, 70)
    f.minBet:SetPoint("TOPLEFT", 124, -118)
    label("Max bet (gold)", -148)
    f.maxBet = Input(f, 70)
    f.maxBet:SetPoint("TOPLEFT", 124, -144)
    label("House cut (%)", -174)
    f.cut = Input(f, 40)
    f.cut:SetPoint("TOPLEFT", 124, -170)
    f.cut:SetNumeric(true)
    f.cut:SetMaxLetters(2)

    label("Broadcast to", -202)
    f.scope = Button(f, "", 100, function(_, mouse)
        d.scope = cycle(SCOPE_ORDER, d.scope, mouse == "RightButton" and -1 or 1)
        UI:RefreshHostPanel()
    end)
    f.scope:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    f.scope:SetPoint("TOPLEFT", 120, -197)
    f.scopeHelp = Text(f, "GameFontDisableSmall")
    f.scopeHelp:SetPoint("TOPLEFT", 18, -226)
    f.scopeHelp:SetWidth(264)

    f.hint = Text(f, "GameFontDisableSmall")
    f.hint:SetPoint("TOPLEFT", 18, -250)
    f.hint:SetWidth(264)
    f.hint:SetText("Odds are pari-mutuel: winners share the pool. Gold changes hands by trade; the ledger keeps score.")

    local create = Button(f, "Open betting", 140, function() UI:CreateRaceFromPanel() end)
    create:SetPoint("BOTTOM", 0, 14)

    f:SetScript("OnShow", function()
        f.name:SetText(d.name or "")
        f.minBet:SetText(tostring(d.minBet / 10000))
        f.maxBet:SetText(tostring(d.maxBet / 10000))
        f.cut:SetText(tostring(d.cut))
        UI:RefreshHostPanel()
    end)
end

function UI:RefreshHostPanel()
    local d = ns.db.hostDefaults
    hostPanel.horses:SetText(d.horses)
    hostPanel.distance:SetText(d.furlongs .. " furlongs")
    hostPanel.scope:SetText(d.scope)
    hostPanel.scopeHelp:SetText(SCOPE_HELP[d.scope] or "")
end

function UI:ShowHostPanel()
    if not hostPanel then self:CreateHostPanel() end
    hostPanel:Show()
end

function UI:CreateRaceFromPanel()
    local f, d = hostPanel, ns.db.hostDefaults
    local minBet, maxBet = U.ParseMoney(f.minBet:GetText()), U.ParseMoney(f.maxBet:GetText())
    if not minBet or not maxBet then return ns.Print("Enter the bet limits in gold, e.g. 1 or 0.5.") end
    local name = f.name:GetText()
    local race, err = Races:Create({
        name = name, horses = d.horses, furlongs = d.furlongs,
        minBet = minBet, maxBet = maxBet, cut = tonumber(f.cut:GetText()) or 0, scope = d.scope,
    })
    if not race then return ns.Print(err) end
    d.name, d.minBet, d.maxBet, d.cut = name, race.minBet, race.maxBet, race.cut
    f:Hide()
    self:Show(race.id)
    ns.Status("Betting is open on '" .. race.name .. "'.")
end

--------------------------------------------------------------------------------
-- Track
--------------------------------------------------------------------------------

local TRACK_W, LANE_H, LABEL_W, TRACK_PAD = 660, 26, 132, 34
local track, trackRaceId

function UI:CreateTrack()
    local lanesH = Horses.MAX * LANE_H
    track = Window("HorseBotTrackFrame", "", TRACK_W, lanesH + 150)
    track:SetPoint("TOP", 0, -120)

    track.field = CreateFrame("Frame", nil, track)
    track.field:SetPoint("TOPLEFT", 12, -50)
    track.field:SetSize(TRACK_W - 24, lanesH)
    local turf = track.field:CreateTexture(nil, "BACKGROUND")
    turf:SetAllPoints()
    turf:SetColorTexture(0.10, 0.22, 0.10, 0.9)

    track.runW = TRACK_W - 24 - LABEL_W - TRACK_PAD
    track.lanes = {}
    for i = 1, Horses.MAX do
        local lane = {}
        local y = -(i - 1) * LANE_H
        lane.stripe = track.field:CreateTexture(nil, "BORDER")
        lane.stripe:SetPoint("TOPLEFT", 0, y)
        lane.stripe:SetSize(TRACK_W - 24, LANE_H)
        lane.stripe:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.03 or 0.07)
        lane.label = Text(track.field, "GameFontHighlightSmall")
        lane.label:SetPoint("TOPLEFT", 6, y - 7)
        lane.label:SetWidth(LABEL_W - 10)
        lane.label:SetWordWrap(false)
        lane.silk = track.field:CreateTexture(nil, "ARTWORK")
        lane.silk:SetSize(24, 24)
        lane.icon = track.field:CreateTexture(nil, "OVERLAY")
        lane.icon:SetSize(20, 20)
        lane.icon:SetTexture(HORSE_ICON)
        lane.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        lane.icon:SetPoint("CENTER", lane.silk, "CENTER")
        lane.place = Text(track.field, "GameFontNormalSmall")
        lane.place:SetPoint("LEFT", lane.silk, "RIGHT", 4, 0)
        lane.y = y - 1
        track.lanes[i] = lane
    end

    track.finishLine = track.field:CreateTexture(nil, "ARTWORK")
    track.finishLine:SetWidth(3)
    track.finishLine:SetColorTexture(1, 1, 1, 0.9)
    track.finishLine:SetPoint("TOP", track.field, "TOPLEFT", LABEL_W + track.runW + 12, 0)
    track.posts = {}

    track.header = Text(track, "GameFontNormal")
    track.header:SetPoint("TOPLEFT", 16, -30)
    track.header:SetPoint("RIGHT", -16, 0)

    track.countdown = Text(track.field, "GameFontNormalHuge", "CENTER")
    track.countdown:SetPoint("CENTER")

    track.calls = {}
    for i = 1, 3 do
        local fs = Text(track, i == 3 and "GameFontHighlight" or "GameFontDisableSmall")
        fs:SetPoint("BOTTOMLEFT", 18, 64 - i * 18)
        fs:SetPoint("RIGHT", -18, 0)
        track.calls[i] = fs
    end
    track.result = Text(track, "GameFontNormal")
    track.result:SetPoint("BOTTOMLEFT", 18, 12)
    track.result:SetPoint("RIGHT", -18, 0)

    track:SetScript("OnUpdate", function() UI:UpdateTrack() end)
end

function UI:ShowTrack(raceId)
    local race = Races:Get(raceId)
    if not race or not Races:Runtime(race) then return end
    if not track then self:CreateTrack() end
    trackRaceId = raceId
    local rt = Races:Runtime(race)
    if GetTime() > rt.startAt + Sim.Duration(rt.sim) + 2 then
        rt.startAt = GetTime() + 2 -- finished long ago: replay it
    end

    track.title:SetText(race.name)
    track.header:SetText(string.format("%d furlongs  |  hosted by %s", race.furlongs, U.ShortName(race.host)))
    local n = race.numHorses
    for i, lane in ipairs(track.lanes) do
        local h = race.horses[i]
        local show = h and i <= n
        lane.stripe:SetShown(show)
        lane.label:SetShown(show)
        lane.silk:SetShown(show)
        lane.icon:SetShown(show)
        lane.place:SetShown(show)
        if show then
            lane.label:SetText(Horses.ColoredName(h))
            lane.silk:SetColorTexture(Horses.Color(i))
        end
    end
    track.field:SetHeight(n * LANE_H)
    track:SetHeight(n * LANE_H + 150)
    track.finishLine:SetHeight(n * LANE_H)

    -- Furlong posts
    for _, post in ipairs(track.posts) do post:Hide() end
    for f = 1, race.furlongs - 1 do
        local post = track.posts[f]
        if not post then
            post = track.field:CreateTexture(nil, "BORDER")
            post:SetWidth(1)
            post:SetColorTexture(1, 1, 1, 0.15)
            track.posts[f] = post
        end
        post:ClearAllPoints()
        post:SetPoint("TOP", track.field, "TOPLEFT", LABEL_W + 12 + track.runW * f / race.furlongs, 0)
        post:SetHeight(n * LANE_H)
        post:Show()
    end
    track:Show()
    self:UpdateTrack()
end

function UI:UpdateTrack()
    local race = trackRaceId and Races:Get(trackRaceId)
    local rt = race and Races:Runtime(race)
    if not rt then return end
    local sim, frames = rt.sim, rt.sim.frames
    local t = (GetTime() - rt.startAt) / Sim.TICK_SECONDS

    if t < 0 then
        track.countdown:SetText(math.ceil(-t * Sim.TICK_SECONDS))
        track.countdown:Show()
    else
        track.countdown:Hide()
    end

    local tick = math.max(0, math.min(sim.ticks, math.floor(t)))
    local frac = math.max(0, math.min(1, t - tick))
    local nextTick = math.min(sim.ticks, tick + 1)
    local cur, nxt = frames[tick], frames[nextTick]

    -- Live placings: finished horses by finish time, then by position.
    local order = {}
    for i = 1, race.numHorses do order[i] = i end
    table.sort(order, function(a, b)
        local fa = sim.finish[a] and sim.finish[a] < (tick + 1) * 1000000 and sim.finish[a]
        local fb = sim.finish[b] and sim.finish[b] < (tick + 1) * 1000000 and sim.finish[b]
        if fa and fb then return fa < fb end
        if fa or fb then return fa and true or false end
        if cur[a] ~= cur[b] then return cur[a] > cur[b] end
        return a < b
    end)
    local place = {}
    for p, i in ipairs(order) do place[i] = p end

    for i = 1, race.numHorses do
        local lane = track.lanes[i]
        local pos = cur[i] + (nxt[i] - cur[i]) * frac
        local x = LABEL_W + 12 + track.runW * pos / sim.distance - 12
        lane.silk:ClearAllPoints()
        lane.silk:SetPoint("TOPLEFT", track.field, "TOPLEFT", x, lane.y)
        local p = place[i]
        lane.place:SetText(t >= 0 and Sim.Ordinal(p) or "")
        lane.place:SetTextColor(p == 1 and 1 or 0.8, p == 1 and 0.82 or 0.8, p == 1 and 0 or 0.8)
    end

    -- Commentary: the last three calls up to now.
    local shown = {}
    for _, line in ipairs(rt.commentary) do
        if t >= line.tick then shown[#shown + 1] = line.text end
    end
    for i = 1, 3 do
        track.calls[i]:SetText(shown[#shown - 3 + i] or "")
    end

    if t >= sim.ticks then
        local parts = {}
        for p = 1, math.min(3, #sim.order) do
            parts[p] = Sim.Ordinal(p) .. " " .. Horses.ColoredName(race.horses[sim.order[p]])
        end
        local text = table.concat(parts, "   ")
        if race.result then
            local won = 0
            for _, bet in ipairs(Races:MyBets(race)) do won = won + (bet.payout or 0) end
            if won > 0 then text = text .. "   |cff40ff40You collect " .. U.FormatMoney(won) .. "|r" end
        end
        track.result:SetText(text)
    else
        track.result:SetText("")
    end
end

--------------------------------------------------------------------------------
-- Ledger
--------------------------------------------------------------------------------

local LEDGER_ROWS = 10
local ledgerFrame

function UI:CreateLedger()
    local f = Window("HorseBotLedgerFrame", "HorseBot - Ledger", 360, 380)
    ledgerFrame = f
    local intro = Text(f, "GameFontDisableSmall")
    intro:SetPoint("TOPLEFT", 16, -32)
    intro:SetWidth(328)
    intro:SetText("Stakes and payouts are booked here. Gold you trade with someone listed is booked automatically.")

    f.rows = {}
    for i = 1, LEDGER_ROWS do
        local row = CreateFrame("Frame", nil, f)
        row:SetSize(328, 22)
        row:SetPoint("TOPLEFT", 16, -64 - (i - 1) * 24)
        row.name = Text(row, "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", 2, 0)
        row.name:SetWidth(110)
        row.balance = Text(row, "GameFontHighlightSmall")
        row.balance:SetPoint("LEFT", 116, 0)
        row.balance:SetWidth(150)
        row.settle = Button(row, "Settle", 56, function(self)
            Ledger:Settle(self:GetParent().player)
        end)
        row.settle:SetHeight(18)
        row.settle:SetPoint("RIGHT", 0, 0)
        f.rows[i] = row
    end
    f.empty = Text(f, "GameFontDisableSmall")
    f.empty:SetPoint("TOPLEFT", 18, -68)
    f.empty:SetText("Nobody owes anybody anything.")
    f.more = Text(f, "GameFontDisableSmall")
    f.more:SetPoint("BOTTOMLEFT", 18, 16)
    f:SetScript("OnShow", function() UI:RefreshLedger() end)
end

function UI:RefreshLedger()
    if not (ledgerFrame and ledgerFrame:IsShown()) then return end
    local rows = Ledger:Rows()
    ledgerFrame.empty:SetShown(#rows == 0)
    for i, row in ipairs(ledgerFrame.rows) do
        local entry = rows[i]
        if entry then
            row.player = entry.player
            row.name:SetText(U.ShortName(entry.player))
            local color = entry.balance > 0 and "|cff40ff40" or "|cffff7070"
            row.balance:SetText(color .. Ledger:Describe(entry.balance) .. "|r")
            row:Show()
        else
            row:Hide()
        end
    end
    ledgerFrame.more:SetText(#rows > LEDGER_ROWS and ("+" .. (#rows - LEDGER_ROWS) .. " more") or "")
end

function UI:ShowLedger()
    if not ledgerFrame then self:CreateLedger() end
    ledgerFrame:Show()
end

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

ns.On("RACES_CHANGED", function() UI:Refresh() end)
ns.On("LEDGER_CHANGED", function() UI:RefreshLedger() end)
ns.On("STATUS", function(msg)
    if main then main.status:SetText(msg) end
end)
ns.On("RACE_STARTED", function(id)
    local race = Races:Get(id)
    if not race then return end
    local involved = Races:IsHost(race) or #Races:MyBets(race) > 0 or (UI:IsShown() and selectedId == id)
    if involved and ns.db.settings.autoWatch then UI:ShowTrack(id) end
end)
