-- discord/init.lua : pintu masuk `require('discord')`.
-- Memuat library native (libdiscord.so), menggabungkannya dengan builder Lua, dan menyediakan Client bergaya discord.js:
--   client:slash(builder, handler)  -> daftarkan slash command + routing otomatis
--   handler(ctx): ctx.options, ctx:reply(...), ctx:defer(), ctx:edit(...)
--   client:button(id, fn) / client:select(id, fn) / client:modal(id, fn) / client:autocomplete(command, fn)
--   ctx:update(...), ctx:deferUpdate(), ctx:showModal(modal), ctx:respond(choices), ctx.customId, ctx.values, ctx.fields
-- Path library native: global DISCORD_LIB, atau bawaan di bawah.
local NAME = (...) or 'discord'
local M = {}
M.lua_version = '0.2.0'

------------------------------------------------------------ library native
local LIB = rawget(_G, 'DISCORD_LIB') or '/data/data/com.rtsoft.growtopia/libdiscord.so'
local open, err = package.loadlib(LIB, 'luaopen_discord')
if not open then error('libdiscord: tidak bisa memuat ' .. LIB .. ': ' .. tostring(err), 2) end
local native = open()
for k, v in pairs(native) do M[k] = v end          -- connect, request, now, version, tls, bot (API mentah)

local json = require(NAME .. '.json')
local B = require(NAME .. '.builders')
for k, v in pairs(B) do M[k] = v end
M.json = json

local function log(msg)
  local f = rawget(_G, 'LogToConsole')
  if f then f('[discord] ' .. tostring(msg)) end
end

