--[[
Leitor: plugin para um Kindle com touch fantasma.

1. Filtro de toque: substitui Input.handleTouchEv. Só aceita toque de 1 dedo, com duração
   "humana", quase parado e dentro de uma das duas áreas abaixo. Todo o resto é descartado
   antes do detector de gestos do KOReader.
2. Gravação: anota os eventos crus do touch em CONFIG.log_toques (para tools/mapa_toques.py).
3. Página web: lista os livros, abre um livro no Kindle e recebe arquivos enviados pelo celular.
]]

local Device = require("device")
local Event = require("ui/event")
local Input = require("device/input")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local ffi = require("ffi")
local C = ffi.C
require("ffi/linux_input_h")

-- Ajuste aqui depois do mapa da Fase 2. Coordenadas em pixels do touch (tela 1072x1448, retrato).
local CONFIG = {
    porta = 8090,
    pasta_livros = "/mnt/us/documents",
    log_toques = "/mnt/us/toques.log",
    -- {x1, y1, x2, y2}. Definitivas, a partir das gravações de 17/11/2026: fantasmas em y 480-650
    -- e numa coluna em x≈763 (y 1290-1420, <60 ms ou arrastando); em 25/11 a coluna estava em x 702-718, de y 112 a 1440
    area_avancar = { 820, 900, 1072, 1448 },
    area_voltar = { 0, 900, 300, 1448 },
    -- 25/11/2026: toques reais do dono nas áreas duraram 49-124 ms (2 de 11 recusados com 60); os únicos fantasmas
    -- já vistos dentro das áreas duraram 37 e 38 ms (gravação da noite de 17/11)
    dur_min_ms = 45,
    dur_max_ms = 800, -- toques de propósito do dono duraram 350-520 ms
    mov_max_px = 40,
    upload_max_bytes = 200 * 1024 * 1024,
}

-- sem txt: em documents/ só há logs do sistema (;dm) e My Clippings
local EXTENSOES = { epub = true, pdf = true, mobi = true, azw3 = true, fb2 = true, cbz = true, djvu = true }

-- O filtro é sempre ligado: sem ele um toque fantasma sem coordenada derruba o gesturedetector do KOReader
-- (crash.log de 17/11/2026: gesturedetector.lua:869 e :326, "attempt to perform arithmetic on field 'y'").
local settings = G_reader_settings:readSetting("leitor", { servidor = true })

---------------------------------------------------------------- decisão (função pura)

local function dentro(a, x, y)
    return x >= a[1] and x <= a[3] and y >= a[2] and y <= a[4]
end

-- toque = {x0, y0, x, y, dur, dedos}. Devolve 1 (avançar), -1 (voltar) ou nil (descartar).
local function classificar(t, cfg)
    if t.dedos ~= 1 then return nil end
    if t.dur < cfg.dur_min_ms or t.dur > cfg.dur_max_ms then return nil end
    if math.abs(t.x - t.x0) > cfg.mov_max_px or math.abs(t.y - t.y0) > cfg.mov_max_px then return nil end
    if dentro(cfg.area_avancar, t.x, t.y) then return 1 end
    if dentro(cfg.area_voltar, t.x, t.y) then return -1 end
    return nil
end

local function autoteste()
    local cfg = { area_avancar = { 100, 100, 200, 200 }, area_voltar = { 0, 0, 50, 50 },
                  dur_min_ms = 60, dur_max_ms = 400, mov_max_px = 40 }
    local function t(x, y, dur, dedos, x0, y0)
        return { x = x, y = y, x0 = x0 or x, y0 = y0 or y, dur = dur, dedos = dedos or 1 }
    end
    assert(classificar(t(150, 150, 100), cfg) == 1, "toque na área avançar")
    assert(classificar(t(10, 10, 100), cfg) == -1, "toque na área voltar")
    assert(classificar(t(300, 300, 100), cfg) == nil, "fora das áreas")
    assert(classificar(t(150, 150, 30), cfg) == nil, "curto demais")
    assert(classificar(t(150, 150, 900), cfg) == nil, "longo demais")
    assert(classificar(t(150, 150, 100, 2), cfg) == nil, "dois dedos")
    assert(classificar(t(150, 150, 100, 1, 100, 150), cfg) == nil, "arrastou")
end

---------------------------------------------------------------- touch: rastreio, filtro e gravação

local original_handleTouchEv = Input.handleTouchEv
local slots, slot_atual = {}, 0
local arquivo_log = nil

local function contatos_ativos()
    local n = 0
    for _, c in pairs(slots) do
        if not c.solto then n = n + 1 end
    end
    return n
end

-- Acompanha o protocolo multitouch tipo B e devolve a lista de toques terminados neste quadro.
local function rastrear(ev)
    local terminados
    if ev.type == C.EV_ABS then
        if ev.code == C.ABS_MT_SLOT then
            slot_atual = ev.value
        elseif ev.code == C.ABS_MT_TRACKING_ID then
            if ev.value >= 0 then
                slots[slot_atual] = { dedos = 0 }
            elseif slots[slot_atual] then
                slots[slot_atual].solto = true
            end
        elseif ev.code == C.ABS_MT_POSITION_X or ev.code == C.ABS_X then
            local c = slots[slot_atual]
            if c then c.x = ev.value; c.x0 = c.x0 or ev.value end
        elseif ev.code == C.ABS_MT_POSITION_Y or ev.code == C.ABS_Y then
            local c = slots[slot_atual]
            if c then c.y = ev.value; c.y0 = c.y0 or ev.value end
        end
    elseif ev.type == C.EV_SYN and ev.code == C.SYN_REPORT then
        local agora = ev.time.sec * 1000 + ev.time.usec / 1000
        local n = contatos_ativos()
        for s, c in pairs(slots) do
            c.t0 = c.t0 or agora
            if n > c.dedos then c.dedos = n end
            if c.solto then
                slots[s] = nil
                if c.x and c.y then
                    terminados = terminados or {}
                    table.insert(terminados, { x0 = c.x0, y0 = c.y0, x = c.x, y = c.y,
                                               dur = agora - c.t0, dedos = c.dedos })
                end
            end
        end
    end
    return terminados
