-- Pure selection policy. Engine-facing code is responsible for classifying safe
-- food, clean water, useful weapons, and checking the selected path before acting.
ClaudeLootPolicy = {}

local function validCandidate(candidate)
    if type(candidate) ~= "table" or type(candidate.items) ~= "table" then return false end
    local distance = candidate.distance
    return type(distance) == "number" and distance == distance and distance >= 0 and distance <= 4
end

local function flags(needs)
    needs = type(needs) == "table" and needs or {}
    return {food=needs.food == nil or needs.food == true,
        water=needs.water == nil or needs.water == true,
        weapon=needs.weapon == true, prefer=needs.prefer}
end

local function validRecord(record)
    return type(record) == "table" and (type(record.item) == "table" or type(record.item) == "userdata")
end

local function supplies(candidate, needs)
    local result, seen, food, water = {}, {}, 0, 0
    for _,record in ipairs(candidate.items) do
        if validRecord(record) and not seen[record.item] then
            -- Repeated engine object references cannot create repeated transfers.
            seen[record.item] = true
            local wantedFood = needs.food and record.food == true
            local wantedWater = needs.water and record.water == true
            if wantedFood or wantedWater then
                result[#result + 1] = record
                if wantedFood then food = food + 1 end
                if wantedWater then water = water + 1 end
            end
        end
    end
    return result, food, water
end

local function preference(record, needs)
    if needs.prefer == "water" and needs.water and record.water == true then return 1 end
    if needs.prefer == "food" and needs.food and record.food == true then return 1 end
    return 0
end

-- candidates: array of {distance=0..4, items={{item=engineObject,
-- food=safeEdibleBool, water=cleanWaterBool, weapon=usefulWeaponBool},...},...}.
-- needs: {food=true, water=true, weapon=false, prefer="water"|"food"}; missing
-- food/water flags default true. Returns the original candidate and <=6 original
-- records, or nil, {}. Never fills spare capacity with arbitrary inventory items.
function ClaudeLootPolicy.choose(candidates, requestedNeeds)
    if type(candidates) ~= "table" then return nil, {} end
    local needs = flags(requestedNeeds)
    local best, bestItems, bestPreferred, bestCoverage, bestCount
    for _,candidate in ipairs(candidates) do
        if validCandidate(candidate) then
            local items, food, water = supplies(candidate, needs)
            if #items > 0 then
                local preferred = ((needs.prefer == "food" and food > 0)
                    or (needs.prefer == "water" and water > 0)) and 1 or 0
                local coverage = (food > 0 and 1 or 0) + (water > 0 and 1 or 0)
                local count = math.min(#items, 6)
                if not best or preferred > bestPreferred
                    or (preferred == bestPreferred and coverage > bestCoverage)
                    or (preferred == bestPreferred and coverage == bestCoverage and candidate.distance < best.distance)
                    or (preferred == bestPreferred and coverage == bestCoverage and candidate.distance == best.distance and count > bestCount) then
                    best, bestItems = candidate, items
                    bestPreferred, bestCoverage, bestCount = preferred, coverage, count
                end
            end
        end
    end
    if best then
        local picks = {}
        -- Two stable passes prioritize the requested category without sorting or
        -- modifying caller-owned arrays. Each record appears in exactly one pass.
        for wanted = 1, 0, -1 do
            for _,record in ipairs(bestItems) do
                if #picks < 6 and preference(record, needs) == wanted then picks[#picks + 1] = record end
            end
        end
        return best, picks
    end
    if needs.weapon then
        local weaponCandidate, weapon
        for _,candidate in ipairs(candidates) do
            if validCandidate(candidate) then
                for _,record in ipairs(candidate.items) do
                    if validRecord(record) and record.weapon == true
                        and (not weaponCandidate or candidate.distance < weaponCandidate.distance) then
                        weaponCandidate, weapon = candidate, record
                    end
                end
            end
        end
        if weapon then return weaponCandidate, {weapon} end
    end
    return nil, {}
end

return ClaudeLootPolicy
