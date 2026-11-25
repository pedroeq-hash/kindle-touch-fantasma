"""Mapa de calor dos toques gravados pelo plugin leitor.koplugin.

Uso:
    python tools/mapa_toques.py D:\\toques.log [saida.svg] [--areas x1,y1,x2,y2 x1,y1,x2,y2]
    python tools/mapa_toques.py --teste

O log tem uma linha por evento cru do touch: "seg.usec tipo codigo valor".
Gera um SVG da tela (1072x1448) com a contagem de toques por célula e imprime estatísticas.
"""
import sys
from collections import Counter

LARGURA, ALTURA, CELULA = 1072, 1448, 32
EV_SYN, EV_ABS = 0, 3
SYN_REPORT = 0
ABS_X, ABS_Y = 0, 1
ABS_MT_SLOT, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID = 0x2F, 0x35, 0x36, 0x39


def toques(linhas):
    """Mesmo rastreio do plugin (protocolo multitouch tipo B). Devolve dicts com x0,y0,x,y,dur,dedos,t."""
    slots, atual, saida = {}, 0, []
    for linha in linhas:
        partes = linha.split()
        if len(partes) != 4:
            continue
        t = float(partes[0]) * 1000
        tipo, codigo, valor = int(partes[1]), int(partes[2]), int(partes[3])
        if tipo == EV_ABS:
            if codigo == ABS_MT_SLOT:
                atual = valor
            elif codigo == ABS_MT_TRACKING_ID:
                if valor >= 0:
                    slots[atual] = {"dedos": 0}
                elif atual in slots:
                    slots[atual]["solto"] = True
            elif codigo in (ABS_MT_POSITION_X, ABS_X) and atual in slots:
                slots[atual]["x"] = valor
                slots[atual].setdefault("x0", valor)
            elif codigo in (ABS_MT_POSITION_Y, ABS_Y) and atual in slots:
                slots[atual]["y"] = valor
                slots[atual].setdefault("y0", valor)
        elif tipo == EV_SYN and codigo == SYN_REPORT:
            n = sum(1 for c in slots.values() if not c.get("solto"))
            for s in list(slots):
                c = slots[s]
                c.setdefault("t0", t)
                c["dedos"] = max(c["dedos"], n)
                if c.get("solto"):
                    del slots[s]
                    if "x" in c and "y" in c:
                        saida.append({"x0": c["x0"], "y0": c["y0"], "x": c["x"], "y": c["y"],
                                      "dur": t - c["t0"], "dedos": c["dedos"], "t": c["t0"]})
    return saida


def svg(lista, areas):
    cont = Counter((min(int(t["x"]) // CELULA, LARGURA // CELULA), min(int(t["y"]) // CELULA, ALTURA // CELULA))
                   for t in lista)
    maximo = max(cont.values(), default=1)
    partes = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {LARGURA} {ALTURA}" width="536" height="724">',
              f'<rect width="{LARGURA}" height="{ALTURA}" fill="#fff" stroke="#000" stroke-width="4"/>']
    for (cx, cy), n in cont.items():
        alfa = 0.25 + 0.75 * (n / maximo) ** 0.5  # raiz: células com poucos toques continuam visíveis
        partes.append(f'<rect x="{cx * CELULA}" y="{cy * CELULA}" width="{CELULA}" height="{CELULA}" '
                      f'fill="#d00" fill-opacity="{alfa:.2f}"><title>{n} toques</title></rect>')
    for i, (x1, y1, x2, y2) in enumerate(areas):
        cor = "#06c" if i == 0 else "#090"
        partes.append(f'<rect x="{x1}" y="{y1}" width="{x2 - x1}" height="{y2 - y1}" fill="none" '
                      f'stroke="{cor}" stroke-width="6" stroke-dasharray="20 10"/>')
    partes.append("</svg>")
    return "\n".join(partes)


def estatisticas(lista):
    if not lista:
        return "Nenhum toque no log."
    dur = Counter("<50ms" if t["dur"] < 50 else "50-150ms" if t["dur"] < 150 else
                  "150-400ms" if t["dur"] < 400 else ">400ms" for t in lista if t["dedos"] == 1)
    dedos = Counter(t["dedos"] for t in lista)
    seg = (lista[-1]["t"] - lista[0]["t"]) / 1000 or 1
    ys = Counter(int(t["y"]) // CELULA * CELULA for t in lista).most_common(5)
    return "\n".join([
        f"Toques: {len(lista)} em {seg:.0f} s ({len(lista) / seg:.2f}/s)",
        "Dedos simultâneos: " + ", ".join(f"{k}: {v}" for k, v in sorted(dedos.items())),
        "Duração (1 dedo): " + ", ".join(f"{k}: {dur[k]}" for k in ("<50ms", "50-150ms", "150-400ms", ">400ms")),
        "Faixas (y) com mais toques: " + ", ".join(f"y {y}-{y + CELULA - 1}: {n}" for y, n in ys),
    ])


def teste():
    log = [  # 1 dedo em (100,200) por 100 ms; depois 2 dedos juntos
        "1.000000 3 47 0", "1.000000 3 57 5", "1.000000 3 53 100", "1.000000 3 54 200", "1.000000 0 0 0",
        "1.100000 3 57 -1", "1.100000 0 0 0",
        "2.000000 3 47 0", "2.000000 3 57 6", "2.000000 3 53 10", "2.000000 3 54 20",
        "2.000000 3 47 1", "2.000000 3 57 7", "2.000000 3 53 500", "2.000000 3 54 600", "2.000000 0 0 0",
        "2.050000 3 47 0", "2.050000 3 57 -1", "2.050000 3 47 1", "2.050000 3 57 -1", "2.050000 0 0 0",
    ]
    r = toques(log)
    assert len(r) == 3, r
    assert (r[0]["x"], r[0]["y"], r[0]["dedos"]) == (100, 200, 1) and abs(r[0]["dur"] - 100) < 1, r[0]
    assert all(t["dedos"] == 2 for t in r[1:]), r[1:]
    assert "<svg" in svg(r, [(0, 0, 10, 10)])
    print("teste ok")


def main(args):
    if args == ["--teste"]:
        return teste()
    if not args:
        sys.exit(__doc__)
    areas = []
    if "--areas" in args:
        i = args.index("--areas")
        areas = [tuple(int(v) for v in a.split(",")) for a in args[i + 1:]]
        args = args[:i]
    entrada = args[0]
    saida = args[1] if len(args) > 1 else "mapa_toques.svg"
    with open(entrada, encoding="ascii", errors="replace") as f:
        lista = toques(f)
    with open(saida, "w", encoding="utf-8") as f:
        f.write(svg(lista, areas))
    print(estatisticas(lista))
    print(f"Mapa salvo em {saida}")


if __name__ == "__main__":
    main(sys.argv[1:])
