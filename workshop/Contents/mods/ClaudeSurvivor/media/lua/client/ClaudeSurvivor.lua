-- ClaudeSurvivor — the body half of "Claude plays Project Zomboid".
-- Perception OUT : one-line JSON to  %USERPROFILE%/Zomboid/Lua/claude_percept.json  (~1/s)
-- Intent     IN  : reads  %USERPROFILE%/Zomboid/Lua/claude_intent.txt  ->  "SEQ|ACTION|A|B|SAY|THOUGHT"
--                  Actions: MOVE dx dy | EAT | DRINK | LOOT | EQUIP | STOP | WAIT
-- Lab movement   : integer offsets within four tiles; no momentum or game-speed changes.
-- Lab control    : initially disarmed; a fresh world/actor/session heartbeat gates all autonomy.
-- Reflex         : a zombie inside 6 tiles while idle -> auto-flee instantly (no round-trip).
-- HUD            : on-screen overlay (toggle with H) showing action, live thought, vitals,
--                  inventory and zombie awareness — full visual transparency.
-- All game calls are pcall-guarded; a bridge failure must never take the game down.

local PERCEPT_EVERY = 60      -- ticks between percept writes (~1s)
local INTENT_EVERY  = 45      -- ticks between intent polls (~0.75s — snappier reaction)
local REFLEX_DIST   = 6
local REFLEX_COOLDOWN = 300

local tick       = 0
local lastSeq    = 0
local lastError  = ""
local lastIntentRaw = nil
local announced  = false
local reflexTick = -99999
local lastLootTick = -99999   -- protects an in-progress loot from being interrupted
local travel     = { active = false, dx = 0, dy = 0, budget = 0 }  -- momentum

-- Human takeover is permanent for the current session; the lab gate below owns it.
local observing = false   -- true while the AI is deliberately holding to look around

-- Safe-default player-client lab lease. No Lua autonomy runs before explicit arming.
require "ClaudeLabControl"
require "ClaudeLootPolicy"
require "ClaudeActionEvidence"
require "ClaudeHealthFacts"
require "ClaudeWindowPolicy"
local function readActionState(p)
  local count, nativeBusy, traversing = -1, nil, nil
  pcall(function()
    local q = ISTimedActionQueue.getTimedActionQueue(p)
    if q and type(q.queue) == "table" then count = #q.queue end
  end)
  pcall(function()
    local value = ISTimedActionQueue.isPlayerDoingAction(p)
    if type(value) == "boolean" then nativeBusy = value end
  end)
  pcall(function() traversing = p:getCurrentState() == ClimbThroughWindowState.instance() end)
  return count, nativeBusy, traversing
end
local actionEvidence = ClaudeActionEvidence.new()
local lab = ClaudeLabControl.new({
  now = function() return tonumber(getTimestampMs()) end,
  random = function() return ZombRand(1000000) end,
  identity = function(p) return tostring(getWorld():getWorld()), tostring(p:getOnlineID()) end,
  readControl = function()
    local ok, line = pcall(function()
      local reader = getFileReader("claude_control.txt", false)
      if not reader then return nil end
      local value = reader:readLine(); reader:close(); return value
    end)
    return ok and line or nil
  end,
  busy = function(p)
    local count, nativeBusy = readActionState(p)
    return count < 0 or nativeBusy ~= false or count > 0
  end,
  stop = function(p)
    actionEvidence:cancel("control_revoked")
    travel.active, travel.budget, observing = false, 0, false
    if not p then return false end
    local ok, empty = pcall(function()
      ISTimedActionQueue.clear(p)
      local count, nativeBusy = readActionState(p)
      return count == 0 and nativeBusy == false
    end)
    return ok and empty
  end,
})

-- shared with the HUD (below)
local HUD = {
  action = "—", thought = "Booting up. Let's see this body.", say = "", goal = "",
  hp = 100, hunger = 0, thirst = 0, fatigue = 0, panic = 0,
  zNear = 0, zClose = 0, zDist = -1, zDir = "-",
  foods = 0, waters = 0, weapon = "none", room = "", qlen = 0, day = 0, hour = 0,
  lastIntentTick = -9999, seq = 0, visible = true, injury = "Body check: unknown",
}

local function esc(s)
  s = tostring(s or "")
  s = s:gsub("\\", "\\\\"); s = s:gsub('"', '\\"'); s = s:gsub("\r", " "); s = s:gsub("\n", " ")
  return s
end
local function n2(x) return tostring(math.floor(((tonumber(x) or 0) * 100) + 0.5) / 100) end
local function split(s, sep)
  local out, i = {}, 1
  while true do
    local j = string.find(s, sep, i, true)
    if not j then table.insert(out, string.sub(s, i)); break end
    table.insert(out, string.sub(s, i, j - 1)); i = j + 1
  end
  return out
end

-- ---------- item classification ----------
local function isFoodItem(it, p)
  -- Match the official B42 inventory pane's edible-food checks; unknown APIs fail closed.
  local ok, food = pcall(function()
    return instanceof(it, "Food") and it:getHungChange() < 0
      and not it:getScriptItem():isCantEat() and not it:isBurnt() and not it:isRotten()
      and not p:isKnownPoison(it) and not (it:isbDangerousUncooked() and not it:isCooked())
  end)
  return ok and food or false
