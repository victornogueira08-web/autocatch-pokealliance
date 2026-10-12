-- Cliente falso para o Hunt: reaproveita o fake do Auto Catch e acrescenta
-- andar (autoWalk simulado), ataque, chat, teclado e area de transferencia.
local source = debug.getinfo(1, 'S').source
local testDirectory = source:sub(1, 1) == '@' and source:sub(2):match('^(.*)[/\\]') or '.'
local modulesDir = testDirectory .. '/../..'
local Fake = dofile(modulesDir .. '/game_autocatch/tests/fake_client.lua')

local HuntFake = {}

local function stepTowards(from, to)
  local function sign(v) if v > 0 then return 1 elseif v < 0 then return -1 end return 0 end
  return { x = from.x + sign(to.x - from.x), y = from.y + sign(to.y - from.y), z = from.z }
end

function HuntFake.new()
  local fake = Fake.new()
  local env = fake.env
  fake.modulesDir = modulesDir
  fake.walkTarget = nil
  fake.walkBlocked = false
  fake.walkSends = 0
  fake.steps = 0
  fake.talks = {}
  fake.attacks = {}
  fake.attacking = nil
  fake.playerHealth = 100
  fake.clipboard = ''
  fake.hotkeys = {}
  fake.itemUsesById = {}

  local player = env.g_game.getLocalPlayer()
  player.getHealthPercent = function() return fake.playerHealth end
  player.isWalking = function() return false end
  player.isAutoWalking = function() return fake.walkTarget ~= nil end
  player.stopAutoWalk = function() fake.walkTarget = nil end
  player.autoWalk = function(_, dest)
    fake.walkSends = fake.walkSends + 1
    if fake.walkBlocked then return false end
    fake.walkTarget = { x = dest.x, y = dest.y, z = dest.z }
    return true
  end
  player.getName = function() return 'Tester' end

  env.g_game.attack = function(creature)
    fake.attacking = creature
    fake.attacks[#fake.attacks + 1] = creature and creature:getName()
  end
  env.g_game.cancelAttack = function() fake.attacking = nil end
  env.g_game.getAttackingCreature = function() return fake.attacking end
  env.g_game.talk = function(text) fake.talks[#fake.talks + 1] = text end
  env.g_game.walk = function() if fake.walkBlocked then return false end return true end
  env.g_game.useInventoryItem = function(id) fake.itemUsesById[id] = (fake.itemUsesById[id] or 0) + 1 end
  env.g_game.use = function(thing) fake.usedThing = thing end
  env.g_map.findPath = function() return {} end
  env.g_keyboard = {
    bindKeyDown = function(key, fn) fake.hotkeys[key] = fn end,
    unbindKeyDown = function(key) fake.hotkeys[key] = nil end
  }
  env.g_window = {
    setClipboardText = function(text) fake.clipboard = text end,
    getClipboardText = function() return fake.clipboard end,
    flash = function() fake.flashes = (fake.flashes or 0) + 1 end
  }
  env.modules.game_textmessage = { displayFailureMessage = function(text) fake.lastAlert = text end }
  env.KeyEnter = 13
  local createWidget = env.g_ui.createWidget
  env.g_ui.createWidget = function(name, parent)
    local w = createWidget(name, parent)
    if name == 'HuntWindow' then fake.window = w end
    return w
  end

  -- um passo a cada 100 ms ate o destino do autoWalk
  env.cycleEvent(function()
    if fake.walkTarget and not fake.walkBlocked then
      if fake.playerPos.x == fake.walkTarget.x and fake.playerPos.y == fake.walkTarget.y and fake.playerPos.z == fake.walkTarget.z then
        fake.walkTarget = nil
      else
        fake.playerPos = stepTowards(fake.playerPos, fake.walkTarget)
        fake.steps = fake.steps + 1
        if fake.walkTarget.z ~= fake.playerPos.z then fake.walkTarget = nil end
      end
    end
  end, 100)

  function fake:loadModule(name, file)
    local function loadWithEnv(path)
      local fn = assert(loadfile(path))
      setfenv(fn, env)
      return fn
    end
    env.modules[name] = env
    setmetatable(env, { __index = _G })
    env.dofile = function(path)
      local resolved = path:gsub('^/modules/', self.modulesDir .. '/')
      return loadWithEnv(resolved)()
    end
    loadWithEnv(self.modulesDir .. '/' .. name .. '/' .. file)()
    return env
  end

  function fake:monster(options)
    local creature = self:creature(options)
    self.spectators = self.spectators or {}
    table.insert(self.spectators, creature)
    return creature
  end

  function fake:player(name, position)
    local creature = self:creature({ name = name, position = position, monster = false })
    self.spectators = self.spectators or {}
    table.insert(self.spectators, creature)
    return creature
  end

  function fake:removeCreature(creature)
    for index, other in ipairs(self.spectators or {}) do
      if other == creature then table.remove(self.spectators, index); break end
    end
    if self.attacking == creature then self.attacking = nil end
  end

  function fake:kill(creature)
    self:health(creature, 0)
    self:removeCreature(creature)
  end

  return fake
end

return HuntFake
