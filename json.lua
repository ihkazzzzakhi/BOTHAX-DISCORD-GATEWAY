-- discord/json.lua : encoder JSON kecil untuk builder dan payload Discord (decoder: discord.json_decode, native).
-- Objek yang punya metode toJSON() (semua builder) di-encode lewat metode itu.
-- Kunci objek diurutkan, jadi hasilnya deterministik. Tabel kosong = objek; pakai json.array({}) untuk array kosong.
local M = {}

M.null = setmetatable({}, { __tostring = function() return 'null' end })
function M.array(t) return setmetatable(t or {}, { __jsonarray = true }) end

local esc = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
local function quote(s)
  return '"' .. s:gsub('[%c"\\]', function(c) return esc[c] or ('\\u%04x'):format(c:byte()) end) .. '"'
end

local function is_array(t)
  local mt = getmetatable(t)
  if mt and mt.__jsonarray then return true end
  local n = 0
  for k in pairs(t) do
    if math.type(k) ~= 'integer' or k < 1 then return false end
    n = n + 1
  end
  return n > 0 and n == #t
end

local function enc(v, depth)
  if depth > 40 then error('JSON terlalu dalam', 0) end
  local tv = type(v)
  if tv == 'string' then return quote(v)
  elseif tv == 'boolean' then return v and 'true' or 'false'
  elseif tv == 'nil' then return 'null'
  elseif tv == 'number' then
    if v ~= v or v == math.huge or v == -math.huge then error('angka tidak valid untuk JSON', 0) end
    if math.type(v) == 'integer' or (v == math.floor(v) and math.abs(v) < 2 ^ 53) then return ('%d'):format(v) end
    return ('%.14g'):format(v)
  elseif tv == 'table' then
    if v == M.null then return 'null' end
    local conv = v.toJSON
    if type(conv) == 'function' then return enc(conv(v), depth + 1) end
    local out = {}
    if is_array(v) then
      for i = 1, #v do out[i] = enc(v[i], depth + 1) end
      return '[' .. table.concat(out, ',') .. ']'
    end
    local keys = {}
    for k in pairs(v) do
      if type(k) ~= 'string' then error('kunci objek JSON harus string', 0) end
      keys[#keys + 1] = k
    end
    table.sort(keys)
    for i, k in ipairs(keys) do out[i] = quote(k) .. ':' .. enc(v[k], depth + 1) end
    return '{' .. table.concat(out, ',') .. '}'
  end
  error('tipe tidak bisa di-encode ke JSON: ' .. tv, 0)
end

function M.encode(v) return enc(v, 0) end

return M
