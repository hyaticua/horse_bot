local _, ns = ...

local U, Comm, Sim, Horses, Ledger = ns.Util, ns.Comm, ns.Sim, ns.Horses, ns.Ledger
local floor = math.floor

-- Race book: race state, pari-mutuel betting, and the host/client protocol.
--
-- The host (bookie) is authoritative. Clients send bet requests to the host by
-- whisper; the host validates them, numbers them, and broadcasts the accepted
-- bets so every client holds the same book. When the host starts the race it
-- broadcasts a seed and each client replays the identical simulation.
--
-- Messages (fields after "<protocol>^<cmd>"):
--   A  announce   id, name, furlongs, minBet, maxBet, cut, state, horses, betSeq, seed
--   H  horses     id, "idx,name,spd,sta,con,style,ml;..."
--   L  bets       id, "seq,bettor,horse,amount,nonce,void;..."
--   B  bet req    id, horse, amount, nonce                (whisper -> host)
--   N  bet nack   id, nonce, reason                       (whisper -> bettor)
--   S  state      id, state, seed
--   V  void bet   id, seq
--   R  result     id, "1st,2nd,...", pool, winningStake
--   Q  query      id | "*"                                (ask hosts to resend)
local Races = {
    runtime = {},       -- id -> { sim, commentary, startAt } (not saved)
    outbox = {},        -- id -> accepted bets waiting to be broadcast
    pending = {},       -- nonce -> bet request awaiting the host's answer
    queryReplies = {},  -- sender -> time of last reply to "Q *"
}
ns.Races = Races

local OPEN, CLOSED, RUNNING, FINISHED, CANCELLED = "OPEN", "CLOSED", "RUNNING", "FINISHED", "CANCELLED"
Races.OPEN, Races.CLOSED, Races.RUNNING, Races.FINISHED, Races.CANCELLED =
    OPEN, CLOSED, RUNNING, FINISHED, CANCELLED

local STATE_RANK = { [OPEN] = 1, [CLOSED] = 2, [RUNNING] = 3, [FINISHED] = 4, [CANCELLED] = 4 }

Races.DISTANCES = { 5, 6, 7, 8, 10, 12 }
Races.COUNTDOWN = 5
Races.MAX_CUT = 25
Races.ML_RUNS = 250
local BET_TIMEOUT = 30
local KEEP_SECONDS = 6 * 3600

--------------------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------------------

function Races:Get(id)
    return self.db[id]
end

function Races:IsHost(race)
    return race.host == ns.Me()
end

function Races:HorseCount(race)
    local n = 0
    for i = 1, race.numHorses or 0 do
        if race.horses[i] then n = n + 1 end
    end
    return n
end

function Races:IsComplete(race)
    return race.name ~= nil and race.numHorses ~= nil and self:HorseCount(race) == race.numHorses
end

function Races:IsActive(race)
    return race.state == OPEN or race.state == CLOSED or race.state == RUNNING
end