------------------------------------------------------------ payload pesan
-- string -> dikirim sebagai teks biasa. Tabel/EmbedBuilder -> JSON lengkap (embeds, components V2, dst).
local function message_data(payload, ephemeral)
  if getmetatable(payload) == B.EmbedBuilder then payload = { embeds = { payload } } end
  if type(payload) ~= 'table' then error('payload harus string, EmbedBuilder, atau tabel', 3) end
  local d = {}
  for k, v in pairs(payload) do d[k] = v end
  if d.ephemeral ~= nil then ephemeral = ephemeral or d.ephemeral; d.ephemeral = nil end
  if getmetatable(d.embeds) == B.EmbedBuilder then d.embeds = { d.embeds } end
  if type(d.content) == 'string' and (utf8 and utf8.len(d.content) or #d.content) > 2000 then error('content maksimal 2000 karakter', 3) end
  if d.embeds and #d.embeds > 10 then error('maksimal 10 embed per pesan', 3) end
  if ephemeral then d.flags = (d.flags or 0) | B.MessageFlags.Ephemeral end
  if d.flags and (d.flags & B.MessageFlags.IsComponentsV2) ~= 0 and (d.content or d.embeds) then
    error('Components V2 tidak bisa dipadukan dengan content/embeds', 3)
  end
  if d.allowed_mentions == nil then d.allowed_mentions = { parse = json.array({}) } end   -- tidak ada mention otomatis
  return d
end

------------------------------------------------------------ Context (satu per interaction)
local Context = {}
Context.__index = Context

local Fields = {}
Fields.__index = Fields
function Fields:getTextInputValue(id) return self.values[id] end   -- nil bila tidak ada (discord.js melempar error)

local function collect_fields(node, out, depth)     -- cari {custom_id, value|values} di seluruh komponen modal
  if type(node) ~= 'table' or depth > 8 then return end
  if type(node.custom_id) == 'string' then
    if node.value ~= nil then out[node.custom_id] = node.value
    elseif node.values ~= nil then out[node.custom_id] = node.values end
  end
  for _, ch in ipairs(node.components or {}) do collect_fields(ch, out, depth + 1) end
  if node.component then collect_fields(node.component, out, depth + 1) end
end

function Context.new(client, ev)
  local it = ev.interaction_type or 2
  local ctx = setmetatable({
    client = client, ev = ev, id = ev.id, token = ev.token, name = ev.name, sub = ev.sub, options = ev.options or {},
    user_id = ev.user_id, user = ev.user, channel_id = ev.channel_id, guild_id = ev.guild_id, replied = false, deferred = false,
    interaction_type = it, customId = ev.custom_id, componentType = ev.component_type, message_id = ev.message_id, focused = ev.focused,
  }, Context)
  if (it == 3 or it == 5) and ev.data then
    local d = native.json_decode(ev.data)
    if type(d) == 'table' then
      if it == 3 then ctx.values = d.values or {} end                      -- select: nilai yang dipilih (array string)
      if it == 5 then local v = {}; collect_fields(d, v, 0); ctx.fields = setmetatable({ values = v }, Fields) end
    end
  end
  return ctx
end

local function need_type(self, what, ...)
  for _, t in ipairs { ... } do if self.interaction_type == t then return end end
  error(('ctx:%s tidak tersedia untuk jenis interaction ini'):format(what), 3)
end
local function callback(self, body)
  return self.client.bot:rest('POST', '/interactions/' .. self.id .. '/' .. self.token .. '/callback', json.encode(body))
end

-- ctx:reply("teks" | EmbedBuilder | {content=, embeds={...}, ephemeral=true} | ComponentsV2(...) [, {ephemeral=true}])
function Context:reply(payload, opts)
  local eph = opts and opts.ephemeral
  local bot = self.client.bot
  self.replied = true
  if type(payload) == 'string' then return bot:reply(self.ev, payload, eph) end
  local body = json.encode({ type = 4, data = message_data(payload, eph) })
  return bot:rest('POST', '/interactions/' .. self.id .. '/' .. self.token .. '/callback', body)
end

function Context:defer(ephemeral)
  self.deferred, self.replied = true, true
  return self.client.bot:defer(self.ev, ephemeral)
end

-- ubah balasan asli (setelah reply atau defer)
function Context:edit(payload)
  local bot = self.client.bot
  if type(payload) == 'string' then return bot:edit(self.ev, payload) end
  local app = self.client.app_id
  if not app then return nil, 'app_id belum diketahui (tunggu event ready)' end
  local body = json.encode(message_data(payload))
  return bot:rest('PATCH', '/webhooks/' .. app .. '/' .. self.token .. '/messages/@original', body)
end

-- ctx:update("teks" | {content=, embeds=, components=} | ComponentsV2(...))  ubah pesan tempat tombol/select berada (type 7)
function Context:update(payload)
  need_type(self, 'update', 3, 5)
  if type(payload) == 'string' then payload = { content = payload } end
  self.replied = true
  return callback(self, { type = 7, data = message_data(payload) })
end

-- ctx:deferUpdate()  ack tanpa mengubah apa pun (type 6); setelah ini ctx:edit(...) mengubah pesan asal
function Context:deferUpdate()
  need_type(self, 'deferUpdate', 3, 5)
  self.deferred, self.replied, self.deferredUpdate = true, true, true
  return callback(self, { type = 6 })
end

-- ctx:showModal(ModalBuilder)  tampilkan form (type 9); hanya dari slash command atau tombol/select
function Context:showModal(modal)
  need_type(self, 'showModal', 2, 3)
  if type(modal) ~= 'table' or type(modal.toJSON) ~= 'function' then error('showModal butuh ModalBuilder', 2) end
  self.replied = true
  return callback(self, { type = 9, data = modal:toJSON() })
end

-- ctx:respond({ 'a', 'b' } | { {name=, value=}, ... })  jawab autocomplete (type 8), maks 25 pilihan
function Context:respond(choices)
  need_type(self, 'respond', 4)
  if type(choices) ~= 'table' then error('choices harus berupa array', 2) end
  local list = {}
  for i, c in ipairs(choices) do
    if i > 25 then error('maksimal 25 pilihan autocomplete', 2) end
    if type(c) == 'string' or type(c) == 'number' then c = { name = tostring(c), value = c } end
    if type(c) ~= 'table' or type(c.name) ~= 'string' or #c.name < 1 or #c.name > 100 then error('pilihan butuh name 1..100 karakter', 2) end
    if not (type(c.value) == 'number' or (type(c.value) == 'string' and #c.value <= 100)) then error('value pilihan harus angka atau string maks 100 karakter', 2) end
    list[i] = { name = c.name, value = c.value }
  end
  self.replied = true
  return callback(self, { type = 8, data = { choices = json.array(list) } })
end

------------------------------------------------------------ Client
local Client = {}
Client.__index = function(self, k)
  local v = Client[k]
  if v ~= nil then return v end
  local bot = rawget(self, 'bot')
  local f = bot and bot[k]
  if f ~= nil then return function(_, ...) return f(bot, ...) end end   -- poll/status/close/ping/presence/command/rest/...
end

local CORE_EVENTS = { 'message', 'ready', 'status', 'interaction', 'rest_response', 'rest_error' }

-- discord.Client(token [, opts]) -> client | nil, err.  opts sama dengan discord.bot (intents, ignore_bots, ...).
-- Untuk bot slash-only pakai {intents = 0}. Dipanggil dari body script utama (memasang hook OnDraw otomatis).
function M.Client(token, opts)
  local bot, e = native.bot(token, opts)
  if not bot then return nil, e end
  local self = setmetatable({ bot = bot, handlers = {}, autocompletes = {}, listeners = {}, routes = {
    button = { exact = {}, prefix = {} }, select = { exact = {}, prefix = {} }, modal = { exact = {}, prefix = {} } } }, Client)
  for _, ev in ipairs(CORE_EVENTS) do
    bot:on(ev, function(data) self:_emit(ev, data) end)
  end
  return self
end

function Client:on(name, fn)
  local l = self.listeners[name] or {}
  self.listeners[name] = l
  l[#l + 1] = fn
  return self
end

function Client:_emit(name, ev)
  if name == 'ready' then self.app_id = ev.app_id
  elseif name == 'interaction' then self:_dispatch(ev) end
  for _, key in ipairs { name, '*' } do
    for _, fn in ipairs(self.listeners[key] or {}) do
      local ok, e = pcall(fn, ev)
      if not ok then log('error di listener ' .. name .. ': ' .. tostring(e)) end
    end
  end
end

local function route_find(t, id)
  if type(id) ~= 'string' then return nil end
  local h = t.exact[id]
  if h then return h end
  local best, bl = nil, -1                              -- pola "awalan*": yang terpanjang menang
  for p, fn in pairs(t.prefix) do if #p > bl and id:sub(1, #p) == p then best, bl = fn, #p end end
  return best
end

function Client:_dispatch(ev)
  local it = ev.interaction_type or 2
  local h, label
  if it == 2 then h, label = self.handlers[ev.name], 'command /' .. tostring(ev.name)
  elseif it == 4 then h, label = self.autocompletes[ev.name], 'autocomplete /' .. tostring(ev.name)
  elseif it == 3 then
    local kind = ev.component_type == 2 and 'button' or 'select'
    h, label = route_find(self.routes[kind], ev.custom_id), kind .. ' ' .. tostring(ev.custom_id)
  elseif it == 5 then h, label = route_find(self.routes.modal, ev.custom_id), 'modal ' .. tostring(ev.custom_id) end
  if not h then return end
  local ctx = Context.new(self, ev)
  local ok, res = pcall(h, ctx)
  if not ok then
    log('error di ' .. label .. ': ' .. tostring(res))
    if it == 4 then
      if not ctx.replied then pcall(ctx.respond, ctx, {}) end                  -- autocomplete harus dijawab (kosong)
    elseif ctx.deferredUpdate then                                              -- jangan menimpa pesan asal dengan teks error
    elseif ctx.deferred then ctx:edit('Terjadi error saat menjalankan command')
    elseif not ctx.replied then ctx:reply('Terjadi error saat menjalankan command', { ephemeral = true }) end
  elseif res ~= nil and not ctx.replied then
    if it == 4 then ctx:respond(res) else ctx:reply(res) end                    -- handler boleh langsung mengembalikan balasan
  end
end

-- client:slash(SlashCommandBuilder, function(ctx) ... end)
function Client:slash(builder, handler)
  if type(handler) ~= 'function' then error('handler harus berupa fungsi', 2) end
  local name, desc, opts = builder:build()
  local ok, e = self.bot:command(name, desc, opts)
  if not ok then error('gagal mendaftarkan /' .. name .. ': ' .. tostring(e), 2) end
  self.handlers[name] = handler
  return self
end

-- client:button(custom_id, fn) / client:select(custom_id, fn) / client:modal(custom_id, fn)
-- custom_id persis, atau "awalan*" untuk semua id berawalan itu (ctx.customId berisi id lengkap, mis. "vote:3").
local function add_route(self, kind, id, handler)
  if type(id) ~= 'string' or #id < 1 or #id > 100 then error('custom_id harus string 1..100 karakter', 3) end
  if type(handler) ~= 'function' then error('handler harus berupa fungsi', 3) end
  local t = self.routes[kind]
  if id:sub(-1) == '*' then t.prefix[id:sub(1, -2)] = handler else t.exact[id] = handler end
  return self
end
function Client:button(id, handler) return add_route(self, 'button', id, handler) end
function Client:select(id, handler) return add_route(self, 'select', id, handler) end
function Client:modal(id, handler) return add_route(self, 'modal', id, handler) end

-- client:autocomplete(nama_command, function(ctx) ... end)  ctx.focused = {name=, value=}; ctx:respond(choices) atau return choices
function Client:autocomplete(command, handler)
  if type(command) ~= 'string' or not command:match('^[%l%d_%-]+$') then error('nama command tidak valid', 2) end
  if type(handler) ~= 'function' then error('handler harus berupa fungsi', 2) end
  self.autocompletes[command] = handler
  return self
end

-- client:send(channel_id, "teks" | EmbedBuilder | tabel | ComponentsV2(...) [, tag])
function Client:send(channel, payload, tag)
  if type(payload) == 'string' then return self.bot:send(channel, payload, tag) end
  if type(channel) ~= 'string' or #channel > 24 or not channel:match('^%d+$') then return nil, 'channel_id tidak valid' end
  return self.bot:rest('POST', '/channels/' .. channel .. '/messages', json.encode(message_data(payload)), tag)
end

return M
