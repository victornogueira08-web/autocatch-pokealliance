-- Testes das partes puras do Hunt (rotas, alvos, contadores).
local source = debug.getinfo(1, 'S').source
local testDirectory = source:sub(1, 1) == '@' and source:sub(2):match('^(.*)[/\\]') or '.'
local base = testDirectory .. '/../'
local Route = dofile(base .. 'route.lua')
local Targeting = dofile(base .. 'targeting.lua')
local HuntStats = dofile(base .. 'hunt_stats.lua')

local passed, failed = 0, 0
local function check(name, fn)
  local ok, message = pcall(fn)
  if ok then passed = passed + 1; print('PASS ' .. name)
  else failed = failed + 1; print('FAIL ' .. name .. ': ' .. tostring(message)) end
end
local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format('%sexpected %s, got %s', label and (label .. ': ') or '', tostring(expected), tostring(actual)), 2)
  end
end

local function route(points, mode)
  local r = Route.new('Teste')
  r.mode = mode or 'loop'
  for _, p in ipairs(points) do assert(Route.addWaypoint(r, p)) end
  return r
end

local function walk(x, y, z) return { type = 'walk', x = x, y = y, z = z or 7 } end

check('normalize drops invalid waypoints and clamps parameters', function()
  local r = Route.normalize({ name = '  Cave  ', mode = 'xx', waypoints = {
    walk(1, 1), { type = 'walk' }, { type = 'stand', x = 1, y = 2, z = 7, seconds = 9999 },
    { type = 'say', text = '   ' }, { type = 'label', label = 'a' }, { type = 'teleport', x = 1, y = 1, z = 7 },
    { type = 'walk', x = 3, y = 3, z = 7, precision = 99 } } })
  equal(r.name, 'Cave')
  equal(r.mode, 'loop')
  equal(#r.waypoints, 4)
  equal(r.waypoints[2].seconds, 600)
  equal(r.waypoints[4].precision, 5)
end)

check('loop mode wraps and counts a lap', function()
  local r = route({ walk(1, 1), walk(2, 2), walk(3, 3) })
  local index, direction, lap = Route.nextIndex(r, 3, 'loop', 1)
  equal(index, 1); equal(direction, 1); equal(lap, true)
  index, _, lap = Route.nextIndex(r, 1, 'loop', 1)
  equal(index, 2); equal(lap, false)
end)

check('ping-pong mode turns around at both ends', function()
  local r = route({ walk(1, 1), walk(2, 2), walk(3, 3) }, 'pingpong')
  local index, direction, lap = Route.nextIndex(r, 3, nil, 1)
  equal(index, 2); equal(direction, -1); equal(lap, false)
  index, direction, lap = Route.nextIndex(r, 1, nil, -1)
  equal(index, 2); equal(direction, 1); equal(lap, true)
end)

check('once mode ends after the last waypoint', function()
  local r = route({ walk(1, 1), walk(2, 2) }, 'once')
  local index, _, lap = Route.nextIndex(r, 2, nil, 1)
  equal(index, nil); equal(lap, true)
end)

check('nearest waypoint ignores other floors and non-positional points', function()
  local r = route({ walk(100, 100, 6), { type = 'label', label = 'x' }, walk(110, 100), walk(103, 101) })
  local index, distance = Route.nearestIndex(r, { x = 100, y = 100, z = 7 })
  equal(index, 4); equal(distance, 3)
end)

check('labels, move, remove and reverse', function()
  local r = route({ walk(1, 1), { type = 'label', label = 'Volta' }, walk(3, 3) })
  equal(Route.findLabel(r, 'volta'), 2)
  equal(Route.moveWaypoint(r, 1, 1), 2)
  equal(r.waypoints[1].type, 'label')
  equal(Route.moveWaypoint(r, 1, -1), nil)
  Route.reverse(r)
  equal(r.waypoints[1].x, 3)
  equal(Route.removeWaypoint(r, 1), true)
  equal(#r.waypoints, 2)
end)

check('addWaypoint inserts after the selected index', function()
  local r = route({ walk(1, 1), walk(3, 3) })
  equal(Route.addWaypoint(r, walk(2, 2), 1), 2)
  equal(r.waypoints[2].x, 2)
end)

check('unique names avoid duplicates', function()
  local routes = { Route.new('Rota'), Route.new('Rota 2') }
  equal(Route.uniqueName(routes, 'rota'), 'rota 3')
  local list = Route.normalizeList({ { name = 'A', waypoints = {} }, { name = 'a', waypoints = {} } })
  equal(list[2].name, 'a (2)')
end)

check('export and import round trip and reject garbage', function()
  local encoded
  local function encode(v) encoded = v; return '{"ok":true}' end
  local text = Route.export(route({ walk(1, 1) }), encode)
  equal(text:sub(1, #Route.EXPORT_PREFIX), Route.EXPORT_PREFIX)
  equal(encoded.waypoints[1].x, 1)
  local r = Route.import(Route.EXPORT_PREFIX .. '{}', function() return { name = 'X', waypoints = { walk(5, 5) } } end)
  equal(r.name, 'X'); equal(#r.waypoints, 1)
  local bad, err = Route.import('hello', function() return {} end)
  equal(bad, nil); equal(err ~= nil, true)
end)

check('recorder adds a point every N squares and marks stairs as exact', function()
  local rec = Route.Recorder.new(3)
  equal(#rec:observe({ x = 0, y = 0, z = 7 }), 1)
  equal(#rec:observe({ x = 1, y = 0, z = 7 }), 0)
  equal(#rec:observe({ x = 2, y = 0, z = 7 }), 0)
  local out = rec:observe({ x = 3, y = 0, z = 7 })
  equal(#out, 1); equal(out[1].x, 3)
  rec:observe({ x = 4, y = 0, z = 7 })
  out = rec:observe({ x = 4, y = 1, z = 6 })
  equal(#out, 2)
  equal(out[1].type, 'exact'); equal(out[1].x, 4); equal(out[1].y, 0); equal(out[1].z, 7)
  equal(out[2].z, 6)
  out = rec:observe({ x = 40, y = 1, z = 6 })
  equal(out[1].type, 'exact')
end)

local function mon(id, name, distance, hp, shiny)
  return { id = id, name = name, distance = distance, healthPercent = hp or 100, isShiny = shiny == true,
    position = { x = 100 + distance, y = 100, z = 7 } }
end

check('targeting prefers priority, then shiny, then distance', function()
  local index = Targeting.buildIndex(Targeting.normalizeList({ { name = 'Rattata', priority = 2 }, { name = 'Pidgey', priority = 4 } }))
  local best = Targeting.choose({ mon(1, 'Rattata', 1), mon(2, 'Pidgey', 5) }, index, { maxDistance = 7 })
  equal(best.id, 2)
  best = Targeting.choose({ mon(1, 'Rattata', 1), mon(2, 'Shiny Rattata', 5, 100, true) }, index, { maxDistance = 7 })
  equal(best.id, 2, 'shiny of the same species wins')
  best = Targeting.choose({ mon(1, 'Rattata', 4), mon(3, 'Rattata', 2) }, index, { maxDistance = 7 })
  equal(best.id, 3)
end)

check('targeting honors list, wildcard, attackAll, ignore, range and blacklist', function()
  local empty = Targeting.buildIndex({})
  equal(Targeting.choose({ mon(1, 'Abra', 1) }, empty, { maxDistance = 7 }), nil)
  equal(Targeting.choose({ mon(1, 'Abra', 1) }, empty, { maxDistance = 7, attackAll = true }).id, 1)
  local all = Targeting.buildIndex({ { name = '*', priority = 1, enabled = true } })
  equal(Targeting.choose({ mon(1, 'Abra', 1) }, all, { maxDistance = 7, ignore = Targeting.parseNameSet('abra, ditto') }), nil)
  equal(Targeting.choose({ mon(1, 'Abra', 9) }, all, { maxDistance = 7 }), nil)
  equal(Targeting.choose({ mon(1, 'Abra', 1) }, all, { maxDistance = 7, blacklist = { [1] = true } }), nil)
  local disabled = Targeting.buildIndex(Targeting.normalizeList({ { name = 'Abra', enabled = false } }))
  equal(Targeting.choose({ mon(1, 'Abra', 1) }, disabled, { maxDistance = 7 }), nil)
end)

check('current target is kept against an equal candidate; anti-KS skips stolen targets', function()
  local all = Targeting.buildIndex({ { name = '*', priority = 3, enabled = true } })
  local best = Targeting.choose({ mon(1, 'Abra', 3), mon(2, 'Abra', 1) }, all, { maxDistance = 7, currentId = 1 })
  equal(best.id, 1)
  best = Targeting.choose({ mon(1, 'Abra', 1, 50), mon(2, 'Abra', 3) }, all,
    { maxDistance = 7, isStolen = function(c) return c.id == 1 end })
  equal(best.id, 2)
  equal(Targeting.countTargets({ mon(1, 'Abra', 1), mon(2, 'Abra', 3), mon(3, 'Abra', 6) }, all, {}, 4), 2)
end)

check('stats: rates, durations, experience parsing and top kills', function()
  local s = HuntStats.new()
  s:start(0)
  s:recordKill('Abra'); s:recordKill('Abra'); s:recordKill('Zubat')
  s:recordExperience(1500)
  equal(s:perHour(s.kills, 3600000), 3)
  equal(s:perHour(1500, 1800000), 3000)
  equal(s:perHour(10, 1000), 0, 'no rate in the first 30 s')
  s:stop(60000)
  equal(s:elapsedMs(999999), 60000)
  equal(HuntStats.formatDuration(3909000), '1:05:09')
  equal(HuntStats.formatDuration(65000), '01:05')
  equal(HuntStats.formatNumber(12345), '12.3k')
  equal(HuntStats.formatNumber(2500000), '2.50M')
  equal(s:topKills(1)[1].name, 'Abra')
  equal(HuntStats.parseExperience('Voce ganhou 1.234 pontos de experiencia.'), 1234)
  equal(HuntStats.parseExperience('You gained 250 experience points.'), 250)
  equal(HuntStats.parseExperience('O jogador X ganhou 50 de experiencia'), nil)
  equal(HuntStats.parseExperience('Hello'), nil)
end)

print(string.format('RESULT %d passed, %d failed', passed, failed))
if failed > 0 then error('Hunt logic tests failed') end
