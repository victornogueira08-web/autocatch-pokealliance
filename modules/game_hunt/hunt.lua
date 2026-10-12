-- Hunt PKA: caca automatica seguindo rotas, integrada ao Auto Catch.
--
-- Modulo sandboxed: toda funcao declarada sem "local" vira campo de
-- modules.game_hunt. A API publica esta listada no fim do arquivo.

local Route = dofile('/modules/game_hunt/route.lua')
local Targeting = dofile('/modules/game_hunt/targeting.lua')
local HuntStats = dofile('/modules/game_hunt/hunt_stats.lua')
local okStaffGuard, StaffGuard = pcall(dofile, '/modules/game_autocatch/staff_guard.lua')
if not okStaffGuard or type(StaffGuard) ~= 'table' then StaffGuard = nil end

-- ---------------------------------------------------------------------------
-- Constantes
-- ---------------------------------------------------------------------------

local CFG = {
  TICK_MS = 100,             -- tick normal
  TICK_FIGHT_MS = 80,        -- tick enquanto ataca
  TICK_IDLE_MS = 400,        -- em espera (staff, sem rota)
  SPECTATOR_CACHE_MS = 150,  -- leitura de criaturas reaproveitada entre ticks
  SAFETY_CACHE_MS = 400,
  WALK_RESEND_MS = 1200,     -- reenvia o andar se o personagem nao se mexeu
  STUCK_MS = 3500,           -- parado este tempo = tentativa de destravar
  STUCK_RETRIES = 3,         -- tentativas antes de pular o ponto
  FLOOR_MISMATCH_MS = 3000,  -- andar diferente do ponto: procura o ponto mais proximo
  ATTACK_SWITCH_MS = 400,    -- intervalo minimo entre trocas de alvo
  BLACKLIST_MS = 30000,      -- alvo que nao perde HP fica ignorado este tempo
  HEAL_COOLDOWN_MS = 1000,
  SUMMON_HEAL_COOLDOWN_MS = 1500,
  MOVE_GAP_MS = 700,         -- intervalo minimo entre dois moves
  SAY_PAUSE_MS = 600,
  USE_WAIT_MS = 900,
  LEASH_DISTANCE = 6,        -- distancia maxima de um corpo pendente do Auto Catch
  ANTI_KS_RADIUS = 2,
  MAX_GOTO_PER_TICK = 10,
  SAVE_DELAY_MS = 600,
  REFRESH_MS = 1000,
  RECORD_MS = 200,
  RESUME_DELAY_MS = 5000,
  DELETE_CONFIRM_MS = 2500
}

local SETTINGS_KEY = 'huntPkaConfig'

local DIRECTIONS = {
  north = North or 0, east = East or 1, south = South or 2, west = West or 3,
  northEast = NorthEast or 4, southEast = SouthEast or 5, southWest = SouthWest or 6, northWest = NorthWest or 7
}

local PHASES = {
  IDLE = { title = 'HUNT PARADO', color = '#8da3b3', indicator = '#a85863' },
  WALKING = { title = 'SEGUINDO A ROTA', color = '#62b6f0', indicator = '#42a5f5' },
  FIGHTING = { title = 'ATACANDO', color = '#ff9f5a', indicator = '#ff8a3d' },
  CHASING = { title = 'PERSEGUINDO ALVO', color = '#ff9f5a', indicator = '#ff8a3d' },
  CATCHING = { title = 'ESPERANDO O AUTO CATCH', color = '#c99bff', indicator = '#a66bff' },
  STANDING = { title = 'PARADO NO PONTO', color = '#ffcc66', indicator = '#e5a03a' },
  WAITING = { title = 'AGUARDANDO', color = '#9cb1c2', indicator = '#6f8798' },
  NO_ROUTE = { title = 'SEM ROTA', color = '#ffcc66', indicator = '#e5a03a' },
  PAUSED_STAFF = { title = 'EM ESPERA: STAFF', color = '#ff7676', indicator = '#ff4d4d' },
  PAUSED_PLAYER = { title = 'EM ESPERA: JOGADOR', color = '#ff7676', indicator = '#ff4d4d' },
  OFFLINE = { title = 'FORA DO JOGO', color = '#8da3b3', indicator = '#a85863' }
}

local DEFAULTS = {
  routes = {}, activeRoute = 1, startNearest = true,
  walk = true, attack = true, waitCatch = true, chase = true, chaseDistance = 3,
  lureCount = 0, lureRadius = 4,
  targets = {}, attackAll = true, ignoreText = '', maxDistance = 7, preferShiny = true, antiKs = true,
  targetTimeout = 20,
  healItemId = 0, healPercent = 60, summonHealItemId = 0, summonHealPercent = 50,
  movesEnabled = false, moveRange = 6, moves = {},
  staffPause = true, playerPause = false, playerWhitelistText = '', lowHpStop = true, lowHpPercent = 20,
  alarm = true, shinyAlert = true, stuckSkip = true, recordStep = 4, autoResume = false, wasRunning = false
}

-- campos simples ligados a widgets do painel (id do widget -> chave da config)
local FIELDS = {
  { id = 'optWalk', key = 'walk', kind = 'check' },
  { id = 'optAttack', key = 'attack', kind = 'check' },
  { id = 'optWaitCatch', key = 'waitCatch', kind = 'check' },
  { id = 'optStartNearest', key = 'startNearest', kind = 'check' },
  { id = 'optChase', key = 'chase', kind = 'check' },
  { id = 'optAttackAll', key = 'attackAll', kind = 'check' },
  { id = 'optPreferShiny', key = 'preferShiny', kind = 'check' },
  { id = 'optAntiKs', key = 'antiKs', kind = 'check' },
  { id = 'optMovesEnabled', key = 'movesEnabled', kind = 'check' },
  { id = 'optStaffPause', key = 'staffPause', kind = 'check' },
  { id = 'optPlayerPause', key = 'playerPause', kind = 'check' },
  { id = 'optLowHpStop', key = 'lowHpStop', kind = 'check' },
  { id = 'optAlarm', key = 'alarm', kind = 'check' },
  { id = 'optShinyAlert', key = 'shinyAlert', kind = 'check' },
  { id = 'optStuckSkip', key = 'stuckSkip', kind = 'check' },
  { id = 'optAutoResume', key = 'autoResume', kind = 'check' },
  { id = 'maxDistanceEdit', key = 'maxDistance', kind = 'number', min = 1, max = 10 },
  { id = 'targetTimeoutEdit', key = 'targetTimeout', kind = 'number', min = 5, max = 120 },
  { id = 'chaseDistanceEdit', key = 'chaseDistance', kind = 'number', min = 1, max = 7 },
  { id = 'lureCountEdit', key = 'lureCount', kind = 'number', min = 0, max = 10 },
  { id = 'lureRadiusEdit', key = 'lureRadius', kind = 'number', min = 1, max = 8 },
  { id = 'healPercentEdit', key = 'healPercent', kind = 'number', min = 1, max = 99 },
  { id = 'summonHealPercentEdit', key = 'summonHealPercent', kind = 'number', min = 1, max = 99 },
  { id = 'lowHpPercentEdit', key = 'lowHpPercent', kind = 'number', min = 1, max = 90 },
  { id = 'moveRangeEdit', key = 'moveRange', kind = 'number', min = 1, max = 10 },
  { id = 'recordStepEdit', key = 'recordStep', kind = 'number', min = 1, max = 10 },
  { id = 'ignoreEdit', key = 'ignoreText', kind = 'text' },
  { id = 'playerWhitelistEdit', key = 'playerWhitelistText', kind = 'text' }
}

local TABS = { 'dashboard', 'routes', 'targets', 'support', 'safety' }

local TYPE_PARAM = {
  walk = { hint = 'Tolerancia (0 a 5 SQM)', default = '1' },
  exact = { hint = 'Sem parametro (escada, buraco, teleporte)', default = '' },
  stand = { hint = 'Segundos parado (lure)', default = '5' },
  use = { hint = 'Sem parametro (usa o tile: alavanca, porta)', default = '' },
  say = { hint = 'Texto a falar', default = '' },
  label = { hint = 'Nome do marcador', default = 'inicio' },
  ['goto'] = { hint = 'Marcador de destino', default = 'inicio' }
}

-- ---------------------------------------------------------------------------
-- Estado
-- ---------------------------------------------------------------------------

local config = {}
local stats = HuntStats.new()
local ui = { window = nil, button = nil, cache = {}, waypointRows = {}, selectedType = 'walk',
  selectedWaypoint = nil, highlighted = nil, updating = false, deleteArmedAt = 0, grabber = nil, tab = 'dashboard' }
local state = {
  running = false, phase = 'IDLE', detail = '', waypointIndex = nil, direction = 1,
  walk = {}, standUntil = nil, usedIndex = nil, usedAt = 0, saidIndex = nil, floorMismatchSince = nil,
  attack = {}, attackedIds = {}, blacklist = {}, moveUsedAt = {}, lastMoveAt = 0,
  lastHealAt = 0, lastSummonHealAt = 0, hold = nil, safety = { at = 0 },
  creatures = { at = nil }, seenShiny = {}, lastPosition = nil
}
local events = { tick = nil, save = nil, refresh = nil, record = nil, resume = nil }
local recorder = nil
local targetIndexCache = nil
local ignoreSetCache = nil
local whitelistCache = nil

-- declaracoes antecipadas
local refreshStatus, refreshDashboard, refreshRouteHeader, refreshWaypointList, highlightCurrentWaypoint
local refreshTargetList, refreshMoveList, refreshSupportSlots, refreshTypeButtons, refreshFields
local advanceWaypoint

-- ---------------------------------------------------------------------------
-- Utilidades
-- ---------------------------------------------------------------------------

