-- Rotas do Hunt: lista de pontos (waypoints), modos de percurso e gravacao.
-- Modulo puro (sem API do cliente): testado em tests/hunt_logic_spec.lua.
local Route = {}

Route.TYPES = {
  walk = { label = 'Caminhar', short = 'ANDAR', color = '#4aa8e0', needsPosition = true },
  exact = { label = 'Exato', short = 'EXATO', color = '#9b7bea', needsPosition = true },
  stand = { label = 'Parar', short = 'PARAR', color = '#e5a03a', needsPosition = true },
  use = { label = 'Usar', short = 'USAR', color = '#3ac7a6', needsPosition = true },
  say = { label = 'Falar', short = 'FALAR', color = '#d86d9a', needsPosition = false },
  label = { label = 'Marcador', short = 'MARCA', color = '#8da3b3', needsPosition = false },
  ['goto'] = { label = 'Ir para', short = 'IR P/', color = '#e0d04a', needsPosition = false }
}
Route.TYPE_ORDER = { 'walk', 'exact', 'stand', 'use', 'say', 'label', 'goto' }

Route.MODES = { loop = 'Loop', pingpong = 'Ida e volta', once = 'Uma vez' }
Route.MODE_ORDER = { 'loop', 'pingpong', 'once' }

Route.DEFAULT_PRECISION = 1
Route.MAX_WAYPOINTS = 500
Route.MAX_NAME_LENGTH = 32

