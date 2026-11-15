"""Рисует график кривых режимов для README: docs/curves-light.svg и docs/curves-dark.svg.

Запуск из корня репозитория:  python tools/curve_chart.py
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SERIES = [  # файл, подпись, цвет светлой темы, цвет тёмной темы
    ("night2.crv3", "Ночь 2", "#eb6834", "#d95926"),
    ("night1.crv3", "Ночь 1", "#2a78d6", "#3987e5"),
    ("dusk2.crv3", "Сумерки 2", "#eda100", "#c98500"),
    ("dusk1.crv3", "Сумерки 1", "#1baf7a", "#199e70"),
]
THEMES = {
    "light": dict(bg="#fcfcfb", text="#0b0b0b", text2="#52514e", muted="#8a8984", grid="#e6e5e0", axis="#c3c2b7"),
    "dark": dict(bg="#1a1a19", text="#f0efec", text2="#c3c2b7", muted="#8f8e88", grid="#2c2c2a", axis="#4a4a47"),
}
FONT = "Segoe UI, system-ui, -apple-system, sans-serif"


def load(name):
    vals = [0] * 256
    for line in (ROOT / "curves" / name).read_text(encoding="utf-8").splitlines():
        p = line.split()
        if len(p) >= 4 and p[0].isdigit() and int(p[0]) < 256:
            i = int(p[0])
            vals[i] = (int(p[1]) + int(p[2]) + int(p[3])) / 3 / 65535 * 100
    return vals


def dodge(items, gap):
    """Раздвигает подписи по вертикали, чтобы не налезали (items: [y, ...])."""
    items.sort(key=lambda it: it[0])
    for k in range(1, len(items)):
        if items[k][0] - items[k - 1][0] < gap:
            items[k][0] = items[k - 1][0] + gap
    return items


def panel(out, t, x0, y0, w, h, xmax, title, curves, std, label_right):
    sx = lambda i: x0 + i / xmax * w
    sy = lambda v: y0 + h - v / 100 * h
    out.append(f'<text x="{x0}" y="{y0 - 14}" fill="{t["text"]}" font-size="14" font-weight="600">{title}</text>')
    for v in range(0, 101, 25):
        y = sy(v)
        out.append(f'<line x1="{x0}" x2="{x0 + w}" y1="{y:.1f}" y2="{y:.1f}" stroke="{t["grid"]}" stroke-width="1"/>')
        out.append(f'<text x="{x0 - 8}" y="{y + 4:.1f}" fill="{t["muted"]}" font-size="11" text-anchor="end">{v}%</text>')
    step = 64 if xmax == 255 else 16
    for i in range(0, xmax + 1, step):
        out.append(f'<text x="{sx(i):.1f}" y="{y0 + h + 18}" fill="{t["muted"]}" font-size="11" text-anchor="middle">{i}</text>')
    if xmax == 255:
        out.append(f'<text x="{sx(255):.1f}" y="{y0 + h + 18}" fill="{t["muted"]}" font-size="11" text-anchor="middle">255</text>')
    out.append(f'<line x1="{x0}" x2="{x0 + w}" y1="{y0 + h}" y2="{y0 + h}" stroke="{t["axis"]}" stroke-width="1"/>')

    def path(vals):
        return "M" + " L".join(f"{sx(i):.1f},{sy(vals[i]):.1f}" for i in range(xmax + 1))

    out.append(f'<path d="{path(std)}" fill="none" stroke="{t["muted"]}" stroke-width="2" stroke-dasharray="5 4"/>')
    for vals, _, color in curves:
        out.append(f'<path d="{path(vals)}" fill="none" stroke="{color}" stroke-width="2" '
                   f'stroke-linejoin="round" stroke-linecap="round"/>')
    if label_right:
        items = [[sy(v[xmax]), name, c, v[xmax]] for v, name, c in curves]
        items.append([sy(std[xmax]), "Стандарт", t["muted"], std[xmax]])
        for y, name, c, val in dodge(items, 16):
            yv = sy(val)
            out.append(f'<line x1="{x0 + w + 2}" x2="{x0 + w + 10}" y1="{yv:.1f}" y2="{y:.1f}" stroke="{c}" stroke-width="1.5"/>')
            out.append(f'<circle cx="{x0 + w + 15}" cy="{y:.1f}" r="4" fill="{c}"/>')
            out.append(f'<text x="{x0 + w + 23}" y="{y + 4:.1f}" fill="{t["text2"]}" font-size="12">'
                       f'{name} · {val:.0f}%</text>')


def render(mode):
    t = THEMES[mode]
    std = [i / 255 * 100 for i in range(256)]
    curves = [(load(f), name, light if mode == "light" else dark) for f, name, light, dark in SERIES]
    W, H = 960, 430
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
           f'font-family="{FONT}">',
           f'<rect width="{W}" height="{H}" rx="12" fill="{t["bg"]}"/>',
           f'<text x="28" y="38" fill="{t["text"]}" font-size="18" font-weight="700">Кривые режимов Lumen</text>',
           f'<text x="28" y="60" fill="{t["text2"]}" font-size="13">По горизонтали — исходная яркость пикселя (0–255), '
           f'по вертикали — яркость на экране. Пунктир — стандарт Windows.</text>']
    # легенда
    lx = 28
    for _, name, c in curves:
        out.append(f'<line x1="{lx}" x2="{lx + 18}" y1="84" y2="84" stroke="{c}" stroke-width="3" stroke-linecap="round"/>')
        out.append(f'<text x="{lx + 24}" y="88" fill="{t["text2"]}" font-size="12">{name}</text>')
        lx += 24 + len(name) * 7.5 + 22
    out.append(f'<line x1="{lx}" x2="{lx + 18}" y1="84" y2="84" stroke="{t["muted"]}" stroke-width="2" stroke-dasharray="5 4"/>')
    out.append(f'<text x="{lx + 24}" y="88" fill="{t["text2"]}" font-size="12">Стандарт</text>')

    panel(out, t, 64, 138, 330, 240, 255, "Весь диапазон", curves, std, False)
    panel(out, t, 470, 138, 300, 240, 64, "Тени крупно (0–64)", curves, std, True)
    out.append(f'<text x="{64 + 165}" y="{138 + 240 + 40}" fill="{t["muted"]}" font-size="11" text-anchor="middle">исходная яркость</text>')
    out.append(f'<text x="{470 + 150}" y="{138 + 240 + 40}" fill="{t["muted"]}" font-size="11" text-anchor="middle">исходная яркость</text>')
    out.append("</svg>")
    (ROOT / "docs").mkdir(exist_ok=True)
    (ROOT / "docs" / f"curves-{mode}.svg").write_text("\n".join(out), encoding="utf-8")


def table():
    """Печатает markdown-таблицу «во сколько раз ярче тени»."""
    std = lambda i: i / 255 * 100
    pts = [8, 16, 32, 64, 128]
    print("| Режим | " + " | ".join(f"вход {p}" for p in pts) + " |")
    print("|---|" + "---|" * len(pts))
    print("| Стандарт | " + " | ".join(f"{std(p):.0f}%" for p in pts) + " |")
    for f, name, *_ in sorted(SERIES, key=lambda s: s[0]):
        v = load(f)
        print(f"| {name} | " + " | ".join(f"{v[p]:.0f}% (×{v[p] / std(p):.1f})" for p in pts) + " |")


if __name__ == "__main__":
    render("light")
    render("dark")
    table()