local function now() return g_clock.millis() end

local function logInfo(msg) pcall(function() print('[Hunt] ' .. tostring(msg)) end) end

local function logWarn(msg)
  pcall(function()
    if g_logger and g_logger.warning then g_logger.warning('[Hunt] ' .. tostring(msg))
    else print('[Hunt] AVISO: ' .. tostring(msg)) end
  end)
end

local function safeCall(object, method, ...)
  if not object then return nil end
  local fn = object[method]
  if type(fn) ~= 'function' then return nil end
  local ok, result = pcall(fn, object, ...)
  if ok then return result end
  return nil
end

local function trim(text) return (tostring(text or ''):gsub('^%s+', ''):gsub('%s+$', '')) end

local function copyPos(p) return p and { x = p.x, y = p.y, z = p.z } or nil end

local function samePos(a, b) return a and b and a.x == b.x and a.y == b.y and a.z == b.z end

local function localPlayer() return g_game.isOnline() and g_game.getLocalPlayer() or nil end

local function playerPosition()
  local player = localPlayer()
  return player and safeCall(player, 'getPosition') or nil
end

local function deepCopy(value)
  if type(value) ~= 'table' then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = deepCopy(v) end
  return out
end

local function clampNumber(value, minimum, maximum, default)
  local number = tonumber(value)
  if not number then return default end
  number = math.floor(number + 0.5)
  if number < minimum then return minimum end
  if number > maximum then return maximum end
  return number
end

local function wireButton(widget, onClick)
  if not widget then return end
  widget.onClick = function()
    local ok, err = pcall(onClick)
    if not ok then logWarn('erro em botao: ' .. tostring(err)) end
    return true
  end
end

local function widget(id)
  if not ui.window then return nil end
  local cached = ui.cache[id]
  if cached ~= nil then return cached or nil end
  local found = ui.window:recursiveGetChildById(id)
  ui.cache[id] = found or false
  return found or nil
end

local function setText(id, text, color)
  local w = widget(id)
  if not w then return end
  w:setText(text)
  if color then w:setColor(color) end
end

local function alarm(text)
  if not config.alarm then return end
  pcall(function() if g_window and g_window.flash then g_window.flash() end end)
  pcall(function()
    local tm = modules.game_textmessage
    if tm and tm.displayFailureMessage then tm.displayFailureMessage('[Hunt] ' .. text) end
  end)
end

-- ---------------------------------------------------------------------------
-- Configuracao
-- ---------------------------------------------------------------------------

local function normalizeMoves(raw)
  local list = {}
  for _, move in ipairs(type(raw) == 'table' and raw or {}) do
    if type(move) == 'table' then
      list[#list + 1] = {
        text = trim(move.text):sub(1, 40),
        cooldown = clampNumber(move.cooldown, 1, 600, 10),
        enabled = move.enabled ~= false
      }
    end
  end
  return list
end