end
local function isWaterItem(it)
  local ok, water = pcall(function()
    local fc = it:getFluidContainer()
    if fc and (not fc:isEmpty()) and fc:isPureFluid(Fluid.Water) then return true end
    return false
  end)
  return ok and water or false
end

local function isWeaponItem(it)
  local ok, weapon = pcall(function() return instanceof(it, "HandWeapon") and it:getCondition() > 0 end)
  return ok and weapon or false
end

local function inventorySnapshot(p)
  local snapshot = {now = tonumber(getTimestampMs()), valid = false, items = {},
    world=lab.world, actor=lab.actor, session=lab.session}
  local ok = pcall(function()
    local items = p:getInventory():getItems()
    for i = 0, items:size() - 1 do
      local it, id = items:get(i), nil
      pcall(function() id = it:getID() end)
      snapshot.items[id ~= nil and ("id:" .. tostring(id)) or it] = true
    end
    snapshot.hunger = p:getStats():get(CharacterStat.HUNGER)
    snapshot.thirst = p:getStats():get(CharacterStat.THIRST)
  end)
  snapshot.valid = ok
  return snapshot
end

-- Loaded containers within the existing four-tile Manhattan limit. This is proximity
-- information, not a promise of line of sight, access, or a successful transfer.
local function scanLoot(p)
  local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
  local candidates, seen = {}, {}
  local summary = {containers=0, foods=0, waters=0, weapons=0, valid=true}
  local ok = pcall(function()
    for dx = -4, 4 do for dy = -4, 4 do
      local distance = math.abs(dx) + math.abs(dy)
      if distance <= 4 then
        local sq = getCell():getGridSquare(px+dx, py+dy, pz)
        local objects = sq and sq:getObjects()
        if objects then for oi = 0, objects:size()-1 do
          local object = objects:get(oi)
          local containers = {}
          pcall(function()
            for ci = 0, object:getContainerCount()-1 do
              table.insert(containers, object:getContainerByIndex(ci))
            end
          end)
          if #containers == 0 then pcall(function()
            local c = object:getContainer(); if c then table.insert(containers, c) end
          end) end
          for _, container in ipairs(containers) do if not seen[container] then
            seen[container] = true
            local candidate = {distance=distance, dx=dx, dy=dy, square=sq, container=container, items={}}
            local items = container:getItems()
            for ii = 0, items:size()-1 do
              local it = items:get(ii)
              local food, water, weapon = isFoodItem(it,p), isWaterItem(it), isWeaponItem(it)
              table.insert(candidate.items, {item=it, food=food, water=water, weapon=weapon})
              if food then summary.foods=summary.foods+1 end
              if water then summary.waters=summary.waters+1 end
              if weapon then summary.weapons=summary.weapons+1 end
            end
            summary.containers=summary.containers+1
            table.insert(candidates, candidate)
          end end
        end end
      end
    end end
  end)
  if not ok then return {}, {containers=0,foods=0,waters=0,weapons=0,valid=false} end
  return candidates, summary
end

local function lootNeeds(p)
  local hunger, thirst = p:getStats():get(CharacterStat.HUNGER), p:getStats():get(CharacterStat.THIRST)
  return {food=true,water=true,weapon=not isWeaponItem(p:getPrimaryHandItem()),
    prefer=thirst > hunger and "water" or "food"}
end

-- ---------- zombie awareness ----------
local function zombieScan(px, py)
  local zTotal, zNear, zClose, nearestD, ndx, ndy = 0, 0, 0, 9999, 0, 0
  pcall(function()
    local zl = getCell():getZombieList()
    if zl then
      zTotal = zl:size()
      for i = 0, zTotal - 1 do
        local z = zl:get(i)
        local dx, dy = z:getX() - px, z:getY() - py
        local d = math.sqrt(dx * dx + dy * dy)
        if d < nearestD then nearestD, ndx, ndy = d, dx, dy end
        if d <= 30 then zNear = zNear + 1 end
        if d <= 10 then zClose = zClose + 1 end
      end
    end
  end)
  local dir = "-"
  if zTotal > 0 then
    local ew = ndx > 3 and "E" or (ndx < -3 and "W" or "")
    local ns = ndy > 3 and "S" or (ndy < -3 and "N" or "")
    dir = (ns .. ew ~= "") and (ns .. ew) or "HERE"
  else nearestD = -1 end
  return zTotal, zNear, zClose, nearestD, dir, ndx, ndy
end

-- "where's civilization" sense so he heads toward buildings instead of wandering into open
-- forest. DENSE grid scan (every 3 tiles out to ~20) so it doesn't miss buildings he's next to.
local bldgDir, bldgDist = "none", -1
local function scanBuildings(px, py, pz)
  local bestD, bx, by = 99999, nil, nil
  for dx = -20, 20, 3 do
    for dy = -20, 20, 3 do
      local sq = getCell():getGridSquare(px + dx, py + dy, pz)
      if sq then
        local b = nil
        pcall(function() b = sq:getBuilding() end)
        if b then
          local d = math.abs(dx) + math.abs(dy)
          if d < bestD then bestD, bx, by = d, dx, dy end
        end
      end
    end
  end
  if not bx then bldgDir, bldgDist = "none", -1; return end
  local ew = bx > 3 and "E" or (bx < -3 and "W" or "")
  local ns = by > 3 and "S" or (by < -3 and "N" or "")
  bldgDir = (ns .. ew ~= "") and (ns .. ew) or "HERE"
  bldgDist = bestD
