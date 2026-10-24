-- soulPilot GE graph diagnostics (moved from legacy main).
local logger = require("extensions.soulPilot.modules.logger")

local M = {}
-- === ╨ñ╨░╨╖╨░ 2: ╤ì╨║╤ü╨┐╨╛╤Ç╤é ╨│╤Ç╨░╤ä╨░ ╨┤╨╛╤Ç╨╛╨│ (╤ê╨░╨│ 2.3) ===
-- apl_exportGraph() ΓÇö ╤ü╤é╤Ç╨╛╨╕╤é ai/road/graph.json ╨╕╨╖ ╨╜╨░╨▓╨╕╨│╤Ç╨░╤ä╨░ ╤â╤Ç╨╛╨▓╨╜╤Å
-- (map.nodes, ge/map.lua). ╨í╤à╨╡╨╝╨░: ai/road/graph_schema.md.
-- ╨Æ╨¥╨ÿ╨£╨É╨¥╨ÿ╨ò: ╨▓╤ü╨╡ ╨┐╤â╤é╨╕ ΓÇö ╨ó╨₧╨¢╨¼╨Ü╨₧ ╨╛╤é╨╜╨╛╤ü╨╕╤é╨╡╨╗╤î╨╜╤ï╨╡ ╨╛╤é userPath (sandbox io.open,
-- ╨┤╨╕╨░╨│╨╜╨╛╤ü╤é╨╕╨║╨░ apl_diag ╨▓ ╨ñ╨░╨╖╨╡ 1).

local GRAPH_DIR = 'mods/unpacked/soulPilot/ai/road/'
local GRAPH_CONF = 'mods/unpacked/soulPilot/src/config/graph.json'

-- jsonEncodePretty ╨┐╤Ç╨╛╨┐╤â╤ü╨║╨░╨╡╤é ╨║╨╗╤Ä╤ç╨╕ ╤ü╨╛ ╨╖╨╜╨░╤ç╨╡╨╜╨╕╨╡╨╝ nil (utils.lua:402), ╨░
-- ╨¥╨ò╨╕╨╖╨▓╨╡╤ü╤é╨╜╤ï╨╡ ╤é╨╕╨┐╤ï ╨┐╨╕╤ê╨╡╤é ╨║╨░╨║ null (utils.lua:417) ΓÇö ╤ì╤é╨╕╨╝ ╨┐╨╛╨╗╤î╨╖╤â╨╡╨╝╤ü╤Å ╨┤╨╗╤Å
-- ╤Å╨▓╨╜╤ï╤à null-╨┐╨╛╨╗╨╡╨╣ ╤ü╤à╨╡╨╝╤ï (angle_deg ╨┐╤Ç╨╕ degree ~= 2 ╨╕ ╤é.╨┐.)
local JSON_NULL = function() end

local function loadGraphConfig()
  local defaults = { friction_mu = 0.75, turn_angle_threshold_deg = 20, speed_round_kph = 5 }
  local f = io.open(GRAPH_CONF, 'r')
  if not f then
    logger.logLine('WARN', '╨Ü╨╛╨╜╤ä╨╕╨│ ╨│╤Ç╨░╤ä╨░ ╨╜╨╡ ╨╜╨░╨╣╨┤╨╡╨╜ (' .. GRAPH_CONF .. ') ΓÇö ╨┤╨╡╤ä╨╛╨╗╤é╤ï: mu=0.75, ╨┐╨╛╤Ç╨╛╨│ 20┬░, ╤ê╨░╨│ 5 ╨║╨╝/╤ç')
    return defaults
  end
  local content = f:read('*all')
  f:close()
  local ok, decoded = pcall(jsonDecode, content, GRAPH_CONF)
  if not ok or type(decoded) ~= 'table' then
    logger.logLine('WARN', '╨Ü╨╛╨╜╤ä╨╕╨│ ╨│╤Ç╨░╤ä╨░ ╨╜╨╡ ╤Ç╨░╤ü╨┐╨░╤Ç╤ü╨╡╨╜ ΓÇö ╨┤╨╡╤ä╨╛╨╗╤é╤ï: mu=0.75, ╨┐╨╛╤Ç╨╛╨│ 20┬░, ╤ê╨░╨│ 5 ╨║╨╝/╤ç')
    return defaults
  end
  return {
    friction_mu = tonumber(decoded.friction_mu) or defaults.friction_mu,
    turn_angle_threshold_deg = tonumber(decoded.turn_angle_threshold_deg) or defaults.turn_angle_threshold_deg,
    speed_round_kph = tonumber(decoded.speed_round_kph) or defaults.speed_round_kph,
  }
end

-- --- ╨▓╨╡╨║╤é╨╛╤Ç╨╜╤ï╨╡ ╤â╤é╨╕╨╗╨╕╤é╤ï (╤é╨╛╨╗╤î╨║╨╛ ╤ç╤é╨╡╨╜╨╕╨╡ ╨│╨╡╨╛╨╝╨╡╤é╤Ç╨╕╨╕, ╨╜╨╕╤ç╨╡╨│╨╛ ╨╜╨╡ ╨┤╤æ╤Ç╨│╨░╨╡╨╝) ---
local function vecSub(a, b) return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z } end
local function vecLen(v) return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) end
local function vecDot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function vecCross(a, b)
  return { x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x }
end

-- ╨É╨╖╨╕╨╝╤â╤é in (dx, dy): 0┬░ = ╤ü╨╡╨▓╨╡╤Ç (+Y), ╨ƒ╨₧ ╨º╨É╨í╨₧╨Æ╨₧╨Ö ╤ü╤é╤Ç╨╡╨╗╨║╨╡ (╤Ç╨╡╤ê╨╡╨╜╨╕╨╡ ╨┐╨╛╨╗╤î╨╖╨╛╨▓╨░╤é╨╡╨╗╤Å)
local function azimuthDeg(dx, dy)
  return (math.deg(math.atan2(dx, dy)) + 360) % 360
end

-- ╨ú╨│╨╛╨╗ ╨╝╨╡╨╢╨┤╤â ╨┤╨▓╤â╨╝╤Å ╨▓╨╡╨║╤é╨╛╤Ç╨░╨╝╨╕, ╨│╤Ç╨░╨┤╤â╤ü╤ï (0..180); nil, ╨╡╤ü╨╗╨╕ ╨║╨░╨║╨╛╨╣-╤é╨╛ ╨╜╤â╨╗╨╡╨▓╨╛╨╣
local function angleBetweenDeg(v1, v2)
  local l1, l2 = vecLen(v1), vecLen(v2)
  if l1 < 1e-9 or l2 < 1e-9 then return nil end
  local c = vecDot(v1, v2) / (l1 * l2)
  c = math.max(-1, math.min(1, c))
  return math.deg(math.acos(c))
end

-- ╨á╨░╨┤╨╕╤â╤ü ╨╛╨┐╨╕╤ü╨░╨╜╨╜╨╛╨╣ ╨╛╨║╤Ç╤â╨╢╨╜╨╛╤ü╤é╨╕ ╤é╤Ç╨╡╤â╨│╨╛╨╗╤î╨╜╨╕╨║╨░ (prevP, fromP, toP):
-- R = a┬╖b┬╖c / (4┬╖S), S = ╨┐╨╗╨╛╤ë╨░╨┤╤î ╤ç╨╡╤Ç╨╡╨╖ cross; ╨╜╨░ ╨┐╤Ç╤Å╨╝╤ï╤à (SΓëê0) ΓåÆ nil (╤ü╤à╨╡╨╝╨░)
local function circumradius(prevP, fromP, toP)
  local area2 = vecLen(vecCross(vecSub(fromP, prevP), vecSub(toP, prevP))) -- 2┬╖S
  if area2 < 1e-6 then return nil end
  local a = vecLen(vecSub(toP, fromP))
  local b = vecLen(vecSub(toP, prevP))
  local c = vecLen(vecSub(fromP, prevP))
  if a < 1e-9 or b < 1e-9 or c < 1e-9 then return nil end
  return a * b * c / (2 * area2)
end

-- ╨₧╨║╤Ç╤â╨│╨╗╨╡╨╜╨╕╨╡ ╨Æ╨¥╨ÿ╨ù ╨┤╨╛ ╤ê╨░╨│╨░ (╤Ç╨╡╨║╨╛╨╝╨╡╨╜╨┤╨╛╨▓╨░╨╜╨╜╨░╤Å ╤ü╨║╨╛╤Ç╨╛╤ü╤é╤î)
local function floorToStep(v, step)
  if v == nil or v ~= v or step == nil or step <= 0 then return v end
  return math.floor(v / step + 1e-9) * step