end

local function gravar(ev)
    arquivo_log:write(string.format("%d.%06d %d %d %d\n", ev.time.sec, ev.time.usec, ev.type, ev.code, ev.value))
    if ev.type == C.EV_SYN then arquivo_log:flush() end
end

local function handleTouchEv(input, ev)
    if arquivo_log then gravar(ev) end
    local evs
    for _, t in ipairs(rastrear(ev) or {}) do
        local dir = classificar(t, CONFIG)
        if dir then
            evs = evs or {}
            table.insert(evs, Event:new("GotoViewRel", dir))
        end
    end
    return evs
end

-- Só a instância. Os plugins carregam com o input inibido (Input:inhibitInput guarda o tratador em
-- _abs_ev_handler e o devolve depois), então trocamos o guardado para a restauração já trazer o nosso.
local function instalar_handler()
    -- O log mostra quando foi preciso (re)instalar: fora da abertura do KOReader, algo tinha trocado o nosso.
    local inp = Device.input
    if inp._abs_ev_handler == original_handleTouchEv then
        inp._abs_ev_handler = handleTouchEv
        logger.info("Leitor: filtro de toque instalado (entrada inibida)")
    elseif inp.handleTouchEv == original_handleTouchEv then
        inp.handleTouchEv = handleTouchEv
        logger.info("Leitor: filtro de toque instalado")
    end
    return inp.handleTouchEv == handleTouchEv or inp._abs_ev_handler == handleTouchEv
end

local function set_gravacao(on)
    if on and not arquivo_log then
        arquivo_log = io.open(CONFIG.log_toques, "a")
    elseif not on and arquivo_log then
        arquivo_log:close()
        arquivo_log = nil
    end
    -- dormindo, o touch desliga e nada é gravado: segura acordado. O preventScreenSaver segura o powerd;
    -- o AutoSuspend do KOReader (15 min sem interação) só para com pause_auto_suspend, e keepalive=true
    -- faz ele não mexer no t1 do powerd, como no keepalive.koplugin.
    local PluginShare = require("pluginshare")
    PluginShare.pause_auto_suspend = arquivo_log ~= nil
    PluginShare.keepalive = arquivo_log ~= nil
    if Device:isKindle() then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver " .. (arquivo_log and "1" or "0"))
    end
    return arquivo_log ~= nil
end

---------------------------------------------------------------- web

local function ip_local()
    local p = io.popen("ifconfig wlan0 2>/dev/null")
    if not p then return nil end
    local out = p:read("*a")
    p:close()
    return out:match("inet addr:(%d+%.%d+%.%d+%.%d+)") or out:match("inet (%d+%.%d+%.%d+%.%d+)")
end

local function html_escape(s)
    return (s:gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }))
end

local function url_encode(s)
    return (s:gsub("[^%w%-%._~]", function(ch) return string.format("%%%02X", ch:byte()) end))
end

local function extensao(nome)
    local ext = nome:match("%.([^.]+)$")
    return ext and ext:lower()
end

-- Título legível a partir do nome do arquivo (inclui os nomes da Amazon: "livro.pdf-cdeKey_XXXX.pdf").
local function titulo(nome)
    local t = nome:gsub("%.[^.]+$", ""):gsub("%.%a+%-cdeKey_%w+$", "")
    if t:find(" ", 1, true) then t = t:gsub("_", " ") else t = t:gsub("[-_]+", " ") end
    return (t:gsub("^%l", string.upper))
end

local function tamanho_txt(bytes)
    if bytes < 1024 * 1024 then return string.format("%d KB", math.max(1, math.floor(bytes / 1024))) end
    return (string.format("%.1f MB", bytes / 1024 / 1024):gsub("%.", ","))
end

local function data_txt(t)
    local function dia(x) local d = os.date("*t", x); return math.floor(os.time{ year = d.year, month = d.month, day = d.day, hour = 12 } / 86400) end
    local n = dia(os.time()) - dia(t)
    if n <= 0 then return "hoje" elseif n == 1 then return "ontem" elseif n < 7 then return "há " .. n .. " dias" end
    return os.date("%d/%m/%Y", t)
end

local function livro_aberto()
    local RUI = package.loaded["apps/reader/readerui"]
    local i = RUI and RUI.instance
    return i and i.document and i.document.file
end

-- Página atual e total do livro aberto (nil sem livro aberto).
local function paginas()
    local RUI = package.loaded["apps/reader/readerui"]
    local i = RUI and RUI.instance
    if not (i and i.document) then return nil end
    local ok, atual, total = pcall(function() return i:getCurrentPage(), i.document:getPageCount() end)
    if ok and atual and total then return atual, total end