end

-- ---------- perception ----------
local function buildPercept(p)
  local px, py, pz = p:getX(), p:getY(), p:getZ()
  local st = p:getStats()
  local hp = 0
  pcall(function() hp = p:getBodyDamage():getOverallBodyHealth() end)

  local zTotal, zNear, zClose, nearestD, nearestDir = zombieScan(px, py)

  local room = "outside"
  pcall(function()
    local sq = p:getSquare(); local r = sq and sq:getRoom()
    if r and r:getName() then room = r:getName() end
  end)

  local foods, waters, names, inventoryCount = 0, 0, {}, 0
  pcall(function()
    local items = p:getInventory():getItems()
    inventoryCount = items:size()
    for i = 0, items:size() - 1 do
      local it = items:get(i)
      if isFoodItem(it,p) then foods = foods + 1 end
      if isWaterItem(it) then waters = waters + 1 end
      if i < 12 then table.insert(names, esc(it:getDisplayName())) end
    end
  end)

  local weapon = "none"
  pcall(function() local w = p:getPrimaryHandItem(); if w then weapon = esc(w:getDisplayName()) end end)

  local qlen, nativeBusy, traversing = readActionState(p)
  local health = ClaudeHealthFacts.read(p)

  local hour, day = 0, 0
  pcall(function() hour = getGameTime():getHour() end)
  pcall(function() day = getGameTime():getNightsSurvived() end)

  local hunger = st:get(CharacterStat.HUNGER)
  local thirst = st:get(CharacterStat.THIRST)
  local fatigue = st:get(CharacterStat.FATIGUE)
  local endurance = st:get(CharacterStat.ENDURANCE)
  local panic = st:get(CharacterStat.PANIC)
  local candidates, nearbyLoot = scanLoot(p)
  local bestLoot = ClaudeLootPolicy.choose(candidates, lootNeeds(p))

  -- feed the HUD (visual transparency)
  HUD.hp, HUD.hunger, HUD.thirst, HUD.fatigue, HUD.panic = hp, hunger, thirst, fatigue, panic
  HUD.zNear, HUD.zClose, HUD.zDist, HUD.zDir = zNear, zClose, nearestD, nearestDir
  HUD.foods, HUD.waters, HUD.weapon, HUD.room = foods, waters, weapon, room
  HUD.qlen, HUD.day, HUD.hour = qlen, day, hour
  local injuries = health.summary or {}
  HUD.injury = health.valid and "Body check: observed" or "Body check: incomplete"
  if health.observedParts and health.observedParts > 0 then
    HUD.injury = HUD.injury .. " | " .. tostring(injuries.bleedingParts or 0)
      .. " bleeding, " .. tostring(injuries.glassParts or 0) .. " glass"
  end

  local j = '{'
  j = j .. '"dead":' .. tostring(p:isDead())
  j = j .. ',"labProtocol":1,"armed":' .. tostring(lab.armed)
  j = j .. ',"bodyRevision":"survival-1"'
  j = j .. ',"session":"' .. esc(lab.session or "") .. '","world":"' .. esc(lab.world or "") .. '"'
  j = j .. ',"actor":"' .. esc(lab.actor or "") .. '","labToken":"' .. esc(lab.token or "") .. '"'
  j = j .. ',"observed_ms":' .. string.format("%.0f", tonumber(getTimestampMs()))
  j = j .. ',"controlReason":"' .. esc(lab.reason) .. '","lease_until_ms":' .. string.format("%.0f", lab.leaseUntil)
  j = j .. ',"stopFailed":' .. tostring(lab.stopFailed)
  j = j .. ',"x":' .. math.floor(px) .. ',"y":' .. math.floor(py) .. ',"z":' .. math.floor(pz)
  j = j .. ',"hour":' .. hour .. ',"day":' .. day
  j = j .. ',"outside":' .. tostring(p:isOutside())
  j = j .. ',"room":"' .. esc(room) .. '"'
  j = j .. ',"hp":' .. n2(hp)
  j = j .. ',"health":' .. ClaudeHealthFacts.toJSON(health)
  j = j .. ',"capabilities":{"injuryObservation":true,"injuryTreatment":false,"windowSmash":false,"windowTraverse":"adjacent_safe_only","tapDrinking":false}'
  j = j .. ',"hunger":' .. n2(hunger) .. ',"thirst":' .. n2(thirst) .. ',"fatigue":' .. n2(fatigue)
  j = j .. ',"endurance":' .. n2(endurance) .. ',"panic":' .. n2(panic)
  j = j .. ',"zTotal":' .. zTotal .. ',"zNear":' .. zNear .. ',"zClose":' .. zClose
  j = j .. ',"zDist":' .. n2(nearestD) .. ',"zDir":"' .. nearestDir .. '"'
  j = j .. ',"foods":' .. foods .. ',"waters":' .. waters
  j = j .. ',"inventoryCount":' .. inventoryCount
  j = j .. ',"nearbyLoot":{"valid":' .. tostring(nearbyLoot.valid)
    .. ',"containers":' .. nearbyLoot.containers .. ',"foods":' .. nearbyLoot.foods
    .. ',"waters":' .. nearbyLoot.waters .. ',"weapons":' .. nearbyLoot.weapons
    .. ',"useful":' .. tostring(bestLoot ~= nil)
  if bestLoot then
    j = j .. ',"dx":' .. bestLoot.dx .. ',"dy":' .. bestLoot.dy .. ',"distance":' .. bestLoot.distance
  end
  j = j .. '}'
  local receipt = actionEvidence.receipt
  if receipt then
    j = j .. ',"actionOutcome":{"seq":' .. receipt.seq .. ',"action":"' .. esc(receipt.action)
      .. '","world":"' .. esc(receipt.world) .. '","actor":"' .. esc(receipt.actor)
      .. '","session":"' .. esc(receipt.session)
      .. '","status":"' .. esc(receipt.status) .. '","added":' .. (receipt.added or 0)
      .. ',"hungerDrop":' .. string.format("%.6f",receipt.hungerDrop or 0)
      .. ',"thirstDrop":' .. string.format("%.6f",receipt.thirstDrop or 0)
      .. ',"detail":"' .. esc(receipt.detail) .. '"}'
  end
  j = j .. ',"bldgDir":"' .. bldgDir .. '","bldgDist":' .. bldgDist
  j = j .. ',"weapon":"' .. weapon .. '"'
  j = j .. ',"items":"' .. table.concat(names, ", ") .. '"'
  j = j .. ',"qlen":' .. qlen
  j = j .. ',"nativeBusy":' .. (nativeBusy == nil and "null" or tostring(nativeBusy))
  j = j .. ',"traversingWindow":' .. (traversing == nil and "null" or tostring(traversing))
  j = j .. ',"reflexed":' .. tostring(tick - reflexTick < 600)
  j = j .. ',"lastSeq":' .. lastSeq
  j = j .. ',"err":"' .. esc(lastError) .. '"'
  j = j .. '}'
  return j
