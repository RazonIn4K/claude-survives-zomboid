-- Read-only awareness of every loaded zombie, without visibility or floor
-- filtering. A missing, changing, malformed, or bounded list is not an all-clear.
ClaudeThreatFacts = {}
local MAX_ZOMBIES = 16384
local function finite(value)
    return type(value)=="number" and value==value and value>-math.huge and value<math.huge
end
local function count(value)
    return finite(value) and value==math.floor(value) and value>=0 and value<=9007199254740991
end

function ClaudeThreatFacts.read(px,py)
    local result={valid=false,status="unknown",error=nil,scanned=0,limit=MAX_ZOMBIES,
        zTotal=-1,zNear=0,zClose=0,zDist=-1,zDir="-",dx=0,dy=0}
    local ok=pcall(function()
        if not finite(px) or not finite(py) then result.error="threat_player_position_unknown";return end
        local cell=getCell()
        if not cell then result.error="threat_cell_unavailable";return end
        local zombies=cell:getZombieList()
        if not zombies then result.error="threat_list_unavailable";return end
        local size=zombies:size()
        if not count(size) then result.error="threat_count_unknown";return end
        result.zTotal=size
        local seen={}
        for index=0,math.min(size,MAX_ZOMBIES)-1 do
            local zombie=zombies:get(index)
            if not zombie or seen[zombie] then result.error="threat_entry_unknown";return end
            seen[zombie]=true
            local x,y=zombie:getX(),zombie:getY()
            if not finite(x) or not finite(y) then result.error="threat_position_unknown";return end
            local dx,dy=x-px,y-py
            local distance=math.sqrt(dx*dx+dy*dy)
            if not finite(dx) or not finite(dy) or not finite(distance) then
                result.error="threat_distance_unknown";return
            end
            result.scanned=result.scanned+1
            if result.zDist<0 or distance<result.zDist then
                result.zDist,result.dx,result.dy=distance,dx,dy
            end
            if distance<=30 then result.zNear=result.zNear+1 end
            if distance<=10 then result.zClose=result.zClose+1 end
        end
        if zombies:size()~=size then result.error="threat_list_changed";return end
        if size>MAX_ZOMBIES then result.error="threat_scan_bounded";return end
        result.valid=true
    end)
    if not ok then result.error="threat_facts_unavailable" end
    result.status=result.valid and "observed" or (result.scanned>0 and "partial" or "unknown")
    if result.zDist>=0 then
        local ew=result.dx>3 and "E" or (result.dx< -3 and "W" or "")
        local ns=result.dy>3 and "S" or (result.dy< -3 and "N" or "")
        result.zDir=(ns..ew~="") and (ns..ew) or "HERE"
    end
    return result
end

-- Counts and distances remain the legacy top-level percept fields. This
-- metadata belongs to that same snapshot; unknown is never encoded as valid.
function ClaudeThreatFacts.toJSON(result)
    local error=result.error and ('"'..result.error..'"') or "null"
    return '{"valid":'..tostring(result.valid)..',"status":"'..result.status
        ..'","scanned":'..result.scanned..',"limit":'..result.limit..',"error":'..error..'}'
end

return ClaudeThreatFacts
