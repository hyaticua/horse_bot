local _, ns = ...

local floor = math.floor

-- The race simulation. It uses only integer arithmetic driven by the shared
-- PRNG, so the host just broadcasts a seed and every client replays the exact
-- same race locally instead of streaming positions over the throttled
-- addon-message channel.
local Sim = {}
ns.Sim = Sim

Sim.UNITS_PER_FURLONG = 1000
Sim.TICK_SECONDS = 0.15      -- playback speed; ~16s for a 6f sprint
Sim.MAX_TICKS = 4000
local SCORE = 1000000        -- sub-tick resolution for finish times

local function copy(t)
    local c = {}
    for i = 1, #t do c[i] = t[i] end
    return c
end

-- Base speed of a horse (units per tick) at position p, before random terms.
function Sim.Speed(h, p, dist, tick)
    local pm = floor(p * 1000 / dist) -- progress, per mille
    local v = 50 + floor(h.spd * 12 / 100)

    local style = h.style
    if style == 1 then
        if pm < 250 then v = v + 4 elseif pm >= 750 then v = v - 2 end
    elseif style == 3 then
        if pm < 250 then v = v - 3 elseif pm >= 750 then v = v + 4 end
    elseif pm >= 250 and pm < 750 then
        v = v + 1
    end

    -- Stamina is an absolute distance, so sprints reward speed and routes
    -- reward stamina. Front-runners spend theirs early, closers save it.
    local reserve = 2000 + h.sta * 70
    if style == 1 then reserve = reserve - 400 elseif style == 3 then reserve = reserve + 300 end
    if p > reserve then
        v = v - floor((p - reserve) * (110 - h.sta) / 20000)
    end

    if tick <= 5 then v = floor(v * (5 + tick) / 10) end -- breaking from the gate
    return v
end

-- Runs a race. Returns { order, finish, ticks, distance, frames? } where
-- frames[t][i] is horse i's position after tick t (only when record is set).
function Sim.Run(horses, furlongs, seed, record)
    local rng = ns.Util.NewRNG(seed)
    local dist = furlongs * Sim.UNITS_PER_FURLONG
    local n = #horses
    local pos, form, drift, finish = {}, {}, {}, {}

    for i = 1, n do
        -- Day form: inconsistent horses can run well above or below their stats.
        local amp = floor((100 - horses[i].con) / 12)
        form[i] = rng:Int(-amp, amp)
        drift[i] = 0
        pos[i] = 0
    end

    local frames = record and { [0] = copy(pos) } or nil
    local finished, tick = 0, 0
    while finished < n and tick < Sim.MAX_TICKS do
        tick = tick + 1
        for i = 1, n do
            local h = horses[i]
            -- Random draws happen for every horse every tick, finished or not,
            -- so the stream never depends on finishing order.
            local noiseAmp = 2 + floor((100 - h.con) / 10)
            local noise = rng:Int(-noiseAmp, noiseAmp)
            local d = drift[i] + rng:Int(-1, 1) -- slow surges and fades
            if d > 3 then d = 3 elseif d < -3 then d = -3 end
            drift[i] = d

            if not finish[i] then
                local p = pos[i]
                local v = Sim.Speed(h, p, dist, tick) + form[i] + d + noise
                if v < 15 then v = 15 end
                if p + v >= dist then
                    finish[i] = (tick - 1) * SCORE + floor((dist - p) * SCORE / v)
                    pos[i] = dist
                    finished = finished + 1
                else
                    pos[i] = p + v
                end
            end
        end
        if frames then frames[tick] = copy(pos) end
    end

    local order = {}
    for i = 1, n do order[i] = i end
    table.sort(order, function(a, b)
        local fa, fb = finish[a], finish[b]
        if fa and fb then
            if fa ~= fb then return fa < fb end
            return a < b
        end
        if fa or fb then return fa ~= nil end
        if pos[a] ~= pos[b] then return pos[a] > pos[b] end
        return a < b
    end)

    return { order = order, finish = finish, ticks = tick, distance = dist, frames = frames }
