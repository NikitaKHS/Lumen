;=====================================================================
; Построение кривой из параметров редактора
;=====================================================================
; Параметры режима (хранятся в .crv3 строкой «; lumen: k=v|k=v|...»):
;   base       — файл кривой-основы ("" — стандарт)
;   exp        — экспозиция, -100..100 (±1 ступень)
;   gamma      — гамма ×100, 50..250 (больше — светлее средние тона)
;   contrast   — контраст, -100..100
;   black      — точка чёрного, -50..50 (плюс — приподнять чёрное, минус — углубить)
;   shadows    — тени, -100..100
;   highlights — света, -100..100
;   temp       — цветовая температура, 3000..9000 K (6500 — нейтрально)
;   vib        — насыщенность NVIDIA 0..100 ("" — не менять)
;   pts        — 9 точек кривой мышкой (выход при входе 0, 1/8, ... 1)

DefaultParams() => {src: "", exp: 0, gamma: 100, contrast: 0, black: 0, shadows: 0, highlights: 0,
    temp: 6500, vib: "", pts: [0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1]}

global PRESETS := [
    ["Ночное зрение",     {gamma: 160, shadows: 40, black: 10}],
    ["Яркие тени",        {gamma: 120, shadows: 60}],
    ["Мягкие сумерки",    {gamma: 125, shadows: 25, highlights: -10}],
    ["Контраст",          {contrast: 25, shadows: 15, black: -5}],
    ["Лес (насыщенный)",  {shadows: 30, contrast: 10, vib: 75}],
    ["Тёплый",            {temp: 5200}],
    ["Холодный",          {temp: 8000}]
]

ParamsToString(P) {
    pts := ""
    for v in P.pts
        pts .= (pts = "" ? "" : ",") Format("{:.4f}", v)
    return "base=" P.src "|exp=" P.exp "|gamma=" P.gamma "|contrast=" P.contrast "|black=" P.black
        . "|shadows=" P.shadows "|highlights=" P.highlights "|temp=" P.temp "|vib=" P.vib "|pts=" pts
}

ParseParams(s) {
    P := DefaultParams()
    for kv in StrSplit(s, "|") {
        eq := InStr(kv, "=")
        if !eq
            continue
        k := Trim(SubStr(kv, 1, eq - 1)), v := Trim(SubStr(kv, eq + 1))
        switch k {
            case "base":
                P.src := v
            case "vib":
                P.vib := IsInteger(v) ? Integer(v) : ""
            case "pts":
                arr := []
                for x in StrSplit(v, ",")
                    if IsNumber(x)
                        arr.Push(Max(0, Min(1, Number(x))))
                if arr.Length = 9
                    P.pts := arr
            case "exp", "gamma", "contrast", "black", "shadows", "highlights", "temp":
                if IsNumber(v)
                    P.%k% := Number(v)
        }
    }
    return P
}

; Кривая по параметрам поверх основы. Возвращает буфер GAMMARAMP.
BuildToneRamp(P, baseBuf) {
    lut := PtsLut(P.pts)
    mul := KelvinMul(P.temp)
    e := 2 ** (P.exp / 100), gm := P.gamma / 100
    s := P.shadows / 100 * 1.5, h := P.highlights / 100 * 1.5, ct := 1 + P.contrast / 100
    bp := P.black / 500
    buf := Buffer(1536)
    loop 3 {
        ch := A_Index - 1, prev := 0, m := mul[A_Index]
        loop 256 {
            o := ch * 512 + (A_Index - 1) * 2
            y := NumGet(baseBuf, o, "UShort") / 65535 * e
            y := y > 0 ? Min(y, 1) ** (1 / gm) : 0
            y := y + s * y * (1 - y) ** 2 + h * y * y * (1 - y)
            y := 0.5 + (y - 0.5) * ct
            y := bp >= 0 ? bp + y * (1 - bp) : (y + bp) / (1 + bp)
            y := Max(0, Min(1, y))
            f := y * 255, k := Min(Floor(f), 254), t := f - k
            y := lut[k + 1] + (lut[k + 2] - lut[k + 1]) * t
            v := Round(Max(0, Min(1, y * m)) * 65535)
            v := Max(v, prev), prev := v                  ; кривая не должна убывать
            NumPut("UShort", v, buf, o)
        }
    }
    return buf
}

