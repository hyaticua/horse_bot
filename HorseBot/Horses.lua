local _, ns = ...

local Horses = {}
ns.Horses = Horses

Horses.MIN, Horses.MAX = 2, 8

Horses.STYLE_NAMES = { "Front-runner", "Stalker", "Closer" }
Horses.STYLE_SHORT = { "FR", "ST", "CL" }
Horses.STYLE_HELP = {
    "Breaks fast and tries to lead throughout; burns stamina early.",
    "Sits just off the pace and makes an even run.",
    "Settles at the back and finishes with a late kick.",
}

-- Lane colours (silks). Picked to stay distinguishable on the dark track.
Horses.COLORS = {
    { 0.91, 0.26, 0.21 },
    { 0.27, 0.56, 0.96 },
    { 0.96, 0.81, 0.22 },
    { 0.31, 0.80, 0.36 },
    { 0.74, 0.42, 0.92 },
    { 0.97, 0.56, 0.16 },
    { 0.88, 0.88, 0.88 },
    { 0.33, 0.86, 0.86 },
}

-- No commas or semicolons: names travel inside list-encoded addon messages.
Horses.NAMES = {
    "Thunderhoof", "Barrens Breeze", "Durotar Dust", "Westfall Wind",
    "Elwynn Flash", "Stranglethorn Sprint", "Mulgore Mist", "Ironforge Express",
    "Darkshore Dancer", "Tanaris Twister", "Redridge Rocket", "Silverpine Shadow",
    "Ashenvale Arrow", "Duskwood Dasher", "Feralas Fury", "Winterspring Whisper",
    "Gadgetzan Gambit", "Booty Bay Bolt", "Needlerock", "Un'Goro Uproar",
    "Moonglade Miracle", "Hinterlands Hero", "Kodo Kicker", "Murloc Mayhem",
    "Gnomeregan Gnash", "Felwood Phantom", "Azshara Ace", "Badlands Bandit",
    "Crossroads Courier", "Dun Morogh Drift", "Loch Modan Legend", "Stonetalon Storm",
    "Desolace Drifter", "Silithus Sandstorm", "Wetlands Wader", "Arathi Arrow",
    "Thousand Fortunes", "Lakeshire Lightning", "Goldshire Glory", "Razorhill Runner",
    "Sentinel Hill", "Ratchet Rattler", "Everlook Echo", "Menethil Mariner",
    "Darnassus Dawn", "Bloodhoof Bounder", "Gromgol Gallop", "Kargath Comet",
}

-- Builds a field of `count` horses. Stats are 1-100:
--   spd  raw cruising speed
--   sta  how far the horse can go before it starts to tire
--   con  consistency: low values mean big day-to-day form swings
function Horses.Generate(count, rng)
    count = ns.Util.Clamp(count, Horses.MIN, Horses.MAX)
    local pool = {}
    for i = 1, #Horses.NAMES do pool[i] = Horses.NAMES[i] end
    local field = {}
    for i = 1, count do
        local pick = rng:Int(i, #pool)
        pool[i], pool[pick] = pool[pick], pool[i]
        field[i] = {
            idx = i,
            name = pool[i],
            spd = rng:Int(45, 95),
            sta = rng:Int(40, 95),
            con = rng:Int(30, 95),
            style = rng:Int(1, 3),
        }
    end
    return field
end

function Horses.Color(idx)
    local c = Horses.COLORS[idx] or Horses.COLORS[1]
    return c[1], c[2], c[3]
end

function Horses.ColoredName(horse)
    local r, g, b = Horses.Color(horse.idx)
    return string.format("|cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255, horse.name)
end
