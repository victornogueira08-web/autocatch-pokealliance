-- Testa hunt.lua de ponta a ponta em um cliente falso (tests/hunt_fake.lua).
local source = debug.getinfo(1, 'S').source
local testDirectory = source:sub(1, 1) == '@' and source:sub(2):match('^(.*)[/\\]') or '.'
local HuntFake = dofile(testDirectory .. '/hunt_fake.lua')

local passed, failed = 0, 0
local function check(name, fn)
  local ok, message = pcall(fn)
  if ok then passed = passed + 1; print('PASS ' .. name)
  else
    failed = failed + 1; print('FAIL ' .. name .. ': ' .. tostring(message))
    if LAST_FAKE and os.getenv('HUNT_DEBUG') then for _, line in ipairs(LAST_FAKE.log) do print('   log: ' .. line) end end
  end
end
local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format('%sexpected %s, got %s', label and (label .. ': ') or '', tostring(expected), tostring(actual)), 2)
  end
end

-- Avanca em passos de 50 ms; true se o predicado ficou verdadeiro em algum momento.
local function runUntil(fake, ms, predicate)
  local elapsed = 0
  while elapsed < ms do
    fake:advance(50)
    elapsed = elapsed + 50
    if predicate() then return true end
  end
  return false
end

local function wp(kind, x, y, z, extra)
  local w = { type = kind, x = x, y = y, z = z or 7 }
  for k, v in pairs(extra or {}) do w[k] = v end
  return w
end

-- Liga o modulo com uma configuracao salva (opcional).
local function boot(config)
  local fake = HuntFake.new()
  if config then fake.settings.huntPkaConfig = fake.env.json.encode(config) end
  local api = fake:loadModule('game_hunt', 'hunt.lua')
  api.init()
  LAST_FAKE = fake
  return fake, api
end

local function routeConfig(waypoints, extra)
  local config = { routes = { { name = 'Teste', mode = 'loop', waypoints = waypoints } }, activeRoute = 1,
    attack = false, waitCatch = false, startNearest = false, staffPause = true }
  for k, v in pairs(extra or {}) do config[k] = v end
  return config
end

local function window(fake) return fake.window or fake.env.g_ui end

check('module loads, creates the window and registers hotkeys', function()
  local fake, api = boot()
  equal(type(api.start), 'function')
  equal(type(fake.hotkeys['Ctrl+Shift+H']), 'function')
  equal(api.getBotState(), 'STOPPED')
  api.show()
end)

check('walks the route in order and counts laps in loop mode', function()
  local fake, api = boot(routeConfig({ wp('walk', 103, 100, 7, { precision = 0 }), wp('walk', 103, 103, 7, { precision = 0 }), wp('walk', 100, 100, 7, { precision = 0 }) }))
  equal(api.start(), true)
  local function at(x, y) return function() return fake.playerPos.x == x and fake.playerPos.y == y end end
  equal(runUntil(fake, 1000, at(103, 100)), true, 'reached #1')
  equal(runUntil(fake, 1000, at(103, 103)), true, 'reached #2')
  equal(runUntil(fake, 1000, at(100, 100)), true, 'reached #3')
  equal(runUntil(fake, 500, function() return api.getStats().laps == 1 end), true, 'lap counted')
  equal(api.getBotState(), 'WALKING')
  equal(fake.walkSends <= 6, true, 'one walk command per waypoint, no spam')
end)

check('starts from the nearest waypoint when configured', function()
  local fake, api = boot(routeConfig({ wp('walk', 130, 100), wp('walk', 103, 101, 7, { precision = 0 }), wp('walk', 140, 100) }, { startNearest = true }))
  api.start()
  fake:advance(50)
  equal(api.getWaypointIndex(), 2)
end)

check('stand waits the configured seconds before moving on', function()
  local fake, api = boot(routeConfig({ wp('stand', 100, 100, 7, { seconds = 3 }), wp('walk', 105, 100, 7, { precision = 0 }) }))
  api.start()
  fake:advance(1500)
  equal(api.getBotState(), 'STANDING')
  equal(fake.playerPos.x, 100)
  equal(api.getWaypointIndex(), 1)
  equal(runUntil(fake, 2000, function() return api.getWaypointIndex() == 2 end), true, 'moved on after 3 s')
end)