; Монотонная кубическая интерполяция (Фрич — Карлсон) по точкам на равных
; промежутках — плавная кривая без «перелётов». Возвращает 256 значений 0..1.
PtsLut(p) {
    n := p.Length, hh := 1 / (n - 1)
    d := [], m := []
    loop n - 1
        d.Push((p[A_Index + 1] - p[A_Index]) / hh)
    m.Push(d[1])
    loop n - 2
        m.Push(d[A_Index] * d[A_Index + 1] <= 0 ? 0 : (d[A_Index] + d[A_Index + 1]) / 2)
    m.Push(d[n - 1])
    loop n - 1 {
        k := A_Index
        if d[k] = 0 {
            m[k] := 0, m[k + 1] := 0
            continue
        }
        a := m[k] / d[k], b := m[k + 1] / d[k], q := a * a + b * b
        if q > 9 {
            t := 3 / Sqrt(q)
            m[k] := t * a * d[k], m[k + 1] := t * b * d[k]
        }
    }
    lut := []
    loop 256 {
        x := (A_Index - 1) / 255
        k := Min(Floor(x / hh), n - 2) + 1
        t := (x - (k - 1) * hh) / hh, t2 := t * t, t3 := t2 * t
        y := (2 * t3 - 3 * t2 + 1) * p[k] + (t3 - 2 * t2 + t) * hh * m[k]
           + (-2 * t3 + 3 * t2) * p[k + 1] + (t3 - t2) * hh * m[k + 1]
        lut.Push(Max(0, Min(1, y)))
    }
    return lut
}

; Множители каналов для цветовой температуры относительно 6500 K
KelvinMul(K) {
    a := KelvinRGB(K), r := KelvinRGB(6500)
    m := [a[1] / r[1], a[2] / r[2], a[3] / r[3]]
    top := Max(m[1], m[2], m[3])
    return [m[1] / top, m[2] / top, m[3] / top]
}

; Приближение Таннера Хелланда: цвет абсолютно чёрного тела, 0..255
KelvinRGB(K) {
    t := K / 100
    r := t <= 66 ? 255 : 329.698727446 * ((t - 60) ** (-0.1332047592))
    gr := t <= 66 ? 99.4708025861 * Ln(t) - 161.1195681661 : 288.1221695283 * ((t - 60) ** (-0.0755148492))
    b := t >= 66 ? 255 : t <= 19 ? 0 : 138.5177312231 * Ln(t - 10) - 305.0447927307
    return [Max(1, Min(255, r)), Max(1, Min(255, gr)), Max(1, Min(255, b))]
}

; Кривая-основа по имени файла
BaseBuf(file) {
    if file = ""
        return IDENTITY
    for i, m in MODES
        if m.file = file
            return CURVES[i]
    buf := ParseCurve(CURVE_DIR file, &t, &p)
    return buf ? buf : IDENTITY
}

; Записывает кривую в файл .crv3
WriteCurve(path, name, buf, params := "") {
    text := "; " name "`r`n"
    if params != ""
        text .= "; lumen: " params "`r`n"
    loop 256 {
        o := (A_Index - 1) * 2
        text .= (A_Index - 1) "`t" NumGet(buf, o, "UShort") "`t" NumGet(buf, 512 + o, "UShort")
            . "`t" NumGet(buf, 1024 + o, "UShort") "`r`n"
    }
    if FileExist(path)
        FileDelete(path)
    FileAppend(text, path, "UTF-8-RAW")
}

SafeFileName(name) => RegExReplace(Trim(name), '[\\/:*?"<>|]', "_") ".crv3"
