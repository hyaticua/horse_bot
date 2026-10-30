-- Offline test suite. Run from the repository root:  lua5.1 tests/run.lua
package.path = (arg[0]:match("^(.*)/[^/]+$") or ".") .. "/?.lua;" .. package.path
local World = require("wow_sim")

math.randomseed(12345)

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        passed = passed + 1
        print("ok    " .. name)
    else
        failed = failed + 1
        print("FAIL  " .. name .. "\n" .. tostring(err))
    end
end

local function eq(a, b, msg)
    if a ~= b then error((msg or "values differ") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local function truthy(v, msg)
    if not v then error(msg or "expected a true value", 2) end
end

-- Standard scenario: three ungrouped players who meet on the shared channel.
local function setup(names)
    local world = World.new()
    local clients = {}
    for _, n in ipairs(names or { "Alice", "Bob", "Carol" }) do
        clients[n] = world:AddClient(n):Login()
    end
    world:Advance(15) -- channel join + discovery
    return world, clients
end

local function host(world, client, opts)
    opts = opts or {}
    local ns = client.ns
    local race, err = ns.Races:Create({
        name = opts.name or "Test Stakes", horses = opts.horses or 6, furlongs = opts.furlongs or 6,
        minBet = opts.minBet or 10000, maxBet = opts.maxBet or 1000000, cut = opts.cut or 0,
        scope = opts.scope or "CHANNEL",
    })
    assert(race, err)
    world:Advance(12)
    return race
end

local function bet(world, client, raceId, horse, copper)
    local ns = client.ns
    local ok, err = ns.Races:PlaceBet(ns.Races:Get(raceId), horse, copper)
    assert(ok, err)
    world:Advance(5)
end

local function run(world, hostClient, raceId)
    local ns = hostClient.ns
    ns.Races:Start(ns.Races:Get(raceId))
    world:Advance(5 + 60 + 5)
end

-- A fresh, isolated copy of the addon's pure modules (no network).
local function modules()
    return World.new():AddClient("Solo"):Login().ns
end

--------------------------------------------------------------------------------
-- Util
--------------------------------------------------------------------------------

test("PRNG matches the Park-Miller reference value", function()
    local U = modules().Util
    local rng = U.NewRNG(1)
    for _ = 1, 10000 do rng:Next() end
    eq(rng.state, 1043618065, "state after 10000 draws from seed 1")
end)

test("money parsing and formatting", function()
    local U = modules().Util
    eq(U.ParseMoney("12"), 120000)
    eq(U.ParseMoney("2.5"), 25000)
    eq(U.ParseMoney("2g 50s"), 25000)
    eq(U.ParseMoney("1g2s3c"), 10203)
    eq(U.ParseMoney("75s"), 7500)
    eq(U.ParseMoney("abc"), nil)
    eq(U.ParseMoney("5g x"), nil)
    eq(U.ParseMoney(""), nil)
    eq(U.FormatMoney(10203, true), "1g 2s 3c")
    eq(U.FormatMoney(0, true), "0c")
    eq(U.FormatMoney(-50000, true), "-5g")
end)

test("text cleaning strips protocol delimiters", function()
    local U = modules().Util
    eq(U.Clean("  Big^Race;, |cffRed  "), "BigRace cffRed")
    eq(#U.Clean(string.rep("x", 40), 24), 24)
end)

--------------------------------------------------------------------------------
-- Simulation
--------------------------------------------------------------------------------

test("simulation is deterministic for a seed", function()
    local ns = modules()
    local horses = ns.Horses.Generate(8, ns.Util.NewRNG(99))
    local a = ns.Sim.Run(horses, 8, 424242, true)
    local b = ns.Sim.Run(horses, 8, 424242, true)
    eq(table.concat(a.order, ","), table.concat(b.order, ","))
    eq(a.ticks, b.ticks)
    for t = 0, a.ticks do
        for i = 1, 8 do eq(a.frames[t][i], b.frames[t][i]) end
    end
    local c = ns.Sim.Run(horses, 8, 424243, false)
    truthy(c.ticks > 0)
end)

test("every horse finishes and race lengths suit the distance", function()
    local ns = modules()
    local rng = ns.Util.NewRNG(7)
    for _, furlongs in ipairs(ns.Races.DISTANCES) do
        for _ = 1, 20 do
            local horses = ns.Horses.Generate(8, rng)
            local r = ns.Sim.Run(horses, furlongs, rng:Next(), false)
            for i = 1, 8 do truthy(r.finish[i], "horse did not finish") end
            local secs = ns.Sim.Duration(r)
            truthy(secs > furlongs * 1.8 and secs < furlongs * 3.5,
                ("%df race took %.1fs"):format(furlongs, secs))
        end
    end
end)

test("no running style or stat dominates", function()
    local ns = modules()
    local rng = ns.Util.NewRNG(2024)
    local styleWins, styleRuns = { 0, 0, 0 }, { 0, 0, 0 }
    local favWins, races = 0, 600
    local sprintSpd, routeSta = 0, 0
    for k = 1, races do
        local horses = ns.Horses.Generate(6, rng)
        local furlongs = (k % 2 == 0) and 5 or 12
        local r = ns.Sim.Run(horses, furlongs, rng:Next(), false)
        local w = horses[r.order[1]]
        for _, h in ipairs(horses) do styleRuns[h.style] = styleRuns[h.style] + 1 end
        styleWins[w.style] = styleWins[w.style] + 1
        -- Is the winner the best by the stat that should matter at this trip?
        local best = 0
        for _, h in ipairs(horses) do
            best = math.max(best, furlongs == 5 and h.spd or h.sta)
        end
        if furlongs == 5 and w.spd == best then sprintSpd = sprintSpd + 1 end
        if furlongs == 12 and w.sta == best then routeSta = routeSta + 1 end
        local fav, favChance = 1, -1
        if k <= 60 then
            local chances = ns.Sim.EstimateWinChances(horses, furlongs, 150, rng:Next())
            for i, c in ipairs(chances) do if c > favChance then fav, favChance = i, c end end
            if r.order[1] == fav then favWins = favWins + 1 end
        end
    end
    for s = 1, 3 do
        local rate = styleWins[s] / styleRuns[s] * 6 -- 1.0 = fair share
        truthy(rate > 0.6 and rate < 1.5, ("style %d wins at %.2fx its share"):format(s, rate))
    end
    -- Speed should matter most in sprints, stamina in routes, but neither should be destiny.
    truthy(sprintSpd / 300 > 0.25 and sprintSpd / 300 < 0.85, "sprint speed effect " .. sprintSpd)
    truthy(routeSta / 300 > 0.25 and routeSta / 300 < 0.85, "route stamina effect " .. routeSta)
    truthy(favWins >= 15 and favWins <= 50, "favourites won " .. favWins .. " of 60")
end)

test("commentary covers start and finish", function()
    local ns = modules()
    local horses = ns.Horses.Generate(6, ns.Util.NewRNG(5))
    local r = ns.Sim.Run(horses, 6, 777, true)
    local lines = ns.Sim.Commentary(r, horses)
    eq(lines[1].text, "And they're off!")
    truthy(lines[#lines].text:find(horses[r.order[1]].name, 1, true), "winner not called")
    for i = 2, #lines do truthy(lines[i].tick >= lines[i - 1].tick, "commentary out of order") end
end)

--------------------------------------------------------------------------------
-- Pari-mutuel maths
--------------------------------------------------------------------------------

test("payouts split the net pool and refund when nobody backed the winner", function()
    local ns = modules()
    local R = ns.Races
    local race = { cut = 10, bets = {
        [1] = { seq = 1, bettor = "A", horse = 1, amount = 30000 },
        [2] = { seq = 2, bettor = "B", horse = 1, amount = 10000 },
        [3] = { seq = 3, bettor = "C", horse = 2, amount = 60001 },
    } }
    local pool, byHorse = R:Totals(race)
    eq(pool, 100001)
    race.result = { order = { 1, 2 }, pool = pool, winStake = byHorse[1] }
    local net = R:Net(race, pool)
    eq(net, 90000)
    eq(R:Payout(race, race.bets[1]), 67500)
    eq(R:Payout(race, race.bets[2]), 22500)
    eq(R:Payout(race, race.bets[3]), 0)

    race.result = { order = { 3, 1 }, pool = pool, winStake = 0 }
    eq(R:Payout(race, race.bets[1]), 30000)
    eq(R:Payout(race, race.bets[3]), 60001)
end)

--------------------------------------------------------------------------------
-- Multiplayer
--------------------------------------------------------------------------------

test("ungrouped players share one race over the channel", function()
    local world, c = setup()
    local alice, bob, carol = c.Alice, c.Bob, c.Carol
    local race = host(world, alice)

    for _, p in ipairs({ bob, carol }) do
        local seen = p.ns.Races:Get(race.id)
        truthy(seen and p.ns.Races:IsComplete(seen), p.name .. " does not have the race")
        eq(seen.horses[3].name, race.horses[3].name)
        eq(seen.horses[3].ml, race.horses[3].ml)
    end
    truthy(bob:Printed("opened 'Test Stakes'"), "Bob was not told about the race")

    bet(world, bob, race.id, 1, 50000)
    bet(world, carol, race.id, 2, 30000)
    bet(world, carol, race.id, 1, 20000)
    bet(world, alice, race.id, 3, 10000) -- the host may bet on their own race
    world:Advance(5)

    for _, p in ipairs({ alice, bob, carol }) do
        local r = p.ns.Races:Get(race.id)
        local pool = p.ns.Races:Totals(r)
        eq(pool, 110000, p.name .. "'s view of the pool")
        eq(r.betSeq, 4)
    end

    run(world, alice, race.id)
    local result = alice.ns.Races:Get(race.id).result
    truthy(result, "host has no result")
    for _, p in ipairs({ bob, carol }) do
        local r = p.ns.Races:Get(race.id)
        eq(r.state, "FINISHED", p.name .. " state")
        eq(table.concat(r.result.order, ","), table.concat(result.order, ","), p.name .. " result")
    end

    -- Each punter's ledger mirrors the bookie's.
    for _, p in ipairs({ bob, carol }) do
        eq(p.ns.Ledger:Get(alice.full), -alice.ns.Ledger:Get(p.full), p.name .. " vs host ledger")
    end
    -- And the book balances: what punters owe net of payouts equals the
    -- pool minus everything paid back out.
    local paid = 0
    for _, b in pairs(alice.ns.Races:Get(race.id).bets) do
        if b.bettor ~= alice.full then paid = paid + (b.payout or 0) end
    end
    eq(alice.ns.Ledger:Get(bob.full) + alice.ns.Ledger:Get(carol.full), 100000 - paid)
end)

test("bet requests are validated by the host", function()
    local world, c = setup({ "Alice", "Bob" })
    local alice, bob = c.Alice, c.Bob
    local race = host(world, alice, { minBet = 10000, maxBet = 50000 })
    local r = bob.ns.Races:Get(race.id)

    local ok, err = bob.ns.Races:PlaceBet(r, 1, 500)
    eq(ok, nil); truthy(err:find("Minimum"))
    ok, err = bob.ns.Races:PlaceBet(r, 1, 60000)
    eq(ok, nil); truthy(err:find("Maximum"))

    -- A request still in flight when the host closes betting is refused.
    bob.ns.Races:PlaceBet(r, 1, 20000)
    alice.ns.Races:Close(alice.ns.Races:Get(race.id))
    world:Advance(5)
    truthy(bob:Printed("Bet rejected"), "Bob was not told his bet was rejected")
    eq(next(alice.ns.Races:Get(race.id).bets), nil)
    eq(bob.ns.Ledger:Get(alice.full), 0)

    -- A forged request straight to the host is checked as well.
    alice.ns.Races:OnBetRequest(bob.full, "WHISPER", race.id, "9", "20000", "1")
    eq(next(alice.ns.Races:Get(race.id).bets), nil)
end)

test("late joiners discover running books and sync every bet", function()
    local world = World.new()
    local alice = world:AddClient("Alice"):Login()
    local punters = {}
    for i = 1, 5 do punters[i] = world:AddClient("Punter" .. i):Login() end
    world:Advance(15)
    local race = host(world, alice, { horses = 8 })
    for round = 1, 8 do
        for i, p in ipairs(punters) do
            p.ns.Races:PlaceBet(p.ns.Races:Get(race.id), (i + round) % 8 + 1, 10000 * round)
        end
        world:Advance(3)
    end
    world:Advance(30)
    eq(alice.ns.Races:Get(race.id).betSeq, 40)

    local dave = world:AddClient("Dave"):Login()
    world:Advance(60)
    local r = dave.ns.Races:Get(race.id)
    truthy(r and dave.ns.Races:IsComplete(r), "Dave never found the race")
    local count = 0
    for _ in pairs(r.bets) do count = count + 1 end
    eq(count, 40, "bets synced to Dave")
    eq(dave.ns.Races:Totals(r), alice.ns.Races:Totals(alice.ns.Races:Get(race.id)))
end)

test("a client that loses messages resyncs from the heartbeat", function()
    local world, c = setup()
    local race = host(world, c.Alice)
    -- Carol's connection drops every bet broadcast for a while.
    world.drop = function(to, text) return to == c.Carol and text:find("^1%^L%^") end
    bet(world, c.Bob, race.id, 1, 20000)
    bet(world, c.Bob, race.id, 3, 30000)
    eq(next(c.Carol.ns.Races:Get(race.id).bets), nil)
    world.drop = nil
    world:Advance(75) -- next heartbeat reveals betSeq 2; Carol asks for a resync
    eq(c.Carol.ns.Races:Totals(c.Carol.ns.Races:Get(race.id)), 50000)
end)

test("a player who logs in mid-race still gets the result", function()
    local world, c = setup({ "Alice", "Bob" })
    local race = host(world, c.Alice)
    bet(world, c.Bob, race.id, 2, 40000)
    c.Alice.ns.Races:Start(c.Alice.ns.Races:Get(race.id))
    world:Advance(8)
    local erin = world:AddClient("Erin"):Login()
    world:Advance(120)
    local r = erin.ns.Races:Get(race.id)
    truthy(r and r.result, "Erin has no result")
    eq(r.result.order[1], c.Alice.ns.Races:Get(race.id).result.order[1])
end)

test("host /reload keeps the book and keeps taking bets", function()
    local world, c = setup({ "Alice", "Bob" })
    local race = host(world, c.Alice)
    bet(world, c.Bob, race.id, 1, 20000)
    c.Alice:Reload()
    world:Advance(15)
    bet(world, c.Bob, race.id, 2, 30000)
    world:Advance(5)
    local r = c.Alice.ns.Races:Get(race.id)
    eq(r.betSeq, 2)
    eq(c.Alice.ns.Ledger:Get(c.Bob.full), 50000)
    run(world, c.Alice, race.id)
    eq(c.Bob.ns.Races:Get(race.id).state, "FINISHED")
end)

test("host /reload while the race is running settles it", function()
    local world, c = setup({ "Alice", "Bob" })
    local race = host(world, c.Alice)
    bet(world, c.Bob, race.id, 1, 20000)
    c.Alice.ns.Races:Start(c.Alice.ns.Races:Get(race.id))
    world:Advance(3)
    c.Alice:Reload()
    world:Advance(40)
    eq(c.Alice.ns.Races:Get(race.id).state, "FINISHED")
    eq(c.Bob.ns.Races:Get(race.id).state, "FINISHED")
    eq(c.Bob.ns.Ledger:Get(c.Alice.full), -c.Alice.ns.Ledger:Get(c.Bob.full))
end)

test("cancelling refunds everyone", function()
    local world, c = setup()
    local race = host(world, c.Alice)
    bet(world, c.Bob, race.id, 1, 20000)
    bet(world, c.Carol, race.id, 2, 30000)
    eq(c.Alice.ns.Ledger:Get(c.Carol.full), 30000)
    c.Alice.ns.Races:Cancel(c.Alice.ns.Races:Get(race.id))
    world:Advance(5)
    for _, p in ipairs({ c.Alice, c.Bob, c.Carol }) do
        eq(p.ns.Races:Get(race.id).state, "CANCELLED", p.name)
    end
    eq(c.Alice.ns.Ledger:Get(c.Bob.full), 0)
    eq(c.Alice.ns.Ledger:Get(c.Carol.full), 0)
    eq(c.Bob.ns.Ledger:Get(c.Alice.full), 0)
end)

test("voiding a bet removes it everywhere", function()
    local world, c = setup({ "Alice", "Bob" })
    local race = host(world, c.Alice)
    bet(world, c.Bob, race.id, 1, 20000)
    bet(world, c.Bob, race.id, 2, 30000)
    c.Alice.ns.Races:Void(c.Alice.ns.Races:Get(race.id), 1)
    world:Advance(5)
    eq(c.Bob.ns.Races:Totals(c.Bob.ns.Races:Get(race.id)), 30000)
    eq(c.Bob.ns.Ledger:Get(c.Alice.full), -30000)
    eq(c.Alice.ns.Ledger:Get(c.Bob.full), 30000)
end)

test("trades with a ledger counterparty are booked", function()
    local world, c = setup({ "Alice", "Bob" })
    local race = host(world, c.Alice)
    bet(world, c.Bob, race.id, 1, 20000)
    -- Bob hands Alice 2g: each side sees the other's gold arrive / leave.
    c.Alice:Trade(c.Bob, 20000, 0)
    c.Bob:Trade(c.Alice, 0, 20000)
    eq(c.Alice.ns.Ledger:Get(c.Bob.full), 0)
    eq(c.Bob.ns.Ledger:Get(c.Alice.full), 0)
    -- Strangers' trades are not booked.
    local zed = world:AddClient("Zed"):Login()
    c.Alice:Trade(zed, 50000, 0)
    eq(c.Alice.ns.Ledger:Get(zed.full), 0)
end)

test("party races stay in the party", function()
    local world = World.new()
    local alice = world:AddClient("Alice", { group = 1 }):Login()
    local bob = world:AddClient("Bob", { group = 1 }):Login()
    local stranger = world:AddClient("Stranger"):Login()
    world:Advance(15)
    local race = host(world, alice, { scope = "AUTO" })
    eq(race.scope, "PARTY")
    truthy(bob.ns.Races:Get(race.id), "party member missed the race")
    eq(stranger.ns.Races:Get(race.id), nil)
end)

test("guild races reach guildmates who are not grouped", function()
    local world = World.new()
    local alice = world:AddClient("Alice", { guild = "Hoof" }):Login()
    local bob = world:AddClient("Bob", { guild = "Hoof" }):Login()
    world:Advance(15)
    bob.ns.db.settings.autoJoin = false
    bob.ns.Comm:LeaveChannel()
    local race = host(world, alice, { scope = "GUILD" })
    bet(world, bob, race.id, 1, 10000)
    eq(alice.ns.Races:Get(race.id).betSeq, 1)
end)

test("traffic stays under the addon message throttle", function()
    local world = World.new()
    local alice = world:AddClient("Alice"):Login()
    local punters = {}
    for i = 1, 12 do punters[i] = world:AddClient("P" .. i):Login() end
    world:Advance(15)
    local race = host(world, alice, { horses = 8 })
    for i, p in ipairs(punters) do
        p.ns.Races:PlaceBet(p.ns.Races:Get(race.id), i % 8 + 1, 10000)
    end
    world:Advance(40)
    eq(alice.ns.Races:Get(race.id).betSeq, 12)
    local mine = {}
    for _, m in ipairs(world.sent) do
        if m.from == alice then mine[#mine + 1] = m.at end
    end
    for i = 1, #mine do
        local n = 0
        for j = i, #mine do if mine[j] - mine[i] < 1 then n = n + 1 end end
        truthy(n <= 8, n .. " messages within one second")
    end
end)

test("messages from other protocol versions and spoofed hosts are ignored", function()
    local world, c = setup({ "Alice", "Bob" })
    local race = host(world, c.Alice)
    local Comm = c.Bob.ns.Comm
    -- Mallory tries to cancel Alice's race.
    Comm:OnAddonMessage("HorseBot", "1^S^" .. race.id .. "^CANCELLED^0", "CHANNEL", "Mallory-Testrealm")
    eq(c.Bob.ns.Races:Get(race.id).state, "OPEN")
    Comm:OnAddonMessage("HorseBot", "99^S^" .. race.id .. "^CANCELLED^0", "CHANNEL", c.Alice.full)
    eq(c.Bob.ns.Races:Get(race.id).state, "OPEN")
    truthy(c.Bob:Printed("newer HorseBot"))
end)

--------------------------------------------------------------------------------
-- UI smoke test (stub frames; catches nil errors in the drawing code)
--------------------------------------------------------------------------------

test("UI builds and refreshes through a whole race", function()
    local world, c = setup({ "Alice", "Bob" })
    local UI = c.Alice.ns.UI
    UI:ShowHostPanel()
    c.Alice.env.HorseBotHostFrame.minBet:SetText("1")
    c.Alice.env.HorseBotHostFrame.maxBet:SetText("50")
    UI:CreateRaceFromPanel()
    world:Advance(12)
    local race = c.Alice.ns.Races:List()[1]
    truthy(race, "race was not created from the panel")
    c.Bob.ns.UI:Show(race.id)
    c.Bob.env.HorseBotFrame.stake:SetText("2g 50s")
    c.Bob.ns.UI:BetOn(2)
    world:Advance(5)
    eq(c.Bob.ns.Races:Get(race.id).betSeq, 1)
    UI:PostOdds(race)
    truthy(#c.Alice.chat >= 2, "odds were not posted")
    c.Alice.ns.Races:Start(race)
    for _ = 1, 40 do
        world:Advance(1)
        UI:UpdateTrack()
        c.Bob.ns.UI:UpdateTrack()
    end
    UI:ShowLedger()
    UI:RefreshLedger()
    c.Bob.ns.UI:ShowTrack(race.id) -- replay
    c.Bob.ns.UI:UpdateTrack()
end)

-- Model files as the fake client reports them: every coat of a breed shares
-- its breed's file; two of the candidate guesses are wrong.
local function horseModels(world)
    for _, id in ipairs({ 2404, 2402, 2409, 2405 }) do world.modelFiles[id] = 500 end
    for _, id in ipairs({ 5228, 10670, 10671 }) do world.modelFiles[id] = 600 end
    world.modelFiles[2408] = 777    -- some other creature
    world.modelFiles[10672] = 500   -- a riding horse, not a skeleton
    world.badDisplays[2410] = true  -- doesn't exist
end

local function contains(list, v)
    for _, x in ipairs(list) do if x == v then return true end end
    return false
end

test("candidate coats are checked in the client before use", function()
    local world = World.new()
    horseModels(world)
    local ns = world:AddClient("Alice"):Login().ns
    eq(table.concat(ns.Models.usable.skeletal, ","), "5228", "before the check only verified IDs")
    world:Advance(15)
    eq(table.concat(ns.Models.usable.riding, ","), "2404,2402,2409,2405")
    eq(table.concat(ns.Models.usable.skeletal, ","), "5228,10670,10671")
    truthy(ns.Models.canDetectFailure)

    -- Mixed fields use both breeds; a horse always gets the same coat.
    local seen = {}
    for _, name in ipairs(ns.Horses.NAMES) do
        local h = { name = name }
        local breed = ns.Models:Breed(h)
        seen[breed] = (seen[breed] or 0) + 1
        truthy(contains(ns.Models.usable[breed], ns.Models:For(h)), name .. " got a coat outside its breed")
        eq(ns.Models:For(h), ns.Models:For({ name = name }))
    end
    truthy(seen.riding > seen.skeletal and seen.skeletal >= 8, "breed mix " .. tostring(seen.skeletal))

    ns.db.settings.breed = "skeletal"
    for _, name in ipairs(ns.Horses.NAMES) do
        truthy(contains(ns.Models.usable.skeletal, ns.Models:For({ name = name })))
    end
end)

test("clients that can't report model files keep the verified coats", function()
    local world = World.new()
    world.noFileIds = true
    local ns = world:AddClient("Alice"):Login().ns
    world:Advance(30)
    eq(table.concat(ns.Models.usable.riding, ","), "2404,2402,2409")
    eq(table.concat(ns.Models.usable.skeletal, ","), "5228")
    eq(ns.Models.canDetectFailure, false)
end)

test("the track runs the in-game horse models", function()
    local world = World.new()
    horseModels(world)
    local alice = world:AddClient("Alice"):Login()
    local bob = world:AddClient("Bob"):Login()
    world:Advance(15)
    local race = host(world, alice, { horses = 8 })
    bet(world, bob, race.id, 1, 20000)
    local Models = bob.ns.Models
    local horses = bob.ns.Races:Get(race.id).horses
    -- One coat fails to load on Bob's machine at race time, after the check.
    local broken = Models:For(horses[2])
    world.badDisplays[broken] = true
    local function loads(i) return Models:For(horses[i]) ~= broken end

    alice.ns.Races:Start(alice.ns.Races:Get(race.id))
    world:Advance(1) -- Bob's track opens on its own: he has money on this race
    local track = bob.env.HorseBotTrackFrame
    truthy(track and track:IsShown(), "track did not open for a bettor")
    local UI = bob.ns.UI
    local function runner(i) return track.lanes[i].runner end
    local function x(i) return runner(i)._point[4] end

    for i = 1, 8 do
        local r = runner(i)
        eq(r.model._display, Models:For(horses[i]), "lane " .. i .. " coat")
        if loads(i) then
            eq(r.model._facing, math.pi / 2, "lane " .. i .. " facing")
            eq(r.model._anim, 0, "standing in the gate")
        end
    end
    world:Advance(2.5)
    for i = 1, 8 do
        eq(runner(i).modelMode, loads(i), "lane " .. i .. " model mode")
        eq(runner(i).icon:IsShown(), not loads(i), "lane " .. i .. " icon fallback")
    end

    world:Advance(4) -- off and running
    local before = x(1)
    for i = 1, 8 do
        if loads(i) then eq(runner(i).model._anim, 5, "lane " .. i .. " running") end
    end
    world:Advance(3)
    truthy(x(1) > before, "horse 1 did not move")

    world:Advance(60) -- everyone home and pulled up
    local finishX = track.startX + track.runW
    for i = 1, 8 do
        truthy(x(i) >= finishX, "lane " .. i .. " stopped short of the line")
        if loads(i) then eq(runner(i).model._anim, 0, "lane " .. i .. " pulled up") end
    end

    -- An all-skeleton field, then icons only, on request.
    bob.env.SlashCmdList.HORSEBOT("models skeletal")
    UI:ShowTrack(race.id)
    for i = 1, 8 do
        truthy(contains(Models.usable.skeletal, runner(i).model._display), "lane " .. i .. " is not skeletal")
    end
    bob.env.SlashCmdList.HORSEBOT("models off")
    UI:ShowTrack(race.id)
    UI:UpdateTrack()
    truthy(not runner(1).modelMode and runner(1).icon:IsShown(), "models off still shows models")
    eq(track.laneH, 26)
end)

print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