function Races:List()
    local list = {}
    for _, race in pairs(self.db) do
        if self:IsComplete(race) then list[#list + 1] = race end
    end
    table.sort(list, function(a, b)
        local aa, ba = self:IsActive(a), self:IsActive(b)
        if aa ~= ba then return aa end
        return (a.createdAt or 0) > (b.createdAt or 0)
    end)
    return list
end

function Races:MaxSeq(race)
    local max = 0
    for seq in pairs(race.bets) do
        if seq > max then max = seq end
    end
    return max
end

-- Pool totals over live (non-void) bets.
function Races:Totals(race)
    local pool, byHorse = 0, {}
    for _, bet in pairs(race.bets) do
        if not bet.void then
            pool = pool + bet.amount
            byHorse[bet.horse] = (byHorse[bet.horse] or 0) + bet.amount
        end
    end
    return pool, byHorse
end

function Races:Net(race, pool)
    return floor(pool * (100 - race.cut) / 100)
end

-- Current tote odds ("to 1") on a horse, or nil if nothing is on it.
function Races:ToteOdds(race, horse)
    local pool, byHorse = self:Totals(race)
    local stake = byHorse[horse]
    if not stake or stake == 0 then return nil end
    return self:Net(race, pool) / stake - 1
end

-- What a stake on `horse` would return if it won, after adding `extra`.
function Races:ProjectedReturn(race, horse, stake, extra)
    local pool, byHorse = self:Totals(race)
    extra = extra or 0
    local onHorse = (byHorse[horse] or 0) + extra
    if onHorse == 0 then return 0 end
    return floor(self:Net(race, pool + extra) * stake / onHorse)
end

function Races:MorningLine(horse)
    local p = horse.ml or 0
    if p <= 0 then return nil end
    return (1000 - p) / p
end

-- Payout for a settled bet. Pari-mutuel: winners split the pool after the
-- house cut in proportion to their stakes. If nobody backed the winner every
-- bet is refunded in full.
function Races:Payout(race, bet)
    local r = race.result
    if not r or bet.void then return 0 end
    if r.winStake == 0 then return bet.amount end
    if bet.horse ~= r.order[1] then return 0 end
    return floor(self:Net(race, r.pool) * bet.amount / r.winStake)
end

function Races:MyBets(race)
    local me, list = ns.Me(), {}
    for _, bet in pairs(race.bets) do
        if bet.bettor == me and not bet.void then list[#list + 1] = bet end
    end
    table.sort(list, function(a, b) return a.seq < b.seq end)
    return list
end

--------------------------------------------------------------------------------
-- Ledger booking
--------------------------------------------------------------------------------

local function raceLabel(race)
    return "'" .. (race.name or "?") .. "'"
end

-- sign = 1 when a bet is taken, -1 when it is voided or refunded.
function Races:BookBet(race, bet, sign)
    local me = ns.Me()
    local note = (sign > 0 and "Bet on " or "Refund: ") .. raceLabel(race)
    if race.host == me and bet.bettor ~= me then
        Ledger:Add(bet.bettor, sign * bet.amount, note)
    elseif bet.bettor == me and race.host ~= me then
        Ledger:Add(race.host, -sign * bet.amount, note)
    end
    bet.booked = sign > 0
end

function Races:BookPayouts(race)
    if race.paidOut then return end
    race.paidOut = true
    local me = ns.Me()
    local myWinnings = 0
    for _, bet in pairs(race.bets) do
        local payout = self:Payout(race, bet)
        bet.payout = payout
        if payout > 0 and bet.booked then
            local note = "Payout: " .. raceLabel(race)
            if race.host == me and bet.bettor ~= me then
                Ledger:Add(bet.bettor, -payout, note)
            elseif bet.bettor == me and race.host ~= me then
                Ledger:Add(race.host, payout, note)
            end
        end
        if bet.bettor == me then myWinnings = myWinnings + payout end
    end
    if myWinnings > 0 and race.host ~= me then
        ns.Print(string.format("You collect %s from %s on %s. Trade them to settle.",
            U.FormatMoney(myWinnings), U.ShortName(race.host), raceLabel(race)))
    end
end

--------------------------------------------------------------------------------
-- Wire encoding
--------------------------------------------------------------------------------

local function horseItem(h)
    return table.concat({ h.idx, h.name, h.spd, h.sta, h.con, h.style, h.ml or 0 }, ",")
end

local function betItem(b)
    return table.concat({ b.seq, b.bettor, b.horse, b.amount, b.nonce or "", b.void and 1 or 0 }, ",")
end

local function validId(id, host)
    return type(id) == "string" and host ~= nil and id:sub(1, #host + 1) == host .. "#"
end

-- Sends the whole race (header, field, book, result) to one destination.
function Races:SendFull(race, chatType, target)
    local seed = (race.state == RUNNING or race.state == FINISHED) and race.seed or 0
    Comm:Enqueue(Comm:Encode("A", race.id, race.name, race.furlongs, race.minBet, race.maxBet,
        race.cut, race.state, race.numHorses, race.betSeq, seed), chatType, target)
    local horses = {}
    for i = 1, race.numHorses do horses[i] = horseItem(race.horses[i]) end
    Comm:SendList(chatType, target, "H", { race.id }, horses)
    local bets = {}
    for seq = 1, race.betSeq do
        if race.bets[seq] then bets[#bets + 1] = betItem(race.bets[seq]) end
    end
    if #bets > 0 then Comm:SendList(chatType, target, "L", { race.id }, bets) end
    if race.state == FINISHED and race.result then
        local r = race.result
        Comm:Enqueue(Comm:Encode("R", race.id, table.concat(r.order, ","), r.pool, r.winStake), chatType, target)
    end
end

-- Broadcast to wherever this race lives. Returns false if that is not possible.
function Races:Broadcast(race, cmd, ...)
    local chatType, target = Comm:Resolve(race.scope)
    if not chatType then
        ns.Status("Cannot broadcast: " .. target)
        return false
    end
    Comm:Enqueue(Comm:Encode(cmd, ...), chatType, target)
    return true
end

function Races:FlushOutbox(race)
    local out = self.outbox[race.id]
    self.outbox[race.id] = nil
    if not out or #out == 0 then return end
    local chatType, target = Comm:Resolve(race.scope)
    if not chatType then return ns.Status("Cannot broadcast: " .. target) end
    local items = {}
    for i, bet in ipairs(out) do items[i] = betItem(bet) end
    Comm:SendList(chatType, target, "L", { race.id }, items)
end

function Races:QueueBroadcast(race, bet)
    local out = self.outbox[race.id]
    if not out then
        out = {}
        self.outbox[race.id] = out
        -- Batch bets that arrive close together into one message.
        C_Timer.After(1, function() self:FlushOutbox(race) end)
    end
    out[#out + 1] = bet
end

--------------------------------------------------------------------------------
-- Hosting
--------------------------------------------------------------------------------

function Races:Create(opts)
    if Comm:Locked() then return nil, Comm.LOCKED_MSG end
    local scope = opts.scope or ns.db.settings.scope
    local chatType, err = Comm:Resolve(scope)
    if not chatType then return nil, "Cannot broadcast: " .. err end
    -- Pin AUTO to what it means right now, so the race doesn't jump channels
    -- (and lose its audience) if the host joins or leaves a group later.
    if scope == "AUTO" then scope = chatType == "CHANNEL" and "CHANNEL" or "PARTY" end

    local minBet, maxBet = floor(opts.minBet or 0), floor(opts.maxBet or 0)
    if minBet < 1 then return nil, "Minimum bet must be at least 1 copper." end
    if maxBet < minBet then return nil, "Maximum bet must be at least the minimum." end
    local cut = floor(opts.cut or 0)
    if cut < 0 or cut > Races.MAX_CUT then return nil, "House cut must be 0-" .. Races.MAX_CUT .. "%." end
    local furlongs = opts.furlongs
    if not tContains(Races.DISTANCES, furlongs) then return nil, "Invalid distance." end

    local me = ns.Me()
    ns.db.raceCounter = ns.db.raceCounter + 1
    local id = me .. "#" .. ns.db.raceCounter
    local rng = U.NewRNG(U.RandomSeed())
    local count = U.Clamp(floor(opts.horses or 6), Horses.MIN, Horses.MAX)
    local horses = Horses.Generate(count, rng)
    local chances = Sim.EstimateWinChances(horses, furlongs, Races.ML_RUNS, rng:Next())
    for i, h in ipairs(horses) do h.ml = chances[i] end

    local name = U.Clean(opts.name, 24)
    if name == "" then name = U.ShortName(me) .. "'s Race " .. ns.db.raceCounter end

    local race = {
        id = id, host = me, name = name, furlongs = furlongs,
        minBet = minBet, maxBet = maxBet, cut = cut, scope = scope,
        state = OPEN, horses = horses, numHorses = count,
        bets = {}, betSeq = 0, nonces = {},
        createdAt = time(), lastSeen = time(),
    }
    self.db[id] = race

    local chatType, target = Comm:Resolve(scope)
    self:SendFull(race, chatType, target)
    ns.Fire("RACES_CHANGED", id)
    return race
end

function Races:AcceptBet(race, bettor, horse, amount, nonce)
    if race.state ~= OPEN then return nil, "betting is closed" end
    if not horse or horse < 1 or horse > race.numHorses or horse ~= floor(horse) then
        return nil, "no such horse"
    end
    if not amount or amount ~= floor(amount) then return nil, "invalid amount" end
    if amount < race.minBet then return nil, "minimum bet is " .. U.FormatMoney(race.minBet, true) end
    if amount > race.maxBet then return nil, "maximum bet is " .. U.FormatMoney(race.maxBet, true) end

    local key = bettor .. ":" .. tostring(nonce)
    local existing = race.nonces[key]
    if existing then
        -- A retransmitted request; make sure the bettor hears about it.
        self:QueueBroadcast(race, race.bets[existing])
        return race.bets[existing]
    end

    race.betSeq = race.betSeq + 1
    local bet = { seq = race.betSeq, bettor = bettor, horse = horse, amount = amount, nonce = nonce }
    race.bets[bet.seq] = bet
    race.nonces[key] = bet.seq
    self:BookBet(race, bet, 1)
    self:QueueBroadcast(race, bet)
    ns.Fire("RACES_CHANGED", race.id)
    return bet
end

function Races:Close(race)
    if race.state ~= OPEN then return end
    race.state = CLOSED
    self:FlushOutbox(race)
    self:Broadcast(race, "S", race.id, CLOSED, 0)
    ns.Fire("RACES_CHANGED", race.id)
end

function Races:Start(race)
    -- Players would never see the start; keep the field waiting instead.
    if Comm:Locked() then return nil, Comm.LOCKED_MSG end
    if race.state == OPEN then self:Close(race) end
    if race.state ~= CLOSED then return end
    race.seed = U.RandomSeed()
    race.state = RUNNING
    self:Broadcast(race, "S", race.id, RUNNING, race.seed)
    self:BeginRun(race, Races.COUNTDOWN)
    ns.Fire("RACES_CHANGED", race.id)
    return true
end

function Races:Cancel(race)
    if race.state ~= OPEN and race.state ~= CLOSED then return end
    self.outbox[race.id] = nil
    self:Broadcast(race, "S", race.id, CANCELLED, 0)
    self:ApplyState(race, CANCELLED)
end

function Races:Void(race, seq)
    local bet = race.bets[seq]
    if not bet or bet.void or (race.state ~= OPEN and race.state ~= CLOSED) then return end
    bet.void = true
    if bet.booked then self:BookBet(race, bet, -1) end
    self:Broadcast(race, "V", race.id, seq)
    ns.Fire("RACES_CHANGED", race.id)
end

-- Host only: the simulation has played out.
function Races:Finish(race, order)
    local pool, byHorse = self:Totals(race)
    race.result = { order = order, pool = pool, winStake = byHorse[order[1]] or 0 }
    race.state = FINISHED
    self:BookPayouts(race)
    self:Broadcast(race, "R", race.id, table.concat(order, ","), pool, race.result.winStake)
    self:AnnounceResult(race)
    ns.Fire("RACES_CHANGED", race.id)
end

-- Periodically re-announce the header so late arrivals find the race and
-- clients that missed bets notice the gap (betSeq) and resync.
function Races:Heartbeat()
    for _, race in pairs(self.db) do
        if self:IsHost(race) and (race.state == OPEN or race.state == CLOSED) then
            local chatType, target = Comm:Resolve(race.scope)
            if chatType then
                Comm:Enqueue(Comm:Encode("A", race.id, race.name, race.furlongs, race.minBet, race.maxBet,
                    race.cut, race.state, race.numHorses, race.betSeq, 0), chatType, target)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Betting (client side; also used by a host betting on their own race)
--------------------------------------------------------------------------------

function Races:PlaceBet(race, horse, amount)
    if race.state ~= OPEN then return nil, "Betting is closed." end
    if not amount then return nil, "Enter a stake, e.g. 10 or 2g 50s." end
    if amount < race.minBet then return nil, "Minimum bet is " .. U.FormatMoney(race.minBet) .. "." end
    if amount > race.maxBet then return nil, "Maximum bet is " .. U.FormatMoney(race.maxBet) .. "." end

    local nonce = tostring(math.random(100000, 999999))
    if self:IsHost(race) then
        local bet, err = self:AcceptBet(race, ns.Me(), horse, amount, nonce)
        if not bet then return nil, err end
        return true
    end

    if Comm:Locked() then return nil, Comm.LOCKED_MSG end
    self.pending[nonce] = { id = race.id, horse = horse, amount = amount }
    Comm:Enqueue(Comm:Encode("B", race.id, horse, amount, nonce), "WHISPER", race.host, function(reason)
        if not self.pending[nonce] then return end
        self.pending[nonce] = nil
        ns.Status(reason == "offline"
            and (U.ShortName(race.host) .. " is offline - your bet was not placed.")
            or "Your client refused to send the bet - it was not placed.")
    end)
    C_Timer.After(BET_TIMEOUT, function()
        if self.pending[nonce] then
            self.pending[nonce] = nil
            ns.Status("No answer from " .. U.ShortName(race.host) .. " - your bet was not placed.")
        end
    end)
    return true
end

--------------------------------------------------------------------------------
-- Race playback
--------------------------------------------------------------------------------

function Races:BeginRun(race, delay)
    local sim = Sim.Run(race.horses, race.furlongs, race.seed, true)
    local rt = {
        sim = sim,
        commentary = Sim.Commentary(sim, race.horses),
        startAt = GetTime() + delay,
    }
    self.runtime[race.id] = rt
    C_Timer.After(delay + Sim.Duration(sim) + 0.5, function() self:OnRunComplete(race.id) end)
    ns.Fire("RACE_STARTED", race.id)
end

function Races:Runtime(race)
    local rt = self.runtime[race.id]
    if not rt and race.seed and (race.state == RUNNING or race.state == FINISHED) and self:IsComplete(race) then
        -- Replays (e.g. after /reload) start immediately.
        local sim = Sim.Run(race.horses, race.furlongs, race.seed, true)
        rt = { sim = sim, commentary = Sim.Commentary(sim, race.horses), startAt = GetTime() }
        self.runtime[race.id] = rt
    end
    return rt
end

function Races:OnRunComplete(id)
    local race = self.db[id]
    local rt = self.runtime[id]
    if not race or not rt or race.state ~= RUNNING then return end
    if self:IsHost(race) then
        self:Finish(race, rt.sim.order)
    else
        -- Wait for the host's result (it carries the authoritative pool), but
        -- don't hang forever if the host went offline.
        C_Timer.After(30, function()
            if race.state == RUNNING then
                local pool, byHorse = self:Totals(race)
                self:ApplyResult(race, rt.sim.order, pool, byHorse[rt.sim.order[1]] or 0)
                ns.Print(raceLabel(race) .. " settled from the local replay; the host never confirmed.")
            end
        end)
    end
end

function Races:ApplyResult(race, order, pool, winStake)
    race.result = { order = order, pool = pool, winStake = winStake }
    race.state = FINISHED
    self:BookPayouts(race)
    self:AnnounceResult(race)
    ns.Fire("RACES_CHANGED", race.id)
end

function Races:AnnounceResult(race)
    if not ns.db.settings.chatAnnounce then return end
    local parts = {}
    for place = 1, math.min(3, #race.result.order) do
        local h = race.horses[race.result.order[place]]
        parts[#parts + 1] = Sim.Ordinal(place) .. " " .. Horses.ColoredName(h)
    end
    ns.Print(raceLabel(race) .. " result: " .. table.concat(parts, "  "))
end

--------------------------------------------------------------------------------
-- State changes shared by host and clients
--------------------------------------------------------------------------------

function Races:ApplyState(race, state, seed)
    if not STATE_RANK[state] then return end
    if race.state and STATE_RANK[state] <= STATE_RANK[race.state] then return end
    if race.state == FINISHED or race.state == CANCELLED then return end
    local previous = race.state
    race.state = state

    if state == CANCELLED then
        self.runtime[race.id] = nil
        for _, bet in pairs(race.bets) do
            if bet.booked then self:BookBet(race, bet, -1) end
        end
        if previous and ns.db.settings.chatAnnounce then
            ns.Print(raceLabel(race) .. " was cancelled; all bets are refunded.")
        end
    elseif state == RUNNING and seed and seed > 0 then
        race.seed = seed
        if self:IsComplete(race) then self:BeginRun(race, Races.COUNTDOWN) end
    end
    ns.Fire("RACES_CHANGED", race.id)
end

--------------------------------------------------------------------------------
-- Incoming messages
--------------------------------------------------------------------------------

local function stub(self, id, host)
    local race = self.db[id]
    if not race then
        race = { id = id, host = host, horses = {}, bets = {}, betSeq = 0, nonces = {},
            createdAt = time(), lastSeen = time() }
        self.db[id] = race
    end
    return race
end

function Races:RequestSync(race)
    local now = GetTime()
    if race.syncAt and now - race.syncAt < 15 then return end
    race.syncAt = now
    Comm:Enqueue(Comm:Encode("Q", race.id), "WHISPER", race.host)
end

-- Ask for a resync once a full burst (A, H, L...) has had time to arrive.
function Races:CheckGaps(race)
    C_Timer.After(5, function()
        if race.state == CANCELLED or race.result then return end
        if not self:IsComplete(race) or self:MaxSeq(race) < (race.betSeq or 0) then
            self:RequestSync(race)
        end
    end)
end

function Races:OnAnnounce(sender, _, id, name, furlongs, minBet, maxBet, cut, state, numHorses, betSeq, seed)
    if not validId(id, sender) then return end
    local isNew = not self.db[id]
    local race = stub(self, id, sender)
    local wasComplete = self:IsComplete(race)
    race.name = U.Clean(name, 24)
    race.furlongs = tonumber(furlongs)
    race.minBet = tonumber(minBet)
    race.maxBet = tonumber(maxBet)
    race.cut = tonumber(cut) or 0
    race.numHorses = U.Clamp(tonumber(numHorses) or 0, 0, Horses.MAX)
    race.betSeq = math.max(race.betSeq or 0, tonumber(betSeq) or 0)
    race.lastSeen = time()
    seed = tonumber(seed)
    if seed and seed > 0 then race.seed = seed end
    if race.state == nil and state == OPEN and isNew and ns.db.settings.chatAnnounce then
        ns.Print(string.format("%s opened %s (%d horses, %df). /hb to bet.",
            U.ShortName(sender), raceLabel(race), race.numHorses, race.furlongs or 0))
    end
    if state == FINISHED then
        -- Settled by the R message that follows; it carries the result.
        if not race.state then race.state = RUNNING end
    elseif state == RUNNING and race.state ~= RUNNING and not wasComplete then
        -- Horses arrive in the next message; start once they are here.
        race.pendingState = state
    else
        self:ApplyState(race, state, race.seed)
    end
    self:CheckGaps(race)
    ns.Fire("RACES_CHANGED", id)
end

function Races:OnHorses(sender, _, id, list)
    if not validId(id, sender) or not list then return end
    local race = stub(self, id, sender)
    for _, item in ipairs(U.Split(list, ";")) do
        local f = U.Split(item, ",")
        local idx = tonumber(f[1])
        if idx and idx >= 1 and idx <= Horses.MAX then
            race.horses[idx] = {
                idx = idx, name = U.Clean(f[2], 24),
                spd = tonumber(f[3]) or 50, sta = tonumber(f[4]) or 50, con = tonumber(f[5]) or 50,
                style = tonumber(f[6]) or 2, ml = tonumber(f[7]) or 0,
            }
        end
    end
    if race.pendingState and self:IsComplete(race) then
        local state = race.pendingState
        race.pendingState = nil
        self:ApplyState(race, state, race.seed)
    end
    ns.Fire("RACES_CHANGED", id)
end

function Races:OnBets(sender, _, id, list)
    if not validId(id, sender) or not list then return end
    local race = stub(self, id, sender)
    local me = ns.Me()
    for _, item in ipairs(U.Split(list, ";")) do
        local f = U.Split(item, ",")
        local seq, bettor, horse, amount = tonumber(f[1]), f[2], tonumber(f[3]), tonumber(f[4])
        local nonce, void = f[5], f[6] == "1"
        if seq and bettor and horse and amount then
            local bet = race.bets[seq]
            if not bet then
                bet = { seq = seq, bettor = bettor, horse = horse, amount = amount, nonce = nonce }
                race.bets[seq] = bet
                if not void and race.state ~= CANCELLED then self:BookBet(race, bet, 1) end
                if seq > (race.betSeq or 0) then race.betSeq = seq end
                if bettor == me and self.pending[nonce] then
                    self.pending[nonce] = nil
                    local h = race.horses[horse]
                    ns.Status(string.format("Bet accepted: %s on %s.", U.FormatMoney(amount),
                        h and h.name or ("#" .. horse)))
                end
            end
            if void and not bet.void then
                bet.void = true
                if bet.booked then self:BookBet(race, bet, -1) end
            end
        end
    end
    ns.Fire("RACES_CHANGED", id)
end

function Races:OnBetRequest(sender, _, id, horse, amount, nonce)
    local race = self.db[id]
    if not race or not self:IsHost(race) then return end
    local bet, err = self:AcceptBet(race, sender, tonumber(horse), tonumber(amount), nonce)
    if not bet then
        Comm:Enqueue(Comm:Encode("N", id, nonce, err), "WHISPER", sender)
    end
end

function Races:OnBetRejected(sender, _, id, nonce, reason)
    local race = self.db[id]
    if not race or race.host ~= sender or not self.pending[nonce] then return end
    self.pending[nonce] = nil
    ns.Status("Bet rejected by " .. U.ShortName(sender) .. ": " .. (reason or "?"))
end

function Races:OnState(sender, _, id, state, seed)
    if not validId(id, sender) then return end
    local race = self.db[id]
    if not race then
        -- We never saw this race; get the whole thing.
        race = stub(self, id, sender)
        return self:RequestSync(race)
    end
    race.lastSeen = time()
    seed = tonumber(seed)
    if state == RUNNING and not self:IsComplete(race) then
        race.seed = seed
        race.pendingState = state
        return self:RequestSync(race)
    end
    self:ApplyState(race, state, seed)
end

function Races:OnVoid(sender, _, id, seq)
    local race = validId(id, sender) and self.db[id]
    local bet = race and race.bets[tonumber(seq)]
    if not bet or bet.void then return end
    bet.void = true
    if bet.booked then self:BookBet(race, bet, -1) end
    ns.Fire("RACES_CHANGED", id)
end

function Races:OnResult(sender, _, id, orderList, pool, winStake)
    local race = validId(id, sender) and self.db[id]
    if not race or race.result or race.state == CANCELLED then return end
    local order = {}
    for _, v in ipairs(U.Split(orderList or "", ",")) do order[#order + 1] = tonumber(v) end
    if #order == 0 then return end
    local rt = self.runtime[id]
    if rt and rt.sim.order[1] ~= order[1] then
        ns.Print("Warning: your replay of " .. raceLabel(race) .. " disagrees with the host. Using the host's result.")
    end
    self:ApplyResult(race, order, tonumber(pool) or 0, tonumber(winStake) or 0)
end

function Races:OnQuery(sender, _, id)
    if id == "*" then
        local now = GetTime()
        if self.queryReplies[sender] and now - self.queryReplies[sender] < 10 then return end
        self.queryReplies[sender] = now
        for _, race in pairs(self.db) do
            if self:IsHost(race) and self:IsActive(race) then
                self:SendFull(race, "WHISPER", sender)
            end
        end
    else
        local race = self.db[id]
        if race and self:IsHost(race) then self:SendFull(race, "WHISPER", sender) end
    end
end

-- Ask every reachable host for its open races.
function Races:Discover()
    local sent = {}
    for _, scope in ipairs({ "AUTO", "GUILD", "CHANNEL" }) do
        local chatType, target = Comm:Resolve(scope)
        local key = chatType and (chatType .. tostring(target))
        if key and not sent[key] then
            sent[key] = true
            Comm:Enqueue(Comm:Encode("Q", "*"), chatType, target)
        end
    end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function Races:Prune()
    local now = time()
    for id, race in pairs(self.db) do
        local age = now - (race.lastSeen or race.createdAt or 0)
        local mine = race.host == ns.Me()
        if age > KEEP_SECONDS and (not mine or not self:IsActive(race)) then
            self.db[id] = nil
        end
    end
end

function Races:OnInit()
    self.db = ns.db.races
end

function Races:OnLogin()
    self:Prune()
    Comm:Register("A", function(...) self:OnAnnounce(...) end)
    Comm:Register("H", function(...) self:OnHorses(...) end)
    Comm:Register("L", function(...) self:OnBets(...) end)
    Comm:Register("B", function(...) self:OnBetRequest(...) end)
    Comm:Register("N", function(...) self:OnBetRejected(...) end)
    Comm:Register("S", function(...) self:OnState(...) end)
    Comm:Register("V", function(...) self:OnVoid(...) end)
    Comm:Register("R", function(...) self:OnResult(...) end)
    Comm:Register("Q", function(...) self:OnQuery(...) end)

    -- A race that was running when we logged out or reloaded has been decided
    -- already. Once the channels are up, the host settles it and clients ask
    -- the host for the result.
    C_Timer.After(15, function()
        for _, race in pairs(self.db) do
            if race.state == RUNNING and race.seed and self:IsComplete(race) then
                if self:IsHost(race) then
                    self:Finish(race, Sim.Run(race.horses, race.furlongs, race.seed, false).order)
                else
                    self:RequestSync(race)
                end
            end
        end
    end)

    ns.On("CHANNEL_READY", function() self:Discover() end)
    C_Timer.After(12, function()
        if not ns.db.settings.autoJoin then self:Discover() end
    end)
    C_Timer.NewTicker(60, function() self:Heartbeat() end)
end

ns.RegisterModule(Races)
