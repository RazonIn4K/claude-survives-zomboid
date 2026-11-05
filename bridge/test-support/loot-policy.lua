-- Pure-policy tests; these do not prove game engine paths or transfer completion.
dofile(assert(arg[1]) .. "/ClaudeLootPolicy.lua")
local count = 0
local function test(name, fn)
    fn(); count = count + 1; print("ok " .. name)
end
local function record(kind, item)
    local result = {item=item or {}}
    if kind then result[kind] = true end
    return result
end
local function candidate(distance, records) return {distance=distance, items=records} end
local function choose(candidates, needs) return ClaudeLootPolicy.choose(candidates, needs) end

test("farther clean water beats nearer generic junk", function()
    local junk = candidate(0, {record(),record()})
    local water = candidate(4, {record("water")})
    local selected,picks = choose({junk,water})
    assert(selected == water and #picks == 1 and picks[1] == water.items[1])
end)
test("category coverage beats distance", function()
    local food = candidate(0, {record("food")})
    local both = candidate(4, {record("food"),record("water")})
    assert(choose({food,both}) == both)
end)
test("an urgent category beats a nearer unneeded category", function()
    local food = candidate(0, {record("food")})
    local water = candidate(4, {record("water")})
    assert(choose({food,water},{prefer="water"}) == water)
    assert(choose({food,water},{food=false,water=true}) == water)
    assert(choose({food,water},{food=true,water=false}) == food)
end)
test("unique references remain unique even with overlapping categories", function()
    local shared = {}; local both = {item=shared,food=true,water=true}
    local selected,picks = choose({candidate(1,{both,both,{item=shared,food=true},record()})})
    assert(selected and #picks == 1 and picks[1] == both)
end)
test("six item cap prioritizes urgent supplies stably and never fills with junk", function()
    local rows = {record("food"),record("food"),record("food"),record("food"),record("food"),
        record("food"),record("water"),record("water"),record(),record("weapon")}
    local _,picks = choose({candidate(1,rows)},{prefer="water",weapon=true})
    assert(#picks == 6 and picks[1] == rows[7] and picks[2] == rows[8] and picks[3] == rows[1] and picks[6] == rows[4])
    local _,few = choose({candidate(1,{rows[1],rows[9],rows[10]})})
    assert(#few == 1 and few[1] == rows[1])
end)
test("same category chooses distance then quantity then stable candidate order", function()
    local near = candidate(1,{record("food")})
    local far = candidate(2,{record("food"),record("food")})
    assert(choose({far,near}) == near)
    local many = candidate(1,{record("food"),record("food")})
    assert(choose({near,many}) == many)
    local tie = candidate(1,{record("food"),record("food")})
    assert(choose({tie,many}) == tie and choose({many,tie}) == many)
end)
test("weapons are a one-item fallback only when requested and supplies absent", function()
    local weapons = candidate(1,{record("weapon"),record("weapon")})
    local farFood = candidate(4,{record("food")})
    assert(choose({weapons,farFood},{weapon=true}) == farFood)
    assert(choose({weapons}) == nil)
    local selected,picks = choose({weapons},{weapon=true})
    assert(selected == weapons and #picks == 1 and picks[1] == weapons.items[1])
    assert(choose({weapons,farFood},{food=false,water=false,weapon=true}) == weapons)
end)
test("nearer weapon wins and equal-distance weapon order remains stable", function()
    local near = candidate(0,{record("weapon")})
    local far = candidate(4,{record("weapon")})
    local tie = candidate(0,{record("weapon")})
    assert(choose({far,near},{weapon=true}) == near)
    assert(choose({tie,near},{weapon=true}) == tie)
end)
test("no useful or requested items yields an empty result", function()
    for _,rows in ipairs({{}, {candidate(1,{})}, {candidate(1,{record()})}, {candidate(1,{record("food")})}}) do
        local selected,picks = choose(rows,{food=false,water=false})
        assert(selected == nil and #picks == 0)
    end
end)
test("malformed data and out-of-range containers fail closed", function()
    for _,value in ipairs({false,1,"bad"}) do
        local selected,picks = choose(value)
        assert(selected == nil and #picks == 0)
    end
    local invalid = {false,{},candidate(-1,{record("water")}),candidate(4.01,{record("water")}),
        candidate(0/0,{record("water")}),candidate(math.huge,{record("water")}),
        candidate("1",{record("water")}),{distance=1,items=false},
        candidate(1,{false,{}, {item=false,water=true},{item="fake",food=true},{item=1,weapon=true},
            {item={},food="true"}, {item={},water=1}, {item={},weapon="yes"}})}
    local selected,picks = choose(invalid,{weapon=true})
    assert(selected == nil and #picks == 0)
    local edge = candidate(4,{record("water")})
    assert(choose(invalid) == nil and choose({edge}) == edge)
end)
test("policy leaves caller candidates and records untouched", function()
    local rows = {record("food"),record("water")}; local source = candidate(2,rows)
    local selected,picks = choose({source},{prefer="water"})
    assert(selected == source and source.items == rows and rows[1].food and rows[2].water)
    assert(picks[1] == rows[2] and picks[2] == rows[1] and #rows == 2)
end)

print("passed " .. count .. " loot policy Lua tests")