end

local function writePercept(p)
  local ok, err = pcall(function()
    local w = getFileWriter("claude_percept.json", true, false)
    w:write(buildPercept(p)); w:close()
  end)
  if not ok then lastError = "percept:" .. tostring(err) end
end

-- ---------- movement (fluid) ----------
-- Walk to the FARTHEST LOADED square along (dx,dy). Far chunks may be unloaded, so instead of
-- halving down to a tiny hop we step the vector down until a square exists — longest smooth path.
local function stepWalk(p, dx, dy)
  local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
  if not lab.armed then return false end
  dx, dy = math.floor(tonumber(dx) or 0), math.floor(tonumber(dy) or 0)
  local length = math.sqrt(dx*dx + dy*dy)
  if length > 4 then dx, dy = math.floor(dx/length*3 + 0.5), math.floor(dy/length*3 + 0.5) end
  if dx == 0 and dy == 0 then return false end
  for i = 8, 1, -1 do
    local tx = px + math.floor(dx * i / 8 + 0.5)
    local ty = py + math.floor(dy * i / 8 + 0.5)
    local sq = getCell():getGridSquare(tx, ty, pz)
    if sq then ISTimedActionQueue.add(ISWalkToTimedAction:new(p, sq)); return true end
  end
  lastError = "move: no loaded square along heading"
  return false
end

local function doMove(p, dx, dy)
  if not lab.armed then return end
  actionEvidence:cancel("movement_replaced_action")
  ISTimedActionQueue.clear(p)
  travel.active, travel.budget = false, 0
  stepWalk(p, dx, dy)
end

-- No momentum: a completed walk remains stopped until a new validated decision.

-- ---------- other actions ----------
local function doEat(p)
  local items = p:getInventory():getItems()
  for i = 0, items:size() - 1 do
    local it = items:get(i)
    if isFoodItem(it,p) then ISTimedActionQueue.add(ISEatFoodAction:new(p, it, 1)); return end
  end
  lastError = "eat: no safe edible food"
end
local function doDrink(p)
  local items = p:getInventory():getItems()
  for i = 0, items:size() - 1 do
    local it = items:get(i)
    if isWaterItem(it) then ISTimedActionQueue.add(ISDrinkFluidAction:new(p, it, 1)); return end
  end
  lastError = "drink: no water"
end
local function doEquip(p)
  local w = nil
  pcall(function() w = p:getInventory():getBestWeapon(p:getDescriptor()) end)
  if w then ISTimedActionQueue.add(ISEquipWeaponAction:new(p, w, 25, true)) else lastError = "equip: no weapon" end
end
local function doLoot(p)
  local candidates = scanLoot(p)
  local best, picks = ClaudeLootPolicy.choose(candidates, lootNeeds(p))
  if not best then lastError = "loot: no useful supplies or weapon within 4 tiles"; return end
  lastLootTick = tick
  ISTimedActionQueue.clear(p)
  -- walkAdj can return false without throwing. Never queue transfers after that failure.
  local ok, walked = pcall(luautils.walkAdj, p, best.square, true)
  if not ok or walked ~= true then lastError = "loot: no adjacent route"; return end
  local names = {}
  for _, selected in ipairs(picks) do
    local it = selected.item
    ISTimedActionQueue.add(ISInventoryTransferAction:new(p, it, best.container, p:getInventory(), 10))
    pcall(function() table.insert(names, it:getDisplayName()) end)
  end
  HUD.action = "LOOT"
  HUD.thought = "Trying to collect: " .. table.concat(names, ", ")