end

-- ╨ö╨╡╤é╨╡╤Ç╨╝╨╕╨╜╨╕╤Ç╨╛╨▓╨░╨╜╨╜╤ï╨╣ id ╤Ç╨╡╨▒╤Ç╨░: min_max (╤é╨╛╤é ╨╢╨╡ ╤ä╨╛╤Ç╨╝╨░╤é ╨▓ marks.csv)
local function edgeIdOf(a, b)
  a, b = tostring(a), tostring(b)
  if a < b then return a .. '_' .. b end
  return b .. '_' .. a
end

local function cmpId(a, b) return tostring(a) < tostring(b) end

-- ╨ƒ╨╛╨╖╨╕╤å╨╕╤Å ╨║╨╛╨╜╤å╨░ ╤Ç╨╡╨▒╤Ç╨░ ╤â ╤â╨╖╨╗╨░ nid (map.lua:174-187): ╤â╨╖╨╡╨╗-inNode ┬½╨▓╨╗╨░╨┤╨╡╨╡╤é┬╗
-- inPos, ╤â╨╖╨╡╨╗-outNode ΓÇö outPos; ╨╜╨╡╤ü╨╛╨▓╨┐╨░╨┤╨╡╨╜╨╕╨╡/nil ΓåÆ pos ╤â╨╖╨╗╨░ (fallback)
local function edgeEndPos(edge, nid, nodePos)
  if edge.inNode == nid then return edge.inPos or nodePos end
  if edge.outNode == nid then return edge.outPos or nodePos end
  return nodePos
end