end

-- Tamanho da fonte do livro aberto; nil em PDF/CBZ/DJVU, que não têm o módulo de fonte do KOReader.
local function fonte_atual()
    local RUI = package.loaded["apps/reader/readerui"]
    local i = RUI and RUI.instance
    return i and i.font and i.document and i.document.configurable and i.document.configurable.font_size
end

local function bateria_txt()
    local ok, txt = pcall(function()
        local p = Device:getPowerDevice()
        return string.format("%d%%%s", p:getCapacity(), p:isCharging() and " ⚡" or "")
    end)
    return ok and txt or nil
end

-- Caminho relativo seguro dentro da pasta de livros: sem "..", sem absoluto, sem arquivo oculto.
local function caminho_seguro(rel)
    if not rel or rel == "" or rel:sub(1, 1) == "/" or rel:find("\\", 1, true) or rel:find("%z") then return nil end
    for parte in rel:gmatch("[^/]+") do
        if parte == ".." or parte == "." or parte:sub(1, 1) == "." then return nil end
    end
    if not EXTENSOES[extensao(rel) or ""] then return nil end
    return CONFIG.pasta_livros .. "/" .. rel
end

local function listar_livros()
    local livros = {}
    local function varrer(dir, prefixo, nivel)
        if nivel > 3 then return end
        for nome in lfs.dir(dir) do
            if nome:sub(1, 1) ~= "." and not nome:match("%.sdr$") then
                local caminho = dir .. "/" .. nome
                local attr = lfs.attributes(caminho)
                if attr and attr.mode == "directory" then
                    varrer(caminho, prefixo .. nome .. "/", nivel + 1)
                elseif attr and EXTENSOES[extensao(nome) or ""] then
                    table.insert(livros, { rel = prefixo .. nome, nome = nome, mtime = attr.modification, tamanho = attr.size })
                end
            end
        end
    end
    pcall(varrer, CONFIG.pasta_livros, "", 0)
    table.sort(livros, function(a, b) return a.mtime > b.mtime end)
    return livros
end