end

-- Monte Carlo morning line: win chance per horse in per mille.
function Sim.EstimateWinChances(horses, furlongs, runs, seed)
    local rng = ns.Util.NewRNG(seed)
    local wins = {}
    for i = 1, #horses do wins[i] = 0 end
    for _ = 1, runs do
        local r = Sim.Run(horses, furlongs, rng:Next(), false)
        wins[r.order[1]] = wins[r.order[1]] + 1
    end
    local chances = {}
    for i = 1, #horses do
        chances[i] = ns.Util.Clamp(floor(wins[i] * 1000 / runs + 0.5), 5, 990)
    end
    return chances
end

function Sim.Duration(result)
    return result.ticks * Sim.TICK_SECONDS
end

--------------------------------------------------------------------------------
-- Commentary, derived from the recorded frames (so it is identical everywhere)
--------------------------------------------------------------------------------

local function rankAt(frame, n)
    local order = {}
    for i = 1, n do order[i] = i end
    table.sort(order, function(a, b)
        if frame[a] ~= frame[b] then return frame[a] > frame[b] end
        return a < b
    end)
    return order
end

local function ordinal(n)
    local suffix = (n == 1 and "st") or (n == 2 and "nd") or (n == 3 and "rd") or "th"
    return n .. suffix
end
Sim.Ordinal = ordinal

function Sim.Commentary(result, horses)
    local frames, dist, n = result.frames, result.distance, #horses
    local lines = { { tick = 0, text = "And they're off!" } }
    local function say(tick, text) lines[#lines + 1] = { tick = tick, text = text } end
    local function name(i) return horses[i].name end

    local called, candidate, since, lastCall = nil, nil, 0, -100
    local halfway, stretch = false, false
    local moved, prevRanks = {}, nil
    local winner = result.order[1]
    local winTick = floor(result.finish[winner] / SCORE) + 1

    for t = 1, winTick - 1 do
        local frame = frames[t]
        local ranks = rankAt(frame, n)
        local leader = ranks[1]
        local leadPm = floor(frame[leader] * 1000 / dist)

        if leader ~= candidate then candidate, since = leader, t end
        if leader ~= called and t - since >= 4 and t - lastCall >= 8 then
            if not called then
                say(t, name(leader) .. " breaks sharply and takes the early lead.")
            elseif leadPm >= 750 then
                say(t, name(leader) .. " hits the front!")
            else
                say(t, name(leader) .. " takes over the lead.")
            end
            called, lastCall = leader, t
        end

        if not halfway and leadPm >= 500 then
            halfway = true
            local top = {}
            for k = 1, math.min(3, n) do top[k] = name(ranks[k]) end
            say(t, "Halfway: " .. table.concat(top, ", ") .. ".")
            lastCall = t
        end

        if not stretch and leadPm >= 800 and n > 1 then
            stretch = true
            say(t, "Into the stretch - " .. name(leader) .. " leads, " .. name(ranks[2]) .. " gives chase!")
            lastCall = t
        end

        if t % 10 == 0 then
            if prevRanks and leadPm >= 350 and t - lastCall >= 6 then
                local before = {}
                for k = 1, n do before[prevRanks[k]] = k end
                for k = 2, math.min(3, n) do
                    local h = ranks[k]
                    if not moved[h] and before[h] - k >= 2 then
                        moved[h] = true
                        say(t, name(h) .. " is making a big move!")
                        lastCall = t
                        break
                    end
                end
            end
            prevRanks = ranks
        end
    end

    if n > 1 then
        local second = result.order[2]
        local margin = result.finish[second] - result.finish[winner]
        if margin < SCORE / 3 then
            say(winTick, "Photo finish... it's " .. name(winner) .. " by a nose over " .. name(second) .. "!")
        elseif margin > 12 * SCORE then
            say(winTick, name(winner) .. " wins by daylight!")
        else
            say(winTick, name(winner) .. " wins it! " .. name(second) .. " runs second.")
        end
    else
        say(winTick, name(winner) .. " wins it!")
    end
    return lines
end
