--[[
  Smarter Patrols

  Two kinds of AI attack troops are split into groups by the AI character file: patrol
  (AttUnitPatrol, behaviour 16, troop slots 15 and 16) and siege defence (AttUnitSiegeDef,
  behaviour 19, slots 190 and 191). What the game does with them:

  * Patrol: sendAITribe_0xf_toAttackPatrol (attack states 3, 4 and 5, once per AI week) only
    ever orders slot 15. It walks to a tile 11-16 tiles away that lies on the ring 12 tiles of
    walking out from the attacked castle (layer 1105). Slot 16 never gets an order and stands
    at the rally point for the whole attack.
  * Siege defence: moveAttackingUnitsToNextRallyPoint (states 3, 4) walks both slots from one
    of the team's built catapults, trebuchets and fire ballistas to the next, in unit-array
    order and in step with each other; aiCommandWallAssaultTribes (state 5) gives both the
    "attack what is in reach" order (assignAttackTargetsForTribe, kind 0x3F2).
  * Both are capped at 2 groups by the slot layout: addUnitToSmallestBehaviourTypeTribe uses
    slots start .. start + AttUnit<x>GroupsCount - 1, so a 3rd patrol group lands in the moat
    diggers' slot 17 and a 3rd siege defence group in the main army's slot 192.

  This module replaces those three functions with lua (a jmp at each function's start), lets
  every new recruit of the two kinds go into the first group (the group count read in
  addUnitToSmallestBehaviourTypeTribe becomes 1) and splits the units itself into as many
  troops as asked once the army has set out (attack states 3 to 5). The extra troops are not
  registered with the AI, so the module gives them every order the AI would. When the attack
  state leaves 3..5 (castle breached, lord dead, retreat, help request), every extra troop is
  put back into the AI's own troop with the game's addUnitToItsTribe, and on a retreat the
  AI's retreat order is given again so they go home too. That check runs right after the
  AI's attack state update (the call after it in updateAIBehaviour, chained the way lord-hunt
  does it). Nothing is saved: after loading, units in unregistered troops go back to the AI.

  Patrol routes, by group number g: pattern (g - 1) % 3 - 0 round the castle one way, 1 the
  other way, 2 back and forth along the front (the side facing the attacker's own keep);
  every further round of three follows the same routes a quarter circle behind. The route
  points are 16 directions from the attacked keep, each the first tile out along that
  direction on the distance ring the AI's own patrol uses.
]]

local MODULE_NAME = "smarter-patrols"

local DEFAULTS = {
  patrol = { enabled = true, groups = 0, distance = 12 },
  siegedef = { enabled = true, groups = 4, forward = 4 },
  general = { min_size = 4 },
  diagnostics = { log = false },
}

---------------------------------------------------------------------------------------
-- What the game's code looks like where this module reads it
---------------------------------------------------------------------------------------

-- The three AI functions this module replaces (thiscall AICState, (player), ret 4).
local AOB_PATROL = "8B 4C 24 04 8B C1 69 C0 F4 39 00 00 83 B8 ? ? ? ? 00 74 52 8B D1 69 D2 F4 39 00 00 "
  .. "0F BF 92 ? ? ? ? 85 D2 74 3F"
local PATROL_SEND = 0x62              -- jmp sendAttackingPatrolTribeToComputedDestination
local SEND_MOVE = 0xD8                -- call giveTribeMoveInstruction in there
local AOB_RALLY = "83 EC 0C 8B 44 24 10 69 C0 F4 39 00 00 83 B8 ? ? ? ? 00 89 4C 24 08 ? ? ? ? ? ? "
  .. "53 55 33 C9 8D 80 ? ? ? ?"
local RALLY_REACHED = 0x73            -- call allUnitsReachedTheirDestination
local RALLY_MOVE = 0x127              -- call giveTribeMoveInstruction
local RALLY_CLOSEST = { 0x10F, { 0x66, 0x83, 0xB8 } }   -- cmp word [eax+closestEnemy],0x60
-- The siege defence wall assault loop: push 0x3F2 / ... / call assignAttackTargetsForTribe /
-- ... / cmp esi,2. The function starts 0x54 before it.
local AOB_WALL_LOOP = "68 F2 03 00 00 51 B9 ? ? ? ? 66 C7 80 ? ? ? ? 02 00 E8 ? ? ? ? 83 C6 01 "
  .. "83 C7 02 83 FE 02 7C A8"
local WALL_START = 0x54
local WALL_ASSIGN = 0x14              -- call assignAttackTargetsForTribe, from the loop match
local WALL_FUNCTION_HEAD = { 0x8B, 0x44, 0x24, 0x04, 0x69, 0xC0, 0xF4, 0x39, 0x00, 0x00 }

-- addUnitToSmallestBehaviourTypeTribe: the group count reads of the patrol and siege defence
-- cases (mov edx,[edx+ecx+0x264] / [edx+ecx+0x284]).
local AOB_SMALLEST = "83 EC 08 53 8B 5C 24 10 8B C3 69 C0 F4 39 00 00 8B 80 ? ? ? ? 85 C0 75 07 5B 83 C4 "
  .. "08 C2 0C 00 55 8D 50 FF 8B 44 24 1C 56 8B 34 85"
local COUNT_PATROL = { 0x65, { 0x8B, 0x94, 0x0A, 0x64, 0x02, 0x00, 0x00 } }
local COUNT_SIEGEDEF = { 0x83, { 0x8B, 0x94, 0x0A, 0x84, 0x02, 0x00, 0x00 } }
local COUNT_ONE = { 0xBA, 0x01, 0x00, 0x00, 0x00, 0x90, 0x90 }   -- mov edx,1 / nop / nop

-- The AI's distance-from-the-attacked-castle layer, read where the game's own patrol tile
-- search reads it: imul ecx,0x177BC / mov ecx,[ecx+layerIndex] / imul ecx,0x13A10 / ... /
-- movzx ebp,byte [ecx+eax+layer].
local AOB_LAYER = "8B 4C 24 24 0F B6 B8 ? ? ? ? 69 C9 BC 77 01 00 8B 89 ? ? ? ? 69 C9 10 3A 01 00 "
  .. "83 7C 24 2C 00 0F B6 AC 01"
local LAYER_INDEX = 0x13
local LAYER_BASE = 0x26
local LAYER_PLAYER_STRIDE, LAYER_STRIDE = 0x177BC, 0x13A10

-- updateAIBehaviour, per AI player: updateAIPlayerState / aiUpdateTaxesAndRations /
-- setFoodBuyPlan. The second call is chained (lord-hunt does the same).
local AOB_CALLS = "57 8B CB E8 ? ? ? ? 57 8B CB E8 ? ? ? ? 57 8B CB E8 ? ? ? ? 39 3D ? ? ? ? 74"
local CALL_HOOK = 0x0B

-- AICState::addUnitToItsTribe(unit, behaviour), and the arrays read out of it.
local AOB_ADD_TO_ITS_TRIBE = "56 57 8B 7C 24 0C 8B C7 69 C0 90 04 00 00 0F BF 90 ? ? ? ? 8B F2 69 F6 F4 39 00 00"
local ITS_UNIT_OWNER = { 0x0E, { 0x0F, 0xBF, 0x90 } }
local ITS_AI_TYPE = { 0x1D, { 0x83, 0xBE } }
local ITS_TRIBES = { 0x3F, { 0xB9 } }
local ITS_ADD_TO_TRIBE = 0x44

local AOB_ADD_TO_TRIBE = "53 8B 5C 24 08 56 57 8B 7C 24 14 8B C7 69 C0 ? ? 00 00 66 83"
local AOB_REMOVE_FROM_TRIBE = "53 55 56 8B 74 24 10 8B D9 8B CE 69 C9 90 04 00 00 66 83 B9 ? ? ? ? 00 57 8B 7C 24 18"
local REMOVE_STRIDE = { 0x5B, { 0x69, 0xC0 } }
local AOB_CREATE_TRIBE = "53 55 8B 6C 24 0C 56 57 BF ? ? 00 00 2B FD 33 DB 3B FB 7E"
local AOB_STANCE = "8B 44 24 04 66 8B 54 24 08 69 C0 ? ? 00 00 66 89 94 08 ? ? 00 00 C7 05"
local AOB_MOVE = "83 EC 34 33 C0 55 8B 6C 24 44 57 8B 7C 24 44 3B F8 89 4C 24 08 89 44 24 18"
local AOB_GO_DEFENSIVE = "83 EC 0C 53 8B 5C 24 14 69 DB F4 39 00 00 83 BB ? ? ? ? 00"

-- GameState::canNavigateFromKeepToKeep: the area map, the path finder and the area test.
local AOB_KEEP_TO_KEEP = "56 8B 74 24 08 8B C6 69 C0 F4 39 00 00 03 C1 83 B8 ? ? ? ? 00 75 09 B8 01 00 00 00"
local K2K_AREA = { 0x42, { 0x0F, 0xB7, 0x04, 0x4D } }
local K2K_PATHS = { 0x72, { 0xB9 } }
local K2K_CAN_NAVIGATE = 0x77

local AOB_TEAMS = "8B 0C 85 ? ? ? ? 8B 44 24 30 3B 0C 85 ? ? ? ?"
local TEAMS_OPERAND = 0x03
local AOB_TICKS = "8B 87 50 0A 00 00 8B 8F 98 09 00 00 8B 15"
local TICKS_OPERAND = 0x0E
local AOB_TILE_FLAGS = "F7 04 9D ? ? ? ? 00 01 00 00"
local TILE_FLAGS_OPERAND = 0x03

---------------------------------------------------------------------------------------
-- Layouts (the same in both executables unless read from code above)
---------------------------------------------------------------------------------------

local U = {
  STRIDE = 0x490, STATE = 0x8C, TYPE = 0x8E, OWNER = 0x96, X = 0xC4, Y = 0xC6, TILE = 0xD4,
  DYING = 0x2A0, CLOSEST_ENEMY = 0x2A6, TRIBE = 0x2D8, BUILT = 0x3FE, BEHAVIOUR = 0x42A,
  STATE_OFFSET = 0x614,
}
local P = {
  STRIDE = 0x39F4, HAS_KEEP = 0x94, KEEP_TILE = 0x1E0, AI_TYPE = 0x2300, AI_STATE = 0x2BA4,
  ATTACKED = 0x2BD8, TRIBE_IDS = 0x310C, TRIBE_UIDS = 0x329C,
}
local T = { OWNER = 0x2C, UID = 0x34, STATE = 0x40, LEADER = 0x5A, SIZE = 0x5C }
local MAP = { FLAGS = 0x165160, AREA = 0x363ED0, Y_OF_TILE = 0x742B90, ROWS = 0x8A40F8, SIZE = 400 }
local AIC_STRIDE = 0x2A4

-- The two kinds of troop this module splits.
local KINDS = {
  patrol = { behaviour = 16, slots = { 15, 16 }, aic = 0x264, stance = 1 },
  siegedef = { behaviour = 19, slots = { 190, 191 }, aic = 0x284, stance = 2 },
}
local KIND_PATROL, KIND_RALLY, KIND_WALL = 1, 2, 3

-- The engines the siege defence walks between: the game's own list (catapult, trebuchet, fire
-- ballista), built (byte +0x3FE == 3).
local ENGINES = { [39] = true, [40] = true, [77] = true }
local ENGINE_BUILT = 3
-- Units that shoot. A troop that is mostly something else walks in front of the engines.
local RANGED = { [22] = true, [23] = true, [70] = true, [72] = true, [74] = true, [76] = true }

