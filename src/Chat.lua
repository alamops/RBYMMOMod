-- Chat: the scrollback the chat screen reads.
--
-- Scope routing is the hub's job, not this module's -- a client that
-- filtered "local" itself would still have received the text, which is not
-- what a local message means.  What lives here is presentation: what the
-- player sees, and in what order.
--
-- It used to own the speech bubbles that floated over heads as well, and
-- those are gone.  A line now appears as a toast in the corner
-- (src/Toast.lua), which is a strictly better place for it: the toast
-- carries the sender's name, it is legible at any window size in a font that
-- has lowercase, and it does not need the sender to be standing on screen --
-- so a whisper from three maps away is finally visible at all.

local need = ...
local Config = need("Config")

local M = {}
M.__index = M

-- One-character scope tags.  The chat box is 20 tiles wide at Game Boy
-- resolution, so a full word per line would cost a third of it.
M.TAG = { global = "G", ["local"] = "L", private = "W", party = "P" }

function M.new()
  return setmetatable({ history = {}, unread = 0 }, M)
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

function M:clear()
  self.history, self.unread = {}, 0
end

return M