end

-- close the nearest open door (buys time when fleeing indoors — zombies must thump through)
local function doCloseDoor(p)
  local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
  local door = nil
  for dx = -2, 2 do
    for dy = -2, 2 do
      local sq = getCell():getGridSquare(px + dx, py + dy, pz)
      if sq then
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
          local o = objs:get(i)
          local open = false
          pcall(function() if instanceof(o, "IsoDoor") and o:IsOpen() then open = true end end)
          if open then door = o; break end
        end
      end
      if door then break end
    end
    if door then break end
  end
  if door then ISTimedActionQueue.add(ISOpenCloseDoor:new(p, door)) else lastError = "closedoor: no open door within 2 tiles" end
end

-- Legacy BREAKIN may only traverse an already-open, currently safe adjacent window.
-- Never smash glass, clear existing work, or blindly append a walk-and-climb chain.
local function doBreakin(p)
  local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
  local win, blocked = nil, "no adjacent safe window"
  for dx = -2, 2 do
    for dy = -2, 2 do
      local sq = getCell():getGridSquare(px + dx, py + dy, pz)
      if sq then
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
          local o = objs:get(i)
          local isWin = false
          pcall(function() if instanceof(o, "IsoWindow") then isWin = true end end)
          if isWin then
            local result = ClaudeWindowPolicy.inspect(p, o)
            if result.allowed then win = o; break end
            blocked = result.reason or "window facts unavailable"
          end
        end
      end
      if win then break end
    end
    if win then break end
  end
  if not win then lastError = "breakin: " .. tostring(blocked); return end
  local ownerSession, ownerToken, ownerWorld, ownerActor, ownerSequence = lab.session, lab.token, lab.world, lab.actor, lab.lastSeq
  local createdAt = tonumber(getTimestampMs())
  local function authorized()
    return lab.armed and lab.player == p and getSpecificPlayer(0) == p
      and lab.session == ownerSession and lab.token == ownerToken and lab.lastSeq == ownerSequence
      and lab.world == ownerWorld and lab.actor == ownerActor
      and tostring(getWorld():getWorld()) == ownerWorld and tostring(p:getOnlineID()) == ownerActor
      and tonumber(getTimestampMs()) >= createdAt and tonumber(getTimestampMs()) <= lab.leaseUntil
  end
  local queued, reason = ClaudeWindowPolicy.queue(p, win, nil, function(blocker)
    lastError = "breakin: " .. tostring(blocker)
  end, authorized)
  if not queued then lastError = "breakin: " .. tostring(reason or "window traversal refused") end
end

-- CONCEAL: hunker down — close every open door and window curtain nearby so he can't be seen
-- from outside. The core "hide inside" behavior.
local function doConceal(p)
  local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
  local did = false
  for dx = -2, 2 do
    for dy = -2, 2 do
      local sq = getCell():getGridSquare(px + dx, py + dy, pz)
      if sq then
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
          local o = objs:get(i)
          pcall(function()
            if instanceof(o, "IsoDoor") and o:IsOpen() then ISTimedActionQueue.add(ISOpenCloseDoor:new(p, o)); did = true end
          end)
          pcall(function()
            if instanceof(o, "IsoWindow") and o:HasCurtains() and o:isCurtainOpen() then
              ISTimedActionQueue.add(ISOpenCloseCurtain:new(p, o, o:getOtherSideWindow())); did = true
            end
          end)
        end
      end
    end
  end
  if not did then lastError = "conceal: nothing open to close nearby" end
end

-- night vision is bad in Zomboid — keep a light source lit after dark so he can see (and act).
local function manageLight(p)
  local hour = 12
  pcall(function() hour = getGameTime():getHour() end)
  local night = hour < 7 or hour >= 20
  pcall(function()
    local items = p:getInventory():getItems()
    for i = 0, items:size() - 1 do
      local it = items:get(i)
      local strength = 0
      pcall(function() strength = it:getLightStrength() end)
      if strength and strength > 0 then pcall(function() it:setActivated(night) end) end
    end
  end)
end