local ASSAULT_TARGETS = 0x3F2         -- assignAttackTargetsForTribe: what is in reach
local CLOSE_ENEMY = 0x60              -- micro units (12 tiles): the game's "busy fighting"
local DIRECTIONS = 16                 -- route points round the castle
local LAG = 4                         -- a later round of groups follows a quarter circle behind
local FRONT_SPAN = 2                  -- front sweep: 2 directions either side of the front
local ARRIVED = 5                     -- tiles from a route point that count as there
local STEP_TICKS = 1600               -- a group that has not got there by then moves on anyway
local RING_SLACK = 6                  -- a route point may lie this much beyond the ring
local RAY_LENGTH = 180
local MAX_GROUPS = 12
local MAX_MOVES = 200                 -- units moved between groups per check
local LOAD_GAP = 4000                 -- a jump in the tick counter this big is a load
local ACTIVE_FIRST, ACTIVE_LAST = 3, 5
local RETREAT_STATES = { [0] = true, [8] = true, [9] = true }

---------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------

local rd32, rd16, rd8 = core.readInteger, core.readSmallInteger, core.readByte

local function scan(pattern, purpose)
  local ok, address = pcall(core.AOBScan, pattern)
  if not ok or address == nil then
    error(MODULE_NAME .. ": could not find " .. purpose)
  end
  return address