function apl_exportGraph()
  -- ╨ö╨╛╤ü╤é╤â╨┐ ╨║ ╨│╤Ç╨░╤ä╤â ╨ó╨₧╨¢╨¼╨Ü╨₧ ╤ç╨╡╤Ç╨╡╨╖ map.getMap() (╨ú1, 2026-10-12): map.nodes ΓÇö
  -- ╨┐╤Ç╨╕╨▓╨░╤é╨╜╨░╤Å ╨┐╨╡╤Ç╨╡╨╝╨╡╨╜╨╜╨░╤Å ╨╝╨╛╨┤╤â╨╗╤Å (map.lua:25), ╤â ╤é╨░╨▒╨╗╨╕╤å╤ï API ╤Ç╨░╤ü╤ê╨╕╤Ç╨╡╨╜╨╕╤Å ╨┐╨╛╨╗╤Å
  -- nodes ╨¥╨ò╨ó; pcall(map.getMap) ΓÇö ╨▓╤ï╨╖╨╛╨▓ ╤ü╨╛ ╤ü╨║╨╛╨▒╨║╨░╨╝╨╕, ╨┐╨╛╨╗╨╡ ╨╜╨╡ ╤ç╨╕╤é╨░╨╡╨╝ ╨╜╨░╨┐╤Ç╤Å╨╝╤â╤Ä.
  -- map.load() ΓÇö ╨ó╨₧╨¢╨¼╨Ü╨₧ ╨╡╤ü╨╗╨╕ ╤â╨╖╨╗╨╛╨▓ 0 (╨ú2: ╨╜╨░ East Coast 5439 ╤â╨╢╨╡ ╨┐╨╛╤ü╤é╤Ç╨╛╨╡╨╜╤ï
  -- ╨┤╨▓╨╕╨╢╨║╨╛╨╝, ╨╗╨╡╨╜╨╕╨▓╨░╤Å ╨╖╨░╨│╤Ç╤â╨╖╨║╨░ ╨┐╨╡╤Ç╨╡╤ü╤é╤Ç╨░╨╕╨▓╨░╨╡╤é ╨│╤Ç╨░╤ä ╨╕ ╨╝╨╡╨╜╤Å╨╡╤é buildSerial).
  local okMap, gm = pcall(map.getMap)
  if not okMap or type(gm) ~= 'table' or type(gm.nodes) ~= 'table' or next(gm.nodes) == nil then
    pcall(function() map.load() end) -- ╨╡╨┤╨╕╨╜╤ü╤é╨▓╨╡╨╜╨╜╨╛╨╡ ╤Ç╨░╨╖╤Ç╨╡╤ê╤æ╨╜╨╜╨╛╨╡ ╨╝╨╡╤ü╤é╨╛ map.load()
    okMap, gm = pcall(map.getMap)
  end
  if not okMap or type(gm) ~= 'table' or type(gm.nodes) ~= 'table' or next(gm.nodes) == nil then
    print('WARN apl_exportGraph: ╨│╤Ç╨░╤ä ╨╜╨╡╨┤╨╛╤ü╤é╤â╨┐╨╡╨╜ (map.getMap() ╨┐╤â╤ü╤é) ΓÇö ╨║╨░╤Ç╤é╨░ ╨╜╨╡ ╨╖╨░╨│╤Ç╤â╨╢╨╡╨╜╨░?')
    return false
  end
  local nodesMap = gm.nodes

  local conf = loadGraphConfig()
  local warnings = {}
  local function warn(msg)
    warnings[#warnings + 1] = msg
  end

  -- ╨ö╨╡╤é╨╡╤Ç╨╝╨╕╨╜╨╕╤Ç╨╛╨▓╨░╨╜╨╜╤ï╨╣ ╨┐╨╛╤Ç╤Å╨┤╨╛╨║ ╨╛╨▒╤à╨╛╨┤╨░ (╨╕╨╜╨░╤ç╨╡ pairs() ╨┤╨░╤æ╤é ╤Ç╨░╨╖╨╜╤ï╨╣ JSON)
  local ids = {}
  for id in pairs(nodesMap) do ids[#ids + 1] = id end
  table.sort(ids, cmpId)

  -- === ╨ƒ╤Ç╨╛╤à╨╛╨┤ A: ╤Ç╤æ╨▒╤Ç╨░ (╤ü╤ï╤Ç╤ï╨╡ ╨┐╨░╤Ç╤ï) + ╨¥╨ò╨₧╨á╨ÿ╨ò╨¥╨ó╨ÿ╨á╨₧╨Æ╨É╨¥╨¥╨É╨» ╤ü╨╝╨╡╨╢╨╜╨╛╤ü╤é╤î ===
  -- ╨ñ╨ÿ╨Ü╨í ╨┐╨╛╤ü╨╗╨╡ ╤é╨╡╤ü╤é╨░ 2.7 (East Coast, 2026-10-12): links ╨▓ ╨╜╨░╨▓╨╕╨│╤Ç╨░╤ä╨╡ ╤à╤Ç╨░╨╜╤Å╤é╤ü╤Å
  -- ╨₧╨ö╨¥╨₧╨í╨ó╨₧╨á╨₧╨¥╨¥╨ò (╤å╨╡╨┐╨╛╤ç╨║╨╕ next ╨╛╤é DecalRoad): map.nodes[A].links[B] ╨╡╤ü╤é╤î,
  -- ╨╛╨▒╤Ç╨░╤é╨╜╨╛╨│╨╛ map.nodes[B].links[A] ╨╝╨╛╨╢╨╡╤é ╨¥╨ò ╨▒╤ï╤é╤î. ╨ö╨╛╨║╨░╨╖╨░╤é╨╡╨╗╤î╤ü╤é╨▓╨╛: ╤ü╤â╨╝╨╝╨░
  -- |links| ╨┐╨╛ ╨▓╤ü╨╡╨╝ ╤â╨╖╨╗╨░╨╝ == ╤ç╨╕╤ü╨╗╨╛ ╤Ç╤æ╨▒╨╡╤Ç ╤Ç╨╛╨▓╨╜╨╛ (phantom == -E ╨▓ ╤ç╨╡╨║╨╡╤Ç╨╡).
  -- ╨ƒ╨╛╤ì╤é╨╛╨╝╤â ╨¥╨ò╨₧╨á╨ÿ╨ò╨¥╨ó╨ÿ╨á╨₧╨Æ╨É╨¥╨¥╨É╨» ╤ü╤é╨╡╨┐╨╡╨╜╤î ╤â╨╖╨╗╨░ = |{B: A.links[B] ╨ÿ╨¢╨ÿ B.links[A]}| ΓÇö
  -- ╤ü╤é╤Ç╨╛╨╕╨╝ ╤ü╨╝╨╡╨╢╨╜╨╛╤ü╤é╤î ╨╕╨╖ ╤ü╨╛╨▒╤Ç╨░╨╜╨╜╤ï╤à ╤Ç╤æ╨▒╨╡╤Ç (O(E)), ╨░ ╨¥╨ò ╨┐╨╛ links ╤â╨╖╨╗╨░.
  -- ╨æ╨╡╨╖ ╤ä╨╕╨║╤ü╨░: ╤å╨╡╨┐╨╛╤ç╨║╨░ A->B->C ╨┤╨░╤æ╤é ┬½╨▓╤ü╨╡ dead_end┬╗, ╨░ ┬½╨┐╤Ç╨╕╤æ╨╝╨╜╨╕╨║╨╕┬╗ ΓÇö isolated
  -- (East Coast: 5098 dead_end, 91% ╤Ç╤æ╨▒╨╡╤Ç ╨▒╨╡╨╖ radius ΓÇö ╨░╤Ç╤é╨╡╤ä╨░╨║╤é ╤é╨░╨║╨╛╨│╨╛ degree).
  local rawEdges = {} -- {a=id, b=toId, edge=╤é╨░╨▒╨╗╨╕╤å╨░ ╤Ç╨╡╨▒╤Ç╨░ links[...]}
  local adj = {}      -- id -> set ╨¥╨ò╨₧╨á╨ÿ╨ò╨¥╨ó╨ÿ╨á╨₧╨Æ╨É╨¥╨¥╨½╨Ñ ╤ü╨╛╤ü╨╡╨┤╨╡╨╣
  local seen = {}
  for _, id in ipairs(ids) do
    local n = nodesMap[id]
    for toId in pairs(n.links or {}) do
      local eid = edgeIdOf(id, toId)
      if not seen[eid] then
        seen[eid] = true
        if nodesMap[toId] then
          rawEdges[#rawEdges + 1] = { a = id, b = toId, edge = n.links[toId] }
          adj[id] = adj[id] or {}
          adj[toId] = adj[toId] or {}
          adj[id][toId] = true
          adj[toId][id] = true
        else
          warn('╨▒╨╕╤é╨░╤Å ╤ü╤ü╤ï╨╗╨║╨░ ╤Ç╨╡╨▒╤Ç╨░: ' .. tostring(id) .. '->' .. tostring(toId))
        end
      end
    end
  end
  -- ╨ö╨╡╤é╨╡╤Ç╨╝╨╕╨╜╨╕╨╖╨╝ JSON: ╤ü╤é╨░╨▒╨╕╨╗╤î╨╜╤ï╨╣ ╨┐╨╛╤Ç╤Å╨┤╨╛╨║ ╤Ç╤æ╨▒╨╡╤Ç ╨┐╨╛ edge_id
  table.sort(rawEdges, function(x, y)
    return edgeIdOf(x.a, x.b) < edgeIdOf(y.a, y.b)
  end)

  -- ╨í╤Ç╨╡╨╖ ╨┤╨╗╤Å example: ╨í╨Æ╨»╨ù╨¥╨½╨Ö ╨┐╨╛╨┤╨│╤Ç╨░╤ä ╨╕╨╖ 20 ╤â╨╖╨╗╨╛╨▓ (BFS ╨╛╤é ╨┐╨╡╤Ç╨▓╨╛╨│╨╛ ╤â╨╖╨╗╨░
  -- degree==2) ΓÇö ╨▓╨░╤Ç╨╕╨░╨╜╤é (a), ╤Ç╨╡╤ê╨╡╨╜╨╕╨╡ ╨┐╨╛╨╗╤î╨╖╨╛╨▓╨░╤é╨╡╨╗╤Å 2026-10-12. ╨á╨░╨╜╤î╤ê╨╡ ╨▒╤Ç╨░╨╗╨╕╤ü╤î
  -- ┬½╨┐╨╡╤Ç╨▓╤ï╨╡ 20 ╨┐╨╛ id┬╗ ΓÇö ╤ì╤é╨╛ ╨┤╨░╨▓╨░╨╗╨╛ ~45 ┬½╨▒╨╕╤é╤ï╤à ╤ü╤ü╤ï╨╗╨╛╨║┬╗ ╨╜╨░ ╤â╨╖╨╗╤ï ╨▓╨╜╨╡ ╤ü╤Ç╨╡╨╖╨░
  -- (╤ü╨▓╤Å╨╖╨╜╤ï╨╣ ╨┐╨╛╨┤╨│╤Ç╨░╤ä ╨╛╤é╤Ç╨░╨╢╨░╨╡╤é ╤Ç╨╡╨░╨╗╤î╨╜╤ï╨╣ ╨│╤Ç╨░╤ä).
  local exampleIdSet = {}
  local exampleNodes = {}
  do
    local function degreeOf(id)
      local c = 0
      for _ in pairs(adj[id] or {}) do c = c + 1 end
      return c
    end
    local startId = ids[1]
    for _, id in ipairs(ids) do
      if degreeOf(id) == 2 then startId = id break end
    end
    local queue = { startId }
    exampleIdSet[startId] = true
    local qi = 1
    while qi <= #queue and #queue < 20 do
      local cur = queue[qi]
      qi = qi + 1
      local nb = {}
      for toId in pairs(adj[cur] or {}) do nb[#nb + 1] = toId end
      table.sort(nb, cmpId)
      for _, toId in ipairs(nb) do
        if #queue >= 20 then break end
        if not exampleIdSet[toId] then
          exampleIdSet[toId] = true
          queue[#queue + 1] = toId
        end
      end
    end
  end

  -- === ╨ƒ╤Ç╨╛╤à╨╛╨┤ B: ╤â╨╖╨╗╤ï (degree ΓÇö ╨¥╨ò╨₧╨á╨ÿ╨ò╨¥╨ó╨ÿ╨á╨₧╨Æ╨É╨¥╨¥╨½╨Ö, ╨╕╨╖ adj) ===
  local nodeInfo = {} -- id -> {pos, degree, angle, sibs}
  local nodesArr = {}
  local isolatedCount = 0
  for _, id in ipairs(ids) do
    local n = nodesMap[id]
    local pos = n.pos
    if type(pos) ~= 'table' and type(pos) ~= 'cdata' then
      warn('╤â╨╖╨╡╨╗ ╨▒╨╡╨╖ pos: id=' .. tostring(id))
      pos = nil -- ╤ü╤é╤Ç╨░╤à╨╛╨▓╨║╨░: ╨╜╨╕╨╢╨╡ ╨▓╤ü╨╡ ╨╛╨▒╤Ç╨░╤ë╨╡╨╜╨╕╤Å ╨╖╨░╤ë╨╕╤ë╨╡╨╜╤ï ╨┐╤Ç╨╛╨▓╨╡╤Ç╨║╨╛╨╣ pos
    end
    local sibs = {}
    for toId in pairs(adj[id] or {}) do sibs[#sibs + 1] = toId end
    table.sort(sibs, cmpId)
    local degree = #sibs

    -- angle_deg ΓÇö ╨ó╨₧╨¢╨¼╨Ü╨₧ degree == 2 (╤ü╤à╨╡╨╝╨░): ╤â╨│╨╛╨╗ ╨╝╨╡╨╢╨┤╤â v_in (prevΓåÆu)
    -- ╨╕ v_out (uΓåÆto); ╨┐╨╛╤Ç╤Å╨┤╨╛╨║ ╤ü╨╛╤ü╨╡╨┤╨╡╨╣ ╨╜╨╡ ╨▓╨░╨╢╨╡╨╜ (╤ü╨╕╨╝╨╝╨╡╤é╤Ç╨╕╤Å ╤â╨│╨╗╨░)
    local angle = nil
    if degree == 2 then
      local a = nodesMap[sibs[1]] and nodesMap[sibs[1]].pos
      local b = nodesMap[sibs[2]] and nodesMap[sibs[2]].pos
      if a and b and pos then
        angle = angleBetweenDeg(vecSub(pos, a), vecSub(b, pos))
      end
      if angle == nil then
        warn('╨▒╨╕╤é╨░╤Å ╤ü╤ü╤ï╨╗╨║╨░ ╤ü╨╛╤ü╨╡╨┤╨░ ╤â degree==2: id=' .. tostring(id))
      end
    end

    local typeStr, junction = nil, nil
    if degree == 0 then
      typeStr = 'isolated'
      isolatedCount = isolatedCount + 1
      warn('isolated: id=' .. tostring(id))
    elseif degree == 1 then
      typeStr = 'dead_end'
    elseif degree == 3 then
      typeStr, junction = 'fork', 'fork'
    elseif degree >= 4 then
      typeStr, junction = 'crossroads', 'crossroads'
    else -- degree == 2
      if angle and angle > conf.turn_angle_threshold_deg then
        typeStr = 'turn'
      else
        typeStr = 'straight'
      end
    end

    -- links[] ΓÇö ╤é╨╛╨╗╤î╨║╨╛ degree >= 3 (╤ü╤à╨╡╨╝╨░): ╨░╨╖╨╕╨╝╤â╤é╤ï ╨▓╤ü╨╡╤à ╨╕╤ü╤à╨╛╨┤╤Å╤ë╨╕╤à ╤Ç╤æ╨▒╨╡╤Ç
    local linksArr = {}
    if degree >= 3 then
      for _, toId in ipairs(sibs) do
        local tn = nodesMap[toId]
        if tn and tn.pos and pos then
          linksArr[#linksArr + 1] = {
            edge_id = edgeIdOf(id, toId),
            to_id = tostring(toId),
            direction_deg = azimuthDeg(tn.pos.x - pos.x, tn.pos.y - pos.y),
          }
        end
      end
    end

    local out = {
      id = tostring(id),
      x = pos and pos.x or 0,
      y = pos and pos.y or 0,
      z = pos and pos.z or 0,
      type = typeStr,
      degree = degree,
      junction_type = junction or JSON_NULL,
      links = linksArr,
    }
    out.angle_deg = (degree == 2) and angle or JSON_NULL
    nodesArr[#nodesArr + 1] = out
    if exampleIdSet[id] then exampleNodes[#exampleNodes + 1] = out end

    nodeInfo[id] = { pos = pos, degree = degree, angle = angle, sibs = sibs }
  end

  -- === ╨ƒ╤Ç╨╛╤à╨╛╨┤ C: ╤Ç╤æ╨▒╤Ç╨░ (╨┐╨╛ ╤ü╤ï╤Ç╤ï╨╝ ╨┐╨░╤Ç╨░╨╝ ╨╕╨╖ ╨┐╤Ç╨╛╤à╨╛╨┤╨░ A; ╨┤╨╡╨┤╤â╨┐ ╤â╨╢╨╡ ╤é╨░╨╝) ===
  local edgesArr = {}
  local exampleEdges = {}
  local noRadius, noSpeed = 0, 0

  for _, re in ipairs(rawEdges) do
    local id, toId, edge = re.a, re.b, re.edge
    local eid = edgeIdOf(id, toId)
    local fi, ti = nodeInfo[id], nodeInfo[toId]
    if fi.pos == nil or ti.pos == nil then
      warn('╤Ç╨╡╨▒╤Ç╨╛ ╤ü ╤â╨╖╨╗╨╛╨╝ ╨▒╨╡╨╖ pos: edge=' .. eid)
    else
      local pA = edgeEndPos(edge, id, fi.pos)
      local pB = edgeEndPos(edge, toId, ti.pos)
      local length = vecLen(vecSub(pB, pA))

      -- ╤Ç╨░╨┤╨╕╤â╤ü: ╤é╨╛╨╗╤î╨║╨╛ ╨╡╤ü╨╗╨╕ degree(from) == 2 ΓÇö prev = ╨▓╤é╨╛╤Ç╨╛╨╣ ╤ü╨╛╤ü╨╡╨┤ from
      local radius = nil
      if fi.degree == 2 then
        local prevId = (fi.sibs[1] == toId) and fi.sibs[2] or fi.sibs[1]
        local prevNode = nodesMap[prevId]
        if prevNode and prevNode.pos and fi.pos and ti.pos then
          radius = circumradius(prevNode.pos, fi.pos, ti.pos)
        end
      end
      if radius == nil then noRadius = noRadius + 1 end

      -- ╤ü╨║╨╛╤Ç╨╛╤ü╤é╤î: ╨╕╨│╤Ç╨╛╨▓╨╛╨╣ ╨╗╨╕╨╝╨╕╤é (╨╝/╤ü ΓåÆ ╨║╨╝/╤ç) ╨╕ ╤ä╨╕╨╖╨╕╨║╨░ sqrt(╬╝┬╖g┬╖R)
      local limitKph = nil
      if edge.speedLimit ~= nil then
        limitKph = floorToStep(edge.speedLimit * 3.6, conf.speed_round_kph)
      else
        noSpeed = noSpeed + 1
        warn('╨╜╨╡╤é speedLimit: edge=' .. eid)
      end
      local physKph = nil
      if radius ~= nil then
        physKph = floorToStep(math.sqrt(conf.friction_mu * 9.81 * radius) * 3.6, conf.speed_round_kph)
      end
      local recKph = JSON_NULL
      if limitKph and physKph then recKph = math.min(limitKph, physKph)
      elseif limitKph then recKph = limitKph
      elseif physKph then recKph = physKph end

      local eOut = {
        edge_id = eid,
        from_id = tostring(id),
        to_id = tostring(toId),
        length_m = length,
        -- ╨░╨╖╨╕╨╝╤â╤é fromΓåÆto ╨┐╨╛ pos ╤â╨╖╨╗╨╛╨▓ (╤ü╤à╨╡╨╝╨░): 0┬░ = ╤ü╨╡╨▓╨╡╤Ç (+Y), ╨┐╨╛ ╤ç╨░╤ü╨╛╨▓╨╛╨╣
        direction_deg = azimuthDeg(ti.pos.x - fi.pos.x, ti.pos.y - fi.pos.y),
        direction = edge.oneWay and 'one-way' or 'both',
        radius_m = radius or JSON_NULL,
        curvature = radius and (1 / radius) or JSON_NULL,
        speed_limit_kph = limitKph or JSON_NULL,
        recommended_speed_kph = recKph,
      }
      -- ╤â╨│╨╛╨╗ ╨╜╨░ ╨▓╤à╨╛╨┤╨╡/╨▓╤ï╤à╨╛╨┤╨╡ (╨┤╤â╨▒╨╗╨╕╨║╨░╤é╤ï nodes[].angle_deg, ╨┐╤Ç╨░╨▓╨║╨░ ╤ü╤à╨╡╨╝╤ï)
      eOut.angle_from_deg = (fi.degree == 2) and fi.angle or JSON_NULL
      eOut.angle_to_deg = (ti.degree == 2) and ti.angle or JSON_NULL
      edgesArr[#edgesArr + 1] = eOut

      if exampleIdSet[id] and exampleIdSet[toId] then
        exampleEdges[#exampleEdges + 1] = eOut
      end
    end
  end

  -- === warnings: ╨┐╨╛╨╗╨╜╤ï╨╣ ╤ü╨┐╨╕╤ü╨╛╨║ ╨▓ ╤ä╨░╨╣╨╗, ╨▓ meta ΓÇö ╨╝╨░╨║╤ü╨╕╨╝╤â╨╝ 10 (╨┐╤Ç╨░╨▓╨║╨░) ===
  if #warnings > 0 then
    local wf = io.open(GRAPH_DIR .. 'warnings.txt', 'w')
    if wf then
      wf:write(table.concat(warnings, '\r\n') .. '\r\n')
      wf:close()
    else
      logger.logLine('WARN', '╨¥╨╡ ╤â╨┤╨░╨╗╨╛╤ü╤î ╨╖╨░╨┐╨╕╤ü╨░╤é╤î ' .. GRAPH_DIR .. 'warnings.txt')
    end
  end
  local metaWarnings = {}
  for i = 1, math.min(10, #warnings) do metaWarnings[i] = warnings[i] end
  if #warnings > 10 then
    metaWarnings[#metaWarnings + 1] = '... (╨╡╤ë╤æ ' .. (#warnings - 10) .. ', ╨┐╨╛╨╗╨╜╤ï╨╣ ╤ü╨┐╨╕╤ü╨╛╨║: ai/road/warnings.txt)'
  end

  local levelName = 'unknown'
  pcall(function()
    local li = getLevelInfo and getLevelInfo()
    if li then levelName = li.name or li.levelName or levelName end
  end)

  local data = {
    meta = {
      format_version = 1,
      created = os.date('%Y-%m-%d %H:%M:%S'),
      level = levelName,
      -- ╨ú3: build_serial ΓÇö ╨╕╨╖ ╨É╨Ü╨ó╨ú╨É╨¢╨¼╨¥╨₧╨Ö ╤ü╤é╤Ç╤â╨║╤é╤â╤Ç╤ï gm ╨ƒ╨₧╨í╨¢╨ò ╨▓╨╛╨╖╨╝╨╛╨╢╨╜╨╛╨│╨╛
      -- map.load() ╨▓ ╨│╨▓╨░╤Ç╨┤╨╡ (╨╜╨╡ ╨┐╤Ç╨╡╨┤╤ï╨┤╤â╤ë╨╡╨╡ ╨╖╨╜╨░╤ç╨╡╨╜╨╕╨╡)
      build_serial = tonumber(gm.buildSerial) or 0,
      mu = conf.friction_mu,
      node_count = #nodesArr,
      edge_count = #edgesArr,
      isolated_count = isolatedCount,
      warnings = metaWarnings,
    },
    nodes = nodesArr,
    edges = edgesArr,
  }

  local okW = jsonWriteFile(GRAPH_DIR .. 'graph.json', data, true)
  if not okW then
    print('ERROR apl_exportGraph: jsonWriteFile ╨╜╨╡ ╤ü╨╝╨╛╨│ ╨╖╨░╨┐╨╕╤ü╨░╤é╤î ' .. GRAPH_DIR .. 'graph.json')
    return false
  end

  -- ╨ƒ╤Ç╨╕╨╝╨╡╤Ç ╤ä╨╛╤Ç╨╝╨░╤é╨░: ╨í╨Æ╨»╨ù╨¥╨½╨Ö ╨┐╨╛╨┤╨│╤Ç╨░╤ä ╨╕╨╖ 20 ╤â╨╖╨╗╨╛╨▓ (BFS) + ╤Ç╤æ╨▒╤Ç╨░ ╨╝╨╡╨╢╨┤╤â ╨╜╨╕╨╝╨╕ ΓÇö
  -- ╨║╨╛╨╝╨╝╨╕╤é╨╕╤é╤ü╤Å. meta example ΓÇö ╨┐╨╛╨╗╨╜╨░╤Å ╨║╨╛╨┐╨╕╤Å meta ╨│╤Ç╨░╤ä╨░ + note: ╤ç╨╡╨║╨╡╤Ç --example
  -- ╤é╤Ç╨╡╨▒╤â╨╡╤é mu/warnings ╨╕ ╤é.╨┐., ╤ü╤Ç╨╡╨╖ ╨┤╨╛╨╗╨╢╨╡╨╜ ╨┤╨╡╨╝╨╛╨╜╤ü╤é╤Ç╨╕╤Ç╨╛╨▓╨░╤é╤î ╨Æ╨í╨« ╤ü╤à╨╡╨╝╤â.
  do
    local exMeta = {}
    for k, v in pairs(data.meta) do exMeta[k] = v end
    exMeta.note = '╤ü╤Ç╨╡╨╖: ╤ü╨▓╤Å╨╖╨╜╤ï╨╣ ╨┐╨╛╨┤╨│╤Ç╨░╤ä 20 ╤â╨╖╨╗╨╛╨▓ graph.json (BFS) ╨┤╨╗╤Å ╨┐╤Ç╨╕╨╝╨╡╤Ç╨░ ╤ä╨╛╤Ç╨╝╨░╤é╨░'
    jsonWriteFile(GRAPH_DIR .. 'graph.example.json', {
      meta = exMeta,
      nodes = exampleNodes,
      edges = exampleEdges,
    }, true)
  end

  -- === ╨₧╤é╤ç╤æ╤é ╨▓ ╨║╨╛╨╜╤ü╨╛╨╗╤î (╨┐╨╡╤Ç╨▓╤ï╨╡ ╤ü╤é╤Ç╨╛╨║╨╕, ╨║╨░╨║ ╤é╤Ç╨╡╨▒╨╛╨▓╨░╨╗ ╨┐╨╛╨╗╤î╨╖╨╛╨▓╨░╤é╨╡╨╗╤î) ===
  local total = #edgesArr
  local pct = total > 0 and math.floor(noRadius * 1000 / total + 0.5) / 10 or 0
  print('graph: ╤â╨╖╨╗╨╛╨▓ ' .. #nodesArr .. ', ╤Ç╤æ╨▒╨╡╤Ç ' .. total)
  print('radius_m == null: ' .. noRadius .. ' (' .. tostring(pct) .. '%)')
  if pct > 50 then
    print('WARN: ╨▒╨╛╨╗╤î╤ê╨╡ 50% ╤Ç╤æ╨▒╨╡╤Ç ╨▒╨╡╨╖ radius_m ΓÇö ╤ì╤é╨╛ ╨┐╨╛╤ç╤é╨╕ ╨╜╨░╨▓╨╡╤Ç╨╜╤Å╨║╨░ ╨┐╤Ç╤Å╨╝╤ï╨╡ (null ╨┐╨╛ ╤ü╤à╨╡╨╝╨╡), ╨╜╨╛ ╨┐╤Ç╨╛╨▓╨╡╤Ç╤î ╤ü╤é╨░╤é╨╕╤ü╤é╨╕╨║╤â ╨▓ graph_check.py')
  end
  print('isolated: ' .. isolatedCount)
  if noSpeed > 0 then
    print('╨▒╨╡╨╖ speedLimit: ' .. noSpeed .. ' ╤Ç╨╡╨▒╤æ╤Ç (WARN, speed_limit_kph = null)')
  end
  local real = ''
  pcall(function() real = FS:getFileRealPath(GRAPH_DIR .. 'graph.json') or '' end)
  print('graph.json: ' .. (real ~= '' and real or (GRAPH_DIR .. 'graph.json')))
  logger.logLine('INFO', string.format('╨ô╤Ç╨░╤ä ╤ì╨║╤ü╨┐╨╛╤Ç╤é╨╕╤Ç╨╛╨▓╨░╨╜: ╤â╨╖╨╗╨╛╨▓ %d, ╤Ç╤æ╨▒╨╡╤Ç %d, isolated %d, ╨▒╨╡╨╖ radius %d (%.1f%%)',
    #nodesArr, total, isolatedCount, noRadius, pct))
  return true
end

-- apl_mark("╨║╨╛╨╝╨╝╨╡╨╜╤é╨░╤Ç╨╕╨╣") ΓÇö ╨╝╨╡╤é╨║╨░ ╨▓ ai/road/marks.csv (╤ê╨░╨│ 2.5).
-- ╨í╤à╨╡╨╝╨░: graph_schema.md, ╤Ç╨░╨╖╨┤╨╡╨╗ ┬½╨ñ╨░╨╣╨╗ ╨╝╨╡╤é╨╛╨║┬╗ (8 ╨║╨╛╨╗╨╛╨╜╨╛╨║). ╨ƒ╤Ç╨╕╨▓╤Å╨╖╨║╨░ ╨║ ╨│╤Ç╨░╤ä╤â:
-- ╨▒╨╗╨╕╨╢╨░╨╣╤ê╨╕╨╣ ╤â╨╖╨╡╨╗ (╨┐╨╡╤Ç╨╡╨▒╨╛╤Ç map.nodes, min ╨╡╨▓╨║╨╗╨╕╨┤╨╛╨▓╨╛╨╣ ╨┤╨╕╤ü╤é╨░╨╜╤å╨╕╨╕) + ╤Ç╨╡╨▒╤Ç╨╛ ╤ç╨╡╤Ç╨╡╨╖
-- map.findClosestRoad(pos) ΓåÆ edge_id ╨▓ ╤ä╨╛╤Ç╨╝╨░╤é╨╡ min_max ╨║╨░╨║ ╨▓ graph.json.
local MARKS_CSV = GRAPH_DIR .. 'marks.csv'
local MARKS_HEADER = 'time,x,y,z,comment,nearest_node_id,node_dist_m,edge_id'

-- ╨¡╨║╤Ç╨░╨╜╨╕╤Ç╨╛╨▓╨░╨╜╨╕╨╡ CSV-╨┐╨╛╨╗╤Å: ╨▓╤ü╨╡╨│╨┤╨░ ╨▓ ╨║╨░╨▓╤ï╤ç╨║╨░╤à, ╨▓╨╜╤â╤é╤Ç╨╡╨╜╨╜╨╕╨╡ ╨║╨░╨▓╤ï╤ç╨║╨╕ ╤â╨┤╨▓╨░╨╕╨▓╨░╨╡╨╝
local function csvQuote(s)
  return '"' .. tostring(s):gsub('"', '""') .. '"'
end

-- ╨º╨╕╤ü╨╗╨╛ ╨▓ CSV: ╤é╨╛╤ç╨║╨░ ╨║╨░╨║ ╤Ç╨░╨╖╨┤╨╡╨╗╨╕╤é╨╡╨╗╤î ╨╜╨╡╨╖╨░╨▓╨╕╤ü╨╕╨╝╨╛ ╨╛╤é ╨╗╨╛╨║╨░╨╗╨╕ C-runtime ╨╕╨│╤Ç╤ï
local function csvNum(v, digits)
  if v == nil or v ~= v then return '' end
  local s = string.format('%.' .. digits .. 'f', v)
  return (s:gsub(',', '.'))
end

-- === ╨ñ╨░╨╖╨░ 6 (╤ê╨░╨│ 6.3): ╨╕╨│╤Ç╨╛╨▓╨╛╨╡ ╨▓╤Ç╨╡╨╝╤Å ΓÇö ╨╢╨╕╨▓╤æ╤é ╨ó╨₧╨¢╨¼╨Ü╨₧ ╨▓ GE (╨▓ electrics ╨╡╨│╨╛ ╨╜╨╡╤é,
-- api_research_phase6.md ┬º2) ===
-- core_environment.getTimeOfDay().time ΓÇö ╨┤╨╛╨╗╤Å ╤ü╤â╤é╨╛╨║ 0..1, 0 = ╨┐╨╛╨╗╨┤╨╡╨╜╤î
-- (╨╛╨▒╤Ç╨░╤é╨╜╨░╤Å ╨║╨╛╨╜╨▓╨╡╤Ç╤é╨░╤å╨╕╤Å ╨▓ ╨▓╨░╨╜╨╕╨╗╨╕: ge_utils.lua:706 setTimeOfDay);
-- ╨º╨º = ((time + 0.5) % 1) * 24 ΓÇö ╤é╨░ ╨╢╨╡ ╤ä╨╛╤Ç╨╝╤â╨╗╨░ ╤â ge_utils.lua:679.
local function gameTodHours()
  local ok, tod = pcall(function()
    if core_environment == nil or core_environment.getTimeOfDay == nil then return nil end
    return core_environment.getTimeOfDay()
  end)
  if not ok or type(tod) ~= 'table' or tonumber(tod.time) == nil then return nil end
  local h = ((tonumber(tod.time) + 0.5) % 1) * 24
  if h ~= h or h < 0 or h >= 24 then return nil end -- NaN/╨│╤Ç╨░╨╜╨╕╤å╤ï
  return h
end

-- "╨º╨º:╨£╨£" ╨╕╨╖ ╨╕╨│╤Ç╨╛╨▓╨╛╨│╨╛ ╨▓╤Ç╨╡╨╝╨╡╨╜╨╕ ╨╕╨╗╨╕ nil (╨▓╨╜╨╡ ╨╝╨╕╤ü╤ü╨╕╨╕/╨╝╨╡╨╜╤Ä ╨▓╤Ç╨╡╨╝╨╡╨╜╨╕ ╨╜╨╡╤é)
local function gameTodString()
  local h = gameTodHours()
  if h == nil then return nil end
  local hh = math.floor(h)
  local mm = math.floor((h - hh) * 60)
  if mm > 59 then mm = 59 end -- ╤ü╤é╤Ç╨░╤à╨╛╨▓╨║╨░ ╨╛╤é ╨┐╨╗╨░╨▓╨░╤Ä╤ë╨╡╨╣ ╨│╤Ç╨░╨╜╨╕╤å╤ï
  return string.format('%02d:%02d', hh, mm)
end

function apl_mark(comment)
  comment = comment ~= nil and tostring(comment) or ''

  -- ╨ñ╨░╨╖╨░ 6 (╤ê╨░╨│ 6.3): ╨░╨▓╤é╨╛╨┤╨╛╨┐╨╛╨╗╨╜╨╡╨╜╨╕╨╡ ╨╕╨│╤Ç╨╛╨▓╤ï╨╝ ╨▓╤Ç╨╡╨╝╨╡╨╜╨╡╨╝ ┬½[╨º╨º:╨£╨£]┬╗ ΓÇö ╨╕╨│╤Ç╨╛╨║
  -- ╨║╨░╨╗╨╕╨▒╤Ç╤â╨╡╤é ╤ü╨▓╨╡╤é╨╛╨▓╤ï╨╡ ╨╛╨║╨╜╨░ lights_by_map.json ╨┐╨╛ ╨╝╨╡╤é╨║╨░╨╝: apl_mark("╤é╤â╤é
  -- ╤é╨╡╨╝╨╜╨╡╨╡╤é") ΓåÆ comment="╤é╤â╤é ╤é╨╡╨╝╨╜╨╡╨╡╤é [19:45]". ╨Æ╤Ç╨╡╨╝╤Å ╤ç╨╕╤é╨░╨╡╨╝ ╨▓ GE
  -- (gameTodString, core_environment); ╨╖╨░╨┐╨╕╤ü╤î marks.csv ╨╕╨┤╤æ╤é ╨╖╨┤╨╡╤ü╤î ╨╢╨╡ ╨▓ GE.
  do
    local todStr = gameTodString()
    if todStr then
      comment = comment ~= '' and (comment .. ' [' .. todStr .. ']') or ('[' .. todStr .. ']')
    else
      print('WARN apl_mark: ╨╕╨│╤Ç╨╛╨▓╨╛╨╡ ╨▓╤Ç╨╡╨╝╤Å ╨╜╨╡╨┤╨╛╤ü╤é╤â╨┐╨╜╨╛ ΓÇö ╨╝╨╡╤é╨║╨░ ╨▒╨╡╨╖ [╨º╨º:╨£╨£]')
    end
  end

  local veh = getPlayerVehicle(0)
  if not veh then
    print('WARN apl_mark: ╨╝╨░╤ê╨╕╨╜╨░ ╨╕╨│╤Ç╨╛╨║╨░ ╨╜╨╡ ╨╜╨░╨╣╨┤╨╡╨╜╨░')
    return false
  end
  local pos = veh:getPosition()
  if pos == nil then
    print('WARN apl_mark: ╤â ╨╝╨░╤ê╨╕╨╜╤ï ╨╕╨│╤Ç╨╛╨║╨░ ╨╜╨╡╤é ╨┐╨╛╨╖╨╕╤å╨╕╨╕')
    return false
  end

  -- ╨ö╨╛╤ü╤é╤â╨┐ ╨║ ╨│╤Ç╨░╤ä╤â ╨ó╨₧╨¢╨¼╨Ü╨₧ ╤ç╨╡╤Ç╨╡╨╖ map.getMap() (╨ú1, 2026-10-12); map.load() ╨╜╨╡
  -- ╨╖╨╛╨▓╤æ╨╝: findClosestRoad ╨╜╨╕╨╢╨╡ ╤Ç╨░╨▒╨╛╤é╨░╨╡╤é ╨┐╨╛ kd-╨┤╨╡╤Ç╨╡╨▓╤â, ╨║╨╛╤é╨╛╤Ç╨╛╨╡ ╨║ ╨╝╨╛╨╝╨╡╨╜╤é╤â
  -- ╨║╨╛╨╜╤ü╨╛╨╗╨╕ ╤â╨╢╨╡ ╨┐╨╛╤ü╤é╤Ç╨╛╨╡╨╜╨╛ (╨┤╨╕╨░╨│╨╜╨╛╤ü╤é╨╕╨║╨░ 2.7a: 5439 ╤â╨╖╨╗╨╛╨▓ ╨╜╨░ East Coast).
  local okMap, gm = pcall(map.getMap)
  if not okMap or type(gm) ~= 'table' or type(gm.nodes) ~= 'table' or next(gm.nodes) == nil then
    print('WARN apl_mark: ╨│╤Ç╨░╤ä ╨╜╨╡╨┤╨╛╤ü╤é╤â╨┐╨╡╨╜ (map.getMap() ╨┐╤â╤ü╤é) ΓÇö ╨╝╨╡╤é╨║╨░ ╨▒╨╡╨╖ ╨┐╤Ç╨╕╨▓╤Å╨╖╨║╨╕ ╨╜╨╡╨▓╨╛╨╖╨╝╨╛╨╢╨╜╨░')
    return false
  end
  local nodesMap = gm.nodes

  -- ╨æ╨╗╨╕╨╢╨░╨╣╤ê╨╕╨╣ ╤â╨╖╨╡╨╗: ╨┐╨╡╤Ç╨╡╨▒╨╛╤Ç map.nodes (min ╨╡╨▓╨║╨╗╨╕╨┤╨╛╨▓╨╛╨╣ ╨┤╨╕╤ü╤é╨░╨╜╤å╨╕╨╕)
  local bestId, bestDist = nil, nil
  for id, n in pairs(nodesMap) do
    if n.pos then
      local dx, dy, dz = n.pos.x - pos.x, n.pos.y - pos.y, n.pos.z - pos.z
      local d = math.sqrt(dx * dx + dy * dy + dz * dz)
      if bestDist == nil or d < bestDist then
        bestId, bestDist = id, d
      end
    end
  end

  -- ╨á╨╡╨▒╤Ç╨╛: map.findClosestRoad(pos) ΓåÆ (n1id, n2id, dist) ╨╕╨╗╨╕ nil (map.lua:2691).
  -- ╨Æ╤ï╨╖╨╛╨▓ ╤ç╨╡╤Ç╨╡╨╖ ╨╖╨░╨╝╤ï╨║╨░╨╜╨╕╨╡ (╨ú1: ╨┐╨╛╨╗╨╡ ╨╜╨╡ ╤ç╨╕╤é╨░╨╡╨╝ ╨╜╨░╨┐╤Ç╤Å╨╝╤â╤Ä, ╤é╨╛╨╗╤î╨║╨╛ ╨▓╤ï╨╖╨╛╨▓).
  local edgeStr = ''
  local okFc, n1, n2 = pcall(function() return map.findClosestRoad(pos) end)
  if okFc and n1 and n2 then
    edgeStr = edgeIdOf(n1, n2) -- ╤é╨╛╤é ╨╢╨╡ ╤ä╨╛╤Ç╨╝╨░╤é min_max, ╤ç╤é╨╛ ╨▓ graph.json
  else
    print('WARN apl_mark: map.findClosestRoad ╨╜╨╡ ╨▓╨╡╤Ç╨╜╤â╨╗ ╤Ç╨╡╨▒╤Ç╨╛ ΓÇö edge_id ╨┐╤â╤ü╤é')
  end

  -- ╨ù╨░╨┐╨╕╤ü╤î: ╨┐╤â╤é╤î ╨╛╤é╨╜╨╛╤ü╨╕╤é╨╡╨╗╤î╨╜╤ï╨╣ (sandbox io.open), ╤ê╨░╨┐╨║╨░ ╨┐╤Ç╨╕ ╨┐╨╡╤Ç╨▓╨╛╨╝ ╨┤╨╛╨▒╨░╨▓╨╗╨╡╨╜╨╕╨╕
  pcall(function() FS:directoryCreate(GRAPH_DIR, true) end)
  local isNew = true
  do
    local probe = io.open(MARKS_CSV, 'r')
    if probe then
      probe:close()
      isNew = false
    end
  end
  local f = io.open(MARKS_CSV, 'a')
  if not f then
    print('ERROR apl_mark: ╨╜╨╡ ╤â╨┤╨░╨╗╨╛╤ü╤î ╨╛╤é╨║╤Ç╤ï╤é╤î ' .. MARKS_CSV .. ' ╨╜╨░ ╨╖╨░╨┐╨╕╤ü╤î')
    return false
  end
  if isNew then
    f:write(MARKS_HEADER .. '\r\n')
  end
  f:write(os.date('%Y-%m-%d %H:%M:%S') .. ',' ..
    csvNum(pos.x, 3) .. ',' .. csvNum(pos.y, 3) .. ',' .. csvNum(pos.z, 3) .. ',' ..
    csvQuote(comment) .. ',' ..
    (bestId and tostring(bestId) or '') .. ',' ..
    csvNum(bestDist, 2) .. ',' ..
    edgeStr .. '\r\n')
  f:close()

  local real = ''
  pcall(function() real = FS:getFileRealPath(MARKS_CSV) or '' end)
  print('╨╝╨╡╤é╨║╨░: ╤â╨╖╨╡╨╗=' .. (bestId and tostring(bestId) or '╨╜╨╡╤é') ..
    ' (' .. (bestDist and string.format('%.1f ╨╝', bestDist) or '?') .. '), ╤Ç╨╡╨▒╤Ç╨╛=' ..
    (edgeStr ~= '' and edgeStr or '╨╜╨╡╤é'))
  print('marks.csv: ' .. (real ~= '' and real or MARKS_CSV))
  logger.logLine('INFO', 'apl_mark: ╤â╨╖╨╡╨╗=' .. tostring(bestId) ..
    ' ╨┤╨╕╤ü╤é=' .. tostring(bestDist) .. ' ╤Ç╨╡╨▒╤Ç╨╛=' .. (edgeStr ~= '' and edgeStr or '╨╜╨╡╤é'))
  return true
end

-- === ╨ñ╨░╨╖╨░ 2 (╤ê╨░╨│ 2.7a): ╨┤╨╕╨░╨│╨╜╨╛╤ü╤é╨╕╨║╨░ ╨╜╨░╨▓╨╕╨│╤Ç╨░╤ä╨░ ===
-- apl_mapDiag() ΓÇö ╨▓╤Ç╨╡╨╝╨╡╨╜╨╜╨░╤Å ╨║╨╛╨╝╨░╨╜╨┤╨░ (╨║╨░╨║ apl_diag ╨▓ ╨ñ╨░╨╖╨╡ 1): ╨┐╨╡╤ç╨░╤é╨░╨╡╤é
-- ╤ü╨╛╤ü╤é╨╛╤Å╨╜╨╕╨╡ ╨╜╨░╨▓╨╕╨│╤Ç╨░╤ä╨░, ╨¥╨ÿ╨º╨ò╨ô╨₧ ╨╜╨╡ ╤ç╨╕╨╜╨╕╤é.
-- ╨¥╨░╨╣╨┤╨╡╨╜╨╛ ╨┐╨╛ ╨╕╤ü╤à╨╛╨┤╨╜╨╕╨║╨░╨╝ ╨ƒ╨ò╨á╨ò╨ö ╨╜╨░╨┐╨╕╤ü╨░╨╜╨╕╨╡╨╝: ╨│╨╗╨╛╨▒╨░╨╗╤î╨╜╨╛╨╡ ╨╕╨╝╤Å ╤Ç╨░╤ü╤ê╨╕╤Ç╨╡╨╜╨╕╤Å `map` ΓÇö
-- ╤ì╤é╨╛ ╤é╨░╨▒╨╗╨╕╤å╨░ API ╨╝╨╛╨┤╤â╨╗╤Å (M), ╤â ╨¥╨ò╨ü ╨╜╨╡╤é ╨┐╨╛╨╗╤Å nodes; ╤ü╤é╤Ç╤â╨║╤é╤â╤Ç╨░ ╤ü ╤â╨╖╨╗╨░╨╝╨╕ ΓÇö
-- ╨╗╨╛╨║╨░╨╗╤î╨╜╨░╤Å ╨┐╨╡╤Ç╨╡╨╝╨╡╨╜╨╜╨░╤Å ╨╝╨╛╨┤╤â╨╗╤Å (map.lua:25 `local map = {nodes = {}}`),
-- ╨╜╨░╤Ç╤â╨╢╤â ╨╡╤æ ╨╛╤é╨┤╨░╤æ╤é map.getMap() (map.lua:3793-3795); deprecated-╨▓╨╡╤é╨║╨░
-- map.map (4001-4012) ΓÇö ╤é╨╛╨╗╤î╨║╨╛ ╨┤╨╗╤Å ╨║╨╗╤Ä╤ç╨░ 'map'. ╨¢╨╡╨╜╨╕╨▓╨░╤Å ╨╖╨░╨│╤Ç╤â╨╖╨║╨░:
-- map.load() = Mload ╤ü ╤ä╨╗╨░╨│╨╛╨╝ loadedMap (map.lua:3642-3646), ╤ü╨▒╤Ç╨╛╤ü ╤ä╨╗╨░╨│╨░ ΓÇö
-- onMissionLoaded. ╨ÿ╤ü╤é╨╛╤ç╨╜╨╕╨║╨╕ ╨╜╨░╨▓╨╕╨│╤Ç╨░╤ä╨░: DecalRoad ╤ü╤å╨╡╨╜╤ï (map.lua:587+)
-- + map.json ┬½manual road segments┬╗ (map.lua:786-795, ╨╛╤é╤ü╤â╤é╤ü╤é╨▓╨╕╨╡ ╤ä╨░╨╣╨╗╨░ ΓÇö
-- ╨╜╨╡ ╨╛╤ê╨╕╨▒╨║╨░, ╨┐╤Ç╨╛╤ü╤é╨╛ ╨▒╨╡╨╖ manual-╤ü╨╡╨│╨╝╨╡╨╜╤é╨╛╨▓).
function apl_mapDiag()
  local function countNodes(t)
    if type(t) ~= 'table' then return -1 end
    local c = 0
    for _ in pairs(t) do c = c + 1 end
    return c
  end

  print('--- apl_mapDiag: ╨╜╨░╨▓╨╕╨│╤Ç╨░╤ä ---')

  -- 1. ╨ú╤Ç╨╛╨▓╨╡╨╜╤î
  local missionFn = ''
  pcall(function() missionFn = getMissionFilename() or '' end)
  print('mission: ' .. (missionFn ~= '' and missionFn or '(getMissionFilename ╨╜╨╡╨┤╨╛╤ü╤é╤â╨┐╨╡╨╜)'))
  local levelDir = missionFn:match('^(.*[/\\])') or ''
  print('levelDir: ' .. (levelDir ~= '' and levelDir or '(╨╜╨╡ ╨▓╤ï╤ç╨╕╤ü╨╗╨╡╨╜)'))

  -- 2. API ╨╝╨╛╨┤╤â╨╗╤Å map (╤ç╤é╨╛ ╨┤╨╛╤ü╤é╤â╨┐╨╜╨╛ ╨╕╨╖ GE-╨║╨╛╨╜╤é╨╡╨║╤ü╤é╨░).
  -- ╨º╤é╨╡╨╜╨╕╨╡ ╨┐╨╛╨╗╨╡╨╣ ╨╖╨┤╨╡╤ü╤î ╨¥╨É╨£╨ò╨á╨ò╨¥╨¥╨₧╨ò (╨╛╤é╤ç╤æ╤é ╨┤╨╕╨░╨│╨╜╨╛╤ü╤é╨╕╨║╨╕): ╨┐╨╛╨║╨░╨╖╤ï╨▓╨░╨╡╨╝ ╤é╨╕╨┐ ╨┐╨╛╨╗╤Å,
  -- ╨▓ ╤Ç╨░╨▒╨╛╤ç╨╡╨╝ ╨║╨╛╨┤╨╡ ╨┐╨╛╨╗╤Å ╤ç╨╕╤é╨░╤é╤î ╨╜╨╡╨╗╤î╨╖╤Å ΓÇö ╤é╨╛╨╗╤î╨║╨╛ ╨▓╤ï╨╖╨╛╨▓╤ï (╨ú1).
  print('map API: type=' .. type(map) ..
    ', getMap(╨┐╨╛╨╗╨╡)=' .. tostring(type(map) == 'table' and type(map.getMap) or 'nil') ..
    ', findClosestRoad(╨┐╨╛╨╗╨╡)=' .. tostring(type(map) == 'table' and type(map.findClosestRoad) or 'nil') ..
    ', load(╨┐╨╛╨╗╨╡)=' .. tostring(type(map) == 'table' and type(map.load) or 'nil'))

  -- 3. ╨ƒ╤Ç╤Å╨╝╨╛╨╣ ╨┤╨╛╤ü╤é╤â╨┐ map.nodes ΓÇö ╤Ç╨╛╨▓╨╜╨╛ ╤é╨╛, ╤ç╤é╨╛ ╨╕╤ü╨┐╨╛╨╗╤î╨╖╨╛╨▓╨░╨╗ apl_exportGraph
  local directNodes = nil
  pcall(function() directNodes = map and map.nodes end)
  print('map.nodes (╨┐╤Ç╤Å╨╝╨╛╨╣ ╨┤╨╛╤ü╤é╤â╨┐): ' .. tostring(directNodes) ..
    '  <-- ╨╡╤ü╨╗╨╕ nil: nodes ╨╜╨╡ ╨┐╨╛╨╗╨╡ API, ╨╜╤â╨╢╨╡╨╜ map.getMap()')

  -- 4. map.getMap().nodes ╨ö╨₧ ╤Ç╤â╤ç╨╜╨╛╨╣ ╨╖╨░╨│╤Ç╤â╨╖╨║╨╕
  local gm = nil
  pcall(function() gm = map.getMap() end)
  local nodesBefore = type(gm) == 'table' and gm.nodes or nil
  print('nodes ╨ö╨₧ map.load(): ' .. countNodes(nodesBefore) ..
    ' ╤â╨╖╨╗╨╛╨▓ (buildSerial=' .. tostring(type(gm) == 'table' and gm.buildSerial or '?') .. ')')

  -- 5. map.json (╨┤╨╛╨┐╨╛╨╗╨╜╨╕╤é╨╡╨╗╤î╨╜╤ï╨╣ ╨╕╤ü╤é╨╛╤ç╨╜╨╕╨║ manual segments, map.lua:786-795)
  local mapJson = levelDir .. 'map.json'
  local exists, size = nil, nil
  pcall(function() exists = FS:fileExists(mapJson) end)
  if exists then
    pcall(function()
      local f = io.open(mapJson, 'r')
      if f then
        local content = f:read('*all') or ''
        f:close()
        size = #content
      end
    end)
  end
  print('map.json (' .. mapJson .. '): exists=' .. tostring(exists) ..
    (exists and (', ╨▒╨░╨╣╤é=' .. tostring(size)) or ''))
  print('  (map.json ΓÇö ╨ö╨₧╨ƒ╨₧╨¢╨¥╨ÿ╨ó╨ò╨¢╨¼╨¥╨½╨Ö ╨╕╤ü╤é╨╛╤ç╨╜╨╕╨║ manual road segments;' ..
    ' ╨╛╤ü╨╜╨╛╨▓╨╜╨╛╨╣ ╨╜╨░╨▓╨╕╨│╤Ç╨░╤ä ΓÇö DecalRoad ╤ü╤å╨╡╨╜╤ï, map.lua:587+)')

  -- 6. findClosestRoad ╨╛╤é ╨┐╨╛╨╖╨╕╤å╨╕╨╕ ╨╕╨│╤Ç╨╛╨║╨░ (kd-╨┤╨╡╤Ç╨╡╨▓╨╛ ╤ü╨╛╨╖╨┤╨░╤æ╤é╤ü╤Å ╨▓ loadMap);
  -- ╨▓╤ï╨╖╨╛╨▓ ╤ç╨╡╤Ç╨╡╨╖ ╨╖╨░╨╝╤ï╨║╨░╨╜╨╕╨╡ (╨ú1: ╨┐╨╛╨╗╨╡ ╨╜╨╡ ╤ç╨╕╤é╨░╨╡╨╝ ╨╜╨░╨┐╤Ç╤Å╨╝╤â╤Ä)
  local veh = getPlayerVehicle(0)
  if veh then
    local pos = veh:getPosition()
    local ok, n1, n2, dist = pcall(function() return map.findClosestRoad(pos) end)
    if ok and n1 and n2 then
      print(string.format('findClosestRoad(pos ╨╕╨│╤Ç╨╛╨║╨░): n1=%s n2=%s dist=%.2f ╨╝',
        tostring(n1), tostring(n2), dist or -1))
    else
      print('findClosestRoad(pos ╨╕╨│╤Ç╨╛╨║╨░): nil (kd-╨┤╨╡╤Ç╨╡╨▓╨░ ╨╜╨╡╤é ΓÇö ╨║╨░╤Ç╤é╨░ ╨╜╨╡ ╨┐╨╛╤ü╤é╤Ç╨╛╨╡╨╜╨░?)')
    end
  else
    print('findClosestRoad: ╨╝╨░╤ê╨╕╨╜╨░ ╨╕╨│╤Ç╨╛╨║╨░ ╨╜╨╡ ╨╜╨░╨╣╨┤╨╡╨╜╨░ ΓÇö ╨┐╤Ç╨╛╨┐╤â╤ë╨╡╨╜╨╛')
  end

  -- 7. ╨á╤â╤ç╨╜╨░╤Å ╨╗╨╡╨╜╨╕╨▓╨░╤Å ╨╖╨░╨│╤Ç╤â╨╖╨║╨░: map.load() ΓÇö no-op, ╨╡╤ü╨╗╨╕ ╤â╨╢╨╡ ╨╖╨░╨│╤Ç╤â╨╢╨╡╨╜╨╛
  local okLoad, err = pcall(function() map.load() end)
  print('map.load(): ' .. (okLoad and '╨▓╤ï╨╖╨▓╨░╨╜' or ('╨₧╨¿╨ÿ╨æ╨Ü╨É: ' .. tostring(err))))
  pcall(function() gm = map.getMap() end)
  local nodesAfter = type(gm) == 'table' and gm.nodes or nil
  print('nodes ╨ƒ╨₧╨í╨¢╨ò map.load(): ' .. countNodes(nodesAfter) ..
    ' ╤â╨╖╨╗╨╛╨▓ (buildSerial=' .. tostring(type(gm) == 'table' and gm.buildSerial or '?') .. ')')

  print('--- ╨║╨╛╨╜╨╡╤å ╨┤╨╕╨░╨│╨╜╨╛╤ü╤é╨╕╨║╨╕ ---')
  logger.logLine('INFO', 'apl_mapDiag: ╨┐╨╛╤ü╨╗╨╡ map.load() ╤â╨╖╨╗╨╛╨▓ ' .. countNodes(nodesAfter))
  return true
end


M.aplExportGraph = apl_exportGraph
M.aplMapDiag = apl_mapDiag
M.aplMark = apl_mark

return M