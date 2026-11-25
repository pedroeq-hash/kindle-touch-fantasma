local agora = os.time()
arquivos = { -- global: o teste em Python acrescenta arquivos
  ["/mnt/us/documents"] = { "Dom Casmurro - Machado de Assis.epub", "spidercat.azw3", "My Clippings.txt", "all_system_logs_x.txt", "Downloads", "x.sdr", ".parcial-a.epub" },
  ["/mnt/us/documents/Downloads"] = { "Items01" },
  ["/mnt/us/documents/Downloads/Items01"] = { "f-scott-fitzgerald-o-grande-gatsby.pdf-cdeKey_5AK3DW2JSKNSHRX7JU6CJ5SINFN3SJH5.pdf", "100% <b>.epub" },
}
local dirs = { ["/mnt/us/documents"]=1, ["/mnt/us/documents/Downloads"]=1, ["/mnt/us/documents/Downloads/Items01"]=1, ["/mnt/us/documents/x.sdr"]=1 }
removidos = {}
function existe(p)
  if dirs[p] then return true end
  local d, n = p:match("^(.*)/([^/]+)$")
  for _, x in ipairs(arquivos[d] or {}) do if x == n then return true end end
end
local fake = {
  device = { isKindle = function() return false end, input = { resetState = function() end },  -- handleTouchEv: abaixo
             getPowerDevice = function() return { getCapacity = function() return 73 end, isCharging = function() return false end } end },
  ["ui/event"] = { new = function(_, n, a) return { name = n, args = a } end },
  ["device/input"] = { handleTouchEv = function() end },
  ["ui/widget/infomessage"] = { new = function(_, t) return t end },
  ["ui/uimanager"] = { nextTick = function(_, f) ultimo_tick = f end, sendEvent = function(_, ev) evento_enviado = ev end, show = function() end, scheduleIn = function() end, unschedule = function() end,
                     event_hook = { registerWidget = function() end } },
  ["ui/widget/container/widgetcontainer"] = { extend = function(_, t) return t end },
  ["libs/libkoreader-lfs"] = {
    dir = function(d) local i = 0; local l = arquivos[d] or {}; return function() i = i + 1; return l[i] end end,
    attributes = function(p, campo)
      if removidos[p] or not existe(p) then return nil end
      local a = dirs[p] and { mode = "directory" } or { mode = "file", size = 1536000, modification = agora - 86400 }
      if campo then return a[campo] end
      return a
    end,
  },
  logger = { info = print, err = print, warn = print, dbg = function() end },
  util = { urlDecode = function(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end },
  ["ffi/linux_input_h"] = true,
  ["apps/reader/readerui"] = { instance = { getCurrentPage = function() return 15 end, font = {},
    document = { file = "/mnt/us/documents/Dom Casmurro - Machado de Assis.epub", getPageCount = function() return 257 end,
                 configurable = { font_size = 22 } } } },
  docsettings = { open = function() return { purge = function() end } end, updateLocation = function(a, b) sdr_movido = a .. ">" .. b end },
  readhistory = { fileDeleted = function() end, updateItem = function() end },
  pluginshare = {},
  ["ui/network/manager"] = { saveNetwork = function(_, rede) rede_salva = rede end },
}
fake.device.input.handleTouchEv = fake["device/input"].handleTouchEv -- começa com o original do KOReader
for k, v in pairs(fake) do package.loaded[k] = v end
os.remove = function(p) removidos[p] = true; return true end
os.rename = function(a, b) renomeado = a .. ">" .. b; return true end
G_reader_settings = { readSetting = function(_, _, d) return d end, saveSetting = function() end }
local Leitor = assert(load(SRC, "=main.lua"))()
local saida
local l = setmetatable({ servidor = { send = function(_, r) saida = r end } }, { __index = Leitor })
function req(linha, corpo)
  saida = nil
  local cab = linha .. " HTTP/1.1\r\nHost: x\r\n" .. (corpo and ("Content-Length: " .. #corpo .. "\r\n") or "")
  local client = { settimeout = function() end, receive = function(_, n) return corpo:sub(1, n) end }
  l:onRequest(cab, client)
  return saida
end

-- simula a perda do filtro (crash de 17/11 15h14) e confere que o plugin o repõe no próximo evento
function teste_reinstalar()
  local inp, original = fake.device.input, fake["device/input"].handleTouchEv
  l.ui = { menu = { registerToMainMenu = function() end } }
  l:init()
  local nosso = inp.handleTouchEv
  assert(nosso ~= original, "init não instalou o filtro")
  inp.handleTouchEv = original
  l:onInputEvent()
  assert(inp.handleTouchEv == nosso, "não reinstalou")
  inp._abs_ev_handler, inp.handleTouchEv = original, function() end -- perdeu durante a entrada inibida
  l:onInputEvent()
  assert(inp._abs_ev_handler == nosso, "não reinstalou com a entrada inibida")
  return true
end