local function normalizeConfig(raw)
  raw = type(raw) == 'table' and raw or {}
  local out = {}
  for key, default in pairs(DEFAULTS) do
    local value = raw[key]
    if type(default) == 'boolean' then
      if type(value) == 'boolean' then out[key] = value else out[key] = default end
    elseif type(default) == 'number' then
      out[key] = tonumber(value) or default
    elseif type(default) == 'string' then
      out[key] = type(value) == 'string' and value or default
    else
      out[key] = deepCopy(default)
    end
  end
  for _, field in ipairs(FIELDS) do
    if field.kind == 'number' then
      out[field.key] = clampNumber(out[field.key], field.min, field.max, DEFAULTS[field.key])
    end
  end
  out.routes = Route.normalizeList(raw.routes)
  out.targets = Targeting.normalizeList(raw.targets)
  out.moves = normalizeMoves(raw.moves)
  out.healItemId = math.max(0, math.floor(tonumber(raw.healItemId) or 0))
  out.summonHealItemId = math.max(0, math.floor(tonumber(raw.summonHealItemId) or 0))
  out.activeRoute = clampNumber(raw.activeRoute, 1, math.max(1, #out.routes), 1)
  return out
end

local function invalidateCaches()
  targetIndexCache, ignoreSetCache, whitelistCache = nil, nil, nil
end

local function saveNow()
  if events.save then removeEvent(events.save); events.save = nil end
  local ok, encoded = pcall(json.encode, config)
  if not ok then logWarn('falha ao salvar a configuracao: ' .. tostring(encoded)); return end
  g_settings.set(SETTINGS_KEY, encoded)
end

local function saveSoon()
  invalidateCaches()
  if events.save then removeEvent(events.save) end
  events.save = scheduleEvent(function() events.save = nil; saveNow() end, CFG.SAVE_DELAY_MS)
end

local function loadConfig()
  local raw = g_settings.getString(SETTINGS_KEY, '')
  local decoded = nil
  if raw ~= '' then
    local ok, value = pcall(json.decode, raw)
    if ok then decoded = value else logWarn('configuracao invalida; usando o padrao.') end
  end
  config = normalizeConfig(decoded)
  invalidateCaches()
end

local function activeRoute()
  return config.routes[config.activeRoute]
end

local function targetIndex()
  if not targetIndexCache then targetIndexCache = Targeting.buildIndex(config.targets) end
  return targetIndexCache
end

local function ignoreSet()
  if not ignoreSetCache then ignoreSetCache = Targeting.parseNameSet(config.ignoreText) end
  return ignoreSetCache
end

local function whitelistSet()
  if not whitelistCache then whitelistCache = Targeting.parseNameSet(config.playerWhitelistText) end
  return whitelistCache
end

-- ---------------------------------------------------------------------------
-- Leitura das criaturas (com cache curto)
-- ---------------------------------------------------------------------------

local SUMMON_OWN = CreatureTypeSummonOwn or 3
local SUMMON_OTHER = CreatureTypeSummonOther or 4

local function isShinyCreature(creature, name)
  if name and name:lower():match('^shiny%s+') then return true end
  return safeCall(creature, 'isShiny') == true
end

local function readCreatures(currentTime)
  local cache = state.creatures
  if cache.at and not cache.dirty and currentTime - cache.at < CFG.SPECTATOR_CACHE_MS then return cache end
  local result = { at = currentTime, monsters = {}, players = {}, byId = {}, summon = nil, all = {} }
  local position = playerPosition()
  if position and g_map and g_map.getSpectators then
    local ok, spectators = pcall(g_map.getSpectators, position, false)
    local player = localPlayer()
    local localId = safeCall(player, 'getId')
    if ok and type(spectators) == 'table' then
      for _, creature in ipairs(spectators) do
        local id = safeCall(creature, 'getId')
        if id and id ~= localId then
          result.all[#result.all + 1] = creature
          local cPos = safeCall(creature, 'getPosition')
          local name = tostring(safeCall(creature, 'getName') or '')
          local cType = safeCall(creature, 'getType')
          if safeCall(creature, 'isPlayer') == true then
            result.players[#result.players + 1] = { id = id, name = name, position = cPos, creature = creature }
          elseif cType == SUMMON_OWN then
            result.summon = { id = id, name = name, position = cPos, creature = creature,
              healthPercent = tonumber(safeCall(creature, 'getHealthPercent')) or 100 }
          elseif cType ~= SUMMON_OTHER and safeCall(creature, 'isNpc') ~= true and safeCall(creature, 'isMonster') == true and cPos then
            local info = {
              id = id, name = name, position = cPos, creature = creature,
              healthPercent = tonumber(safeCall(creature, 'getHealthPercent')) or 100,
              isShiny = isShinyCreature(creature, name),
              distance = Route.distance(position, cPos)
            }
            result.monsters[#result.monsters + 1] = info
            result.byId[id] = info
          end
        end
      end
    end
  end
  state.creatures = result
  return result
end

local function invalidateCreatures() state.creatures.dirty = true end

-- ---------------------------------------------------------------------------
-- Status / fases
-- ---------------------------------------------------------------------------

local function setPhase(phase, detail)
  detail = detail or ''
  if state.phase == phase and state.detail == detail then return end
  state.phase, state.detail = phase, detail
  refreshStatus()
end

local function setMessage(text, color)
  state.message, state.messageColor = text, color
  setText('statusMessage', text or '', color or '#9cb1c2')
end

-- ---------------------------------------------------------------------------
-- Movimento
-- ---------------------------------------------------------------------------

local function stopAutoWalk()
  local player = localPlayer()
  if player and safeCall(player, 'isAutoWalking') then safeCall(player, 'stopAutoWalk') end
end

local function isMoving(player)
  return safeCall(player, 'isWalking') == true or safeCall(player, 'isAutoWalking') == true
end

local function directionTowards(from, to)
  local dx, dy = to.x - from.x, to.y - from.y
  local sx = dx > 0 and 1 or (dx < 0 and -1 or 0)
  local sy = dy > 0 and 1 or (dy < 0 and -1 or 0)
  if sx == 0 and sy < 0 then return DIRECTIONS.north end
  if sx == 0 and sy > 0 then return DIRECTIONS.south end
  if sx > 0 and sy == 0 then return DIRECTIONS.east end
  if sx < 0 and sy == 0 then return DIRECTIONS.west end
  if sx > 0 and sy < 0 then return DIRECTIONS.northEast end
  if sx > 0 and sy > 0 then return DIRECTIONS.southEast end
  if sx < 0 and sy > 0 then return DIRECTIONS.southWest end
  if sx < 0 and sy < 0 then return DIRECTIONS.northWest end
  return nil
end

-- Envia o andar: autoWalk do cliente (pathfinding nativo), depois findPath e,
-- por ultimo, um passo na direcao do destino.
local function sendWalk(player, from, dest)
  local result = safeCall(player, 'autoWalk', dest)
  if result == true then return 'auto' end
  if g_map and g_map.findPath then
    local ok, dirs = pcall(g_map.findPath, from, dest, 20000, 0)
    if ok and type(dirs) == 'table' and #dirs > 0 then
      if g_game.autoWalk and pcall(g_game.autoWalk, dirs, from) then return 'path' end
      if pcall(g_game.walk, dirs[1], false) then return 'step' end
    end
  end
  local direction = directionTowards(from, dest)
  if direction and pcall(g_game.walk, direction, false) then return 'greedy' end
  return nil
end

local function unstuckStep(from)
  local options = { DIRECTIONS.north, DIRECTIONS.east, DIRECTIONS.south, DIRECTIONS.west }
  pcall(g_game.walk, options[math.random(1, #options)], false)
end

local function resetWalk()
  state.walk = {}
end

-- Anda ate `dest` com tolerancia `precision`. loose: destino que se move
-- (alvo perseguido) e tratado como o mesmo se mudou no maximo 1 SQM.
-- Devolve 'arrived', 'walking' ou 'stuck'.
local function walkTo(dest, precision, currentTime, loose)
  local player = localPlayer()
  local from = player and safeCall(player, 'getPosition')
  if not from or not dest then return 'walking' end
  local distance = Route.distance(from, dest)
  if distance and distance <= precision then return 'arrived' end

  local w = state.walk
  local sameDest = w.dest and (samePos(w.dest, dest) or (loose and Route.distance(w.dest, dest) ~= nil and Route.distance(w.dest, dest) <= 1))
  if not sameDest then
    state.walk = { dest = copyPos(dest), sentAt = 0, lastPos = copyPos(from), lastMoveAt = currentTime, attempts = 0 }
    w = state.walk
  end
  if not samePos(w.lastPos, from) then
    w.lastPos = copyPos(from)
    w.lastMoveAt = currentTime
  end

  if isMoving(player) and currentTime - w.sentAt < CFG.WALK_RESEND_MS * 3 then return 'walking' end
  if w.sentAt > 0 and currentTime - w.sentAt < CFG.WALK_RESEND_MS and currentTime - w.lastMoveAt < CFG.WALK_RESEND_MS then
    return 'walking'
  end

  if currentTime - w.lastMoveAt > CFG.STUCK_MS then
    w.attempts = w.attempts + 1
    w.lastMoveAt = currentTime
    if w.attempts >= CFG.STUCK_RETRIES then return 'stuck' end
    unstuckStep(from)
    w.sentAt = currentTime
    return 'walking'
  end

  local how = sendWalk(player, from, dest)
  w.sentAt = currentTime
  w.how = how
  return 'walking'
end

local function useTile(position)
  local tile = g_map.getTile(position)
  if not tile then return false end
  local thing = safeCall(tile, 'getTopUseThing')
  if not thing then return false end
  return pcall(g_game.use, thing)
end

-- ---------------------------------------------------------------------------
-- Protecoes
-- ---------------------------------------------------------------------------

local function findStaffAmong(creatures)
  if StaffGuard then return StaffGuard.findStaff(creatures.all) end
  for _, creature in ipairs(creatures.all) do
    local name = tostring(safeCall(creature, 'getName') or ''):lower()
    if name:match('^%[gm%]') or name:match('^%[cm%]') or name:match('^%[tutor%]') or name:match('^gm%s') then
      return name
    end
  end
  return nil
end

-- Devolve { phase, text } quando o Hunt deve esperar, ou nil.
local function checkSafety(currentTime, creatures)
  local cache = state.safety
  if cache.at and currentTime - cache.at < CFG.SAFETY_CACHE_MS then return cache.result end
  cache.at = currentTime
  cache.result = nil
  if config.staffPause then
    local staff = findStaffAmong(creatures)
    if staff then
      cache.result = { phase = 'PAUSED_STAFF', text = string.format('Staff na tela (%s).', tostring(staff)) }
      return cache.result
    end
  end
  if config.playerPause then
    local whitelist = whitelistSet()
    for _, player in ipairs(creatures.players) do
      if not whitelist[trim(player.name):lower()] then
        cache.result = { phase = 'PAUSED_PLAYER', text = string.format('Jogador na tela: %s.', player.name) }
        return cache.result
      end
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Suporte: cura do jogador, do pokemon e moves
-- ---------------------------------------------------------------------------

local function supportPlayer(player, currentTime)
  local health = tonumber(safeCall(player, 'getHealthPercent'))
  if not health then return nil end
  if config.healItemId > 0 and health <= config.healPercent and currentTime - state.lastHealAt >= CFG.HEAL_COOLDOWN_MS then
    state.lastHealAt = currentTime
    pcall(g_game.useInventoryItem, config.healItemId)
  end
  return health
end

local function supportSummon(creatures, currentTime)
  local summon = creatures.summon
  if not summon or config.summonHealItemId <= 0 then return end
  if summon.healthPercent <= config.summonHealPercent and currentTime - state.lastSummonHealAt >= CFG.SUMMON_HEAL_COOLDOWN_MS then
    state.lastSummonHealAt = currentTime
    pcall(g_game.useInventoryItemWith, config.summonHealItemId, summon.creature)
  end
end

local function castMoves(target, currentTime)
  if not config.movesEnabled or not target or (target.distance or 99) > config.moveRange then return end
  if currentTime - state.lastMoveAt < CFG.MOVE_GAP_MS then return end
  for index, move in ipairs(config.moves) do
    if move.enabled and move.text ~= '' and currentTime - (state.moveUsedAt[index] or -math.huge) >= move.cooldown * 1000 then
      state.moveUsedAt[index] = currentTime
      state.lastMoveAt = currentTime
      pcall(g_game.talk, move.text)
      return
    end
  end
end

-- ---------------------------------------------------------------------------
-- Alvos
-- ---------------------------------------------------------------------------

local function activeBlacklist(currentTime)
  local out = {}
  for id, untilAt in pairs(state.blacklist) do
    if untilAt > currentTime then out[id] = true else state.blacklist[id] = nil end
  end
  return out
end

local function isStolen(creatures)
  return function(target)
    if (target.healthPercent or 100) >= 100 or state.attackedIds[target.id] then return false end
    for _, player in ipairs(creatures.players) do
      local distance = Route.distance(player.position, target.position)
      if distance and distance <= CFG.ANTI_KS_RADIUS then return true end
    end
    return false
  end
end

local function targetOptions(creatures, currentId, currentTime)
  return {
    maxDistance = config.maxDistance, ignore = ignoreSet(), attackAll = config.attackAll,
    preferShiny = config.preferShiny, currentId = currentId, blacklist = activeBlacklist(currentTime),
    isStolen = config.antiKs and isStolen(creatures) or nil
  }
end

local function attack(info, currentTime)
  state.attack = { id = info.id, name = info.name, sentAt = currentTime, lastHealth = info.healthPercent, lastHealthAt = currentTime }
  state.attackedIds[info.id] = currentTime
  pcall(g_game.attack, info.creature)
  stopAutoWalk()
end

-- Devolve o alvo em ataque (info) ou nil.
local function updateTargeting(creatures, currentTime)
  local current = g_game.getAttackingCreature and g_game.getAttackingCreature() or nil
  local currentId = current and safeCall(current, 'getId') or nil
  local currentInfo = currentId and creatures.byId[currentId] or nil

  if currentInfo then
    local a = state.attack
    if a.id ~= currentId then
      state.attack = { id = currentId, name = currentInfo.name, sentAt = currentTime, lastHealth = currentInfo.healthPercent, lastHealthAt = currentTime }
      a = state.attack
    elseif currentInfo.healthPercent < (a.lastHealth or 100) then
      a.lastHealth, a.lastHealthAt = currentInfo.healthPercent, currentTime
    end
    if currentTime - (a.lastHealthAt or currentTime) > config.targetTimeout * 1000 then
      state.blacklist[currentId] = currentTime + CFG.BLACKLIST_MS
      pcall(g_game.cancelAttack)
      setMessage(string.format('%s nao perdeu HP em %d s; ignorado por 30 s.', currentInfo.name, config.targetTimeout), '#ffcc66')
      current, currentId, currentInfo = nil, nil, nil
    end
  elseif current then
    current, currentId = nil, nil -- alvo fora da tela ou morto
  end

  local options = targetOptions(creatures, currentId, currentTime)
  local index = targetIndex()
  if not currentInfo and config.lureCount > 0 and config.walk and not state.standUntil and activeRoute() then
    if Targeting.countTargets(creatures.monsters, index, options, config.lureRadius) < config.lureCount then return nil end
  end

  local best = Targeting.choose(creatures.monsters, index, options)
  if not best then return currentInfo end
  if best.id ~= currentId and currentTime - (state.attack.sentAt or 0) >= CFG.ATTACK_SWITCH_MS then
    attack(best, currentTime)
    return best
  end
  return currentInfo or best
end

-- ---------------------------------------------------------------------------
-- Rota
-- ---------------------------------------------------------------------------

local function waypointText(index)
  local route = activeRoute()
  local waypoint = route and route.waypoints[index]
  if not waypoint then return '-' end
  return string.format('#%d %s %s', index, Route.TYPES[waypoint.type].label, Route.describe(waypoint))
end

local function setWaypointIndex(index)
  state.waypointIndex = index
  state.standUntil, state.usedIndex, state.saidIndex, state.floorMismatchSince = nil, nil, nil, nil
  resetWalk()
  highlightCurrentWaypoint()
end

local stopHunt

advanceWaypoint = function()
  local route = activeRoute()
  if not route then return end
  local nextIndex, direction, lap = Route.nextIndex(route, state.waypointIndex, route.mode, state.direction)
  if lap then stats.laps = stats.laps + 1 end
  if not nextIndex then
    setWaypointIndex(nil)
    stopHunt('Rota concluida (modo uma vez).')
    return
  end
  state.direction = direction
  setWaypointIndex(nextIndex)
end

local function walkRoute(position, currentTime)
  local route = activeRoute()
  if not route or #route.waypoints == 0 then
    setPhase('NO_ROUTE', 'Crie uma rota na aba Rotas ou desative "Seguir rota".')
    return CFG.TICK_IDLE_MS
  end
  if not state.waypointIndex or not route.waypoints[state.waypointIndex] then
    local start = config.startNearest and Route.nearestIndex(route, position) or 1
    setWaypointIndex(start or 1)
  end

  for _ = 1, CFG.MAX_GOTO_PER_TICK do
    local waypoint = route.waypoints[state.waypointIndex]
    if not waypoint then return CFG.TICK_MS end
    if waypoint.type == 'label' then
      advanceWaypoint()
      if not state.running then return nil end
    elseif waypoint.type == 'goto' then
      local target = Route.findLabel(route, waypoint.label)
      if not target then
        setMessage(string.format('Marcador "%s" nao existe; ponto ignorado.', waypoint.label), '#ffcc66')
        advanceWaypoint()
      else
        setWaypointIndex(target)
      end
      if not state.running then return nil end
    elseif waypoint.type == 'say' then
      if state.saidIndex ~= state.waypointIndex then
        state.saidIndex = state.waypointIndex
        pcall(g_game.talk, waypoint.text)
        return CFG.SAY_PAUSE_MS
      end
      advanceWaypoint()
      if not state.running then return nil end
    else
      break
    end
  end

  local index = state.waypointIndex
  local waypoint = route.waypoints[index]
  if not waypoint or not Route.hasPosition(waypoint) then return CFG.TICK_MS end
  local dest = Route.position(waypoint)

  if dest.z ~= position.z then
    state.floorMismatchSince = state.floorMismatchSince or currentTime
    if currentTime - state.floorMismatchSince >= CFG.FLOOR_MISMATCH_MS then
      local nearest = Route.nearestIndex(route, position, index)
      if not nearest then
        stopHunt(string.format('Nenhum ponto da rota no andar %d.', position.z))
        return nil
      end
      setMessage(string.format('Andar diferente; retomando do ponto #%d.', nearest), '#ffcc66')
      setWaypointIndex(nearest)
    end
    setPhase('WALKING', 'Trocando de andar...')
    return CFG.TICK_MS
  end
  state.floorMismatchSince = nil

  local precision = 0
  if waypoint.type == 'walk' then precision = waypoint.precision or Route.DEFAULT_PRECISION
  elseif waypoint.type == 'use' then precision = 1 end

  local result = walkTo(dest, precision, currentTime)
  if result == 'stuck' then
    if config.stuckSkip then
      stats.skippedWaypoints = stats.skippedWaypoints + 1
      setMessage(string.format('Ponto #%d inalcancavel; pulando.', index), '#ffcc66')
      advanceWaypoint()
    else
      resetWalk()
    end
    return CFG.TICK_MS
  end
  if result == 'walking' then
    setPhase('WALKING', string.format('%s  (%d SQM)', waypointText(index), Route.distance(position, dest) or 0))
    return CFG.TICK_MS
  end

  -- chegou
  if waypoint.type == 'stand' then
    state.standUntil = state.standUntil or (currentTime + waypoint.seconds * 1000)
    if currentTime < state.standUntil then
      setPhase('STANDING', string.format('%s  (%d s restantes)', waypointText(index), math.ceil((state.standUntil - currentTime) / 1000)))
      return 200
    end
  elseif waypoint.type == 'use' then
    if state.usedIndex ~= index then
      state.usedIndex, state.usedAt = index, currentTime
      useTile(dest)
      return CFG.USE_WAIT_MS
    end
  end
  advanceWaypoint()
  return 20
end

-- ---------------------------------------------------------------------------
-- Ciclo principal
-- ---------------------------------------------------------------------------

local function autoCatch()
  local module = modules.game_autocatch
  if module and type(module.isEnabled) == 'function' and module.isEnabled() then return module end
  return nil
end

-- Corpo pendente mais proximo do Auto Catch (para nao deixa-lo sair da tela).
local function nearestPending(module, position)
  if type(module.getPendingPositions) ~= 'function' then return nil end
  local ok, list = pcall(module.getPendingPositions)
  if not ok or type(list) ~= 'table' then return nil end
  local best, bestDistance = nil, nil
  for _, pending in ipairs(list) do
    local distance = Route.distance(position, pending)
    if distance and (not bestDistance or distance < bestDistance) then best, bestDistance = pending, distance end
  end
  return best, bestDistance
end

local function step()
  if not g_game.isOnline() then setPhase('OFFLINE', ''); return 1000 end
  local player = localPlayer()
  local position = player and safeCall(player, 'getPosition')
  if not position then return 500 end
  local currentTime = now()

  if state.lastPosition and not samePos(state.lastPosition, position) then
    local moved = Route.distance(state.lastPosition, position)
    if moved and moved <= 2 then stats.steps = stats.steps + moved end
  end
  state.lastPosition = copyPos(position)

  local creatures = readCreatures(currentTime)

  local hold = checkSafety(currentTime, creatures)
  if hold then
    if not state.hold or state.hold.phase ~= hold.phase then
      state.hold = hold
      stopAutoWalk()
      pcall(g_game.cancelAttack)
      alarm(hold.text)
      logWarn(hold.text .. ' Hunt em espera.')
    end
    setPhase(hold.phase, hold.text .. ' Hunt em espera.')
    return CFG.TICK_IDLE_MS
  elseif state.hold then
    state.hold = nil
    setMessage('Tela livre; Hunt retomado.', '#62d985')
  end

  local health = supportPlayer(player, currentTime)
  if config.lowHpStop and health and health <= config.lowHpPercent then
    alarm(string.format('HP baixo (%d%%).', health))
    stopHunt(string.format('HP baixo (%d%%): Hunt parado por seguranca.', health))
    return nil
  end
  supportSummon(creatures, currentTime)

  if config.attack then
    local target = updateTargeting(creatures, currentTime)
    if target then
      castMoves(target, currentTime)
      if config.chase and (target.distance or 0) > config.chaseDistance then
        walkTo(target.position, config.chaseDistance, currentTime, true)
        setPhase('CHASING', string.format('%s a %d SQM', target.name, target.distance or 0))
      else
        setPhase('FIGHTING', string.format('%s%s  HP %d%%', target.isShiny and '[SHINY] ' or '', target.name, target.healthPercent or 0))
      end
      return CFG.TICK_FIGHT_MS
    end
  end

  if config.waitCatch then
    local module = autoCatch()
    if module and type(module.isBusy) == 'function' and module.isBusy() then
      local pending, distance = nearestPending(module, position)
      if pending and distance and distance > CFG.LEASH_DISTANCE then
        walkTo(pending, CFG.LEASH_DISTANCE - 2, currentTime, true)
      end
      setPhase('CATCHING', pending and string.format('Corpo pendente a %d SQM.', distance or 0) or 'Capturas em andamento.')
      return CFG.TICK_MS
    end
  end

  if config.walk then return walkRoute(position, currentTime) end
  setPhase('WAITING', '"Seguir rota" desativado: so ataca o que aparecer.')
  return 200
end

local function tick()
  events.tick = nil
  if not state.running then return end
  local ok, delay = pcall(step)
  if not ok then
    logWarn('erro no ciclo: ' .. tostring(delay))
    delay = 500
  end
  if state.running then events.tick = scheduleEvent(tick, tonumber(delay) or CFG.TICK_MS) end
end

local function catchStatsConfirmed()
  local module = modules.game_autocatch
  if not module or type(module.getStats) ~= 'function' then return nil end
  local ok, value = pcall(module.getStats)
  if ok and type(value) == 'table' then return tonumber(value.confirmed) end
  return nil
end

function start()
  if state.running then return true end
  if not g_game.isOnline() then setMessage('Entre no jogo antes de iniciar o Hunt.', '#ffcc66'); return false end
  if not config.walk and not config.attack then
    setMessage('Ative "Seguir rota" ou "Atacar" antes de iniciar.', '#ffcc66')
    return false
  end
  state.running = true
  state.hold, state.safety, state.blacklist, state.attackedIds = nil, { at = 0 }, {}, {}
  state.attack, state.moveUsedAt, state.lastMoveAt = {}, {}, 0
  state.waypointIndex, state.direction = nil, 1
  state.lastPosition = playerPosition()
  invalidateCreatures()
  resetWalk()
  stats:start(now())
  if stats.catchBase == nil then stats.catchBase = catchStatsConfirmed() or 0 end
  config.wasRunning = true
  saveSoon()
  setMessage('Hunt iniciado.', '#62d985')
  setPhase('WAITING', 'Iniciando...')
  if events.tick then removeEvent(events.tick) end
  events.tick = scheduleEvent(tick, 0)
  return true
end

stopHunt = function(reason, keepWasRunning)
  if events.tick then removeEvent(events.tick); events.tick = nil end
  local wasRunning = state.running
  state.running = false
  state.hold = nil
  stats:stop(now())
  if wasRunning then
    stopAutoWalk()
    if not keepWasRunning then config.wasRunning = false; saveSoon() end
  end
  resetWalk()
  setPhase('IDLE', '')
  if reason then setMessage(reason, '#ffcc66') end
  highlightCurrentWaypoint()
end

function stop(reason)
  stopHunt(reason or 'Hunt parado.')
end

function toggleRunning()
  if state.running then stop() else start() end
end

function isRunning() return state.running end

-- Lido pelo Auto Catch: espera junto quando o Hunt esta em espera.
function getBotState()
  if not state.running then return 'STOPPED' end
  return state.phase
end

function getPhase() return state.phase, state.detail end
function getStats() return stats end
function getConfig() return config end
function getWaypointIndex() return state.waypointIndex end

function resetStats()
  local running = state.running
  stats:reset(now())
  stats.catchBase = catchStatsConfirmed() or 0
  if running then stats:start(now()) end
  refreshDashboard()
end

-- ---------------------------------------------------------------------------
-- Painel: status e estatisticas
-- ---------------------------------------------------------------------------

refreshStatus = function()
  local phase = PHASES[state.phase] or PHASES.IDLE
  local w = widget('statusIndicator')
  if w then w:setImageColor(phase.indicator) end
  setText('statusTitle', phase.title, phase.color)
  local detail = state.detail ~= '' and state.detail or (state.running and '' or 'Configure a rota e os alvos e clique em Iniciar.')
  setText('statusDetail', detail)
  local toggle = widget('toggleButton')
  if toggle then
    toggle:setText(state.running and 'PARAR HUNT' or 'INICIAR HUNT')
    toggle:setOn(state.running)
  end
  if ui.button then ui.button:setOn(state.running or (ui.window and ui.window:isVisible()) or false) end
end

refreshDashboard = function()
  if not ui.window then return end
  local currentTime = now()
  local catches = 0
  local confirmed = catchStatsConfirmed()
  if confirmed and stats.catchBase then catches = math.max(0, confirmed - stats.catchBase) end
  setText('stat_time', HuntStats.formatDuration(stats:elapsedMs(currentTime)))
  setText('stat_kills', HuntStats.formatNumber(stats.kills))
  setText('stat_killsHour', HuntStats.formatNumber(stats:perHour(stats.kills, currentTime)))
  setText('stat_xpHour', HuntStats.formatNumber(stats:perHour(stats.experience, currentTime)))
  setText('stat_catches', HuntStats.formatNumber(catches))
  setText('stat_laps', HuntStats.formatNumber(stats.laps))
  setText('stat_shinies', HuntStats.formatNumber(stats.shiniesSeen))
  setText('stat_steps', HuntStats.formatNumber(stats.steps))
  local top = stats:topKills(4)
  local parts = {}
  for _, entry in ipairs(top) do parts[#parts + 1] = string.format('%s x%d', entry.name, entry.count) end
  setText('topKills', #parts > 0 and ('Mais abatidos: ' .. table.concat(parts, '  |  ')) or 'Mais abatidos: nenhum ainda')
  local route = activeRoute()
  setText('routeInfo', route and string.format('%s  -  %s', route.name, Route.summary(route)) or 'Nenhuma rota criada')
  setText('waypointInfo', state.waypointIndex and ('Ponto atual: ' .. waypointText(state.waypointIndex)) or 'Ponto atual: -')
  setText('skippedInfo', string.format('Pontos pulados: %d  |  XP total: %s', stats.skippedWaypoints, HuntStats.formatNumber(stats.experience)))
end

-- ---------------------------------------------------------------------------
-- Painel: abas e campos simples
-- ---------------------------------------------------------------------------

function selectTab(name)
  ui.tab = name
  for _, tab in ipairs(TABS) do
    local content = widget('tab_' .. tab)
    if content then content:setVisible(tab == name) end
    local nav = widget('nav_' .. tab)
    if nav then nav:setOn(tab == name) end
  end
  if name == 'dashboard' then refreshDashboard() end
end

local function onFieldChanged(key)
  if key == 'walk' or key == 'attack' then
    if state.running and not config.walk and not config.attack then stop('Nada a fazer: "Seguir rota" e "Atacar" desativados.') end
  end
  if key == 'startNearest' and state.running then state.waypointIndex = nil end
  if key == 'recordStep' and recorder then recorder.step = config.recordStep end
  state.safety.at = 0
end

refreshFields = function()
  ui.updating = true
  for _, field in ipairs(FIELDS) do
    local w = widget(field.id)
    if w then
      if field.kind == 'check' then
        w:setChecked(config[field.key] == true)
      else
        w:setText(tostring(config[field.key] or ''))
        w:setColor('#ffffff')
      end
    end
  end
  ui.updating = false
end

local function bindFields()
  for _, field in ipairs(FIELDS) do
    local w = widget(field.id)
    if w then
      if field.kind == 'check' then
        w.onCheckChange = function(_, checked)
          if ui.updating then return end
          config[field.key] = checked == true
          saveSoon()
          onFieldChanged(field.key)
        end
      else
        w.onTextChange = function(self, text)
          if ui.updating then return end
          if field.kind == 'number' then
            local number = tonumber(trim(text))
            if not number or number < field.min or number > field.max then
              self:setColor('#ff7676')
              return
            end
            self:setColor('#ffffff')
            config[field.key] = math.floor(number + 0.5)
          else
            config[field.key] = trim(text):sub(1, 400)
          end
          saveSoon()
          onFieldChanged(field.key)
        end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Painel: rotas e pontos
-- ---------------------------------------------------------------------------

local function ensureRoute()
  if activeRoute() then return activeRoute() end
  local route = Route.new(Route.uniqueName(config.routes, 'Rota 1'))
  config.routes[#config.routes + 1] = route
  config.activeRoute = #config.routes
  saveSoon()
  refreshRouteHeader()
  return route
end

refreshRouteHeader = function()
  local route = activeRoute()
  setText('routeName', route and string.format('%s  (%d/%d)', route.name, config.activeRoute, #config.routes) or 'Nenhuma rota')
  setText('routeSummary', route and Route.summary(route) or 'Clique em "Nova" para criar a primeira rota.')
  setText('routeMode', route and ('Modo: ' .. Route.MODES[route.mode]) or 'Modo: -')
  local edit = widget('routeNameEdit')
  if edit and route then
    ui.updating = true
    edit:setText(route.name)
    ui.updating = false
  end
end

local function updateWaypointRow(row, index, waypoint)
  local spec = Route.TYPES[waypoint.type]
  local function child(id) return row:recursiveGetChildById(id) end
  local indexLabel, typeLabel, desc = child('wpIndex'), child('wpType'), child('wpDesc')
  if indexLabel then indexLabel:setText(tostring(index)) end
  if typeLabel then typeLabel:setText(spec.short); typeLabel:setImageColor(spec.color) end
  if desc then desc:setText(Route.describe(waypoint)) end
  local isCurrent = state.waypointIndex == index
  local isSelected = ui.selectedWaypoint == index
  row:setImageColor(isCurrent and '#1f4a2f' or (isSelected and '#23405a' or '#15222e'))
end

local function selectWaypoint(index)
  local previous = ui.selectedWaypoint
  ui.selectedWaypoint = (previous == index) and nil or index
  local route = activeRoute()
  for _, rowIndex in ipairs({ previous, index }) do
    local row = rowIndex and ui.waypointRows[rowIndex]
    if row and route and route.waypoints[rowIndex] then updateWaypointRow(row, rowIndex, route.waypoints[rowIndex]) end
  end
  setText('wpSelectedHint', ui.selectedWaypoint and string.format('Novos pontos entram depois do #%d.', ui.selectedWaypoint) or 'Novos pontos entram no fim da rota.')
end

local function wireWaypointRow(row, index)
  local function child(id) return row:recursiveGetChildById(id) end
  wireButton(child('wpUp'), function()
    local route = activeRoute()
    local target = route and Route.moveWaypoint(route, index, -1)
    if target then
      if state.waypointIndex == index then state.waypointIndex = target elseif state.waypointIndex == target then state.waypointIndex = index end
      ui.selectedWaypoint = target
      saveSoon(); refreshWaypointList()
    end
  end)
  wireButton(child('wpDown'), function()
    local route = activeRoute()
    local target = route and Route.moveWaypoint(route, index, 1)
    if target then
      if state.waypointIndex == index then state.waypointIndex = target elseif state.waypointIndex == target then state.waypointIndex = index end
      ui.selectedWaypoint = target
      saveSoon(); refreshWaypointList()
    end
  end)
  wireButton(child('wpGo'), function()
    setWaypointIndex(index)
    setMessage(string.format('O Hunt segue a partir do ponto #%d.', index), '#62d985')
  end)
  wireButton(child('wpDelete'), function()
    local route = activeRoute()
    if route and Route.removeWaypoint(route, index) then
      if state.waypointIndex then
        if state.waypointIndex == index then setWaypointIndex(route.waypoints[index] and index or nil)
        elseif state.waypointIndex > index then state.waypointIndex = state.waypointIndex - 1 end
      end
      ui.selectedWaypoint = nil
      saveSoon(); refreshWaypointList()
    end
  end)
  row.onMouseRelease = function(_, _, mouseButton)
    if mouseButton == MouseLeftButton then selectWaypoint(index); return true end
  end
end

local function appendWaypointRow(index, waypoint)
  local list = widget('waypointList')
  if not list then return end
  local row = g_ui.createWidget('HuntWaypointRow', list)
  ui.waypointRows[index] = row
  wireWaypointRow(row, index)
  updateWaypointRow(row, index, waypoint)
end

refreshWaypointList = function()
  local list = widget('waypointList')
  local route = activeRoute()
  if list then
    list:destroyChildren()
    ui.waypointRows = {}
    if route then
      for index, waypoint in ipairs(route.waypoints) do appendWaypointRow(index, waypoint) end
    end
  end
  local empty = widget('waypointEmpty')
  if empty then empty:setVisible(not route or #route.waypoints == 0) end
  ui.highlighted = state.waypointIndex
  refreshRouteHeader()
end

highlightCurrentWaypoint = function()
  local route = activeRoute()
  if not route then return end
  for _, index in ipairs({ ui.highlighted, state.waypointIndex }) do
    local row = index and ui.waypointRows[index]
    if row and route.waypoints[index] then updateWaypointRow(row, index, route.waypoints[index]) end
  end
  ui.highlighted = state.waypointIndex
end

refreshTypeButtons = function()
  for _, kind in ipairs(Route.TYPE_ORDER) do
    local button = widget('type_' .. kind)
    if button then button:setOn(kind == ui.selectedType) end
  end
  local param = TYPE_PARAM[ui.selectedType]
  setText('wpParamHint', param.hint)
  local edit = widget('wpParamEdit')
  if edit then edit:setText(param.default) end
end

function selectWaypointType(kind)
  if not Route.TYPES[kind] then return end
  ui.selectedType = kind
  refreshTypeButtons()
end

-- Monta o ponto do tipo escolhido no painel (posicao opcional).
local function buildWaypoint(position)
  local kind = ui.selectedType
  local edit = widget('wpParamEdit')
  local param = trim(edit and edit:getText() or TYPE_PARAM[kind].default)
  local raw = { type = kind }
  if Route.TYPES[kind].needsPosition then
    if not position then return nil, 'posicao desconhecida' end
    raw.x, raw.y, raw.z = position.x, position.y, position.z
  end
  if kind == 'walk' then raw.precision = tonumber(param) or Route.DEFAULT_PRECISION
  elseif kind == 'stand' then raw.seconds = tonumber(param) or 5
  elseif kind == 'say' then raw.text = param
  elseif kind == 'label' or kind == 'goto' then raw.label = param end
  local waypoint = Route.normalizeWaypoint(raw)
  if not waypoint then
    return nil, (kind == 'say' and 'digite o texto') or ((kind == 'label' or kind == 'goto') and 'digite o nome do marcador') or 'parametro invalido'
  end
  return waypoint
end

local function insertWaypoint(waypoint)
  local route = ensureRoute()
  local after = ui.selectedWaypoint
  local index = Route.addWaypoint(route, waypoint, after)
  if not index then setMessage('Limite de pontos da rota atingido.', '#ff7676'); return nil end
  if state.waypointIndex and state.waypointIndex >= index and after then state.waypointIndex = state.waypointIndex + 1 end
  if after then ui.selectedWaypoint = index end
  saveSoon()
  if not after and index == #route.waypoints and widget('waypointList') then
    appendWaypointRow(index, route.waypoints[index])
    local empty = widget('waypointEmpty')
    if empty then empty:setVisible(false) end
    refreshRouteHeader()
  else
    refreshWaypointList()
  end
  return index
end

function addWaypointHere()
  local position = playerPosition()
  if Route.TYPES[ui.selectedType].needsPosition and not position then
    setMessage('Entre no jogo para marcar a posicao.', '#ffcc66')
    return nil
  end
  local waypoint, err = buildWaypoint(position)
  if not waypoint then setMessage('Ponto nao adicionado: ' .. err .. '.', '#ff7676'); return nil end
  local index = insertWaypoint(waypoint)
  if index then setMessage(string.format('Ponto #%d adicionado: %s %s.', index, Route.TYPES[waypoint.type].label, Route.describe(waypoint)), '#62d985') end
  return index
end

local function finishGrabber()
  local grabber = ui.grabber
  if not grabber then return end
  ui.grabber = nil
  pcall(function() g_mouse.popCursor('target') end)
  pcall(function() grabber:ungrabMouse() end)
  pcall(function() grabber:destroy() end)
end

local function startGrabber(onRelease)
  if ui.grabber or g_ui.isMouseGrabbed() then
    setMessage('Finalize a acao atual do mouse primeiro.', '#ffcc66')
    return false
  end
  if ui.window then ui.window:hide() end
  local grabber = g_ui.createWidget('UIWidget')
  grabber:setVisible(false)
  grabber:setFocusable(false)
  grabber.onMouseRelease = function(_, mousePosition, mouseButton)
    finishGrabber()
    if ui.window then ui.window:show(); ui.window:raise() end
    local ok, err = pcall(onRelease, mousePosition, mouseButton)
    if not ok then logWarn('erro na selecao: ' .. tostring(err)) end
    return true
  end
  ui.grabber = grabber
  grabber:grabMouse()
  pcall(function() g_mouse.pushCursor('target') end)
  return true
end

local function clickedWidgetAt(mousePosition)
  local root = modules.game_interface and modules.game_interface.getRootPanel()
  return root and root:recursiveGetChildByPos(mousePosition, false) or nil
end

function addWaypointFromMap()
  return startGrabber(function(mousePosition, mouseButton)
    if mouseButton ~= MouseLeftButton then setMessage('Selecao cancelada.', '#9cb1c2'); return end
    local clicked = clickedWidgetAt(mousePosition)
    local tile = clicked and clicked:getClassName() == 'UIGameMap' and clicked:getTile(mousePosition) or nil
    local position = tile and safeCall(tile, 'getPosition')
    if not position then setMessage('Clique em um tile do mapa.', '#ffcc66'); return end
    local waypoint, err = buildWaypoint(position)
    if not waypoint then setMessage('Ponto nao adicionado: ' .. err .. '.', '#ff7676'); return end
    local index = insertWaypoint(waypoint)
    if index then setMessage(string.format('Ponto #%d adicionado pelo mapa.', index), '#62d985') end
  end)
end

local function recordTick()
  if not recorder then return end
  local position = playerPosition()
  if not position then return end
  local route = activeRoute()
  if not route then return end
  for _, raw in ipairs(recorder:observe(position)) do
    local index = Route.addWaypoint(route, raw)
    if index and widget('waypointList') then
      appendWaypointRow(index, route.waypoints[index])
    end
  end
  local empty = widget('waypointEmpty')
  if empty then empty:setVisible(#route.waypoints == 0) end
  saveSoon()
  refreshRouteHeader()
end

local function refreshRecordButton()
  local button = widget('wpRecord')
  if button then
    button:setText(recorder and 'Parar gravacao' or 'Gravar andando')
    button:setOn(recorder ~= nil)
  end
end

function setRecording(value)
  if value and not recorder then
    if not g_game.isOnline() then setMessage('Entre no jogo para gravar a rota.', '#ffcc66'); return false end
    ensureRoute()
    ui.selectedWaypoint = nil
    recorder = Route.Recorder.new(config.recordStep)
    events.record = cycleEvent(recordTick, CFG.RECORD_MS)
    recordTick()
    setMessage(string.format('Gravando: um ponto a cada %d SQM, escadas viram ponto exato.', config.recordStep), '#62d985')
  elseif not value and recorder then
    recorder = nil
    if events.record then removeEvent(events.record); events.record = nil end
    setMessage('Gravacao encerrada.', '#9cb1c2')
  end
  refreshRecordButton()
  return true
end

function isRecording() return recorder ~= nil end

local function selectRoute(index)
  if #config.routes == 0 then return end
  if index < 1 then index = #config.routes elseif index > #config.routes then index = 1 end
  if index == config.activeRoute then return end
  if recorder then setRecording(false) end
  config.activeRoute = index
  ui.selectedWaypoint = nil
  setWaypointIndex(nil)
  saveSoon()
  refreshWaypointList()
  refreshDashboard()
end

function newRoute()
  if recorder then setRecording(false) end
  local route = Route.new(Route.uniqueName(config.routes, 'Rota ' .. (#config.routes + 1)))
  config.routes[#config.routes + 1] = route
  config.activeRoute = #config.routes
  ui.selectedWaypoint = nil
  setWaypointIndex(nil)
  saveSoon()
  refreshWaypointList()
  setMessage(string.format('Rota "%s" criada. Adicione pontos ou grave andando.', route.name), '#62d985')
  return route
end

function renameRoute()
  local route = activeRoute()
  local edit = widget('routeNameEdit')
  if not route or not edit then return end
  local others = {}
  for index, other in ipairs(config.routes) do if index ~= config.activeRoute then others[#others + 1] = other end end
  local wanted = Route.cleanName(edit:getText())
  if not wanted then setMessage('Digite um nome para a rota.', '#ffcc66'); return end
  route.name = Route.uniqueName(others, wanted)
  saveSoon()
  refreshRouteHeader()
  refreshDashboard()
  setMessage(string.format('Rota renomeada para "%s".', route.name), '#62d985')
end

function deleteRoute()
  local route = activeRoute()
  if not route then return end
  local currentTime = now()
  local button = widget('routeDelete')
  if currentTime - ui.deleteArmedAt > CFG.DELETE_CONFIRM_MS then
    ui.deleteArmedAt = currentTime
    if button then button:setText('Confirmar?') end
    scheduleEvent(function() if button then button:setText('Excluir') end end, CFG.DELETE_CONFIRM_MS)
    return
  end
  ui.deleteArmedAt = 0
  if button then button:setText('Excluir') end
  if state.running then stop('Hunt parado: a rota em uso foi excluida.') end
  if recorder then setRecording(false) end
  table.remove(config.routes, config.activeRoute)
  config.activeRoute = math.max(1, math.min(config.activeRoute, #config.routes))
  setWaypointIndex(nil)
  saveSoon()
  refreshWaypointList()
  setMessage(string.format('Rota "%s" excluida.', route.name), '#9cb1c2')
end

function cycleRouteMode()
  local route = activeRoute()
  if not route then return end
  local position = 1
  for index, mode in ipairs(Route.MODE_ORDER) do if mode == route.mode then position = index end end
  route.mode = Route.MODE_ORDER[(position % #Route.MODE_ORDER) + 1]
  state.direction = 1
  saveSoon()
  refreshRouteHeader()
end

function reverseRoute()
  local route = activeRoute()
  if not route or #route.waypoints < 2 then return end
  Route.reverse(route)
  setWaypointIndex(nil)
  ui.selectedWaypoint = nil
  saveSoon()
  refreshWaypointList()
  setMessage('Ordem dos pontos invertida.', '#62d985')
end

function exportRoute()
  local route = activeRoute()
  if not route then return nil end
  local text = Route.export(route, json.encode)
  local ok = pcall(function() g_window.setClipboardText(text) end)
  setMessage(ok and string.format('Rota "%s" copiada para a area de transferencia.', route.name) or 'Nao foi possivel copiar a rota.',
    ok and '#62d985' or '#ff7676')
  return text
end

function importRoute(text)
  if not text then
    local ok, clip = pcall(function() return g_window.getClipboardText() end)
    text = ok and clip or ''
  end
  local route, err = Route.import(text, json.decode)
  if not route then setMessage('Importacao falhou: ' .. tostring(err) .. '.', '#ff7676'); return nil end
  route.name = Route.uniqueName(config.routes, route.name)
  config.routes[#config.routes + 1] = route
  config.activeRoute = #config.routes
  setWaypointIndex(nil)
  saveSoon()
  refreshWaypointList()
  setMessage(string.format('Rota "%s" importada (%d pontos).', route.name, #route.waypoints), '#62d985')
  return route
end

-- ---------------------------------------------------------------------------
-- Painel: alvos
-- ---------------------------------------------------------------------------

local function stars(priority) return string.rep('*', priority) .. string.rep('-', Targeting.MAX_PRIORITY - priority) end

refreshTargetList = function()
  local list = widget('targetList')
  if list then
    list:destroyChildren()
    for _, entry in ipairs(config.targets) do
      local row = g_ui.createWidget('HuntTargetRow', list)
      local name = row:recursiveGetChildById('targetName')
      local priority = row:recursiveGetChildById('targetPriority')
      local enabledBox = row:recursiveGetChildById('targetEnabled')
      if name then name:setText(entry.name == '*' and '* (todos)' or entry.name) end
      if priority then priority:setText('Prioridade ' .. stars(entry.priority)) end
      if enabledBox then
        ui.updating = true
        enabledBox:setChecked(entry.enabled)
        ui.updating = false
        enabledBox.onCheckChange = function(_, checked)
          if ui.updating then return end
          entry.enabled = checked == true
          saveSoon()
        end
      end
      wireButton(priority, function()
        entry.priority = (entry.priority % Targeting.MAX_PRIORITY) + 1
        priority:setText('Prioridade ' .. stars(entry.priority))
        saveSoon()
      end)
      wireButton(row:recursiveGetChildById('targetDelete'), function()
        for index, other in ipairs(config.targets) do
          if other == entry then table.remove(config.targets, index); break end
        end
        saveSoon()
        refreshTargetList()
      end)
    end
  end
  local empty = widget('targetEmpty')
  if empty then
    empty:setText(config.attackAll and 'Lista vazia: ataca qualquer Pokemon selvagem (opcao abaixo).' or 'Lista vazia e "Atacar todos" desligado: nenhum alvo.')
    empty:setVisible(#config.targets == 0)
  end
end

function addTarget(name, priority)
  local entry = Targeting.normalizeEntry({ name = name, priority = priority or 3 })
  if not entry then setMessage('Digite o nome do Pokemon (ou * para todos).', '#ffcc66'); return nil end
  for _, other in ipairs(config.targets) do
    if other.name:lower() == entry.name:lower() then setMessage(entry.name .. ' ja esta na lista.', '#ffcc66'); return nil end
  end
  config.targets[#config.targets + 1] = entry
  saveSoon()
  refreshTargetList()
  return entry
end

local function addTargetFromEdit()
  local edit = widget('targetNameEdit')
  local entry = addTarget(edit and edit:getText() or '')
  if entry and edit then edit:setText('') end
  if entry then setMessage(entry.name .. ' adicionado aos alvos.', '#62d985') end
end

function addVisibleTargets()
  local creatures = readCreatures(now())
  local added = 0
  local known = {}
  for _, entry in ipairs(config.targets) do known[entry.name:lower()] = true end
  for _, info in ipairs(creatures.monsters) do
    local name = trim(info.name):gsub('^[Ss]hiny%s+', '')
    if name ~= '' and not known[name:lower()] then
      known[name:lower()] = true
      config.targets[#config.targets + 1] = Targeting.normalizeEntry({ name = name, priority = 3 })
      added = added + 1
    end
  end
  saveSoon()
  refreshTargetList()
  setMessage(added > 0 and string.format('%d Pokemon(s) da tela adicionados.', added) or 'Nenhum Pokemon novo na tela.', added > 0 and '#62d985' or '#9cb1c2')
  return added
end

-- ---------------------------------------------------------------------------
-- Painel: suporte (itens e moves)
-- ---------------------------------------------------------------------------

local function setSlotItem(slot, itemId)
  if not slot then return end
  pcall(function()
    slot:setItem(nil)
    if itemId and itemId > 0 then
      local visual = Item.create(itemId, 1)
      if visual then slot:setItem(visual) else slot:setItemId(itemId) end
    end
    slot:setShowCount(false)
  end)
end

local function itemCountText(itemId)
  if itemId <= 0 then return 'Nao configurado' end
  local player = localPlayer()
  local count = player and tonumber(safeCall(player, 'getItemCount', itemId)) or nil
  if not count then return string.format('ID %d', itemId) end
  return string.format('ID %d  -  Qtd: %d%s', itemId, count, count == 0 and ' (ACABOU)' or '')
end

refreshSupportSlots = function()
  setSlotItem(widget('healSlot'), config.healItemId)
  setSlotItem(widget('summonHealSlot'), config.summonHealItemId)
  setText('healInfo', itemCountText(config.healItemId), config.healItemId > 0 and '#dce9f2' or '#9aaab5')
  setText('summonHealInfo', itemCountText(config.summonHealItemId), config.summonHealItemId > 0 and '#dce9f2' or '#9aaab5')
end

local function itemFromClick(mousePosition)
  local current = clickedWidgetAt(mousePosition)
  while current do
    local className = current:getClassName()
    if className == 'UIGameMap' then
      local tile = current:getTile(mousePosition)
      return tile and safeCall(tile, 'getTopMoveThing') or nil
    elseif className == 'UIItem' and not current:isVirtual() then
      return current:getItem()
    end
    current = current:getParent()
  end
  return nil
end

local function setSupportItem(key, itemOrId)
  local id = type(itemOrId) == 'number' and itemOrId or tonumber(safeCall(itemOrId, 'getId')) or 0
  config[key] = math.max(0, math.floor(id))
  saveSoon()
  refreshSupportSlots()
  return config[key] > 0
end

function selectSupportItem(key)
  if key ~= 'healItemId' and key ~= 'summonHealItemId' then return false end
  return startGrabber(function(mousePosition, mouseButton)
    local item = mouseButton == MouseLeftButton and itemFromClick(mousePosition) or nil
    if item and safeCall(item, 'isItem') then
      setSupportItem(key, item)
      setMessage('Item de cura configurado.', '#62d985')
    else
      setMessage('Clique em um item da mochila.', '#ffcc66')
    end
  end)
end

function clearSupportItem(key)
  if key ~= 'healItemId' and key ~= 'summonHealItemId' then return end
  setSupportItem(key, 0)
end

local function wireSupportSlot(slotId, key)
  local slot = widget(slotId)
  if not slot then return end
  slot.onDrop = function(_, dragged)
    local item = dragged and (dragged.currentDragThing or safeCall(dragged, 'getItem')) or nil
    if dragged then dragged.currentDragThing = nil end
    if item and safeCall(item, 'isItem') then return setSupportItem(key, item) end
    return false
  end
end

refreshMoveList = function()
  local list = widget('moveList')
  if list then
    list:destroyChildren()
    for _, move in ipairs(config.moves) do
      local row = g_ui.createWidget('HuntMoveRow', list)
      local textEdit = row:recursiveGetChildById('moveText')
      local cooldownEdit = row:recursiveGetChildById('moveCooldown')
      local enabledBox = row:recursiveGetChildById('moveEnabled')
      ui.updating = true
      if textEdit then textEdit:setText(move.text) end
      if cooldownEdit then cooldownEdit:setText(tostring(move.cooldown)) end
      if enabledBox then enabledBox:setChecked(move.enabled) end
      ui.updating = false
      if textEdit then
        textEdit.onTextChange = function(_, text)
          if ui.updating then return end
          move.text = trim(text):sub(1, 40)
          saveSoon()
        end
      end
      if cooldownEdit then
        cooldownEdit.onTextChange = function(self, text)
          if ui.updating then return end
          local number = tonumber(trim(text))
          if not number or number < 1 or number > 600 then self:setColor('#ff7676'); return end
          self:setColor('#ffffff')
          move.cooldown = math.floor(number + 0.5)
          saveSoon()
        end
      end
      if enabledBox then
        enabledBox.onCheckChange = function(_, checked)
          if ui.updating then return end
          move.enabled = checked == true
          saveSoon()
        end
      end
      wireButton(row:recursiveGetChildById('moveDelete'), function()
        for index, other in ipairs(config.moves) do
          if other == move then table.remove(config.moves, index); break end
        end
        state.moveUsedAt = {}
        saveSoon()
        refreshMoveList()
      end)
    end
  end
  local empty = widget('moveEmpty')
  if empty then empty:setVisible(#config.moves == 0) end
end

function addMove(text, cooldown)
  if #config.moves >= 12 then setMessage('Limite de 12 moves.', '#ffcc66'); return nil end
  local move = { text = trim(text or ('m' .. (#config.moves + 1))):sub(1, 40), cooldown = clampNumber(cooldown, 1, 600, 10), enabled = true }
  config.moves[#config.moves + 1] = move
  saveSoon()
  refreshMoveList()
  return move
end

-- ---------------------------------------------------------------------------
-- Janela
-- ---------------------------------------------------------------------------

local function bindWindow()
  ui.cache = {}
  for _, tab in ipairs(TABS) do
    wireButton(widget('nav_' .. tab), function() selectTab(tab) end)
  end
  wireButton(widget('closeButton'), hide)
  wireButton(widget('toggleButton'), toggleRunning)
  wireButton(widget('resetStatsButton'), resetStats)
  wireButton(widget('routePrev'), function() selectRoute(config.activeRoute - 1) end)
  wireButton(widget('routeNext'), function() selectRoute(config.activeRoute + 1) end)
  wireButton(widget('routeNew'), newRoute)
  wireButton(widget('routeRename'), renameRoute)
  wireButton(widget('routeDelete'), deleteRoute)
  wireButton(widget('routeMode'), cycleRouteMode)
  wireButton(widget('routeReverse'), reverseRoute)
  wireButton(widget('routeExport'), exportRoute)
  wireButton(widget('routeImport'), function() importRoute() end)
  for _, kind in ipairs(Route.TYPE_ORDER) do
    wireButton(widget('type_' .. kind), function() selectWaypointType(kind) end)
  end
  wireButton(widget('wpAddHere'), addWaypointHere)
  wireButton(widget('wpAddMap'), addWaypointFromMap)
  wireButton(widget('wpRecord'), function() setRecording(recorder == nil) end)
  wireButton(widget('targetAdd'), addTargetFromEdit)
  wireButton(widget('targetAddVisible'), addVisibleTargets)
  wireButton(widget('healSelect'), function() selectSupportItem('healItemId') end)
  wireButton(widget('healClear'), function() clearSupportItem('healItemId') end)
  wireButton(widget('summonHealSelect'), function() selectSupportItem('summonHealItemId') end)
  wireButton(widget('summonHealClear'), function() clearSupportItem('summonHealItemId') end)
  wireButton(widget('moveAdd'), function() addMove() end)
  wireSupportSlot('healSlot', 'healItemId')
  wireSupportSlot('summonHealSlot', 'summonHealItemId')
  local nameEdit = widget('targetNameEdit')
  if nameEdit then
    nameEdit.onKeyPress = function(_, keyCode)
      if keyCode == KeyEnter or keyCode == 13 then addTargetFromEdit(); return true end
    end
  end
  bindFields()
  ui.window.onVisibilityChange = function(_, visible)
    if ui.button then ui.button:setOn(visible or state.running) end
    if visible then refreshDashboard(); refreshSupportSlots() end
  end
  ui.window.onEscape = hide
end

local function refreshAll()
  refreshFields()
  refreshStatus()
  refreshWaypointList()
  refreshTypeButtons()
  refreshRecordButton()
  refreshTargetList()
  refreshMoveList()
  refreshSupportSlots()
  refreshDashboard()
  setMessage(state.message or 'Pronto.', state.messageColor)
  selectTab(ui.tab or 'dashboard')
end

local function createWindow()
  if ui.window then return ui.window end
  local root = modules.game_interface and modules.game_interface.getRootPanel()
  local ok, win = pcall(function() return g_ui.createWidget('HuntWindow', root) end)
  if not ok or not win then logWarn('falha ao criar HuntWindow: ' .. tostring(win)); return nil end
  ui.window = win
  local okBind, err = pcall(function() bindWindow(); refreshAll() end)
  if not okBind then logWarn('erro ao montar o painel: ' .. tostring(err)) end
  win:hide()
  return win
end

function show()
  local win = createWindow()
  if not win then return end
  win:show()
  win:raise()
  win:focus()
  refreshDashboard()
  refreshSupportSlots()
  if ui.button then ui.button:setOn(true) end
end

function hide()
  finishGrabber()
  if ui.window then ui.window:hide() end
  if ui.button then ui.button:setOn(state.running) end
end

function toggle()
  if ui.window and ui.window:isVisible() then hide() else show() end
end

-- ---------------------------------------------------------------------------
-- Eventos do cliente
-- ---------------------------------------------------------------------------

local function onCreatureHealthPercentChange(creature, healthPercent)
  if not state.running then return end
  invalidateCreatures()
  if (tonumber(healthPercent) or 100) > 0 then return end
  local id = safeCall(creature, 'getId')
  if not id then return end
  if id == state.attack.id or state.attackedIds[id] then
    stats:recordKill(tostring(safeCall(creature, 'getName') or state.attack.name or 'Pokemon'))
    state.attackedIds[id] = nil
    state.blacklist[id] = nil
    if id == state.attack.id then state.attack = { sentAt = state.attack.sentAt } end
  end
end

local function onCreatureAppear(creature)
  if not state.running then return end
  invalidateCreatures()
  if not config.shinyAlert then return end
  local name = tostring(safeCall(creature, 'getName') or '')
  local id = safeCall(creature, 'getId')
  if id and not state.seenShiny[id] and safeCall(creature, 'isMonster') == true and isShinyCreature(creature, name) then
    state.seenShiny[id] = true
    stats.shiniesSeen = stats.shiniesSeen + 1
    setMessage('SHINY na tela: ' .. name .. '!', '#e0c3ff')
    alarm('Shiny na tela: ' .. name)
  end
end

local function onCreatureDisappear(creature)
  if not state.running then return end
  invalidateCreatures()
  local id = safeCall(creature, 'getId')
  if id and id == state.attack.id then state.attack = { sentAt = state.attack.sentAt } end
end

local function onTextMessage(_, text)
  if not state.running then return end
  local experience = HuntStats.parseExperience(text)
  if experience then stats:recordExperience(experience) end
end

local function cancelResume()
  if events.resume then removeEvent(events.resume); events.resume = nil end
end

local function onGameStart()
  cancelResume()
  refreshSupportSlots()
  if config.autoResume and config.wasRunning then
    events.resume = scheduleEvent(function()
      events.resume = nil
      if g_game.isOnline() and not state.running and start() then
        setMessage('Hunt retomado automaticamente ao entrar no jogo.', '#62d985')
      end
    end, CFG.RESUME_DELAY_MS)
  end
end

local function onGameEnd()
  cancelResume()
  setRecording(false)
  stopHunt('Hunt parado ao sair do jogo.', true)
  saveNow()
  hide()
end

-- ---------------------------------------------------------------------------
-- Ciclo de vida do modulo
-- ---------------------------------------------------------------------------

local HOTKEYS = {
  { 'Ctrl+Shift+H', function() toggleRunning() end },
  { 'Ctrl+Shift+J', function() addWaypointHere() end }
}

function init()
  g_ui.importStyle('hunt.otui')
  loadConfig()
  math.randomseed(now())

  if modules.client_topmenu and not ui.button then
    ui.button = modules.client_topmenu.addMiddleGameToggleButton(
      'huntButton', tr('Hunt'), '/modules/game_hunt/images/icon', toggle, false, 18)
    if ui.button then ui.button:setOn(false) end
  end

  createWindow()

  connect(Creature, {
    onAppear = onCreatureAppear,
    onHealthPercentChange = onCreatureHealthPercentChange,
    onDisappear = onCreatureDisappear
  })
  connect(g_game, {
    onGameStart = onGameStart,
    onGameEnd = onGameEnd,
    onTextMessage = onTextMessage
  })
  if g_keyboard and g_keyboard.bindKeyDown then
    for _, hotkey in ipairs(HOTKEYS) do pcall(g_keyboard.bindKeyDown, hotkey[1], hotkey[2]) end
  end
  events.refresh = cycleEvent(function()
    if ui.window and (state.running or ui.window:isVisible()) then pcall(refreshDashboard) end
  end, CFG.REFRESH_MS)

  logInfo(string.format('Carregado: %d rota(s), %d alvo(s), %d move(s).', #config.routes, #config.targets, #config.moves))
  if g_game.isOnline() then onGameStart() end
end

function terminate()
  disconnect(Creature, {
    onAppear = onCreatureAppear,
    onHealthPercentChange = onCreatureHealthPercentChange,
    onDisappear = onCreatureDisappear
  })
  disconnect(g_game, {
    onGameStart = onGameStart,
    onGameEnd = onGameEnd,
    onTextMessage = onTextMessage
  })
  if g_keyboard and g_keyboard.unbindKeyDown then
    for _, hotkey in ipairs(HOTKEYS) do pcall(g_keyboard.unbindKeyDown, hotkey[1]) end
  end
  cancelResume()
  setRecording(false)
  stopHunt(nil, true)
  saveNow()
  finishGrabber()
  for name, event in pairs(events) do
    if event then removeEvent(event) end
    events[name] = nil
  end
  if ui.window then ui.window:destroy(); ui.window = nil end
  if ui.button then ui.button:destroy(); ui.button = nil end
  ui.cache, ui.waypointRows = {}, {}
end

-- ---------------------------------------------------------------------------
-- API publica (modules.game_hunt.*)
--   init, terminate, show, hide, toggle, selectTab, start, stop, toggleRunning,
--   isRunning, getBotState, getPhase, getStats, getConfig, getWaypointIndex,
--   resetStats, addWaypointHere, addWaypointFromMap, selectWaypointType,
--   setRecording, isRecording, newRoute, renameRoute, deleteRoute,
--   cycleRouteMode, reverseRoute, exportRoute, importRoute, addTarget,
--   addVisibleTargets, addMove, selectSupportItem, clearSupportItem
-- ---------------------------------------------------------------------------
