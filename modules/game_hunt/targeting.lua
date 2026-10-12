-- Escolha de alvo do Hunt. Modulo puro: recebe criaturas ja lidas do cliente
-- ({ id, name, position, healthPercent, isShiny, distance }) e a configuracao.
local Targeting = {}

Targeting.MAX_PRIORITY = 5

local function trim(text)
  return (tostring(text or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function lower(text)
  return trim(text):lower()
end

function Targeting.normalizeEntry(raw)
  if type(raw) ~= 'table' then return nil end
  local name = trim(raw.name):sub(1, 40)
  if name == '' then return nil end
  local priority = math.floor(tonumber(raw.priority) or 3)
  if priority < 1 then priority = 1 end
  if priority > Targeting.MAX_PRIORITY then priority = Targeting.MAX_PRIORITY end
  return { name = name, priority = priority, enabled = raw.enabled ~= false }
end

function Targeting.normalizeList(rawList)
  local list, seen = {}, {}
  for _, raw in ipairs(type(rawList) == 'table' and rawList or {}) do
    local entry = Targeting.normalizeEntry(raw)
    if entry and not seen[entry.name:lower()] then
      seen[entry.name:lower()] = true
      list[#list + 1] = entry
    end
  end
  return list
end

-- "Rattata, Pidgey" -> { rattata = true, pidgey = true }
function Targeting.parseNameSet(text)
  local set = {}
  for piece in tostring(text or ''):gmatch('[^,;\n]+') do
    local name = lower(piece)
    if name ~= '' then set[name] = true end
  end
  return set
end

-- Indice nome(minusculo) -> prioridade das entradas ativas. "*" vale para todos.
function Targeting.buildIndex(entries)
  local index = { names = {}, wildcard = nil, count = 0 }
  for _, entry in ipairs(entries or {}) do
    if entry.enabled ~= false then
      local name = lower(entry.name)
      if name == '*' or name == 'todos' then
        index.wildcard = math.max(index.wildcard or 0, entry.priority)
      else
        index.names[name] = math.max(index.names[name] or 0, entry.priority)
      end
      index.count = index.count + 1
    end
  end
  return index
end

local function baseName(name)
  local clean = lower(name)
  return clean:gsub('^shiny%s+', '')
end

-- Prioridade da criatura (nil = nao atacar).
function Targeting.priorityFor(creature, index, options)
  options = options or {}
  local name = lower(creature.name)
  if options.ignore and (options.ignore[name] or options.ignore[baseName(name)]) then return nil end
  local priority = index.names[name] or index.names[baseName(name)]
  if not priority then priority = index.wildcard end
  if not priority and options.attackAll then priority = 1 end
  return priority
end

-- Pontuacao: prioridade domina; depois shiny, alvo atual (evita trocar de
-- alvo a cada tick), HP baixo (termina quem ja apanhou) e distancia.
function Targeting.score(creature, priority, options)
  options = options or {}
  local score = priority * 10000
  if creature.isShiny and options.preferShiny ~= false then score = score + 50000 end
  if options.currentId and creature.id == options.currentId then score = score + 3000 end
  score = score + (100 - math.max(0, math.min(100, creature.healthPercent or 100))) * 10
  score = score - (creature.distance or 0) * 150
  return score
end

-- Devolve a melhor criatura e a pontuacao (ou nil).
-- options: maxDistance, ignore (set), attackAll, preferShiny, currentId,
-- blacklist (id -> true), isStolen(creature) -> bool (anti-KS).
function Targeting.choose(creatures, index, options)
  options = options or {}
  local best, bestScore = nil, nil
  for _, creature in ipairs(creatures or {}) do
    local distance = creature.distance
    local inRange = distance ~= nil and distance <= (options.maxDistance or 7)
    local alive = (creature.healthPercent or 100) > 0
    local blocked = options.blacklist and options.blacklist[creature.id]
    if inRange and alive and not blocked then
      local priority = Targeting.priorityFor(creature, index, options)
      if priority and not (options.isStolen and creature.id ~= options.currentId and options.isStolen(creature)) then
        local score = Targeting.score(creature, priority, options)
        if not bestScore or score > bestScore then best, bestScore = creature, score end
      end
    end
  end
  return best, bestScore
end

-- Quantos alvos validos estao a ate `radius` SQM (modo lure).
function Targeting.countTargets(creatures, index, options, radius)
  local total = 0
  for _, creature in ipairs(creatures or {}) do
    if creature.distance and creature.distance <= radius and (creature.healthPercent or 100) > 0
      and Targeting.priorityFor(creature, index, options) then
      total = total + 1
    end
  end
  return total
end

return Targeting
