-- discord/builders.lua : SlashCommandBuilder, EmbedBuilder, Components V2, serta tombol/select/modal interaktif, gaya discord.js.
-- Semua builder fluent (method mengembalikan self), bisa dipanggil sebagai Kelas() atau Kelas.new(), dan punya toJSON().
-- Batas Discord divalidasi saat membangun, jadi kesalahan muncul sebagai error Lua yang jelas (bukan 400 dari REST).
local PREFIX = (...) and (...):match('^(.*)%.builders$') or 'discord'
local json = require(PREFIX .. '.json')

local B = {}

------------------------------------------------------------ helper
local function ulen(s) return (utf8 and utf8.len(s)) or #s end

local function class()
  local c = {}
  c.__index = c
  return setmetatable(c, { __call = function(cls, ...) return cls.new(...) end })
end

local function str(v, what, min, max)
  if type(v) ~= 'string' then error(what .. ' harus berupa string', 3) end
  local n = ulen(v)
  if n < min or n > max then error(('%s harus %d..%d karakter (sekarang %d)'):format(what, min, max, n), 3) end
  return v
end

local function url(v, what)
  str(v, what, 1, 2000)
  if not v:match('^https?://') then error(what .. ' harus diawali http:// atau https://', 3) end
  return v
end

local function color(c)
  if type(c) == 'string' then c = tonumber((c:gsub('^#', ''):gsub('^0[xX]', '')), 16) end
  if math.type(c) ~= 'integer' or c < 0 or c > 0xFFFFFF then error('warna harus angka 0..0xFFFFFF atau string "#RRGGBB"', 3) end
  return c
end

local function jsonable(x) -- builder -> tabel biasa
  if type(x) == 'table' and type(x.toJSON) == 'function' then return x:toJSON() end
  return x
end

B.MessageFlags = { Ephemeral = 64, IsComponentsV2 = 32768 }

------------------------------------------------------------ SlashCommandBuilder
local TYPES = { string = 3, integer = 4, boolean = 5, user = 6, channel = 7, role = 8, number = 10 }
local NAME_PAT = '^[%l%d_%-]+$'

local function cmd_name(v, what)
  str(v, what, 1, 32)
  if not v:match(NAME_PAT) then error(what .. ' hanya boleh huruf kecil a-z, angka, "_" dan "-"', 3) end
  return v
end

local Option = class()
function Option.new(kind) return setmetatable({ _kind = kind, _type = TYPES[kind] }, Option) end
function Option:setName(v) self._name = cmd_name(v, 'nama opsi') return self end
function Option:setDescription(v) self._desc = str(v, 'deskripsi opsi', 1, 100) return self end
function Option:setRequired(b) self._required = b and true or false return self end
local function need_kind(self, what, ...)
  for _, k in ipairs { ... } do if self._kind == k then return end end
  error(what .. ' tidak berlaku untuk opsi bertipe ' .. self._kind, 3)