local function trim(text)
  return (tostring(text or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function int(value, default)
  local number = tonumber(value)
  if not number then return default end
  return math.floor(number + 0.5)
end

local function clamp(value, minimum, maximum)
  if value < minimum then return minimum end
  if value > maximum then return maximum end
  return value
end

-- Distancia em SQM (Chebyshev); nil quando os andares sao diferentes.
function Route.distance(a, b)
  if not a or not b then return nil end
  if a.z ~= b.z then return nil end
  return math.max(math.abs(a.x - b.x), math.abs(a.y - b.y))
end

function Route.hasPosition(waypoint)
  return waypoint ~= nil and tonumber(waypoint.x) ~= nil and tonumber(waypoint.y) ~= nil and tonumber(waypoint.z) ~= nil
end

function Route.position(waypoint)
  if not Route.hasPosition(waypoint) then return nil end
  return { x = waypoint.x, y = waypoint.y, z = waypoint.z }
end

function Route.normalizeWaypoint(raw)
  if type(raw) ~= 'table' then return nil end
  local kind = tostring(raw.type or 'walk')
  local spec = Route.TYPES[kind]
  if not spec then return nil end
  local waypoint = { type = kind }
  if raw.x ~= nil or raw.y ~= nil or raw.z ~= nil then
    local x, y, z = int(raw.x), int(raw.y), int(raw.z)
    if x and y and z then
      waypoint.x, waypoint.y, waypoint.z = x, y, clamp(z, 0, 15)
    end
  end
  if spec.needsPosition and not Route.hasPosition(waypoint) then return nil end
  if kind == 'walk' then
    waypoint.precision = clamp(int(raw.precision, Route.DEFAULT_PRECISION), 0, 5)
  elseif kind == 'stand' then
    waypoint.seconds = clamp(int(raw.seconds, 5), 1, 600)
  elseif kind == 'say' then
    waypoint.text = trim(raw.text):sub(1, 120)
    if waypoint.text == '' then return nil end
  elseif kind == 'label' or kind == 'goto' then
    waypoint.label = trim(raw.label):sub(1, 32)
    if waypoint.label == '' then return nil end
  end
  return waypoint
end

function Route.new(name)
  return { name = Route.cleanName(name) or 'Rota', mode = 'loop', waypoints = {} }
end

function Route.cleanName(name)
  local clean = trim(name):gsub('[%c]', ''):sub(1, Route.MAX_NAME_LENGTH)
  if clean == '' then return nil end
  return clean
end

function Route.normalize(raw)
  if type(raw) ~= 'table' then return nil end
  local route = Route.new(raw.name)
  route.mode = Route.MODES[raw.mode] and raw.mode or 'loop'
  for _, rawWaypoint in ipairs(type(raw.waypoints) == 'table' and raw.waypoints or {}) do
    local waypoint = Route.normalizeWaypoint(rawWaypoint)
    if waypoint and #route.waypoints < Route.MAX_WAYPOINTS then
      route.waypoints[#route.waypoints + 1] = waypoint
    end
  end
  return route
end

function Route.normalizeList(rawList)
  local routes, seen = {}, {}
  for _, raw in ipairs(type(rawList) == 'table' and rawList or {}) do
    local route = Route.normalize(raw)
    if route then
      local base, suffix = route.name, 2
      while seen[route.name:lower()] do
        route.name = string.format('%s (%d)', base, suffix):sub(1, Route.MAX_NAME_LENGTH)
        suffix = suffix + 1
      end
      seen[route.name:lower()] = true
      routes[#routes + 1] = route
    end
  end
  return routes
end

function Route.uniqueName(routes, wanted)
  local base = Route.cleanName(wanted) or 'Rota'
  local taken = {}
  for _, route in ipairs(routes or {}) do taken[route.name:lower()] = true end
  if not taken[base:lower()] then return base end
  local suffix = 2
  while true do
    local candidate = string.format('%s %d', base, suffix):sub(1, Route.MAX_NAME_LENGTH)
    if not taken[candidate:lower()] then return candidate end
    suffix = suffix + 1
  end
end

-- Insere depois de `afterIndex` (ou no fim). Devolve o indice novo ou nil.
function Route.addWaypoint(route, raw, afterIndex)
  local waypoint = Route.normalizeWaypoint(raw)
  if not waypoint or #route.waypoints >= Route.MAX_WAYPOINTS then return nil end
  local index = #route.waypoints + 1
  if afterIndex and afterIndex >= 0 and afterIndex < #route.waypoints then index = afterIndex + 1 end
  table.insert(route.waypoints, index, waypoint)
  return index
end

function Route.removeWaypoint(route, index)
  if not route.waypoints[index] then return false end
  table.remove(route.waypoints, index)
  return true
end

function Route.moveWaypoint(route, index, delta)
  local target = index + delta
  local list = route.waypoints
  if not list[index] or not list[target] then return nil end
  list[index], list[target] = list[target], list[index]
  return target
end

-- Inverte a ordem dos pontos (rota de volta).
function Route.reverse(route)
  local reversed = {}
  for index = #route.waypoints, 1, -1 do reversed[#reversed + 1] = route.waypoints[index] end
  route.waypoints = reversed
end

function Route.findLabel(route, label)
  local wanted = trim(label):lower()
  for index, waypoint in ipairs(route.waypoints) do
    if waypoint.type == 'label' and waypoint.label:lower() == wanted then return index end
  end
  return nil
end

-- Ponto com posicao mais proximo do jogador (mesmo andar). Empate: o menor
-- indice a partir de `preferFrom`, para nao voltar a rota.
function Route.nearestIndex(route, position, preferFrom)
  local best, bestDistance = nil, nil
  local count = #route.waypoints
  if count == 0 or not position then return nil end
  local start = (preferFrom and preferFrom >= 1 and preferFrom <= count) and preferFrom or 1
  for offset = 0, count - 1 do
    local index = ((start - 1 + offset) % count) + 1
    local waypoint = route.waypoints[index]
    if Route.TYPES[waypoint.type].needsPosition then
      local distance = Route.distance(position, waypoint)
      if distance and (not bestDistance or distance < bestDistance) then
        best, bestDistance = index, distance
      end
    end
  end
  return best, bestDistance
end

-- Proximo indice segundo o modo. direction: 1 ou -1 (ida e volta).
-- Devolve indice, direcao e se completou uma volta (nil quando a rota acabou).
function Route.nextIndex(route, current, mode, direction)
  local count = #route.waypoints
  if count == 0 then return nil, direction, false end
  direction = direction == -1 and -1 or 1
  mode = mode or route.mode or 'loop'
  if count == 1 then return 1, direction, true end
  local nextIdx = (current or 0) + direction
  if mode == 'pingpong' then
    if nextIdx > count then return count - 1, -1, false end
    if nextIdx < 1 then return 2, 1, true end
    return nextIdx, direction, false
  elseif mode == 'once' then
    if nextIdx > count then return nil, direction, true end
    return nextIdx, direction, false
  end
  if nextIdx > count then return 1, 1, true end
  if nextIdx < 1 then return count, 1, false end
  return nextIdx, 1, false
end

function Route.describe(waypoint)
  if not waypoint then return '' end
  local function pos()
    return string.format('%d, %d, %d', waypoint.x, waypoint.y, waypoint.z)
  end
  local kind = waypoint.type
  if kind == 'walk' then
    return waypoint.precision and waypoint.precision ~= Route.DEFAULT_PRECISION
      and string.format('%s  (tolerancia %d)', pos(), waypoint.precision) or pos()
  elseif kind == 'exact' then
    return pos() .. '  (tile exato)'
  elseif kind == 'stand' then
    return string.format('%s  por %d s', pos(), waypoint.seconds or 5)
  elseif kind == 'use' then
    return pos() .. '  (usar)'
  elseif kind == 'say' then
    return '"' .. waypoint.text .. '"'
  elseif kind == 'label' then
    return '[' .. waypoint.label .. ']'
  elseif kind == 'goto' then
    return '-> [' .. waypoint.label .. ']'
  end
  return kind
end

function Route.summary(route)
  if not route then return 'Nenhuma rota' end
  local floors, seen = 0, {}
  for _, waypoint in ipairs(route.waypoints) do
    if waypoint.z and not seen[waypoint.z] then seen[waypoint.z] = true; floors = floors + 1 end
  end
  return string.format('%d ponto(s), %d andar(es), modo %s', #route.waypoints, floors, Route.MODES[route.mode] or route.mode)
end

-- Texto de exportacao (area de transferencia).
Route.EXPORT_PREFIX = 'PKAHUNT1:'

function Route.export(route, encode)
  return Route.EXPORT_PREFIX .. encode({ name = route.name, mode = route.mode, waypoints = route.waypoints })
end

function Route.import(text, decode)
  text = trim(text)
  if text:sub(1, #Route.EXPORT_PREFIX) == Route.EXPORT_PREFIX then
    text = text:sub(#Route.EXPORT_PREFIX + 1)
  end
  if text == '' or text:sub(1, 1) ~= '{' then return nil, 'texto nao e uma rota exportada' end
  local ok, decoded = pcall(decode, text)
  if not ok or type(decoded) ~= 'table' then return nil, 'JSON invalido' end
  local route = Route.normalize(decoded)
  if not route or #route.waypoints == 0 then return nil, 'rota sem pontos validos' end
  return route
end

-- ---------------------------------------------------------------------------
-- Gravador: gera pontos enquanto o jogador anda.
-- ---------------------------------------------------------------------------

local Recorder = {}
Recorder.__index = Recorder
Route.Recorder = Recorder

function Recorder.new(step)
  return setmetatable({ step = clamp(int(step, 4), 1, 20), last = nil, previous = nil }, Recorder)
end

-- Recebe a posicao atual; devolve a lista de pontos a adicionar (pode ser vazia).
-- Ao trocar de andar grava o ultimo tile do andar antigo como "exato" (escada,
-- buraco, teleporte) e o primeiro tile do andar novo.
function Recorder:observe(position)
  local out = {}
  if not position then return out end
  local current = { x = position.x, y = position.y, z = position.z }
  if not self.last then
    self.last, self.previous = current, current
    out[#out + 1] = { type = 'walk', x = current.x, y = current.y, z = current.z }
    return out
  end
  if current.z ~= self.last.z then
    local stair = self.previous or self.last
    out[#out + 1] = { type = 'exact', x = stair.x, y = stair.y, z = stair.z }
    out[#out + 1] = { type = 'walk', x = current.x, y = current.y, z = current.z, precision = 0 }
    self.last, self.previous = current, current
    return out
  end
  local jump = Route.distance(self.previous, current)
  if jump and jump > 2 then
    -- teleporte no mesmo andar: o tile anterior vira ponto exato
    out[#out + 1] = { type = 'exact', x = self.previous.x, y = self.previous.y, z = self.previous.z }
    out[#out + 1] = { type = 'walk', x = current.x, y = current.y, z = current.z }
    self.last, self.previous = current, current
    return out
  end
  self.previous = current
  local distance = Route.distance(self.last, current)
  if distance and distance >= self.step then
    out[#out + 1] = { type = 'walk', x = current.x, y = current.y, z = current.z }
    self.last = current
  end
  return out
end

return Route