end

local function expectBytes(address, bytes, purpose)
  for index, byte in ipairs(bytes) do
    if (rd8(address + index - 1) & 0xFF) ~= byte then
      error(string.format("%s: %s at 0x%X is not the code this module knows", MODULE_NAME, purpose,
        address))
    end
  end
end

local function readOperand(base, site, purpose)
  expectBytes(base + site[1], site[2], purpose)
  return rd32(base + site[1] + #site[2])
end

local function readCallTarget(base, offset, purpose, opcode)
  expectBytes(base + offset, { opcode or 0xE8 }, purpose)
  return base + offset + 5 + rd32(base + offset + 1)
end

local function setting(config, group, name)
  local section = config[group]
  if type(section) == "table" and section[name] ~= nil then
    return section[name]
  end
  return DEFAULTS[group][name]
end

local function int(value, low, high)
  value = math.tointeger(math.floor(tonumber(value) or 0)) or 0
  if value < low then return low end
  if value > high then return high end
  return value
end

---------------------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------------------

local G = {}             -- addresses, filled by enable
local F = {}             -- the game's functions, exposed to lua
local O = {}             -- options
local attacks = {}       -- per AI player: { extras = {kind = {troop...}}, routes = {uid = route} }
local swept = {}         -- per AI player: troops checked after a load
local lastTick = nil
local broken = false

local function diag(fmt, ...)
  if O.log then
    log(INFO, MODULE_NAME .. ": " .. string.format(fmt, ...))
  end
end

local function player(p) return G.players + p * P.STRIDE end
local function unit(id) return G.units + id * U.STRIDE end
local function tribe(id) return G.tribes + id * G.tribeStride end

local function area(tile)
  if tile == nil or tile <= 0 then return 0 end
  return rd16(G.area + tile * 2) & 0xFFFF
end

local function tileAt(x, y)
  if x < 0 or y < 0 or x >= MAP.SIZE or y >= MAP.SIZE then return nil end
  return rd32(G.rows + y * 12) + x
end

local function tileXY(tile)
  local y = rd16(G.yOfTile + tile * 2)
  return tile - rd32(G.rows + y * 12), y
end

local function team(p) return rd32(G.teams + p * 4) end

local function distance(ax, ay, bx, by)
  local dx, dy = math.abs(ax - bx), math.abs(ay - by)
  return dx > dy and dx or dy
end

local function tribeAlive(id, uid)
  return id ~= nil and id > 0 and rd16(tribe(id) + T.STATE) == 2 and rd32(tribe(id) + T.UID) == uid
end

local function unitAlive(id)
  local u = unit(id)
  return rd16(u + U.STATE) == 2 and rd16(u + U.DYING) == 0
end

-- The castle under attack: the attacked player's keep tile, as x, y.
local function keepXY(p)
  if p < 1 or p > 8 or rd32(player(p) + P.HAS_KEEP) == 0 then return nil end
  local tile = rd32(player(p) + P.KEEP_TILE)
  if tile <= 0 then return nil end
  return tileXY(tile)
end

-- The game's own "can troops of this player walk from one area to the other", with and
-- without the climbing links.
local function reaches(memo, p, from, to)
  if from == 0 or to == 0 then return false end
  if from == to then return true end
  local key = from * 65536 + to
  local known = memo[key]
  if known == nil then
    known = F.canNavigate(G.paths, p, to, from, 0) ~= 0 or F.canNavigate(G.paths, p, to, from, 2) ~= 0
    memo[key] = known
  end
  return known
end

local function registeredTribes(a)
  local list = {}
  local base = player(a)
  for slot = 0, 199 do
    local id = rd16(base + P.TRIBE_IDS + slot * 2)
    if id > 0 and rd32(tribe(id) + T.UID) == rd32(base + P.TRIBE_UIDS + slot * 4) then
      list[id] = true
    end
  end
  return list
end

-- Troops another module keeps on purpose (lord-hunt's hunters and split troops).
local function keptElsewhere(unitId)
  local ok, lordHunt = pcall(function() return modules["lord-hunt"] end)
  if not ok or lordHunt == nil then return false end
  local fine, kept = pcall(function()
    return lordHunt:isHunter(unitId) or lordHunt:isSplit(unitId)
  end)
  return fine and kept == true
end

---------------------------------------------------------------------------------------
-- The groups of one kind: the AI's own troops (its slots) first, then this module's
---------------------------------------------------------------------------------------

local function attackOf(a)
  local S = attacks[a]
  if S == nil then
    S = { extras = { patrol = {}, siegedef = {} }, routes = {} }
    attacks[a] = S
  end
  return S
end

local function collectGroups(a, kind)
  local K = KINDS[kind]
  local S = attackOf(a)
  local base = player(a)
  local groups, byTribe = {}, {}
  for _, slot in ipairs(K.slots) do
    local id = rd16(base + P.TRIBE_IDS + slot * 2)
    local uid = rd32(base + P.TRIBE_UIDS + slot * 4)
    if id > 0 and tribeAlive(id, uid) and byTribe[id] == nil then
      local g = { id = id, uid = uid, units = {}, own = true }
      groups[#groups + 1] = g
      byTribe[id] = g
    end
  end
  local kept = {}
  for _, extra in ipairs(S.extras[kind]) do
    if tribeAlive(extra.id, extra.uid) and byTribe[extra.id] == nil then
      local g = { id = extra.id, uid = extra.uid, units = {}, own = false }
      groups[#groups + 1] = g
      byTribe[extra.id] = g
      kept[#kept + 1] = extra
    end
  end
  S.extras[kind] = kept

  local count = rd32(G.unitsThis)
  local total = 0
  for index = 1, count - 1 do
    local u = unit(index)
    if rd16(u + U.OWNER) == a and rd16(u + U.BEHAVIOUR) == K.behaviour and unitAlive(index) then
      local g = byTribe[rd16(u + U.TRIBE)]
      if g ~= nil then
        g.units[#g.units + 1] = index
        total = total + 1
      end
    end
  end

  -- Empty troops of this module's are forgotten; the AI's own stay where they are.
  local live = {}
  for _, g in ipairs(groups) do
    if #g.units > 0 or g.own then live[#live + 1] = g end
  end
  return live, total
end

local function moveUnit(index, from, to)
  F.removeFromTribe(G.tribesThis, index, from.id)
  F.addToTribe(G.tribesThis, index, to.id)
  to.units[#to.units + 1] = index
  to.moved = true
end

local function wantedGroups(a, kind)
  local asked = O[kind].groups
  if asked <= 0 then
    local character = rd32(player(a) + P.AI_TYPE)
    if character <= 0 then return 1 end
    asked = rd32(G.aiState + (character - 1) * AIC_STRIDE + KINDS[kind].aic)
  end
  return int(asked, 1, MAX_GROUPS)
end

-- Split the units of one kind into the groups asked for, as long as every group gets at least
-- the minimum size, and even the groups out when they drift apart by more than that.
local function split(a, kind)
  local groups, total = collectGroups(a, kind)
  if total == 0 then return groups end
  local S = attackOf(a)
  local wanted = math.min(wantedGroups(a, kind), math.max(1, total // O.minSize))

  local filled = {}
  for _, g in ipairs(groups) do
    if #g.units > 0 then filled[#filled + 1] = g end
  end
  -- Too many groups for the units left: this module's smallest troops are dissolved.
  while #filled > wanted do
    local smallest, at = nil, nil
    for i, g in ipairs(filled) do
      if not g.own and (smallest == nil or #g.units < #smallest.units) then smallest, at = g, i end
    end
    if smallest == nil then break end
    table.remove(filled, at)
    local into = filled[1]
    for _, index in ipairs(smallest.units) do moveUnit(index, smallest, into) end
    smallest.units = {}
  end
  groups = filled

  local created = 0
  while #groups < wanted do
    local id = F.createTribe(G.tribesThis, a)
    if id == nil or id <= 0 then break end
    local g = { id = id, uid = rd32(tribe(id) + T.UID), units = {}, own = false }
    groups[#groups + 1] = g
    S.extras[kind][#S.extras[kind] + 1] = { id = g.id, uid = g.uid }
    created = created + 1
  end

  local moves, tolerance = 0, math.max(1, created > 0 and 1 or O.minSize)
  while moves < MAX_MOVES do
    local big, small = groups[1], groups[1]
    for _, g in ipairs(groups) do
      if #g.units > #big.units then big = g end
      if #g.units < #small.units then small = g end
    end
    if #big.units - #small.units <= tolerance then break end
    moveUnit(table.remove(big.units), big, small)
    moves = moves + 1
  end
  if created > 0 or moves > 0 then
    for _, g in ipairs(groups) do F.setStance(G.tribesThis, g.id, KINDS[kind].stance) end
    diag("player %d: %d %s units in %d groups (%d new, %d moved)", a, total, kind, #groups, created, moves)
  end
  return groups
end

-- Every troop of this module's back to the AI's own troops.
local function mergeBack(a)
  local S = attacks[a]
  if S == nil then return 0 end
  local merged = 0
  for kind, list in pairs(S.extras) do
    local K = KINDS[kind]
    for _, extra in ipairs(list) do
      if tribeAlive(extra.id, extra.uid) then
        local count = rd32(G.unitsThis)
        for index = 1, count - 1 do
          local u = unit(index)
          if rd16(u + U.OWNER) == a and rd16(u + U.TRIBE) == extra.id and unitAlive(index) then
            F.removeFromTribe(G.tribesThis, index, extra.id)
            F.addToItsTribe(G.aiState, index, K.behaviour)
            merged = merged + 1
          end
        end
      end
    end
  end
  attacks[a] = nil
  return merged
end

-- After a load the module knows nothing of the troops it made: any patrol or siege defence
-- unit in a troop the AI has not registered goes back to the AI.
local function sweep(a)
  local registered = registeredTribes(a)
  local count = rd32(G.unitsThis)
  local moved = 0
  for index = 1, count - 1 do
    local u = unit(index)
    if rd16(u + U.OWNER) == a and unitAlive(index) then
      local behaviour = rd16(u + U.BEHAVIOUR)
      local id = rd16(u + U.TRIBE)
      if (behaviour == KINDS.patrol.behaviour or behaviour == KINDS.siegedef.behaviour)
          and id > 0 and not registered[id] and not keptElsewhere(index) then
        F.removeFromTribe(G.tribesThis, index, id)
        F.addToItsTribe(G.aiState, index, behaviour)
        moved = moved + 1
      end
    end
  end
  if moved > 0 then
    diag("player %d: %d units back in the AI's own troops after loading", a, moved)
  end
end

---------------------------------------------------------------------------------------
-- Moving a group along its route
---------------------------------------------------------------------------------------

local function leaderOf(g, a)
  local id = rd16(tribe(g.id) + T.LEADER)
  if id <= 0 or not unitAlive(id) or rd16(unit(id) + U.OWNER) ~= a or rd16(unit(id) + U.TRIBE) ~= g.id then
    id = g.units[1]
  end
  if id == nil or id <= 0 then return nil end
  local u = unit(id)
  return { id = id, x = rd16(u + U.X), y = rd16(u + U.Y), tile = rd32(u + U.TILE),
    closest = rd16(u + U.CLOSEST_ENEMY) }
end

local function routeOf(a, g)
  local S = attackOf(a)
  local route = S.routes[g.uid]
  if route == nil then
    route = {}
    S.routes[g.uid] = route
  end
  return route
end

-- Time to give the group its next point: it got there, or stands, or took too long. Not while
-- it is fighting (the game's own siege defence check), unless it has been at it a long time.
local function due(route, leader, tick, groupId)
  if route.point == nil or route.again then return true end
  local waited = tick - (route.tick or 0)
  if waited < 0 or waited > 2 * STEP_TICKS then return true end
  if leader.closest <= CLOSE_ENEMY then return false end
  if distance(leader.x, leader.y, route.point.x, route.point.y) <= ARRIVED then return true end
  if F.reached(G.tribesThis, groupId) ~= 0 then return true end
  return waited > STEP_TICKS
end

local function order(a, g, route, point, stance, tick)
  F.setStance(G.tribesThis, g.id, stance)
  local ok = F.move(G.tribesThis, g.id, point.x, point.y, 0, 0, 0)
  route.point, route.tick, route.again = point, tick, false
  return ok ~= 0
end

---------------------------------------------------------------------------------------
-- Patrol routes round the castle
---------------------------------------------------------------------------------------

-- The 16 route points: along each direction from the attacked keep, the first tile on the
-- AI's distance ring (or just beyond it).
local function ringPoints(a, kx, ky)
  local index = rd32(G.layerIndex + a * LAYER_PLAYER_STRIDE)
  if index < 0 or index > 8 then return nil end
  local layer = G.layer + index * LAYER_STRIDE
  local ring = O.patrol.distance
  local points, found = {}, 0
  for d = 0, DIRECTIONS - 1 do
    local angle = d * 2 * math.pi / DIRECTIONS
    local cx, cy = math.cos(angle), math.sin(angle)
    for step = 1, RAY_LENGTH do
      local x = math.floor(kx + cx * step + 0.5)
      local y = math.floor(ky + cy * step + 0.5)
      local tile = tileAt(x, y)
      if tile == nil then break end
      local value = rd8(layer + tile) & 0xFF
      if value >= ring and value <= ring + RING_SLACK then
        points[d + 1] = { x = x, y = y, tile = tile }
        found = found + 1
        break
      end
    end
  end
  if found == 0 then return nil end
  return points
end

local function wrap(index) return (index - 1) % DIRECTIONS + 1 end

local function nearestPoint(points, x, y, choices)
  local best, bestDistance = nil, nil
  for _, i in ipairs(choices) do
    local p = points[i]
    if p ~= nil then
      local d = distance(x, y, p.x, p.y)
      if bestDistance == nil or d < bestDistance then best, bestDistance = i, d end
    end
  end
  return best
end

local function allDirections()
  local list = {}
  for i = 1, DIRECTIONS do list[i] = i end
  return list
end

local function patrol(a)
  local groups = split(a, "patrol")
  if #groups == 0 then return end
  local target = rd32(player(a) + P.ATTACKED)
  local kx, ky = keepXY(target)
  if kx == nil then return end
  local points = ringPoints(a, kx, ky)
  if points == nil then return end

  -- The front: the direction from the attacked keep to the attacker's own keep (else to the
  -- first group).
  local fx, fy = keepXY(a)
  if fx == nil then
    local leader = leaderOf(groups[1], a)
    if leader ~= nil then fx, fy = leader.x, leader.y end
  end
  local front = 1
  if fx ~= nil and (fx ~= kx or fy ~= ky) then
    local angle = math.atan(fy - ky, fx - kx)
    if angle < 0 then angle = angle + 2 * math.pi end
    front = wrap(math.floor(angle / (2 * math.pi) * DIRECTIONS + 0.5) + 1)
  end
  local frontList = {}
  for i = -FRONT_SPAN, FRONT_SPAN do frontList[#frontList + 1] = wrap(front + i) end

  local tick = rd32(G.ticks)
  local memo = {}
  local routes = {}
  for g, group in ipairs(groups) do
    local leader = leaderOf(group, a)
    local route = routeOf(a, group)
    routes[g] = route
    if group.moved then route.again = true end
    if leader ~= nil and due(route, leader, tick, group.id) then
      local pattern, round = (g - 1) % 3, (g - 1) // 3
      local fromArea = area(leader.tile)
      local function usable(i)
        local p = points[i]
        return p ~= nil and reaches(memo, a, fromArea, area(p.tile))
      end

      local pick = nil
      if pattern < 2 then
        -- Round the castle: clockwise (pattern 0) or the other way (pattern 1).
        local dir = pattern == 0 and 1 or -1
        local ahead = routes[g - 3]
        if route.index == nil then
          if ahead ~= nil and ahead.index ~= nil then
            route.index = wrap(ahead.index - dir * LAG)
          else
            route.index = nearestPoint(points, leader.x, leader.y, allDirections())
          end
          if route.index ~= nil and usable(route.index) then pick = route.index end
        end
        if pick == nil and route.index ~= nil then
          local start = route.again and route.point ~= nil and route.index or wrap(route.index + dir)
          for tries = 0, DIRECTIONS - 1 do
            local i = wrap(start + dir * tries)
            if usable(i) then pick = i; break end
          end
        end
      else
        -- Back and forth along the front. A later round starts at the other end.
        if route.pos == nil then
          if round % 2 == 1 then
            route.pos, route.dir = #frontList, -1
          else
            local i = nearestPoint(points, leader.x, leader.y, frontList)
            route.pos, route.dir = 1, 1
            for k, v in ipairs(frontList) do if v == i then route.pos = k end end
          end
          if usable(frontList[route.pos]) then pick = frontList[route.pos] end
        end
        if pick == nil and not (route.again and route.point ~= nil) then
          for tries = 1, 2 * #frontList do
            local nextPos = route.pos + route.dir
            if nextPos < 1 or nextPos > #frontList then
              route.dir = -route.dir
              nextPos = route.pos + route.dir
            end
            route.pos = nextPos
            if usable(frontList[route.pos]) then pick = frontList[route.pos]; break end
          end
        elseif pick == nil and usable(frontList[route.pos]) then
          pick = frontList[route.pos]
        end
      end

      if pick ~= nil then
        route.index = pick
        if not order(a, group, route, points[pick], KINDS.patrol.stance, tick) then
          route.point = nil
        end
      end
    end
  end
end

---------------------------------------------------------------------------------------
-- Siege defence: walking between the siege engines, and the wall assault
---------------------------------------------------------------------------------------

local function enginesOf(a, kx, ky)
  local list = {}
  local mine = team(a)
  local count = rd32(G.unitsThis)
  for index = 1, count - 1 do
    local u = unit(index)
    if ENGINES[rd16(u + U.TYPE)] and unitAlive(index) and (rd8(u + U.BUILT) & 0xFF) == ENGINE_BUILT then
      local owner = rd16(u + U.OWNER)
      if owner >= 1 and owner <= 8 and team(owner) == mine then
        local x, y = rd16(u + U.X), rd16(u + U.Y)
        list[#list + 1] = { x = x, y = y, tile = rd32(u + U.TILE), angle = math.atan(y - ky, x - kx) }
      end
    end
  end
  table.sort(list, function(p, q) return p.angle < q.angle end)
  return list
end

local function mostlyMelee(g)
  local melee = 0
  for _, index in ipairs(g.units) do
    if not RANGED[rd16(unit(index) + U.TYPE)] then melee = melee + 1 end
  end
  return melee * 2 > #g.units
end

-- An engine's spot, moved toward the castle for a melee group.
local function standAt(engine, kx, ky, forward)
  if forward <= 0 then return engine end
  local dx, dy = kx - engine.x, ky - engine.y
  local length = math.sqrt(dx * dx + dy * dy)
  if length < 1 then return engine end
  local step = math.min(forward, length / 2)
  local x = math.floor(engine.x + dx / length * step + 0.5)
  local y = math.floor(engine.y + dy / length * step + 0.5)
  local tile = tileAt(x, y)
  if tile == nil then return engine end
  return { x = x, y = y, tile = tile }
end

local function rally(a)
  local groups = split(a, "siegedef")
  if #groups == 0 then return end
  local target = rd32(player(a) + P.ATTACKED)
  local kx, ky = keepXY(target)
  if kx == nil then
    local leader = leaderOf(groups[1], a)
    if leader == nil then return end
    kx, ky = leader.x, leader.y
  end
  local engines = enginesOf(a, kx, ky)
  local tick = rd32(G.ticks)
  local memo = {}
  for g, group in ipairs(groups) do
    F.setStance(G.tribesThis, group.id, KINDS.siegedef.stance)
    local leader = leaderOf(group, a)
    local route = routeOf(a, group)
    if group.moved then route.again = true end
    if #engines > 0 and leader ~= nil and due(route, leader, tick, group.id) then
      if route.index == nil then
        -- Spread out: each group starts at its own engine, every second one walks the other way.
        route.index = 1 + ((g - 1) * #engines) // #groups
        route.dir = g % 2 == 1 and 1 or -1
      elseif not (route.again and route.point ~= nil) and #engines > 1 then
        local nextIndex = route.index + route.dir
        if nextIndex < 1 or nextIndex > #engines then
          route.dir = -route.dir
          nextIndex = route.index + route.dir
        end
        route.index = nextIndex
      end
      route.index = int(route.index, 1, #engines)
      local engine = engines[route.index]
      local spot = mostlyMelee(group) and standAt(engine, kx, ky, O.siegedef.forward) or engine
      if not reaches(memo, a, area(leader.tile), area(spot.tile)) then spot = engine end
      -- With one engine the game only moves when the group is more than 5 tiles away.
      if #engines > 1 or distance(leader.x, leader.y, spot.x, spot.y) > ARRIVED then
        order(a, group, route, spot, KINDS.siegedef.stance, tick)
      else
        route.point, route.tick, route.again = spot, tick, false
      end
    end
  end
end

local function wallAssault(a)
  local groups = split(a, "siegedef")
  for _, group in ipairs(groups) do
    if rd16(tribe(group.id) + T.LEADER) ~= 0 then
      F.setStance(G.tribesThis, group.id, KINDS.siegedef.stance)
      F.assign(G.tribesThis, group.id, ASSAULT_TARGETS)
    end
    local route = attackOf(a).routes[group.uid]
    if route ~= nil then route.point = nil end
  end
end

---------------------------------------------------------------------------------------
-- Per AI player, after its attack state update
---------------------------------------------------------------------------------------

local function checkTick()
  local tick = rd32(G.ticks)
  if lastTick == nil or tick < lastTick or tick - lastTick > LOAD_GAP then
    attacks, swept = {}, {}
  end
  lastTick = tick
end

local function afterStateUpdate(a)
  checkTick()
  if rd32(player(a) + P.AI_TYPE) == 0 then return end
  if not swept[a] then
    swept[a] = true
    sweep(a)
  end
  local state = rd32(player(a) + P.AI_STATE)
  if state >= ACTIVE_FIRST and state <= ACTIVE_LAST then return end
  if attacks[a] ~= nil then
    local merged = mergeBack(a)
    if merged > 0 then
      diag("player %d: attack state %d, %d units back in the AI's own troops", a, state, merged)
      if RETREAT_STATES[state] then F.goDefensive(G.aiState, a) end
    end
  end
end

local function handle(kind, a)
  checkTick()
  if rd32(player(a) + P.AI_TYPE) == 0 then return end
  if kind == KIND_PATROL then
    patrol(a)
  elseif kind == KIND_RALLY then
    rally(a)
  elseif kind == KIND_WALL then
    wallAssault(a)
  end
end

---------------------------------------------------------------------------------------
-- Injected code
---------------------------------------------------------------------------------------

-- Replaces one of the three AI functions: note the player and the AI state object, run lua.
local REPLACE = [[
mov [THIS],ecx
mov eax,[esp+4]
mov [PLAYER],eax
mov dword [KIND],KIND_VALUE
call PAD
ret 4
]]

-- Replaces the call right after the AI's attack state update: run the lua check, then go on
-- to what the call pointed at before.
local CHAIN = [[
mov eax,[esp+4]
mov [PLAYER],eax
mov [THIS],ecx
push ecx
call PAD
pop ecx
jmp ORIGINAL_TARGET
]]

---------------------------------------------------------------------------------------
-- Enable
---------------------------------------------------------------------------------------

local function resolve()
  G.patrol = scan(AOB_PATROL, "the AI's patrol order")
  local send = readCallTarget(G.patrol, PATROL_SEND, "the patrol troop's move", 0xE9)
  local move = readCallTarget(send, SEND_MOVE, "giveTribeMoveInstruction")
  G.rally = scan(AOB_RALLY, "the siege defence walk between the siege engines")
  readOperand(G.rally, RALLY_CLOSEST, "the siege defence fight check")
  local reached = readCallTarget(G.rally, RALLY_REACHED, "allUnitsReachedTheirDestination")
  if readCallTarget(G.rally, RALLY_MOVE, "giveTribeMoveInstruction") ~= move then
    error(MODULE_NAME .. ": the two move orders do not call the same function")
  end
  local loop = scan(AOB_WALL_LOOP, "the siege defence wall assault")
  G.wall = loop - WALL_START
  expectBytes(G.wall, WALL_FUNCTION_HEAD, "the siege defence wall assault")
  local assign = readCallTarget(loop, WALL_ASSIGN, "assignAttackTargetsForTribe")
  if scan(AOB_MOVE, "giveTribeMoveInstruction") ~= move then
    error(MODULE_NAME .. ": giveTribeMoveInstruction is not where the module expects it")
  end

  G.smallest = scan(AOB_SMALLEST, "where the AI picks a recruit's troop")
  expectBytes(G.smallest + COUNT_PATROL[1], COUNT_PATROL[2], "the patrol group count")
  expectBytes(G.smallest + COUNT_SIEGEDEF[1], COUNT_SIEGEDEF[2], "the siege defence group count")

  local layer = scan(AOB_LAYER, "the AI's distance layer")
  G.layerIndex = rd32(layer + LAYER_INDEX)
  G.layer = rd32(layer + LAYER_BASE)

  local calls = scan(AOB_CALLS, "the AI's per player update")
  G.site = calls + CALL_HOOK
  G.original = readCallTarget(calls, CALL_HOOK, "the call after the AI attack state update")

  local its = scan(AOB_ADD_TO_ITS_TRIBE, "where the AI puts a unit in its troop")
  G.units = readOperand(its, ITS_UNIT_OWNER, "the unit array") - U.OWNER
  G.unitsThis = G.units - U.STATE_OFFSET
  G.players = readOperand(its, ITS_AI_TYPE, "the player array") - P.AI_TYPE
  G.tribesThis = readOperand(its, ITS_TRIBES, "the troop array")
  G.tribes = G.tribesThis
  local addToTribe = readCallTarget(its, ITS_ADD_TO_TRIBE, "addUnitToTribe")
  if scan(AOB_ADD_TO_TRIBE, "addUnitToTribe") ~= addToTribe then
    error(MODULE_NAME .. ": addUnitToTribe is not where the module expects it")
  end
  local remove = scan(AOB_REMOVE_FROM_TRIBE, "removeUnitFromTribe")
  G.tribeStride = readOperand(remove, REMOVE_STRIDE, "the troop size")

  local k2k = scan(AOB_KEEP_TO_KEEP, "the keep to keep test")
  G.area = readOperand(k2k, K2K_AREA, "the area map")
  G.paths = readOperand(k2k, K2K_PATHS, "the path finder")
  local canNavigate = readCallTarget(k2k, K2K_CAN_NAVIGATE, "the area test")

  G.teams = rd32(scan(AOB_TEAMS, "the team table") + TEAMS_OPERAND)
  G.ticks = rd32(scan(AOB_TICKS, "the game tick counter") + TICKS_OPERAND)
  local tileMap = rd32(scan(AOB_TILE_FLAGS, "the tile flags") + TILE_FLAGS_OPERAND) - MAP.FLAGS
  G.rows = tileMap + MAP.ROWS
  G.yOfTile = tileMap + MAP.Y_OF_TILE
  if G.area ~= tileMap + MAP.AREA then
    error(MODULE_NAME .. ": the map layers are not laid out as the module expects")
  end

  F.createTribe = core.exposeCode(scan(AOB_CREATE_TRIBE, "createTribeForPlayer"), 2, 1)
  F.addToTribe = core.exposeCode(addToTribe, 3, 1)
  F.removeFromTribe = core.exposeCode(remove, 3, 1)
  F.addToItsTribe = core.exposeCode(its, 3, 1)
  F.setStance = core.exposeCode(scan(AOB_STANCE, "setUnitStance"), 3, 1)
  F.move = core.exposeCode(move, 7, 1)
  F.reached = core.exposeCode(reached, 2, 1)
  F.assign = core.exposeCode(assign, 3, 1)
  F.canNavigate = core.exposeCode(canNavigate, 5, 1)
  F.goDefensive = core.exposeCode(scan(AOB_GO_DEFENSIVE, "the AI's retreat order"), 2, 1)
end

-- A pad lua runs on, reading the player and the AI state object from a small block.
local function luaPad(fn)
  local block = core.allocate(12, true)
  local pad = core.allocateCode({ 0x90, 0x90, 0x90, 0x90, 0x90, 0xC3 })
  core.detourCode(function(registers)
    if not broken then
      G.aiState = rd32(block + 4)
      local done, problem = pcall(fn, rd32(block), rd32(block + 8))
      if not done then
        broken = true
        log(WARNING, MODULE_NAME .. ": stopped after an error: " .. tostring(problem))
      end
    end
    return registers
  end, pad, 5)
  return block, pad
end

local function enable(self, config)
  config = config or {}
  O.patrol = {
    enabled = setting(config, "patrol", "enabled") == true,
    groups = int(setting(config, "patrol", "groups"), 0, MAX_GROUPS),
    distance = int(setting(config, "patrol", "distance"), 4, 100),
  }
  O.siegedef = {
    enabled = setting(config, "siegedef", "enabled") == true,
    groups = int(setting(config, "siegedef", "groups"), 0, MAX_GROUPS),
    forward = int(setting(config, "siegedef", "forward"), 0, 10),
  }
  O.minSize = int(setting(config, "general", "min_size"), 1, 50)
  O.log = setting(config, "diagnostics", "log") == true
  if not O.patrol.enabled and not O.siegedef.enabled then
    log(INFO, MODULE_NAME .. ": both parts are off")
    return
  end

  local ok, problem = pcall(resolve)
  if not ok then
    log(WARNING, tostring(problem))
    return
  end

  self.saved = {}
  local function save(address, size)
    self.saved[#self.saved + 1] = { address = address, bytes = core.readBytes(address, size) }
  end
  local function replace(address, kind)
    local block, pad = luaPad(function(a, k) handle(k, a) end)
    local stub = core.allocateAssembly(REPLACE, {
      THIS = block + 4, PLAYER = block, KIND = block + 8, KIND_VALUE = kind, PAD = pad,
    })
    save(address, 5)
    core.writeCode(address, { 0xE9, core.itob(core.getRelativeAddress(address, stub, -5)) })
  end

  if O.patrol.enabled then
    replace(G.patrol, KIND_PATROL)
    save(G.smallest + COUNT_PATROL[1], #COUNT_ONE)
    core.writeCode(G.smallest + COUNT_PATROL[1], COUNT_ONE)
  end
  if O.siegedef.enabled then
    replace(G.rally, KIND_RALLY)
    replace(G.wall, KIND_WALL)
    save(G.smallest + COUNT_SIEGEDEF[1], #COUNT_ONE)
    core.writeCode(G.smallest + COUNT_SIEGEDEF[1], COUNT_ONE)
  end

  local block, pad = luaPad(function(a) afterStateUpdate(a) end)
  local chain = core.allocateAssembly(CHAIN, {
    PLAYER = block, THIS = block + 4, PAD = pad, ORIGINAL_TARGET = G.original,
  })
  save(G.site, 5)
  core.writeCode(G.site, { 0xE8, core.itob(core.getRelativeAddress(G.site, chain, -5)) })

  log(INFO, string.format("%s: on (patrol routes %s, siege defence groups %s); patrol 0x%X, "
    .. "siege defence 0x%X / 0x%X, units 0x%X, troops 0x%X (size 0x%X), distance layer 0x%X",
    MODULE_NAME, O.patrol.enabled and "on" or "off", O.siegedef.enabled and "on" or "off",
    G.patrol, G.rally, G.wall, G.units, G.tribes, G.tribeStride, G.layer))
end

local function disable(self, config)
  if self.saved ~= nil then
    for i = #self.saved, 1, -1 do core.writeCode(self.saved[i].address, self.saved[i].bytes) end
    self.saved = nil
  end
end

return {
  enable = enable,
  disable = disable,
}
