-- Chat: the scrollback the chat screen reads, and the speech bubbles that
-- float over heads in the overworld.
--
-- Scope routing is the hub's job, not this module's -- a client that
-- filtered "local" itself would still have received the text, which is not
-- what a local message means.  What lives here is presentation: what the
-- player sees, in what order, and for how long.

local need = ...
local Config = need("Config")

local M = {}
M.__index = M

-- One-character scope tags.  The chat box is 20 tiles wide at Game Boy
-- resolution, so a full word per line would cost a third of it.
M.TAG = { global = "G", ["local"] = "L", private = "W", party = "P" }

function M.new()
  return setmetatable({ history = {}, bubbles = {}, unread = 0 }, M)
end

-- entry: { name, scope, text, from, outgoing }
function M:push(entry)
  if not (entry and entry.text) then return nil end
  self.history[#self.history + 1] = entry
  while #self.history > Config.CHAT_HISTORY do
    table.remove(self.history, 1)
  end
  if not entry.outgoing then self.unread = self.unread + 1 end
  return entry
end

function M:markRead() self.unread = 0 end

-- newest last, which is the order the chat screen scrolls
function M:recent(count)
  local out = {}
  local first = math.max(1, #self.history - (count or Config.CHAT_HISTORY) + 1)
  for i = first, #self.history do out[#out + 1] = self.history[i] end
  return out
end

function M:line(entry)
  local tag = M.TAG[entry.scope] or "?"
  return ("[%s]%s: %s"):format(tag, entry.name, entry.text)
end

-- A bubble replaces whatever that player was already saying: two lines at
-- once over one head is unreadable, and the newer line is the one that
-- matters.  Private messages never bubble -- a whisper drawn over the
-- sender's head in the middle of the world is not private.
--
-- Party messages do bubble, and that is not an exception to the rule above
-- but the same rule applied.  A bubble is drawn only in the game of
-- somebody who *received* the line, and the hub sends a party line to the
-- party and nobody else -- so the only screen it can appear on is your
-- partner's.  Seeing what they said float over their head as you walk
-- together is the point of travelling together.
function M:bubble(playerId, text, scope)
  if scope == "private" then return nil end
  if not (playerId and text) then return nil end
  self.bubbles[playerId] = { text = text, age = 0 }
  return self.bubbles[playerId]
end

function M:bubbleFor(playerId)
  local bubble = self.bubbles[playerId]
  return bubble and bubble.text or nil
end

function M:update(dt)
  for id, bubble in pairs(self.bubbles) do
    bubble.age = bubble.age + (dt or 0)
    if bubble.age >= Config.BUBBLE_SECONDS then self.bubbles[id] = nil end
  end
end

function M:clear()
  self.history, self.bubbles, self.unread = {}, {}, 0
end

return M
