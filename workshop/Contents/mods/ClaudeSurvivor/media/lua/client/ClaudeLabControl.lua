-- Safe-default lab protocol. All autonomy is gated by a fresh, explicitly armed
-- bridge lease. This is a player-client experiment, not multiplayer NPC ownership.
ClaudeLabControl = {}

local function fields(line)
    local result = {}
    for value in (line .. "|"):gmatch("(.-)|") do result[#result + 1] = value end
    return result
end
local function integer(value)
    if type(value) ~= "string" or not value:match("^%-?%d+$") then return nil end
    local n = tonumber(value)
    if not n or n ~= n or math.abs(n) >= 9007199254740991 or n ~= math.floor(n) then return nil end
    return n
end
local function identifier(value)
    return type(value) == "string" and #value > 0 and #value <= 180 and value:match("^[%w_%.:%-]+$")
end
local allowed = {MOVE=true, NAVIGATE=true, LOOT=true, EAT=true, DRINK=true, DRINKTAP=true, FILLBOTTLE=true, BANDAGE=true, EQUIP=true,
    CLOSEDOOR=true, CONCEAL=true, BREAKIN=true, STOP=true, WAIT=true}

function ClaudeLabControl.new(env)
    local self = {armed=false, session=nil, world=nil, actor=nil, token="",
        reason="waiting_for_player", player=nil, lastSeq=0, leaseUntil=0,
        lastTick=nil, changed=true, counter=0, stopFailed=false}

    function self:reset(player, reason)
        local wasArmed, previousPlayer = self.armed, self.player
        self.armed, self.token, self.leaseUntil = false, "", 0
        self.reason, self.player, self.lastSeq = reason, player, 0
        self.counter = self.counter + 1
        self.session = string.format("%.0f", env.now()) .. "-" .. tostring(env.random()) .. "-" .. self.counter
        self.changed = true
        if wasArmed then
            local ok, stopped = pcall(env.stop, previousPlayer)
            self.stopFailed = not ok or stopped ~= true
        end
    end

    function self:manual()
        -- Rotate even while disarmed: invalidate an ARM already on its way to Lua.
        if self.player then self:reset(self.player, "manual_takeover") end
    end

    function self:update(player)
        local now = env.now()
        if not player then
            if self.player then self:reset(self.player, "player_absent"); self.player = nil end
            self.lastTick = now
            return false
        end
        local world, actor = env.identity(player)
        if not identifier(world) or not identifier(actor) then
            self:reset(player, "unsupported_identity")
            return false
        end
        if self.player ~= player or self.world ~= world or self.actor ~= actor then
            self:reset(player, "new_game_session")
            self.world, self.actor = world, actor
        end
        if player:isDead() then
            if self.armed then self:reset(player, "player_dead") end
            self.lastTick = now
            return false
        end
        if self.armed and self.lastTick and (now - self.lastTick > 2000 or now < self.lastTick) then
            self:reset(player, "tick_gap")
        end
        self.lastTick = now
        -- Session duration belongs to the bridge mode; the body enforces each short lease.
        if self.armed and now > self.leaseUntil then
            self:reset(player, "heartbeat_expired")
        end
        local moving = false
        pcall(function() moving = player:pressedMovement(false) or player:pressedCancelAction() end)
        if moving then self:manual(); return false end
        local line = env.readControl()
        if type(line) == "string" and #line <= 1024 then
            local f = fields(line)
            local issued, expires = integer(f[7]), integer(f[8])
            if #f == 8 and f[1] == "1" and f[2] == self.session and f[3] == self.world
                and f[4] == self.actor and identifier(f[5]) and issued and expires
                and issued <= now + 500 and now - issued <= 3000 and expires > now
                and expires > issued and expires - issued <= 3000 then
                if f[6] == "ARM" and (not self.armed or f[5] == self.token) then
                    if not self.armed and env.busy and env.busy(player) then
                        self.reason = "player_busy"
                        return false
                    end
                    if not self.armed then self.changed = true; self.stopFailed = false end
                    self.armed, self.token, self.leaseUntil = true, f[5], expires
                    self.reason = "bridge_armed"
                elseif f[6] == "DISARM" and self.armed and f[5] == self.token then
                    self:reset(player, "bridge_disarmed")
                end
            end
        end
        return self.armed
    end

    function self:accept(line)
        local now = env.now()
        if not self.armed or now > self.leaseUntil or type(line) ~= "string" or #line > 2048 then
            return nil, "controller_disarmed"
        end
        local f = fields(line)
        local seq, issued, expires = integer(f[1]), integer(f[13]), integer(f[14])
        if #f ~= 14 or f[8] ~= "LAB1" or f[9] ~= self.session or f[10] ~= self.world
            or f[11] ~= self.actor or f[12] ~= self.token then return nil, "identity_mismatch" end
        if not seq or seq <= self.lastSeq or seq > 2147483647 then return nil, "invalid_sequence" end
        if not issued or not expires or issued > now + 500 or now - issued > 3000
            or expires <= now or expires <= issued or expires - issued > 3000 then
            return nil, "expired_intent"
        end
        if not allowed[f[2]] then return nil, "unknown_action" end
        if f[2] ~= "STOP" and f[2] ~= "WAIT" and env.busy and env.busy(self.player) then
            return nil, "body_busy"
        end
        if f[2] == "MOVE" then
            local dx, dy = integer(f[3]), integer(f[4])
            if not dx or not dy or dx*dx + dy*dy == 0 or dx*dx + dy*dy > 16 then
                return nil, "movement_bounds"
            end
        elseif f[2] == "NAVIGATE" then
            local destination,unused=integer(f[3]),integer(f[4])
            if not destination or destination<1 or destination>2147483647 or unused~=0 then
                return nil,"navigation_target_invalid"
            end
        end
        self.lastSeq = seq
        return f
    end
    return self
end