-- Tudo embutido (sem fonte nem script de fora): a página carrega só da rede de casa e o Kindle manda poucos KB.
local PAGINA = [==[<!doctype html><html lang="pt-BR"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#f4f1ea" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#161513" media="(prefers-color-scheme: dark)">
<title>Kindle</title>
<style>
:root{--bg:#f4f1ea;--card:#fffdf8;--ink:#1f1c18;--sub:#6f685d;--line:#e3ddd1;--acc:#2f6b5b;--soft:#e6eee8;--perigo:#a23b2a;color-scheme:light dark}
@media (prefers-color-scheme:dark){:root{--bg:#161513;--card:#201e1b;--ink:#ece6da;--sub:#a09886;--line:#34312b;--acc:#7fc2ad;--soft:#1f2c27;--perigo:#e0806e}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.4 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;-webkit-tap-highlight-color:transparent}
main{max-width:560px;margin:0 auto;padding:22px 16px 96px}
.serif{font-family:"Iowan Old Style","Palatino Linotype",Palatino,Georgia,serif}
header{display:flex;align-items:baseline;justify-content:space-between;margin:0 2px 18px}
h1{font-size:30px;font-weight:600;line-height:1.1;margin:0;letter-spacing:-.01em}
.qtd{color:var(--sub);font-size:14px}
h2{font-size:12px;font-weight:600;text-transform:uppercase;letter-spacing:.09em;color:var(--sub);margin:28px 6px 10px}
.lendo{background:var(--soft);border-radius:16px;padding:16px 18px;margin-bottom:14px}
.lendo small{display:block;color:var(--acc);font-weight:600;font-size:12px;text-transform:uppercase;letter-spacing:.09em}
.lendo b{display:block;font-size:20px;font-weight:600;line-height:1.25;margin-top:4px;overflow-wrap:anywhere}
.enviar{display:flex;align-items:center;justify-content:center;gap:10px;padding:16px;border:1.5px dashed var(--acc);border-radius:16px;color:var(--acc);font-weight:600;cursor:pointer}
.enviar input{position:absolute;opacity:0;width:1px;height:1px}
.prog{height:4px;border-radius:2px;background:var(--line);margin:10px 4px 0;overflow:hidden;visibility:hidden}
.prog i{display:block;height:100%;width:0;background:var(--acc);transition:width .2s}
.lista,.ajustes{list-style:none;margin:0;padding:0;background:var(--card);border:1px solid var(--line);border-radius:16px;overflow:hidden}
.lista li{display:flex;align-items:center;border-top:1px solid var(--line)}
.lista li:first-child,.ajustes button:first-child{border-top:0}
.lista li.atual{background:var(--soft)}
.abrir{flex:1;min-width:0;text-align:left;background:none;border:0;padding:14px 4px 14px 16px;color:inherit;font:inherit;cursor:pointer}
.t{display:block;font-size:17px;font-weight:500;line-height:1.3;overflow-wrap:anywhere}
.m{display:flex;flex-wrap:wrap;gap:4px 8px;align-items:center;margin-top:5px;color:var(--sub);font-size:13px}
.fmt{font-size:10.5px;font-weight:700;letter-spacing:.06em;padding:1px 6px;border-radius:5px;border:1px solid var(--line)}
.atual .fmt{border-color:var(--acc);color:var(--acc)}
.lixo,.ren{flex:none;width:44px;height:52px;margin-right:4px;border:0;background:none;color:var(--sub);border-radius:12px;cursor:pointer;display:grid;place-items:center}
.ren{margin-right:0}
.lixo:active{color:var(--perigo);background:var(--line)}
.ren:active{color:var(--acc);background:var(--line)}
.ir{display:flex;align-items:center;gap:8px;margin-top:12px;color:var(--sub);font-size:16px}
.ir input{width:88px;padding:10px;border:1px solid var(--line);border-radius:10px;background:var(--card);color:var(--ink);font:inherit;font-size:17px;text-align:center}
.fonte{display:flex;align-items:center;gap:10px;margin-top:10px;color:var(--sub);font-size:16px}
.fonte button{width:48px;height:44px;border:1px solid var(--line);border-radius:10px;background:var(--card);color:var(--ink);font:inherit;font-weight:600;cursor:pointer}
.fonte button:first-of-type{margin-left:auto}
.fonte b{min-width:30px;text-align:center;color:var(--ink);font-size:17px}
.ir button{margin-left:auto;padding:10px 20px;border:0;border-radius:10px;background:var(--acc);color:var(--card);font:inherit;font-weight:600;cursor:pointer}
.vazio{padding:28px 18px;color:var(--sub);text-align:center}
.ajustes button{display:flex;gap:12px;justify-content:space-between;align-items:center;width:100%;padding:14px 16px;border:0;border-top:1px solid var(--line);background:none;color:inherit;font:inherit;text-align:left;cursor:pointer}
.ajustes small{display:block;color:var(--sub);font-size:13px;margin-top:2px}
.chave{flex:none;width:46px;height:28px;border-radius:14px;background:var(--line);position:relative;transition:background .2s}
.chave::after{content:"";position:absolute;top:3px;left:3px;width:22px;height:22px;border-radius:50%;background:#fff;box-shadow:0 1px 2px rgba(0,0,0,.3);transition:transform .2s}
.on .chave{background:var(--acc)}.on .chave::after{transform:translateX(18px)}
.ajustes .sair{color:var(--perigo);font-weight:600}
.cartao{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:16px}
.cartao label{display:block;font-size:14px;color:var(--sub);margin-bottom:12px}
.cartao input{display:block;width:100%;margin-top:6px;padding:12px;border:1px solid var(--line);border-radius:10px;background:var(--bg);color:var(--ink);font:inherit}
.cartao input:focus{outline:2px solid var(--acc);outline-offset:-1px;border-color:transparent}
.cartao button{width:100%;padding:13px;border:0;border-radius:10px;background:var(--acc);color:var(--card);font:inherit;font-weight:600;cursor:pointer}
.dica{font-size:13px;color:var(--sub);margin:12px 2px 0}
button:focus-visible,.enviar:focus-within{outline:2px solid var(--acc);outline-offset:2px}
#msg{position:fixed;left:50%;bottom:calc(20px + env(safe-area-inset-bottom));transform:translate(-50%,16px);width:max-content;max-width:calc(100% - 32px);background:var(--ink);color:var(--bg);padding:12px 18px;border-radius:12px;font-size:15px;opacity:0;transition:opacity .25s,transform .25s;pointer-events:none}
#msg.vis{opacity:1;transform:translate(-50%,0)}
@media (prefers-reduced-motion:reduce){*{transition:none!important}}
</style></head><body><main>
<header><h1 class="serif">Kindle</h1><span class="qtd">%BATERIA%%QTD%</span></header>
%LENDO%
<label class="enviar"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 16V4M6 10l6-6 6 6M4 20h16"/></svg>Enviar livro<input type="file" id="arq" multiple accept=".epub,.pdf,.mobi,.azw3,.fb2,.cbz,.djvu"></label>
<div class="prog" id="prog"><i></i></div>
<h2>Biblioteca</h2>
<ul class="lista">%LIVROS%</ul>
<h2>Redes Wi-Fi</h2>
<form class="cartao" id="wifi">
<label>Nome da rede<input name="ssid" maxlength="32" required autocomplete="off" autocapitalize="off" spellcheck="false"></label>
<label>Senha<input name="senha" type="password" maxlength="63" autocomplete="new-password"></label>
<button type="submit">Salvar rede no Kindle</button>
<p class="dica">Cadastre aqui o hotspot do seu celular: em qualquer lugar, é só ligá-lo que o Kindle conecta. Para rede aberta, deixe a senha vazia.</p>
</form>
<h2>Ajustes</h2>
<div class="ajustes">
<button class="%GRAVAR_CLASSE%" data-url="/gravar?on=%GRAVAR_PROX%"><span>Gravar toques<small>Para calibrar o touch; mantém o Kindle acordado</small></span><span class="chave"></span></button>
<button class="sair" data-url="/sair" data-aviso="Fechar o KOReader e voltar para a tela normal do Kindle?">Sair do KOReader</button>
</div>
</main><div id="msg" role="status" aria-live="polite"></div>
<script>
const msg=document.getElementById('msg');let tm;
function aviso(t,ms){msg.textContent=t;msg.classList.add('vis');clearTimeout(tm);if(ms)tm=setTimeout(()=>msg.classList.remove('vis'),ms)}
// o servidor reinicia quando o Kindle troca de tela (abrir livro): tenta de novo até voltar
function recarregar(espera,tentativas){setTimeout(()=>fetch('/',{cache:'no-store'}).then(r=>{if(!r.ok)throw 0;location.reload()})
.catch(()=>tentativas>0?recarregar(1500,tentativas-1):aviso('O Kindle não respondeu. Ele pode ter dormido.')),espera)}
async function chamar(url,metodo,corpo){const r=await fetch(url,{method:metodo||'GET',cache:'no-store',body:corpo});const t=await r.text();if(!r.ok)throw new Error(t);return t}
document.getElementById('wifi').addEventListener('submit',async e=>{e.preventDefault();const f=e.target;
const corpo='ssid='+encodeURIComponent(f.ssid.value)+'&senha='+encodeURIComponent(f.senha.value);
try{aviso(await chamar('/wifi','PUT',corpo),5000);f.reset()}catch(err){aviso(err.message||'O Kindle não respondeu.',4000)}});
const ir=document.getElementById('ir');
if(ir)ir.addEventListener('submit',async e=>{e.preventDefault();ir.n.blur();
try{aviso(await chamar('/pagina?n='+ir.n.value),2500)}catch(err){aviso(err.message||'O Kindle não respondeu.',4000)}});
document.addEventListener('click',async e=>{
const b=e.target.closest('button');if(!b||b.form)return; // botão sem type conta como submit; só o do formulário de Wi-Fi tem .form
try{
if(b.dataset.f){aviso('Abrindo no Kindle…');await chamar('/abrir?f='+b.dataset.f);recarregar(2500,6)}
else if(b.dataset.apagar){if(!confirm('Apagar “'+b.dataset.t+'” do Kindle?'))return;
const t=await chamar('/apagar?f='+b.dataset.apagar,'DELETE');b.closest('li').remove();aviso(t,2500)}
else if(b.dataset.fonte){aviso(await chamar('/fonte?d='+b.dataset.fonte),1500);recarregar(1500,4)} // recarrega: o total de páginas muda
else if(b.dataset.renomear){const novo=prompt('Novo nome do livro:',b.dataset.t);if(!novo||novo.trim()===b.dataset.t)return;
aviso(await chamar('/renomear?f='+b.dataset.renomear+'&nome='+encodeURIComponent(novo.trim()),'PUT'),1500);setTimeout(()=>location.reload(),900)}
else if(b.dataset.url){if(b.dataset.aviso&&!confirm(b.dataset.aviso))return;const t=await chamar(b.dataset.url);
if(b.classList.contains('sair'))aviso(t);else location.reload()}
}catch(err){aviso(err.message||'O Kindle não respondeu.',4000)}});
document.getElementById('arq').addEventListener('change',async e=>{
const arqs=[...e.target.files],barra=document.getElementById('prog'),i=barra.firstChild;barra.style.visibility='visible';
for(const [n,f] of arqs.entries()){const rotulo=(arqs.length>1?(n+1)+'/'+arqs.length+' · ':'')+f.name;aviso('Enviando '+rotulo);i.style.width='0';
const ok=await new Promise(res=>{const x=new XMLHttpRequest();x.open('PUT','/enviar?nome='+encodeURIComponent(f.name));
x.upload.onprogress=p=>{if(p.lengthComputable)i.style.width=(100*p.loaded/p.total)+'%'};
x.onload=()=>{aviso(x.responseText);res(x.status==200)};x.onerror=()=>{aviso('Falhou: '+f.name);res(false)};x.send(f)});
if(!ok){barra.style.visibility='hidden';return}}
setTimeout(()=>location.reload(),900)});
</script></body></html>]==]

local ICONE_LAPIS = '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 20h4L19 9l-4-4L4 16v4zM13 7l4 4"/></svg>'
local ICONE_LIXO ='<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3"/></svg>'

local function montar_pagina()
    local aberto = livro_aberto()
    local itens, lendo = {}, ""
    local livros = listar_livros()
    for _, l in ipairs(livros) do
        local f, t = url_encode(l.rel), html_escape(titulo(l.nome))
        local atual = CONFIG.pasta_livros .. "/" .. l.rel == aberto
        if atual then
            local pag, total = paginas()
            local ir = pag and string.format('<form class="ir" id="ir"><span>Página</span><input name="n" type="number" inputmode="numeric" min="1" max="%d" value="%d" required aria-label="Ir para a página">'
                .. '<span>/ %d</span><button type="submit">Ir</button></form>', total, pag, total) or ""
            local fonte = fonte_atual()
            local ajuste = fonte and string.format('<div class="fonte"><span>Fonte</span><button data-fonte="-2" aria-label="Diminuir a fonte">A−</button>'
                .. '<b>%d</b><button data-fonte="2" aria-label="Aumentar a fonte">A+</button></div>', fonte) or ""
            lendo = '<div class="lendo"><small>Lendo agora</small><b class="serif">' .. t .. '</b>' .. ir .. ajuste .. '</div>'
        end
        table.insert(itens, string.format(
            '<li%s><button class="abrir" data-f="%s"><span class="t serif">%s</span><span class="m"><span class="fmt">%s</span>%s · %s</span></button>'
            .. '<button class="ren" data-renomear="%s" data-t="%s" aria-label="Renomear %s">%s</button>'
            .. '<button class="lixo" data-apagar="%s" data-t="%s" aria-label="Apagar %s">%s</button></li>',
            atual and ' class="atual"' or "", f, t, (extensao(l.nome) or ""):upper(), tamanho_txt(l.tamanho or 0), data_txt(l.mtime or 0),
            f, t, t, ICONE_LAPIS, f, t, t, ICONE_LIXO))
    end
    if #itens == 0 then itens[1] = '<li class="vazio">Nenhum livro ainda. Envie um EPUB pelo botão acima.</li>' end
    local valores = {
        QTD = #livros == 1 and "1 livro" or (#livros .. " livros"),
        BATERIA = bateria_txt() and ("Bateria " .. bateria_txt() .. " · ") or "",
        LENDO = lendo,
        LIVROS = table.concat(itens),
        GRAVAR_CLASSE = arquivo_log and "on" or "", GRAVAR_PROX = arquivo_log and "0" or "1",
    }
    -- função na substituição: nomes de livro com "%" não viram padrão do gsub
    return (PAGINA:gsub("%%([%u_]+)%%", function(k) return valores[k] end))
end

local function apagar_livro(arquivo)
    if arquivo == livro_aberto() then return 409, "Esse livro está aberto no Kindle. Abra outro antes de apagar." end
    local ok, err = os.remove(arquivo)
    if not ok then return 500, "Não consegui apagar: " .. tostring(err) end
    pcall(function() require("docsettings"):open(arquivo):purge() end) -- posição e anotações (pasta .sdr)
    pcall(function() require("readhistory"):fileDeleted(arquivo) end)
    return 200, "Apagado."
end

-- Troca o nome do arquivo (mesma pasta e extensão) e leva junto a posição de leitura e o histórico.
local function renomear_livro(arquivo, novo)
    novo = (novo or ""):gsub("^%s+", ""):gsub("%s+$", "")
    -- a memória do Kindle é FAT: esses caracteres não podem ir no nome
    if novo == "" or #novo > 150 or novo:sub(1, 1) == "." or novo:find('[/\\:*?"<>|%c]') then
        return 400, 'Nome inválido. Não use / \\ : * ? " < > |'
    end
    if arquivo == livro_aberto() then return 409, "Esse livro está aberto no Kindle. Abra outro antes de renomear." end
    local destino = arquivo:match("^(.*/)") .. novo .. arquivo:match("%.[^.]+$")
    if destino == arquivo then return 200, "Nome igual, nada mudou." end
    -- FAT não diferencia maiúsculas: "a.epub" -> "A.epub" acha o próprio arquivo
    if destino:lower() ~= arquivo:lower() and lfs.attributes(destino, "mode") then
        return 409, "Já existe um livro com esse nome."
    end
    local ok, err = os.rename(arquivo, destino)
    if not ok then return 500, "Não consegui renomear: " .. tostring(err) end
    local ok_doc, err_doc = pcall(function() require("docsettings").updateLocation(arquivo, destino) end) -- pasta .sdr
    if not ok_doc then logger.warn("Leitor: posição não acompanhou o novo nome:", err_doc) end
    pcall(function() require("readhistory"):updateItem(arquivo, destino) end)
    return 200, "Renomeado."
end

local function parse_query(q)
    local params = {}
    for par in (q or ""):gmatch("[^&]+") do
        local k, v = par:match("^([^=]*)=?(.*)$")
        params[util.urlDecode(k)] = util.urlDecode(v)
    end
    return params
end

-- Lê o corpo do PUT direto do socket para um arquivo temporário e renomeia no fim.
local function receber_arquivo(client, cabecalhos, nome)
    if not nome or nome:find("/", 1, true) or nome:find("\\", 1, true) or nome:sub(1, 1) == "." or not EXTENSOES[extensao(nome) or ""] then
        return 400, "Nome ou formato não aceito."
    end
    local tamanho = tonumber(cabecalhos:match("\n[Cc]ontent%-[Ll]ength:%s*(%d+)"))
    if not tamanho or tamanho == 0 then return 411, "Faltou Content-Length." end
    if tamanho > CONFIG.upload_max_bytes then return 413, "Arquivo grande demais." end
    local destino = CONFIG.pasta_livros .. "/" .. nome
    local parcial = CONFIG.pasta_livros .. "/.parcial-" .. nome
    local f = io.open(parcial, "wb")
    if not f then return 500, "Não consegui criar o arquivo." end
    client:settimeout(15) -- shortcut: leitura bloqueia a interface durante o envio; ok para EPUB de poucos MB
    local falta = tamanho
    while falta > 0 do
        local pedaco, err, parte = client:receive(math.min(65536, falta))
        pedaco = pedaco or parte
        if pedaco and #pedaco > 0 then
            f:write(pedaco)
            falta = falta - #pedaco
        end
        if err then break end
    end
    f:close()
    if falta > 0 then
        os.remove(parcial)
        return 400, "Envio interrompido."
    end
    os.remove(destino)
    local ok = os.rename(parcial, destino)
    if not ok then os.remove(parcial); return 500, "Não consegui salvar." end
    return 200, "Recebido: " .. nome
end

-- Corpo pequeno de formulário (poucos bytes), lido de uma vez.
local function ler_corpo(client, cabecalhos, max)
    local tamanho = tonumber(cabecalhos:match("\n[Cc]ontent%-[Ll]ength:%s*(%d+)"))
    if not tamanho or tamanho > max then return nil end
    client:settimeout(5)
    local corpo, _, parte = client:receive(tamanho)
    corpo = corpo or parte
    return corpo and #corpo == tamanho and corpo or nil
end

-- Guarda a rede no próprio Kindle (wifid), pela mesma função do menu de Wi-Fi do KOReader.
local function salvar_wifi(corpo)
    local f = parse_query(corpo)
    local ssid, senha = f.ssid or "", f.senha or ""
    if #ssid < 1 or #ssid > 32 then return 400, "Nome da rede inválido." end
    if senha ~= "" and (#senha < 8 or #senha > 63) then return 400, "A senha de Wi-Fi precisa ter de 8 a 63 caracteres." end
    require("ui/network/manager"):saveNetwork{ ssid = ssid, password = senha, flags = senha ~= "" and "WPA2" or "" }
    return 200, "Rede “" .. ssid .. "” salva. O Kindle entra nela sozinho quando estiver por perto."
end

---------------------------------------------------------------- plugin

local Leitor = WidgetContainer:extend{
    name = "leitor",
}

local autoteste_ok, autoteste_err = pcall(autoteste)
local ultimo_ip, checagens_sem_ip = nil, 0 -- no módulo: o plugin é recriado ao trocar leitor/gerenciador

function Leitor:init()
    if not instalar_handler() then
        UIManager:nextTick(function()
            UIManager:show(InfoMessage:new{ text = "Leitor: este aparelho usa outro tratador de toque; o filtro não vai agir." })
        end)
    end
    if not autoteste_ok then -- o filtro continua: sem ele o KOReader cai
        UIManager:nextTick(function()
            UIManager:show(InfoMessage:new{ text = "Leitor: autoteste falhou, as áreas podem não virar a página.\n" .. tostring(autoteste_err) })
        end)
    end
    if settings.servidor then
        UIManager:nextTick(function() self:start() end)
    end
    UIManager.event_hook:registerWidget("InputEvent", self) -- o event_hook desregistra sozinho no onCloseWidget
    self.ui.menu:registerToMainMenu(self)
end

-- Uma vez por quadro de entrada: se algo devolveu o tratador original do KOReader, põe o nosso de volta
-- (crash de 17/11/2026 15h14: o original voltou a agir depois de o Kindle acordar).
function Leitor:onInputEvent()
    instalar_handler()
end

function Leitor:mostrarEndereco(segundos)
    local ip = ip_local()
    UIManager:show(InfoMessage:new{
        text = ip and string.format("Página do Kindle:\nhttp://%s:%d", ip, CONFIG.porta) or "Sem Wi-Fi: página indisponível.",
        timeout = segundos or 8,
    })
end

-- A cada 30 s: se o IP mudou (roteador reiniciou, Wi-Fi voltou), mostra o endereço novo na tela.
function Leitor:vigiarRede()
    local ip = ip_local()
    if ip then
        if ip ~= ultimo_ip then self:mostrarEndereco(30) end
        checagens_sem_ip = 0
    else
        checagens_sem_ip = checagens_sem_ip + 1
        -- shortcut: religa o Wi-Fi a cada 2 min sem IP, por até 20 min, porque o Kindle às vezes não volta sozinho
        -- depois que o roteador reinicia; se não adiantar, investigar o wifid pelo log do sistema
        if Device:isKindle() and checagens_sem_ip % 4 == 0 and checagens_sem_ip <= 40 then
            logger.info("Leitor: sem IP, religando o Wi-Fi")
            os.execute("(lipc-set-prop com.lab126.wifid enable 0; sleep 3; lipc-set-prop com.lab126.wifid enable 1) &")
        end
    end
    ultimo_ip = ip
    UIManager:scheduleIn(30, self.vigia)
end

function Leitor:start()
    if self.servidor then return end
    if Device:isKindle() then -- abre a porta no firewall do Kindle (mesmo jeito do httpinspector)
        os.execute(string.format("iptables -A INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT", CONFIG.porta))
        os.execute(string.format("iptables -A OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT", CONFIG.porta))
    end
    local Server = require("ui/message/simpletcpserver")
    self.servidor = Server:new{
        host = "*",
        port = CONFIG.porta,
        receiveCallback = function(data, client) return self:onRequest(data, client) end,
    }
    local ok, err = self.servidor:start()
    if not ok then
        logger.err("Leitor: servidor não subiu:", err)
        self.servidor = nil
        return
    end
    self.fila = UIManager:insertZMQ(self.servidor)
    self.vigia = function() self:vigiarRede() end
    self:vigiarRede()
end

function Leitor:stop()
    if not self.servidor then return end
    if Device:isKindle() then
        os.execute(string.format("iptables -D INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT", CONFIG.porta))
        os.execute(string.format("iptables -D OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT", CONFIG.porta))
    end
    if self.servidor then self.servidor:stop(); self.servidor = nil end
    if self.fila then UIManager:removeZMQ(self.fila); self.fila = nil end
    if self.vigia then UIManager:unschedule(self.vigia); self.vigia = nil end
end

Leitor.onCloseWidget = Leitor.stop
function Leitor:onSuspend()
    self:stop()
    ultimo_ip = nil -- mostra o endereço de novo ao acordar
end
Leitor.onEnterStandby = Leitor.stop
function Leitor:onExit() self:stop(); set_gravacao(false) end
function Leitor:onResume() if settings.servidor then self:start() end end
Leitor.onLeaveStandby = Leitor.onResume

function Leitor:responder(client, codigo, tipo, corpo, extra)
    local status = ({ [200] = "OK", [302] = "Found", [400] = "Bad Request", [404] = "Not Found", [405] = "Method Not Allowed",
                      [409] = "Conflict", [411] = "Length Required", [413] = "Payload Too Large", [500] = "Internal Server Error" })[codigo] or "Error"
    local resp = table.concat({
        string.format("HTTP/1.0 %d %s", codigo, status),
        "Content-Type: " .. tipo .. "; charset=utf-8",
        "Content-Length: " .. #corpo,
        "Cache-Control: no-store",
        "Connection: close",
    }, "\r\n") .. (extra or "") .. "\r\n\r\n" .. corpo
    if self.servidor then self.servidor:send(resp, client) else client:close() end
    return Event:new("InputEvent") -- conta como atividade: adia a hibernação automática
end

function Leitor:onRequest(data, client)
    local metodo, alvo = data:match("^(%u+) (%S+) HTTP/%d%.%d")
    local caminho, query = (alvo or ""):match("^([^?]*)%??(.*)$")
    local p = parse_query(query)

    if metodo == "PUT" and caminho == "/enviar" then
        local codigo, msg = receber_arquivo(client, data, p.nome)
        return self:responder(client, codigo, "text/plain", msg)
    end
    if metodo == "PUT" and caminho == "/wifi" then
        local corpo = ler_corpo(client, data, 1024)
        if not corpo then return self:responder(client, 400, "text/plain", "Formulário não chegou inteiro.") end
        local codigo, msg = salvar_wifi(corpo)
        return self:responder(client, codigo, "text/plain", msg)
    end
    if metodo == "DELETE" and caminho == "/apagar" then
        local arquivo = caminho_seguro(p.f)
        if not arquivo or lfs.attributes(arquivo, "mode") ~= "file" then
            return self:responder(client, 404, "text/plain", "Livro não encontrado.")
        end
        local codigo, msg = apagar_livro(arquivo)
        return self:responder(client, codigo, "text/plain", msg)
    end
    if metodo == "PUT" and caminho == "/renomear" then
        local arquivo = caminho_seguro(p.f)
        if not arquivo or lfs.attributes(arquivo, "mode") ~= "file" then
            return self:responder(client, 404, "text/plain", "Livro não encontrado.")
        end
        local codigo, msg = renomear_livro(arquivo, p.nome)
        return self:responder(client, codigo, "text/plain", msg)
    end
    if metodo ~= "GET" then
        return self:responder(client, 405, "text/plain", "Método não aceito.")
    end
    if caminho == "/" then
        return self:responder(client, 200, "text/html", montar_pagina())
    elseif caminho == "/abrir" then
        local arquivo = caminho_seguro(p.f)
        if not arquivo or lfs.attributes(arquivo, "mode") ~= "file" then
            return self:responder(client, 404, "text/plain", "Livro não encontrado.")
        end
        -- abre depois de responder: abrir o livro fecha esta instância do plugin (e o servidor)
        UIManager:nextTick(function()
            require("apps/reader/readerui"):showReader(arquivo)
        end)
        return self:responder(client, 200, "text/plain", "Abrindo.")
    elseif caminho == "/pagina" then
        local _, total = paginas()
        local n = tonumber(p.n)
        if not total then return self:responder(client, 409, "text/plain", "Nenhum livro aberto no Kindle.") end
        if not n or n ~= math.floor(n) or n < 1 or n > total then
            return self:responder(client, 400, "text/plain", "Escolha uma página de 1 a " .. total .. ".")
        end
        UIManager:nextTick(function() UIManager:sendEvent(Event:new("GotoPage", n)) end)
        return self:responder(client, 200, "text/plain", "Indo para a página " .. n .. ".")
    elseif caminho == "/fonte" then
        local atual, d = fonte_atual(), tonumber(p.d)
        if not atual then return self:responder(client, 409, "text/plain", "Esse livro não tem fonte ajustável (PDF ou quadrinhos).") end
        if not d or d ~= math.floor(d) or d == 0 or math.abs(d) > 10 then
            return self:responder(client, 400, "text/plain", "Ajuste inválido.")
        end
        local novo = math.max(12, math.min(atual + d, 255)) -- mesmos limites do ReaderFont:onSetFontSize
        UIManager:nextTick(function() UIManager:sendEvent(Event:new("SetFontSize", novo)) end)
        return self:responder(client, 200, "text/plain", "Fonte: " .. novo)
    elseif caminho == "/gravar" then
        set_gravacao(p.on == "1")
        return self:responder(client, 200, "text/plain", "ok")
    elseif caminho == "/sair" then
        UIManager:nextTick(function() UIManager:sendEvent(Event:new("Exit")) end)
        return self:responder(client, 200, "text/plain", "Fechando o KOReader.")
    end
    return self:responder(client, 404, "text/plain", "Não encontrado.")
end

function Leitor:addToMainMenu(menu_items)
    menu_items.leitor = {
        text = "Leitor (touch e página)",
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = "Gravar toques crus em " .. CONFIG.log_toques,
                checked_func = function() return arquivo_log ~= nil end,
                callback = function() set_gravacao(not arquivo_log) end,
            },
            {
                text = "Página web ligada",
                checked_func = function() return settings.servidor end,
                callback = function()
                    settings.servidor = not settings.servidor
                    G_reader_settings:saveSetting("leitor", settings)
                    if settings.servidor then self:start() else self:stop() end
                end,
            },
            {
                text = "Mostrar endereço da página",
                callback = function() self:mostrarEndereco() end,
            },
        },
    }
end

return Leitor
