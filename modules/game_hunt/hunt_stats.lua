-- Contadores da sessao de Hunt (abates, XP, voltas, distancia).
local HuntStats = {}
HuntStats.__index = HuntStats

function HuntStats.new()
  local self = setmetatable({}, HuntStats)
  self:reset(0)
  return self
end

function HuntStats:reset(now)
  self.startedAt = nil
  self.accumulatedMs = 0
  self.kills = 0
  self.killsByName = {}
  self.experience = 0
  self.laps = 0
  self.steps = 0
  self.shiniesSeen = 0
  self.skippedWaypoints = 0
  self.catchBase = nil
  self.resetAt = now or 0
end

function HuntStats:start(now)
  if not self.startedAt then self.startedAt = now end
end

function HuntStats:stop(now)
  if self.startedAt then
    self.accumulatedMs = self.accumulatedMs + math.max(0, now - self.startedAt)
    self.startedAt = nil
  end
end

function HuntStats:elapsedMs(now)
  local running = self.startedAt and math.max(0, now - self.startedAt) or 0
  return self.accumulatedMs + running
end

function HuntStats:recordKill(name)
  self.kills = self.kills + 1
  local key = tostring(name or 'Pokemon')
  self.killsByName[key] = (self.killsByName[key] or 0) + 1
end

function HuntStats:recordExperience(amount)
  amount = tonumber(amount) or 0
  if amount > 0 then self.experience = self.experience + amount end
end

function HuntStats:perHour(value, now)
  local hours = self:elapsedMs(now) / 3600000
  if hours < (1 / 120) then return 0 end -- menos de 30 s: taxa nao significa nada
  return math.floor(value / hours + 0.5)
end

-- "1:05:09" / "12:03"
function HuntStats.formatDuration(ms)
  local total = math.floor((ms or 0) / 1000)
  local hours = math.floor(total / 3600)
  local minutes = math.floor((total % 3600) / 60)
  local seconds = total % 60
  if hours > 0 then return string.format('%d:%02d:%02d', hours, minutes, seconds) end
  return string.format('%02d:%02d', minutes, seconds)
end

-- 1234567 -> "1.23M", 12345 -> "12.3k"
function HuntStats.formatNumber(value)
  value = tonumber(value) or 0
  if value >= 1000000 then return string.format('%.2fM', value / 1000000) end
  if value >= 10000 then return string.format('%.1fk', value / 1000) end
  return tostring(math.floor(value))
end

-- Mais abatidos primeiro: { {name, count}, ... }
function HuntStats:topKills(limit)
  local list = {}
  for name, count in pairs(self.killsByName) do list[#list + 1] = { name = name, count = count } end
  table.sort(list, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.name < b.name
  end)
  local out = {}
  for index = 1, math.min(limit or #list, #list) do out[index] = list[index] end
  return out
end

-- XP de mensagens do servidor (pt/en): "Voce ganhou 1.234 pontos de experiencia",
-- "You gained 1234 experience points."
function HuntStats.parseExperience(text)
  if type(text) ~= 'string' then return nil end
  local lowerText = text:lower()
  if not (lowerText:find('experi', 1, true) or lowerText:find('exp', 1, true)) then return nil end
  if lowerText:find('jogador', 1, true) or lowerText:find('player', 1, true) then return nil end
  local number = lowerText:match('ganhou%s+([%d%.,]+)') or lowerText:match('gained%s+([%d%.,]+)')
    or lowerText:match('%+%s*([%d%.,]+)%s*exp')
  if not number then return nil end
  local digits = number:gsub('[%.,]', '')
  local value = tonumber(digits)
  if not value or value <= 0 then return nil end
  return value
end

return HuntStats