local function execIntent(p, line)
  if line == lastIntentRaw then return end -- consumed duplicate: preserve the actual action diagnostic
  local parts, rejection = lab:accept(line)
  if not parts then lastError = "intent:" .. tostring(rejection); return end
  local seq = tonumber(parts[1])
  lastIntentRaw = line
  lastSeq, lastError = seq, ""
  local action = parts[2] or "WAIT"
  local a, b = parts[3], parts[4]
  local say = parts[5] or ""
  local thought = parts[6] or ""
  local goal = parts[7] or ""
  if #say > 0 then pcall(function() p:Say(say) end) end

  -- HUD update (transparency)
  HUD.action = (action == "MOVE") and ("MOVE " .. tostring(a) .. "," .. tostring(b)) or action
  HUD.say = say
  if #thought > 0 then HUD.thought = thought end
  if #goal > 0 then HUD.goal = goal end
  HUD.lastIntentTick = tick
  HUD.seq = seq

  if action == "LOOT" or action == "EAT" or action == "DRINK" then
    actionEvidence:begin(seq, action, inventorySnapshot(p))
  else
    actionEvidence:cancel("superseded_by_" .. action)
  end
  if action == "MOVE" then
    local px2, py2 = p:getX(), p:getY()
    local qlen = 0
    pcall(function() local q = ISTimedActionQueue.getTimedActionQueue(p); if q and q.queue then qlen = #q.queue end end)
    local _, _, _, nd, _, ndx, ndy = zombieScan(px2, py2)
    -- don't interrupt an in-progress loot: let the item transfers finish so he actually gets what
    -- he said he's grabbing (unless a zombie is right on him — survival wins).
    if (tick - lastLootTick < 400) and qlen > 0 and not (nd >= 0 and nd < 8) then
      HUD.thought = "Finishing the grab first."
    -- anti-ping-pong: while we just fled, ignore a brain move heading BACK toward the zombie.
    elseif nd >= 0 and nd < 12 and (tick - reflexTick < 90)
       and ((tonumber(a) or 0) * ndx + (tonumber(b) or 0) * ndy) > 0 then
      HUD.thought = "Not yet — that's back toward them. Opening the gap first."
    else
      doMove(p, a, b)
    end
  elseif action == "EAT" then travel.active = false; doEat(p)
  elseif action == "DRINK" then travel.active = false; doDrink(p)
  elseif action == "LOOT" then travel.active = false; doLoot(p)
  elseif action == "EQUIP" then travel.active = false; doEquip(p)
  elseif action == "CLOSEDOOR" then travel.active = false; doCloseDoor(p)
  elseif action == "CONCEAL" then travel.active = false; doConceal(p)
  elseif action == "BREAKIN" then travel.active = false; doBreakin(p)
  elseif action == "STOP" then travel.active = false; ISTimedActionQueue.clear(p)
  else travel.active = false; observing = true end -- WAIT: hold and visibly scan
  if action ~= "WAIT" then observing = false end
end

local function pollIntent(p)
  local ok, err = pcall(function()
    local r = getFileReader("claude_intent.txt", false)
    if not r then return end
    local line = r:readLine(); r:close()
    if line and #tostring(line) > 0 then execIntent(p, tostring(line)) end
  end)
  if not ok then lastError = "poll:" .. tostring(err) end
end

-- ---------- reflex (the real survival engine — local & fast, no brain round-trip) ----------
-- Sum a repulsion vector AWAY from every zombie within range (closer = stronger), so we flee
-- along the safest heading instead of blindly away from just the nearest one (which could be
-- straight into two others). This is what keeps him alive between slow LLM decisions.
local FLEE_TRIGGER   = 8    -- flee only when a threat is genuinely close (was 12 — too jumpy)
local FLEE_INTERRUPT = 4    -- interrupt a task only when one's basically on him

local function fleeVector(px, py)
  local fx, fy, nearestD, danger = 0, 0, 9999, 0
  pcall(function()
    local zl = getCell():getZombieList()
    if not zl then return end
    for i = 0, zl:size() - 1 do
      local z = zl:get(i)
      local dx, dy = px - z:getX(), py - z:getY()   -- points AWAY from the zombie
      local d = math.sqrt(dx * dx + dy * dy)
      if d < nearestD then nearestD = d end
      if d <= 22 and d > 0.1 then
        local w = (22 - d) / 22                       -- 0..1, nearer pushes harder
        fx = fx + (dx / d) * w
        fy = fy + (dy / d) * w
        if d <= FLEE_TRIGGER then danger = danger + 1 end
      end
    end
  end)
  return fx, fy, nearestD, danger
end

-- nearest zombie + how many are within a radius
local function nearestZombie(px, py, r)
  local best, bd, cnt = nil, 9999, 0
  pcall(function()
    local zl = getCell():getZombieList()
    if not zl then return end
    for i = 0, zl:size() - 1 do
      local z = zl:get(i)
      local d = math.sqrt((z:getX() - px) ^ 2 + (z:getY() - py) ^ 2)
      if d <= r then cnt = cnt + 1 end
      if d < bd then bd, best = d, z end
    end
  end)
  return best, bd, cnt
end

-- ENGAGE: when he's armed and not overwhelmed, actually FIGHT — close on the nearest zombie
-- and swing. This runs locally every few ticks (the LLM is too slow to time hits), but it no
-- longer just cowers: it stands its ground and kills manageable threats.
local function engage(p, z, d)
  actionEvidence:cancel("combat_reflex_interrupted_action")
  pcall(function() p:faceThisObject(z) end)
  if d <= 1.8 then
    pcall(function() p:DoAttack(0) end)          -- in range: swing
    HUD.action = "FIGHT"
    HUD.thought = "On it — swing and drop this one."
  else
    local dx, dy = z:getX() - p:getX(), z:getY() - p:getY()   -- close the gap
    local len = math.max(1, math.sqrt(dx * dx + dy * dy))
    ISTimedActionQueue.clear(p)
    travel.active = false
    stepWalk(p, math.floor(dx / len * math.min(d, 6) + 0.5), math.floor(dy / len * math.min(d, 6) + 0.5))
    HUD.action = "ENGAGING"
    HUD.thought = "One ahead — closing in to take it down."
  end
end

-- FLEE reflex: repulsion-vector escape. Proactive — starts spacing out before contact.
local function reflex(p)
  local px, py = p:getX(), p:getY()
  local fx, fy, nearestD, danger = fleeVector(px, py)
  if danger == 0 then return end
  local qlen = 0
  pcall(function() local q = ISTimedActionQueue.getTimedActionQueue(p); if q and q.queue then qlen = #q.queue end end)
  local emergency = nearestD <= FLEE_INTERRUPT
  if qlen > 0 and not emergency then return end
  if tick - reflexTick < 45 and not emergency then return end
  local len = math.sqrt(fx * fx + fy * fy)
  if len < 0.01 then return end
  reflexTick = tick
  if emergency then pcall(function() p:Say("!") end) end
  HUD.action = "FLEE (reflex)"
  HUD.thought = "Too close — breaking away to open the gap."
  doMove(p, math.floor(fx / len * 16 + 0.5), math.floor(fy / len * 16 + 0.5))  -- short, controlled break
end

-- Fight-or-flee: FIGHT when armed, not swarmed, and healthy enough. Only FLEE when he'd actually
-- lose — unarmed, outnumbered (3+ close), or badly hurt. Returns true if it took over.
local function survive(p)
  local px, py = p:getX(), p:getY()
  local z, nd = nearestZombie(px, py, 11)             -- only engage/flee range; farther = brain's job
  if not z or nd > 11 then return false end           -- nothing close -> let the brain pursue its goal
  local _, _, swarm = nearestZombie(px, py, 7)        -- how many are right around us
  local armed, hp = false, 100
  pcall(function() armed = p:getPrimaryHandItem() ~= nil end)
  pcall(function() hp = p:getBodyDamage():getOverallBodyHealth() end)
  local cornered = nd <= FLEE_INTERRUPT and (swarm >= 2 or not armed)
  -- STAND AND FIGHT is the default when he can win — don't let a lone zombie scare him off task.
  if armed and hp >= 30 and swarm <= 2 and not cornered then
    engage(p, z, nd)
    return true
  end
  -- FLEE only when he'd actually lose: unarmed & close, swarmed, badly hurt, or cornered.
  if (not armed and nd <= FLEE_TRIGGER) or swarm >= 3 or (hp < 30 and nd <= FLEE_TRIGGER) or cornered then
    reflex(p)
    return true
  end
  return false                                        -- otherwise keep pursuing the objective
end

-- auto game-speed: fast-forward the boring safe stretches, snap to normal near danger so the
-- reflex keeps full fidelity. Toggle with G. The user's manual pause (speed 0) always wins.
local autoSpeed = false -- lab control never changes game speed

-- ---------- main loop ----------
local function onTick()
  tick = tick + 1
  local p = getSpecificPlayer(0)
  local active = lab:update(p)
  if not p then return end
  lastSeq = lab.lastSeq
  if actionEvidence.receipt and actionEvidence.receipt.status == "pending" then
    local ok, qlen = pcall(function()
      local q = ISTimedActionQueue.getTimedActionQueue(p)
      return q and q.queue and #q.queue or -1
    end)
    actionEvidence:update(inventorySnapshot(p), ok and qlen or -1, tonumber(getTimestampMs()))
  end
  if lab.changed or tick % PERCEPT_EVERY == 0 then
    writePercept(p); lab.changed = false
  end
  if not active then
    HUD.action = p:isDead() and "DEAD" or ("DISARMED — " .. lab.reason)
    return
  end
  if not announced then announced = true; pcall(function() p:Say("Claude lab armed. Testing survival actions.") end) end
  -- Java traversal outlives the Lua timed action. Keep observation and explicit
  -- STOP/takeover handling, but do not add reflexes, movement or facing work.
  local _, _, traversing = readActionState(p)
  if traversing ~= false then
    if tick % PERCEPT_EVERY == 0 then writePercept(p) end
    if tick % INTENT_EVERY == 0 then pollIntent(p) end
    return
  end
  local px, py = p:getX(), p:getY()

  -- SURVIVAL first, every ~5 ticks (fight/flee locally — the brain is too slow for this).
  -- NOTE: no auto game-pause — PZ halts OnTick at speed 0 so the mod could never un-pause itself
  -- (it froze the game). The flee reflex handles dire moments instead; pause manually if you want.
  local acted = false
  if tick % 5 == 0 then pcall(function() acted = survive(p) end) end

  -- Lab mode leaves persistent sneak/light settings under human control.
  if tick % 120 == 0 then pcall(function() scanBuildings(math.floor(px), math.floor(py), math.floor(p:getZ())) end) end

  -- VISIBLE "look around" while deliberately observing: turn through the compass every ~0.5s
  -- so a pause reads clearly as scanning, not a freeze. Exaggerated on purpose.
  if observing and not acted then
    local qlen = 0
    pcall(function() local q = ISTimedActionQueue.getTimedActionQueue(p); if q and q.queue then qlen = #q.queue end end)
    if qlen == 0 and tick % 30 == 0 then
      local rad = (math.floor(tick / 30) % 8) * (math.pi / 4)
      pcall(function() p:faceLocation(px + math.cos(rad) * 4, py + math.sin(rad) * 4) end)
    end
  end

  -- SITUATIONAL AWARENESS: while moving calmly, glance toward the nearest zombie in view so he
  -- visibly tracks threats (and his vision cone covers them) instead of walking oblivious.
  if not acted and tick % 40 == 0 then
    local z, nd = nearestZombie(px, py, 22)
    if z and nd > 7 then pcall(function() p:faceThisObject(z) end) end
  end

  if tick % PERCEPT_EVERY == 0 then writePercept(p) end
  if tick % INTENT_EVERY == 0 then pollIntent(p) end
end
Events.OnTick.Add(onTick)

-- ================= HUD (on-screen transparency) =================
ClaudeHUD = ISUIElement:derive("ClaudeHUD")
function ClaudeHUD:new()
  local sh = 1080
  pcall(function() sh = getCore():getScreenHeight() end)
  local h = 202
  local o = ISUIElement:new(14, sh - h - 48, 384, h)   -- bottom-left, above the vanilla bars
  setmetatable(o, self); self.__index = self
  return o
end
function ClaudeHUD:wrap(text, n)
  local out, line = {}, ""
  for word in string.gmatch(tostring(text), "%S+") do
    if #line + #word + 1 > n then table.insert(out, line); line = word
    else line = (line == "") and word or (line .. " " .. word) end
  end
  if line ~= "" then table.insert(out, line) end
  return out
end
function ClaudeHUD:statusText()
  if manualMode then return "MANUAL" end
  if string.find(HUD.action, "reflex") then return "REFLEX" end
  local since = tick - HUD.lastIntentTick
  if since < 60 then return "NEW PLAN" end
  if HUD.qlen > 0 then return "ACTING" end
  return "thinking..."
end
function ClaudeHUD:bar(label, v, x, y, invert)
  v = math.max(0, math.min(1, v or 0))
  self:drawText(label, x, y - 1, 0.6, 0.66, 0.72, 1, UIFont.Small)
  local bx, bw = x + 32, 46
  self:drawRect(bx, y + 2, bw, 8, 0.5, 0.15, 0.19, 0.23)
  local danger = invert and (v > 0.7) or ((not invert) and (v < 0.3))
  local r, g, b = 0.5, 0.82, 0.72
  if danger then r, g, b = 0.9, 0.33, 0.33 end
  self:drawRect(bx, y + 2, bw * v, 8, 0.95, r, g, b)
end
function ClaudeHUD:render()
  if not HUD.visible then return end
  local w, h = self.width, self.height
  self:drawRect(0, 0, w, h, 0.62, 0.04, 0.06, 0.08)
  self:drawRectBorder(0, 0, w, h, 0.7, 0.5, 0.82, 0.72)
  self:drawText("CLAUDE", 12, 8, 0.5, 0.82, 0.72, 1, UIFont.Medium)
  self:drawTextRight(self:statusText(), w - 12, 11, 1, 0.83, 0.28, 1, UIFont.Small)
  if HUD.goal ~= "" then
    for _, gl in ipairs(self:wrap("GOAL: " .. HUD.goal, 62)) do
      self:drawText(gl, 12, 28, 1, 0.83, 0.28, 1, UIFont.Small); break  -- one line, amber
    end
  end
  self:drawText("ACTION: " .. HUD.action, 12, 44, 0.9, 0.95, 1, 1, UIFont.Small)
  local ty = 64
  for _, line in ipairs(self:wrap(HUD.thought, 58)) do
    if ty > 104 then break end
    self:drawText(line, 12, ty, 0.74, 0.79, 0.85, 1, UIFont.Small); ty = ty + 15
  end
  local by = 116
  self:bar("HP", (HUD.hp or 0) / 100, 12, by, false)
  self:bar("HUN", HUD.hunger, 104, by, true)
  self:bar("THI", HUD.thirst, 196, by, true)
  self:bar("FAT", HUD.fatigue, 288, by, true)
  local zt = (HUD.zDist and HUD.zDist >= 0) and (math.floor(HUD.zDist) .. " " .. HUD.zDir) or "none near"
  self:drawText("Zombies  " .. HUD.zClose .. " close / " .. HUD.zNear .. " near  (" .. zt .. ")", 12, by + 22, 0.9, 0.62, 0.62, 1, UIFont.Small)
  self:drawText("Inv  " .. HUD.foods .. " food, " .. HUD.waters .. " water  |  " .. HUD.weapon, 12, by + 38, 0.7, 0.86, 0.7, 1, UIFont.Small)
  self:drawTextRight("day " .. HUD.day .. "  " .. string.format("%02d", HUD.hour) .. ":00   [H hides]", w - 12, by + 38, 0.55, 0.6, 0.66, 1, UIFont.Small)
  self:drawText(HUD.injury, 12, by + 56, 0.9, 0.72, 0.62, 1, UIFont.Small)
end

local hudInstance
local function startHUD()
  if hudInstance then return end
  hudInstance = ClaudeHUD:new()
  hudInstance:initialise()
  hudInstance:addToUIManager()
end
Events.OnGameStart.Add(startHUD)
Events.OnCreatePlayer.Add(function() startHUD() end)
-- Any keyboard or mouse input permanently revokes this lab session. Restart an
-- explicitly opted-in bridge to arm the new session; idle time never resumes it.
Events.OnKeyPressed.Add(function(key)
  lab:manual()
  if key == Keyboard.KEY_H then HUD.visible = not HUD.visible end
end)
Events.OnMouseDown.Add(function() lab:manual() end)
if Events.OnRightMouseDown then Events.OnRightMouseDown.Add(function() lab:manual() end) end