check('say talks once; goto jumps to its label', function()
  local fake, api = boot(routeConfig({ { type = 'label', label = 'inicio' }, { type = 'say', text = 'hi' },
    wp('walk', 100, 100, 7), { type = 'goto', label = 'inicio' } }))
  api.start()
  fake:advance(3000)
  equal(fake.talks[1], 'hi')
  equal(#fake.talks >= 2, true, 'goto came back to say again')
end)

check('once mode stops the hunt at the end of the route', function()
  local config = routeConfig({ wp('walk', 101, 100), wp('walk', 102, 100) })
  config.routes[1].mode = 'once'
  local fake, api = boot(config)
  api.start()
  fake:advance(2000)
  equal(api.isRunning(), false)
end)

check('attacks the best target, counts the kill and resumes the route', function()
  local fake, api = boot(routeConfig({ wp('walk', 110, 100) }, { attack = true, attackAll = true }))
  local rattata = fake:monster({ name = 'Rattata', position = { x = 102, y = 100, z = 7 } })
  api.start()
  fake:advance(200)
  equal(fake.attacking, rattata)
  equal(api.getBotState(), 'FIGHTING')
  equal(fake.walkTarget, nil, 'stops walking to fight')
  fake:kill(rattata)
  fake:advance(300)
  equal(api.getStats().kills, 1)
  equal(api.getStats().killsByName.Rattata, 1)
  equal(api.getBotState(), 'WALKING')
end)

check('target list priority, ignore list and shiny first', function()
  local fake, api = boot(routeConfig({}, { attack = true, walk = false, attackAll = false, ignoreText = 'Abra',
    targets = { { name = 'Rattata', priority = 1 }, { name = 'Pidgey', priority = 5 }, { name = 'Abra', priority = 5 } } }))
  fake:monster({ name = 'Rattata', position = { x = 101, y = 100, z = 7 } })
  local pidgey = fake:monster({ name = 'Pidgey', position = { x = 105, y = 100, z = 7 } })
  fake:monster({ name = 'Abra', position = { x = 101, y = 101, z = 7 } })
  fake:monster({ name = 'Zubat', position = { x = 100, y = 101, z = 7 } })
  api.start()
  fake:advance(200)
  equal(fake.attacking, pidgey)
  local shiny = fake:monster({ name = 'Shiny Rattata', position = { x = 106, y = 100, z = 7 }, shiny = true })
  fake:advance(600)
  equal(fake.attacking, shiny)
end)

check('anti-KS skips a hurt monster next to another player', function()
  local fake, api = boot(routeConfig({}, { attack = true, walk = false, antiKs = true }))
  local hurt = fake:monster({ name = 'Rattata', position = { x = 103, y = 100, z = 7 } })
  hurt.__data.health = 40
  fake:player('Outro', { x = 104, y = 100, z = 7 })
  api.start()
  fake:advance(300)
  equal(fake.attacking, nil)
  local fresh = fake:monster({ name = 'Rattata', position = { x = 98, y = 100, z = 7 } })
  fake:advance(300)
  equal(fake.attacking, fresh)
end)

check('a target that does not lose HP is dropped and blacklisted', function()
  local fake, api = boot(routeConfig({}, { attack = true, walk = false, targetTimeout = 5 }))
  local stuck = fake:monster({ name = 'Onix', position = { x = 102, y = 100, z = 7 } })
  api.start()
  fake:advance(200)
  equal(fake.attacking, stuck)
  fake:advance(6000)
  equal(fake.attacking, nil)
  fake:advance(10000)
  equal(fake.attacking, nil, 'still blacklisted')
  fake:advance(20000)
  equal(fake.attacking, stuck, 'blacklist expired')
end)

check('staff on screen holds the hunt and Auto Catch sees PAUSED_STAFF', function()
  local fake, api = boot(routeConfig({ wp('walk', 120, 100) }))
  api.start()
  fake:advance(300)
  local gm = fake:player('[GM] Admin', { x = 105, y = 100, z = 7 })
  fake:advance(600)
  equal(api.getBotState(), 'PAUSED_STAFF')
  local x = fake.playerPos.x
  fake:advance(1000)
  equal(fake.playerPos.x, x, 'no walking while staff is visible')
  equal(fake.flashes ~= nil, true, 'alarm flashed')
  fake:removeCreature(gm)
  fake:advance(1000)
  equal(api.getBotState(), 'WALKING')
end)

check('player pause respects the whitelist', function()
  local fake, api = boot(routeConfig({ wp('walk', 120, 100) }, { playerPause = true, playerWhitelistText = 'Amigo' }))
  fake:player('Amigo', { x = 103, y = 100, z = 7 })
  api.start()
  fake:advance(500)
  equal(api.getBotState(), 'WALKING')
  fake:player('Estranho', { x = 104, y = 100, z = 7 })
  fake:advance(600)
  equal(api.getBotState(), 'PAUSED_PLAYER')
end)

check('heals with the item and stops on critical HP', function()
  local fake, api = boot(routeConfig({ wp('walk', 120, 100) }, { healItemId = 777, healPercent = 60, lowHpPercent = 20 }))
  api.start()
  fake.playerHealth = 50
  fake:advance(500)
  equal((fake.itemUsesById[777] or 0) >= 1, true)
  fake.playerHealth = 15
  fake:advance(300)
  equal(api.isRunning(), false)
end)

check('waits for Auto Catch and walks back toward a far pending corpse', function()
  local busy = true
  local pending = { { x = 100, y = 100, z = 7 } }
  local fake, api = boot(routeConfig({ wp('walk', 120, 100) }, { waitCatch = true }))
  fake.env.modules.game_autocatch = {
    isEnabled = function() return true end,
    isBusy = function() return busy end,
    getPendingPositions = function() return pending end,
    getStats = function() return { confirmed = 0 } end
  }
  fake.playerPos = { x = 110, y = 100, z = 7 }
  api.start()
  fake:advance(1500)
  equal(api.getBotState(), 'CATCHING')
  equal(fake.playerPos.x <= 104, true, 'walked back within the leash')
  busy = false
  fake:advance(3000)
  equal(fake.playerPos.x > 105, true, 'route resumed')
end)

check('an unreachable waypoint is skipped after the stuck retries', function()
  local fake, api = boot(routeConfig({ wp('walk', 110, 100, 7, { precision = 0 }), wp('walk', 100, 105, 7, { precision = 0 }) }))
  fake.walkBlocked = true
  api.start()
  fake:advance(15000)
  equal(api.getStats().skippedWaypoints >= 1, true)
  equal(api.getWaypointIndex() ~= 1 or api.getStats().skippedWaypoints >= 2, true)
end)

check('different floor resumes from the nearest waypoint on the current floor', function()
  local fake, api = boot(routeConfig({ wp('walk', 100, 100, 6), wp('walk', 104, 100, 7, { precision = 0 }) }))
  api.start()
  fake:advance(2000)
  equal(api.getWaypointIndex(), 1, 'waits a moment for a floor change')
  equal(runUntil(fake, 2000, function() return api.getWaypointIndex() == 2 end), true)
  equal(runUntil(fake, 1000, function() return fake.playerPos.x == 104 end), true)
end)

check('recording creates waypoints while walking (stairs as exact)', function()
  local fake, api = boot()
  api.show()
  equal(api.setRecording(true), true)
  for i = 1, 8 do fake.playerPos = { x = 100 + i, y = 100, z = 7 }; fake:advance(200) end
  fake.playerPos = { x = 108, y = 101, z = 6 }
  fake:advance(200)
  api.setRecording(false)
  local route = api.getConfig().routes[1]
  equal(route ~= nil, true)
  equal(#route.waypoints >= 4, true)
  local last = route.waypoints[#route.waypoints]
  equal(last.z, 6)
  equal(route.waypoints[#route.waypoints - 1].type, 'exact')
end)

check('panel adds waypoints of the selected type and hotkey adds one here', function()
  local fake, api = boot()
  api.show()
  api.selectWaypointType('stand')
  fake.window:recursiveGetChildById('wpParamEdit'):setText('7')
  equal(api.addWaypointHere(), 1)
  fake.playerPos = { x = 101, y = 100, z = 7 }
  api.selectWaypointType('say')
  fake.window:recursiveGetChildById('wpParamEdit'):setText('')
  equal(api.addWaypointHere(), nil, 'say needs text')
  api.selectWaypointType('walk')
  fake.hotkeys['Ctrl+Shift+J']()
  local route = api.getConfig().routes[1]
  equal(#route.waypoints, 2)
  equal(route.waypoints[1].seconds, 7)
end)

check('settings persist across reloads; export/import via clipboard', function()
  local fake, api = boot(routeConfig({ wp('walk', 101, 100) }))
  api.addTarget('Rattata', 4)
  api.addMove('m1', 8)
  fake:advance(1000)
  local saved = fake.settings.huntPkaConfig
  equal(type(saved), 'string')
  local text = api.exportRoute()
  equal(fake.clipboard, text)
  local imported = api.importRoute()
  equal(imported.name, 'Teste 2')
  equal(#api.getConfig().routes, 2)

  local fake2 = HuntFake.new()
  fake2.settings.huntPkaConfig = saved
  local api2 = fake2:loadModule('game_hunt', 'hunt.lua')
  api2.init()
  equal(api2.getConfig().targets[1].name, 'Rattata')
  equal(api2.getConfig().targets[1].priority, 4)
  equal(api2.getConfig().moves[1].cooldown, 8)
end)

check('number fields validate input and save valid values', function()
  local fake, api = boot()
  local edit = fake.window:recursiveGetChildById('maxDistanceEdit')
  edit.onTextChange(edit, '99')
  equal(edit.color, '#ff7676')
  edit.onTextChange(edit, '5')
  equal(api.getConfig().maxDistance, 5)
  local box = fake.window:recursiveGetChildById('optAntiKs')
  box.onCheckChange(box, false)
  equal(api.getConfig().antiKs, false)
end)

check('moves rotate respecting cooldowns while attacking', function()
  local fake, api = boot(routeConfig({}, { attack = true, walk = false, movesEnabled = true,
    moves = { { text = 'm1', cooldown = 5 }, { text = 'm2', cooldown = 5 } } }))
  local target = fake:monster({ name = 'Geodude', position = { x = 101, y = 100, z = 7 } })
  api.start()
  fake:advance(2000)
  equal(fake.talks[1], 'm1'); equal(fake.talks[2], 'm2'); equal(#fake.talks, 2)
  for step = 1, 4 do fake:health(target, 90 - step * 10); fake:advance(1000) end
  equal(#fake.talks, 4)
end)

check('experience messages feed XP/h and shiny alert counts', function()
  local fake, api = boot(routeConfig({}, { attack = false, walk = true }))
  api.start()
  fake:gameEvent('onTextMessage', 20, 'Voce ganhou 1.500 pontos de experiencia.')
  equal(api.getStats().experience, 1500)
  local shiny = fake:monster({ name = 'Shiny Abra', position = { x = 101, y = 100, z = 7 }, shiny = true })
  fake:appear(shiny)
  equal(api.getStats().shiniesSeen, 1)
  fake:appear(shiny)
  equal(api.getStats().shiniesSeen, 1)
end)

check('leaving the game stops the hunt; auto resume restarts it', function()
  local fake, api = boot(routeConfig({ wp('walk', 110, 100) }, { autoResume = true }))
  api.start()
  fake:advance(200)
  fake:gameEvent('onGameEnd')
  equal(api.isRunning(), false)
  fake:gameEvent('onGameStart')
  fake:advance(6000)
  equal(api.isRunning(), true)
  api.terminate()
  equal(fake.hotkeys['Ctrl+Shift+H'], nil)
end)

print(string.format('RESULT %d passed, %d failed', passed, failed))
if failed > 0 then error('Hunt runtime tests failed') end
