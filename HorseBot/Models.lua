local _, ns = ...

local floor = math.floor

-- Chooses the 3D model for each runner from the game's own horse mounts.
--
-- Only a few creature display IDs could be verified against the mount
-- tables. The other coats of each breed are the same model file with a
-- different skin, so likely IDs are listed as candidates and checked in the
-- client at login: a candidate is used only if it loads the same model file
-- as the breed's verified anchor. A wrong guess is dropped, never shown.
local Models = {
    fileIds = {},          -- display ID -> model file ID, or false if it never loaded
    usable = {},           -- breed -> display IDs safe to use
    canDetectFailure = false,
}
ns.Models = Models

Models.BREEDS = {
    riding = {
        label = "Riding horse",
        verified = { 2404, 2402, 2409 },  -- Brown Horse, Black Stallion, Pinto
        candidates = { 2405, 2408, 2410 },
    },
    skeletal = {
        label = "Skeletal horse",
        verified = { 5228 },              -- Skeletal Horse
        candidates = { 10670, 10671, 10672 },
    },
}
Models.BREED_ORDER = { "riding", "skeletal" }
Models.MIXES = { mixed = true, riding = true, skeletal = true }

local PROBE_TIMEOUT = 1.5

for key, breed in pairs(Models.BREEDS) do
    Models.usable[key] = { unpack(breed.verified) }
end

local function hash(s)
    local h = 7
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 2147483647 end
    return h
end

-- Breed and coat for a horse. Keyed on the horse's name, so a horse looks
-- the same on every client and every time it is shown.
function Models:Breed(horse)
    local mix = ns.db.settings.breed or "mixed"
    if mix ~= "mixed" and self.BREEDS[mix] then return mix end
    return hash(horse.name) % 3 == 0 and "skeletal" or "riding"
end

function Models:For(horse)
    local coats = self.usable[self:Breed(horse)]
    if not coats or #coats == 0 then coats = self.usable.riding end
    return coats[floor(hash(horse.name) / 3) % #coats + 1]
end

function Models:Finish()
    -- If not even the verified anchors report a model file, this client's
    -- GetModelFileID can't be used to judge anything: trust the verified IDs.
    local anyLoaded = false
    for _, breed in pairs(self.BREEDS) do
        if self.fileIds[breed.verified[1]] then anyLoaded = true end
    end
    self.canDetectFailure = anyLoaded
    if not anyLoaded then return end

    for key, breed in pairs(self.BREEDS) do
        local anchor = self.fileIds[breed.verified[1]]
        local coats = {}
        for _, id in ipairs(breed.verified) do
            if self.fileIds[id] then coats[#coats + 1] = id end
        end
        if anchor then
            for _, id in ipairs(breed.candidates) do
                if self.fileIds[id] == anchor then coats[#coats + 1] = id end
            end
        end
        if #coats > 0 then self.usable[key] = coats end
        ns.Debug(breed.label .. " coats:", table.concat(coats, ", "))
    end
end

-- Loads each display ID in turn in an invisible model frame and records the
-- model file it resolves to. Loading is asynchronous, so this steps through
-- the list from OnUpdate, clearing the model between IDs so a slow load is
-- never mistaken for the previous model.
function Models:Probe()
    local ok, probe = pcall(CreateFrame, "PlayerModel", nil, UIParent)
    if not (ok and probe and probe.SetDisplayInfo and probe.GetModelFileID and probe.ClearModel) then
        return
    end
    probe:SetSize(1, 1)
    probe:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
    probe:SetAlpha(0)

    local queue = {}
    for _, key in ipairs(self.BREED_ORDER) do
        local breed = self.BREEDS[key]
        for _, id in ipairs(breed.verified) do queue[#queue + 1] = id end
        for _, id in ipairs(breed.candidates) do queue[#queue + 1] = id end
    end

    local i, startedAt = 1, nil
    probe:SetScript("OnUpdate", function()
        local id = queue[i]
        if not startedAt then
            probe:ClearModel()
            probe:SetDisplayInfo(id)
            startedAt = GetTime()
            return
        end
        local fileId = probe:GetModelFileID()
        if fileId or GetTime() - startedAt > PROBE_TIMEOUT then
            self.fileIds[id] = fileId or false
            i, startedAt = i + 1, nil
            if i > #queue then
                probe:SetScript("OnUpdate", nil)
                probe:ClearModel()
                probe:Hide()
                self:Finish()
            end
        end
    end)
end

function Models:OnLogin()
    -- Out of the way of the login burst; well before anyone's first race.
    C_Timer.After(5, function() self:Probe() end)
end

ns.RegisterModule(Models)