end
function Option:setMinValue(n) need_kind(self, 'setMinValue', 'integer', 'number') self._min = n return self end
function Option:setMaxValue(n) need_kind(self, 'setMaxValue', 'integer', 'number') self._max = n return self end
function Option:setMinLength(n) need_kind(self, 'setMinLength', 'string') self._minlen = n return self end
function Option:setMaxLength(n) need_kind(self, 'setMaxLength', 'string') self._maxlen = n return self end
function Option:addChoices(...)
  need_kind(self, 'addChoices', 'string', 'integer', 'number')
  self._choices = self._choices or {}
  for _, ch in ipairs { ... } do
    if #self._choices >= 25 then error('maksimal 25 pilihan', 2) end
    str(ch.name, 'nama pilihan', 1, 100)
    local v = ch.value
    if self._kind == 'string' then str(v, 'nilai pilihan', 1, 100)
    elseif self._kind == 'integer' and math.type(v) ~= 'integer' then error('nilai pilihan harus integer', 2)
    elseif self._kind == 'number' and type(v) ~= 'number' then error('nilai pilihan harus angka', 2) end
    self._choices[#self._choices + 1] = { name = ch.name, value = v }
  end
  return self
end
function Option:toJSON()
  if not self._name then error('ada opsi yang belum diberi nama (setName)', 2) end
  if not self._desc then error('opsi "' .. self._name .. '" belum diberi deskripsi (setDescription)', 2) end
  return {
    type = self._type, name = self._name, description = self._desc, required = self._required or nil,
    choices = self._choices, min_value = self._min, max_value = self._max, min_length = self._minlen, max_length = self._maxlen,
  }
end

local SPEC_SETTERS = {
  name = 'setName', description = 'setDescription', required = 'setRequired', min_value = 'setMinValue',
  max_value = 'setMaxValue', min_length = 'setMinLength', max_length = 'setMaxLength',
}

local function add_option(self, kind, spec)
  if #self._options >= 25 then error('maksimal 25 opsi', 3) end
  if self._subs and #self._subs > 0 then error('opsi dan subcommand tidak boleh dicampur', 3) end
  local o = Option.new(kind)
  if type(spec) == 'function' then o = spec(o) or o
  elseif type(spec) == 'table' then
    for k, setter in pairs(SPEC_SETTERS) do if spec[k] ~= nil then o[setter](o, spec[k]) end end
    if spec.choices then o:addChoices(table.unpack(spec.choices)) end
  else error('addXOption menerima fungsi(opt) atau tabel spesifikasi', 3) end
  local js = o:toJSON()
  for _, prev in ipairs(self._options) do
    if prev._name == js.name then error('nama opsi ganda: ' .. js.name, 3) end
    if js.required and not prev._required then error('opsi wajib harus ditaruh sebelum opsi opsional: ' .. js.name, 3) end
  end
  self._options[#self._options + 1] = o
  return self
end

local function options_json(list)
  local out = {}
  for i, o in ipairs(list) do out[i] = o:toJSON() end
  return out
end

local function install_option_adders(cls)
  for kind in pairs(TYPES) do
    cls['add' .. kind:sub(1, 1):upper() .. kind:sub(2) .. 'Option'] = function(self, spec) return add_option(self, kind, spec) end
  end
end

local Subcommand = class()
function Subcommand.new() return setmetatable({ _options = {} }, Subcommand) end
function Subcommand:setName(v) self._name = cmd_name(v, 'nama subcommand') return self end
function Subcommand:setDescription(v) self._desc = str(v, 'deskripsi subcommand', 1, 100) return self end
install_option_adders(Subcommand)
function Subcommand:toJSON()
  if not self._name or not self._desc then error('subcommand butuh setName dan setDescription', 2) end
  return { type = 1, name = self._name, description = self._desc, options = #self._options > 0 and options_json(self._options) or nil }
end

local Slash = class()
function Slash.new() return setmetatable({ _options = {}, _subs = {} }, Slash) end
function Slash:setName(v) self._name = cmd_name(v, 'nama command') return self end
function Slash:setDescription(v) self._desc = str(v, 'deskripsi command', 1, 100) return self end
install_option_adders(Slash)
function Slash:addSubcommand(spec)
  if #self._options > 0 then error('opsi dan subcommand tidak boleh dicampur', 2) end
  if #self._subs >= 25 then error('maksimal 25 subcommand', 2) end
  local s = Subcommand.new()
  if type(spec) == 'function' then s = spec(s) or s elseif type(spec) == 'table' and spec.toJSON then s = spec end
  s:toJSON()
  for _, p in ipairs(self._subs) do if p._name == s._name then error('nama subcommand ganda: ' .. s._name, 2) end end
  self._subs[#self._subs + 1] = s
  return self
end
function Slash:toJSON()
  if not self._name then error('command belum diberi nama (setName)', 2) end
  if not self._desc then error('command "' .. self._name .. '" belum diberi deskripsi (setDescription)', 2) end
  local opts = #self._subs > 0 and options_json(self._subs) or (#self._options > 0 and options_json(self._options) or nil)
  return { type = 1, name = self._name, description = self._desc, options = opts }
end
-- name, description, options_json (string atau nil): argumen persis untuk bot:command(...)
function Slash:build()
  local js = self:toJSON()
  return js.name, js.description, js.options and json.encode(js.options) or nil
end
B.SlashCommandBuilder = Slash
B.SlashCommandSubcommandBuilder = Subcommand

------------------------------------------------------------ EmbedBuilder
local Embed = class()
function Embed.new(data)
  local self = setmetatable({ _d = { fields = {} } }, Embed)
  if type(data) == 'table' then for k, v in pairs(data) do self._d[k] = v end self._d.fields = self._d.fields or {} end
  return self
end
function Embed:setTitle(v) self._d.title = v and str(v, 'title', 1, 256) or nil return self end
function Embed:setDescription(v) self._d.description = v and str(v, 'description', 1, 4096) or nil return self end
function Embed:setURL(v) self._d.url = v and url(v, 'url') or nil return self end
function Embed:setColor(c) self._d.color = c ~= nil and color(c) or nil return self end
function Embed:setTimestamp(t)
  if t == nil then t = os.time() end
  self._d.timestamp = type(t) == 'number' and os.date('!%Y-%m-%dT%H:%M:%SZ', t) or str(t, 'timestamp', 1, 64)
  return self
end
function Embed:setFooter(a, icon)
  if type(a) == 'table' then a, icon = a.text, a.iconURL or a.icon_url end
  self._d.footer = a and { text = str(a, 'footer', 1, 2048), icon_url = icon and url(icon, 'icon footer') or nil } or nil
  return self
end
function Embed:setAuthor(a, icon, link)
  if type(a) == 'table' then a, icon, link = a.name, a.iconURL or a.icon_url, a.url end
  self._d.author = a and { name = str(a, 'author', 1, 256), icon_url = icon and url(icon, 'icon author') or nil, url = link and url(link, 'url author') or nil } or nil
  return self
end
function Embed:setThumbnail(u) self._d.thumbnail = u and { url = url(u, 'thumbnail') } or nil return self end
function Embed:setImage(u) self._d.image = u and { url = url(u, 'image') } or nil return self end
function Embed:addFields(...)
  for _, f in ipairs { ... } do
    if #self._d.fields >= 25 then error('maksimal 25 field per embed', 2) end
    self._d.fields[#self._d.fields + 1] = {
      name = str(f.name, 'nama field', 1, 256), value = str(f.value, 'nilai field', 1, 1024), inline = f.inline and true or nil,
    }
  end
  return self
end
function Embed:toJSON()
  local d = self._d
  local total = ulen(d.title or '') + ulen(d.description or '') + ulen(d.footer and d.footer.text or '') + ulen(d.author and d.author.name or '')
  for _, f in ipairs(d.fields) do total = total + ulen(f.name) + ulen(f.value) end
  if total > 6000 then error(('total teks embed %d karakter, maksimal 6000'):format(total), 2) end
  local out = {}
  for k, v in pairs(d) do out[k] = v end
  if #d.fields == 0 then out.fields = nil end
  return out
end
B.EmbedBuilder = Embed

------------------------------------------------------------ Components V2 (tampilan; tombol/select di dalamnya memakai builder interaktif di bawah)
local TextDisplay = class()
function TextDisplay.new(content) local s = setmetatable({}, TextDisplay) if content ~= nil then s:setContent(content) end return s end
function TextDisplay:setContent(v) self._content = str(v, 'isi teks', 1, 4000) return self end
function TextDisplay:toJSON()
  if not self._content then error('TextDisplay belum punya isi', 2) end
  return { type = 10, content = self._content }
end

local Separator = class()
function Separator.new(divider, spacing) return setmetatable({ _divider = divider ~= false, _spacing = spacing or 1 }, Separator) end
function Separator:setDivider(b) self._divider = b and true or false return self end
function Separator:setSpacing(n)
  if n ~= 1 and n ~= 2 then error('spacing harus 1 (kecil) atau 2 (besar)', 2) end
  self._spacing = n return self
end
function Separator:toJSON() return { type = 14, divider = self._divider, spacing = self._spacing } end

local Thumbnail = class()
function Thumbnail.new(u, description, spoiler)
  return setmetatable({ _url = u and url(u, 'url thumbnail') or nil, _desc = description, _spoiler = spoiler }, Thumbnail)
end
function Thumbnail:setURL(u) self._url = url(u, 'url thumbnail') return self end
function Thumbnail:setDescription(d) self._desc = str(d, 'deskripsi thumbnail', 1, 1024) return self end
function Thumbnail:setSpoiler(b) self._spoiler = b and true or false return self end
function Thumbnail:toJSON()
  if not self._url then error('Thumbnail belum punya url', 2) end
  return { type = 11, media = { url = self._url }, description = self._desc, spoiler = self._spoiler or nil }
end

local MediaGallery = class()
function MediaGallery.new() return setmetatable({ _items = {} }, MediaGallery) end
function MediaGallery:addItems(...)
  for _, it in ipairs { ... } do
    if #self._items >= 10 then error('maksimal 10 item per MediaGallery', 2) end
    if type(it) == 'string' then it = { url = it } end
    self._items[#self._items + 1] = {
      media = { url = url(it.url, 'url media') }, description = it.description and str(it.description, 'deskripsi media', 1, 1024) or nil,
      spoiler = it.spoiler and true or nil,
    }
  end
  return self
end
function MediaGallery:toJSON()
  if #self._items == 0 then error('MediaGallery butuh minimal 1 item', 2) end
  return { type = 12, items = self._items }
end

------------------------------------------------------------ komponen interaktif (tombol, select, modal)
-- Event-nya sampai lewat interaction type 3/4/5 (native 0.6.2+); routing: client:button / client:select / client:modal / client:autocomplete.
B.ButtonStyle = { Primary = 1, Secondary = 2, Success = 3, Danger = 4, Link = 5 }
B.TextInputStyle = { Short = 1, Paragraph = 2 }

local function custom_id(v) return str(v, 'custom_id', 1, 100) end
local function int_range(v, what, min, max)
  if math.type(v) ~= 'integer' or v < min or v > max then error(('%s harus bilangan bulat %d..%d'):format(what, min, max), 3) end
  return v
end
local function emoji(e)
  if type(e) == 'string' then return { name = str(e, 'emoji', 1, 64) } end
  if type(e) == 'table' and (e.name or e.id) then return e end
  error('emoji harus string (unicode) atau tabel {name=, id=, animated=}', 3)
end

local Button = class()   -- ButtonBuilder():setCustomId('x'):setLabel('Klik'):setStyle(ButtonStyle.Primary)   |   tombol link: setURL
function Button.new(label, u)    -- ButtonBuilder(label, url) tetap membuat tombol link (kompatibel 0.1.0)
  local b = setmetatable({}, Button)
  if label ~= nil then b._label = str(label, 'label tombol', 1, 80) end
  if u ~= nil then b._url = url(u, 'url tombol'); b._style = 5 end
  return b
end
function Button.link(label, u)
  local b = Button.new()
  b._label, b._url, b._style = str(label, 'label tombol', 1, 80), url(u, 'url tombol'), 5
  return b
end
function Button:setCustomId(v) self._custom_id = custom_id(v) return self end
function Button:setLabel(v) self._label = str(v, 'label tombol', 1, 80) return self end
function Button:setStyle(v) self._style = int_range(v, 'style tombol', 1, 5) return self end
function Button:setURL(v) self._url = url(v, 'url tombol'); self._style = 5 return self end
function Button:setEmoji(e) self._emoji = emoji(e) return self end
function Button:setDisabled(b) self._disabled = b ~= false return self end
function Button:toJSON()
  local style = self._style
  if not style then error('tombol butuh style (setStyle) atau url (setURL)', 2) end
  local d = { type = 2, style = style, label = self._label, emoji = self._emoji, disabled = self._disabled or nil }
  if style == 5 then
    if not self._url then error('tombol link butuh url (setURL)', 2) end
    if self._custom_id then error('tombol link tidak boleh punya custom_id', 2) end
    d.url = self._url
  else
    if not self._custom_id then error('tombol non-link butuh custom_id (setCustomId)', 2) end
    if self._url then error('hanya tombol link yang boleh punya url', 2) end
    d.custom_id = self._custom_id
  end
  if not d.label and not d.emoji then error('tombol butuh label atau emoji', 2) end
  return d
end

-- Select menu: String (type 3, dengan opsi), User (5), Role (6), Mentionable (7), Channel (8)
local SelectOption = class()
function SelectOption.new(spec)
  local o = setmetatable({}, SelectOption)
  if spec then
    if spec.label ~= nil then o:setLabel(spec.label) end
    if spec.value ~= nil then o:setValue(spec.value) end
    if spec.description ~= nil then o:setDescription(spec.description) end
    if spec.emoji ~= nil then o:setEmoji(spec.emoji) end
    if spec.default ~= nil then o:setDefault(spec.default) end
  end
  return o
end
function SelectOption:setLabel(v) self._label = str(v, 'label opsi', 1, 100) return self end
function SelectOption:setValue(v) self._value = str(v, 'value opsi', 1, 100) return self end
function SelectOption:setDescription(v) self._desc = str(v, 'deskripsi opsi', 1, 100) return self end
function SelectOption:setEmoji(e) self._emoji = emoji(e) return self end
function SelectOption:setDefault(b) self._default = b ~= false return self end
function SelectOption:toJSON()
  if not self._label or not self._value then error('opsi select butuh label dan value', 2) end
  return { label = self._label, value = self._value, description = self._desc, emoji = self._emoji, default = self._default or nil }
end

local function select_class(type_id, has_options)
  local S = class()
  function S.new() return setmetatable({ _options = {} }, S) end
  function S:setCustomId(v) self._custom_id = custom_id(v) return self end
  function S:setPlaceholder(v) self._placeholder = str(v, 'placeholder', 1, 150) return self end
  function S:setMinValues(n) self._min = int_range(n, 'min_values', 0, 25) return self end
  function S:setMaxValues(n) self._max = int_range(n, 'max_values', 1, 25) return self end
  function S:setDisabled(b) self._disabled = b ~= false return self end
  if has_options then
    function S:addOptions(...)
      local list = { ... }
      local f = list[1]
      if #list == 1 and type(f) == 'table' and f.label == nil and f.toJSON == nil and f[1] ~= nil then list = f end
      for _, o in ipairs(list) do
        if #self._options >= 25 then error('maksimal 25 opsi per select menu', 2) end
        if type(o) ~= 'table' then error('opsi harus tabel {label=, value=} atau StringSelectMenuOptionBuilder', 2) end
        self._options[#self._options + 1] = o.toJSON and o or SelectOption.new(o)
      end
      return self
    end
  end
  if type_id == 8 then
    function S:setChannelTypes(...) self._channel_types = { ... } return self end
  end
  function S:toJSON()
    if not self._custom_id then error('select menu butuh custom_id (setCustomId)', 2) end
    if self._min and self._max and self._min > self._max then error('min_values tidak boleh lebih besar dari max_values', 2) end
    local d = { type = type_id, custom_id = self._custom_id, placeholder = self._placeholder,
      min_values = self._min, max_values = self._max, disabled = self._disabled or nil, channel_types = self._channel_types }
    if has_options then
      if #self._options == 0 then error('StringSelectMenu butuh minimal 1 opsi (addOptions)', 2) end
      d.options = {}
      for i, o in ipairs(self._options) do d.options[i] = o:toJSON() end
    end
    return d
  end
  return S
end
local StringSelect, UserSelect, RoleSelect = select_class(3, true), select_class(5), select_class(6)
local MentionableSelect, ChannelSelect = select_class(7), select_class(8)

local TextInput = class()   -- hanya untuk modal
function TextInput.new() return setmetatable({ _style = 1 }, TextInput) end
function TextInput:setCustomId(v) self._custom_id = custom_id(v) return self end
function TextInput:setLabel(v) self._label = str(v, 'label input', 1, 45) return self end
function TextInput:setStyle(v) self._style = int_range(v, 'style input', 1, 2) return self end
function TextInput:setPlaceholder(v) self._placeholder = str(v, 'placeholder', 1, 100) return self end
function TextInput:setValue(v) self._value = str(v, 'value', 1, 4000) return self end
function TextInput:setRequired(b) self._required = b ~= false return self end
function TextInput:setMinLength(n) self._minlen = int_range(n, 'min_length', 0, 4000) return self end
function TextInput:setMaxLength(n) self._maxlen = int_range(n, 'max_length', 1, 4000) return self end
function TextInput:toJSON()
  if not self._custom_id then error('input butuh custom_id (setCustomId)', 2) end
  if not self._label then error('input butuh label (setLabel)', 2) end
  if self._minlen and self._maxlen and self._minlen > self._maxlen then error('min_length tidak boleh lebih besar dari max_length', 2) end
  return { type = 4, custom_id = self._custom_id, label = self._label, style = self._style, placeholder = self._placeholder,
    value = self._value, required = self._required, min_length = self._minlen, max_length = self._maxlen }
end

local ActionRow = class()
function ActionRow.new() return setmetatable({ _items = {} }, ActionRow) end
local function row_push(self, c)
  if #self._items >= 5 then error('maksimal 5 tombol per ActionRow', 3) end
  self._items[#self._items + 1] = c
end
function ActionRow:addComponents(...)
  local list = { ... }
  local f = list[1]
  if #list == 1 and type(f) == 'table' and f.toJSON == nil and f[1] ~= nil then list = f end
  for _, c in ipairs(list) do row_push(self, c) end
  return self
end
function ActionRow:addLinkButton(label, u) row_push(self, Button.link(label, u)) return self end
function ActionRow:toJSON()
  if #self._items == 0 then error('ActionRow butuh minimal 1 komponen', 2) end
  local out, solo = {}, false
  for i, c in ipairs(self._items) do
    out[i] = jsonable(c)
    if out[i].type ~= 2 then solo = true end
  end
  if solo and #out > 1 then error('ActionRow: select menu / text input harus sendirian dalam satu row (tombol hanya boleh dengan tombol)', 2) end
  return { type = 1, components = out }
end

local Modal = class()   -- ModalBuilder():setCustomId('form'):setTitle('Judul'):addComponents(TextInputBuilder()...)  -> ctx:showModal(modal)
function Modal.new() return setmetatable({ _rows = {} }, Modal) end
function Modal:setCustomId(v) self._custom_id = custom_id(v) return self end
function Modal:setTitle(v) self._title = str(v, 'judul modal', 1, 45) return self end
function Modal:addComponents(...)
  local list = { ... }
  local f = list[1]
  if #list == 1 and type(f) == 'table' and f.toJSON == nil and f[1] ~= nil then list = f end
  for _, c in ipairs(list) do
    if #self._rows >= 5 then error('maksimal 5 baris per modal', 2) end
    if getmetatable(c) == TextInput then c = ActionRow.new():addComponents(c) end   -- TextInput langsung dibungkus ActionRow
    self._rows[#self._rows + 1] = c
  end
  return self
end
function Modal:toJSON()
  if not self._custom_id then error('modal butuh custom_id (setCustomId)', 2) end
  if not self._title then error('modal butuh judul (setTitle)', 2) end
  if #self._rows == 0 then error('modal butuh minimal 1 input (addComponents)', 2) end
  local rows = {}
  for i, r in ipairs(self._rows) do rows[i] = jsonable(r) end
  return { custom_id = self._custom_id, title = self._title, components = rows }
end

local Section = class()
function Section.new() return setmetatable({ _texts = {} }, Section) end
function Section:addTextDisplays(...)
  for _, t in ipairs { ... } do
    if #self._texts >= 3 then error('maksimal 3 teks per Section', 2) end
    self._texts[#self._texts + 1] = type(t) == 'string' and TextDisplay.new(t) or t
  end
  return self
end
function Section:setThumbnailAccessory(u)
  self._accessory = type(u) == 'string' and Thumbnail.new(u) or u
  return self
end
function Section:setLinkButtonAccessory(label, u) self._accessory = Button.link(label, u) return self end
function Section:setButtonAccessory(button) self._accessory = button return self end   -- tombol apa pun (interaktif juga)
function Section:toJSON()
  if #self._texts == 0 then error('Section butuh minimal 1 teks (addTextDisplays)', 2) end
  if not self._accessory then error('Section butuh accessory (thumbnail atau tombol link)', 2) end
  return { type = 9, components = self._texts, accessory = self._accessory }
end

local Container = class()
function Container.new() return setmetatable({ _children = {} }, Container) end
function Container:setAccentColor(c) self._accent = color(c) return self end
function Container:setSpoiler(b) self._spoiler = b and true or false return self end
function Container:add(component) self._children[#self._children + 1] = component return self end
function Container:addTextDisplay(t) return self:add(type(t) == 'string' and TextDisplay.new(t) or t) end
function Container:addSeparator(divider, spacing) return self:add(Separator.new(divider, spacing)) end
function Container:addSection(spec)
  local s = Section.new()
  if type(spec) == 'function' then s = spec(s) or s elseif type(spec) == 'table' then s = spec end
  return self:add(s)
end
function Container:addMediaGallery(...)
  local first = ...
  local g
  if type(first) == 'function' then g = MediaGallery.new(); g = first(g) or g
  elseif type(first) == 'table' and first.toJSON then g = first
  else g = MediaGallery.new():addItems(...) end
  return self:add(g)
end
function Container:addActionRow(spec)
  local r = ActionRow.new()
  if type(spec) == 'function' then r = spec(r) or r elseif type(spec) == 'table' then r = spec end
  return self:add(r)
end
function Container:toJSON()
  if #self._children == 0 then error('Container butuh minimal 1 komponen', 2) end
  return { type = 17, accent_color = self._accent, spoiler = self._spoiler or nil, components = self._children }
end

B.TextDisplayBuilder, B.SeparatorBuilder, B.ThumbnailBuilder, B.MediaGalleryBuilder = TextDisplay, Separator, Thumbnail, MediaGallery
B.ButtonBuilder, B.ActionRowBuilder, B.SectionBuilder, B.ContainerBuilder = Button, ActionRow, Section, Container
B.StringSelectMenuBuilder, B.StringSelectMenuOptionBuilder, B.UserSelectMenuBuilder = StringSelect, SelectOption, UserSelect
B.RoleSelectMenuBuilder, B.MentionableSelectMenuBuilder, B.ChannelSelectMenuBuilder = RoleSelect, MentionableSelect, ChannelSelect
B.TextInputBuilder, B.ModalBuilder = TextInput, Modal

-- ComponentsV2(c1, c2, ...) -> payload {flags=32768, components={...}} siap untuk ctx:reply / client:send.
-- Memvalidasi batas Discord: maks 40 komponen (termasuk yang bersarang) dan total teks 4000 karakter.
function B.ComponentsV2(...)
  local list, count, text = {}, 0, 0
  local function walk(c)
    c = jsonable(c)
    count = count + 1
    if c.type == 10 then text = text + ulen(c.content) end
    for _, ch in ipairs(c.components or {}) do walk(ch) end
    if c.accessory then walk(c.accessory) end
  end
  for i, c in ipairs { ... } do
    if type(c) == 'string' then c = TextDisplay.new(c) end
    list[i] = jsonable(c)
    walk(list[i])
  end
  if #list == 0 then error('ComponentsV2 butuh minimal 1 komponen', 2) end
  if count > 40 then error(('Components V2: %d komponen, maksimal 40'):format(count), 2) end
  if text > 4000 then error(('Components V2: total teks %d karakter, maksimal 4000'):format(text), 2) end
  return { flags = B.MessageFlags.IsComponentsV2, components = list }
end

return B
