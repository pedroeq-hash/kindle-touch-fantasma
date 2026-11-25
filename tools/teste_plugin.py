"""Testa o leitor.koplugin no PC: carrega main.lua num LuaJIT (pip install --target <pasta> lupa) com módulos falsos do KOReader.

Uso: python -I tools/teste_plugin.py <pasta do lupa> [main.lua]
"""
import sys, pathlib
sys.path.insert(0, sys.argv[1])
try:
    from lupa import luajit21 as lm
except ImportError:
    import lupa as lm
aqui = pathlib.Path(__file__).parent
L = lm.LuaRuntime()
print("Lua:", L.eval("_VERSION"), "(LuaJIT)" if L.eval("jit ~= nil") else "")
L.globals().SRC = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else aqui.parent / "koreader/plugins/leitor.koplugin/main.lua").read_text(encoding="utf-8")
L.execute((aqui / "teste_plugin_stubs.lua").read_text(encoding="utf-8"))
req = L.globals().req
pag = req("GET /")
corpo = pag.split("\r\n\r\n", 1)[1]
saida = pathlib.Path(sys.argv[1]) / "pagina.html"
saida.write_text(corpo, encoding="utf-8")
assert pag.startswith("HTTP/1.0 200"), pag[:80]
assert "%" + "LIVROS%" not in corpo and "%GRAVAR" not in corpo and "%QTD%" not in corpo and "/filtro" not in corpo, "placeholder ou filtro sobrou"
assert ".txt" not in corpo and "Clippings" not in corpo and "all_system" not in corpo, "txt na lista"
assert "F scott fitzgerald o grande gatsby" in corpo, "título Amazon"
assert "Dom Casmurro - Machado de Assis" in corpo and 'class="lendo"' in corpo and 'class="atual"' in corpo, "livro aberto"
assert "100% &lt;b&gt;" in corpo, "escape"
assert "4 livros" in corpo, "contagem"
assert "1,5 MB" in corpo and "ontem" in corpo, "meta"
assert "parcial" not in corpo and "x.sdr" not in corpo
assert req("DELETE /apagar?f=Dom%20Casmurro%20-%20Machado%20de%20Assis.epub").startswith("HTTP/1.0 409"), "aberto não apaga"
assert req("DELETE /apagar?f=..%2F..%2Fetc%2Fpasswd").startswith("HTTP/1.0 404")
assert req("DELETE /apagar?f=My%20Clippings.txt").startswith("HTTP/1.0 404"), "txt não apaga"
r = req("DELETE /apagar?f=spidercat.azw3"); assert r.startswith("HTTP/1.0 200"), r
assert "spidercat" not in req("GET /")
assert req("GET /filtro?on=0").startswith("HTTP/1.0 404"), "filtro não se desliga"
assert req("GET /gravar?on=0").startswith("HTTP/1.0 200")
assert req("POST /x").startswith("HTTP/1.0 405")
r = req("PUT /wifi", "ssid=Celular%20de%20Teste&senha=senha%2B123%26x"); assert r.startswith("HTTP/1.0 200"), r
rede = L.globals().rede_salva
assert (rede.ssid, rede.password, rede.flags) == ("Celular de Teste", "senha+123&x", "WPA2"), dict(rede)
assert req("PUT /wifi", "ssid=x&senha=curta").startswith("HTTP/1.0 400"), "senha curta"
assert req("PUT /wifi", "ssid=&senha=").startswith("HTTP/1.0 400"), "sem nome"
r = req("PUT /wifi", "ssid=Aberta"); assert r.startswith("HTTP/1.0 200") and L.globals().rede_salva.flags == "", r
assert 'id="wifi"' in corpo
assert "Bateria 73% · 4 livros" in corpo, "bateria"
assert 'id="ir"' in corpo and 'value="15"' in corpo and "/ 257" in corpo, "página do livro aberto"
r = req("GET /pagina?n=200"); assert r.startswith("HTTP/1.0 200"), r
L.globals().ultimo_tick()
ev = L.globals().evento_enviado; assert (ev.name, ev.args) == ("GotoPage", 200), (ev.name, ev.args)
for n in ("0", "258", "1.5", "abc", ""):
    assert req("GET /pagina?n=" + n).startswith("HTTP/1.0 400"), "página " + n
G = L.globals()
L.execute("removidos = {}")  # spidercat volta (foi apagado acima)
r = req("PUT /renomear?f=Downloads%2FItems01%2Ff-scott-fitzgerald-o-grande-gatsby.pdf-cdeKey_5AK3DW2JSKNSHRX7JU6CJ5SINFN3SJH5.pdf&nome=%20O%20Grande%20Gatsby%20")
assert r.startswith("HTTP/1.0 200"), r
pasta = "/mnt/us/documents/Downloads/Items01/"
assert G.renomeado == pasta + "f-scott-fitzgerald-o-grande-gatsby.pdf-cdeKey_5AK3DW2JSKNSHRX7JU6CJ5SINFN3SJH5.pdf>" + pasta + "O Grande Gatsby.pdf", G.renomeado
assert G.sdr_movido == G.renomeado, "posição de leitura não acompanhou"
assert req("PUT /renomear?f=Dom%20Casmurro%20-%20Machado%20de%20Assis.epub&nome=X").startswith("HTTP/1.0 409"), "aberto não renomeia"
for ruim in ("a%2Fb", "..", "", "%20", "Livro%3A%20parte"):
    assert req("PUT /renomear?f=spidercat.azw3&nome=" + ruim).startswith("HTTP/1.0 4"), "nome " + ruim
assert req("PUT /renomear?f=Downloads%2FItems01%2F100%25%20%3Cb%3E.epub&nome=..%20x").startswith("HTTP/1.0 400"), "nome com ponto no início"
L.execute('arquivos["/mnt/us/documents"][#arquivos["/mnt/us/documents"] + 1] = "Outro.azw3"')
assert req("PUT /renomear?f=spidercat.azw3&nome=Outro").startswith("HTTP/1.0 409"), "já existe"
assert req("PUT /renomear?f=..%2Fx.epub&nome=y").startswith("HTTP/1.0 404")
G.renomeado = None
assert req("PUT /renomear?f=spidercat.azw3&nome=SpiderCat").startswith("HTTP/1.0 200") and G.renomeado.endswith(">/mnt/us/documents/SpiderCat.azw3"), "só maiúscula"
assert G.teste_reinstalar()
print("teste ok; página em", saida)
