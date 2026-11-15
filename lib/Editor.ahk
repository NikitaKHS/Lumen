;=====================================================================
; Редактор режима: ползунки, пресеты, кривая мышкой, живой просмотр
;=====================================================================
global ED := 0, editing := false

global ED_SLIDERS := [
    ["exp",        "Экспозиция",    -100, 100],
    ["gamma",      "Гамма",           50, 250],
    ["contrast",   "Контраст",      -100, 100],
    ["black",      "Точка чёрного",  -50,  50],
    ["shadows",    "Тени",          -100, 100],
    ["highlights", "Света",         -100, 100],
    ["temp",       "Температура",     30,  90]
]

EdFormat(key, v) {
    switch key {
        case "gamma": return Format("{:.2f}", v / 100)
        case "temp":  return Round(v) " K"
        case "exp":   return (v > 0 ? "+" : "") Format("{:.2f}", v / 100) " EV"
        case "vib":   return v = "" ? "выкл" : v "%"
        default:      return (v > 0 ? "+" : "") Round(v)
    }
}

EdSliderValue(key, P) => key = "temp" ? Round(P.temp / 100) : key = "vib" ? (P.vib = "" ? 50 : P.vib) : Round(P.%key%)

; modeIdx: 0 — новый режим с нуля, иначе редактировать / взять за основу режим
OpenEditor(modeIdx := 0) {
    global ED, editing
    if ED {
        ED.gui.Show()
        return
    }
    P := DefaultParams(), name := "Мой режим", target := ""
    if modeIdx > 1 {
        m := MODES[modeIdx]
        if m.params != "" {
            P := ParseParams(m.params), name := m.name, target := m.file
        } else {
            P.src := m.file, name := m.name " — мой"
        }
    }
    ED := {P: P, target: target, sl: Map(), val: Map(), keyOf: Map(), buf: 0}
    editing := true

    E := Gui("-MaximizeBox -MinimizeBox", "Lumen — редактор режима")
    E.BackColor := C.bg
    E.MarginX := 0, E.MarginY := 0
    E.OnEvent("Close", (*) => CloseEditor(false))
    E.OnEvent("Escape", (*) => CloseEditor(false))
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", E.Hwnd, "int", 20, "int*", 1, "int", 4)
    try E.Opt("+Owner" G.Hwnd)
    ED.gui := E

    ; график
    ED.pic := E.Add("Picture", "x24 y24 w300 h300 0xE 0x100")
    CLICK_MAP[ED.pic.Hwnd] := true
    E.SetFont("s8 norm c" C.muted, "Segoe UI")
    E.Add("Text", "x24 y334 w300 h90 Background" C.bg,
        "Тяните точки мышью — это своя кривая поверх ползунков. Двойной клик по точке возвращает её на место.`n`n"
        "Пунктир — стандарт, тонкая линия — кривая точек, яркая — итог.")

    ; название, основа, пресет
    y := 24
    EdLabel(E, y, "Название")
    E.SetFont("s10 norm c" C.text)
    ED.name := E.Add("Edit", "x452 y" y " w284 h28 -E0x200 Background" C.panel2, name)

    y += 40
    EdLabel(E, y, "Основа")
    ED.baseFiles := [""]
    items := ["Стандарт"]
    for i, m in MODES
        if i > 1 && m.file != target
            ED.baseFiles.Push(m.file), items.Push(m.name)
    E.SetFont("s10 norm c" C.text)
    ED.baseDdl := E.Add("DropDownList", "x452 y" y " w284 R12 Background" C.panel, items)
    sel := 1
    for k, f in ED.baseFiles
        if f = P.src
            sel := k
    P.src := ED.baseFiles[sel]
    ED.baseDdl.Value := sel
    ED.baseDdl.OnEvent("Change", (*) => (ED.P.src := ED.baseFiles[ED.baseDdl.Value], EdPreview()))
    TIPS[ED.baseDdl.Hwnd] := "Кривая, поверх которой применяются настройки"

    y += 40
    EdLabel(E, y, "Пресет")
    names := ["— свои настройки —"]
    for p in PRESETS
        names.Push(p[1])
    ED.preset := E.Add("DropDownList", "x452 y" y " w284 R10 Background" C.panel, names)
    ED.preset.Value := 1
    ED.preset.OnEvent("Change", EdPresetChange)
    for ctl in [ED.baseDdl, ED.preset]
        try DllCall("uxtheme\SetWindowTheme", "ptr", ctl.Hwnd, "str", "DarkMode_CFD", "ptr", 0)

    ; ползунки
    y += 48
    for s in ED_SLIDERS {
        EdLabel(E, y + 4, s[2])
        sl := E.Add("Slider", "x444 y" y " w244 h30 NoTicks Range" s[3] "-" s[4] " Background" C.bg, EdSliderValue(s[1], P))
        E.SetFont("s9 bold c" C.text)
        vt := E.Add("Text", "x688 y" (y + 4) " w56 h22 Right 0x200 Background" C.bg, EdFormat(s[1], P.%s[1]%))
        ED.sl[s[1]] := sl, ED.val[s[1]] := vt, ED.keyOf[sl.Hwnd] := s[1]
        y += 38
    }

    ; насыщенность NVIDIA
    hasNv := NvAvailable()
    EdLabel(E, y + 4, "Насыщенность")
    ED.vibOn := E.Add("CheckBox", "x444 y" (y + 6) " w16 h18 Background" C.bg, "")
    ED.vibOn.Value := P.vib != ""
    ED.vibOn.OnEvent("Click", EdVibToggle)
    TIPS[ED.vibOn.Hwnd] := "Задать режиму свою насыщенность (Digital Vibrance NVIDIA).`nБез галочки — общая настройка из главного окна."
    sl := E.Add("Slider", "x462 y" y " w226 h30 NoTicks Range0-100 Background" C.bg, EdSliderValue("vib", P))
    E.SetFont("s9 bold c" C.text)
    vt := E.Add("Text", "x688 y" (y + 4) " w56 h22 Right 0x200 Background" C.bg, EdFormat("vib", P.vib))
    ED.sl["vib"] := sl, ED.val["vib"] := vt, ED.keyOf[sl.Hwnd] := "vib"
    if !hasNv {
        ED.vibOn.Enabled := false, sl.Enabled := false
        vt.Text := "нет NVIDIA"
    }
    y += 50

    ; кнопки
    E.SetFont("s10 bold c" C.muted)
    b := E.Add("Text", "x348 y" y " w124 h38 Center 0x200 0x100 Background" C.panel2, "Сбросить")
    Clickable(b, (*) => EdReset(), "Вернуть ползунки и точки к стандарту (основа остаётся)")
    b := E.Add("Text", "x480 y" y " w124 h38 Center 0x200 0x100 Background" C.panel2, "Отмена")
    Clickable(b, (*) => CloseEditor(false))
    E.SetFont("s10 bold c" C.accentText)
    b := E.Add("Text", "x612 y" y " w124 h38 Center 0x200 0x100 Background" C.accentDim, "Сохранить")
    Clickable(b, (*) => EdSave(), "Сохранить как режим (файл в папке curves)")
    y += 50
    E.SetFont("s9 norm c" C.warn)
    ED.note := E.Add("Text", "x24 y" y " w712 h20 0x200 Background" C.bg, "")

    E.Show("w760 h" (y + 32))
    EdPreview()
}

EdLabel(E, y, text) {
    E.SetFont("s9 bold c" C.muted, "Segoe UI")
    E.Add("Text", "x348 y" y " w96 h22 0x200 Background" C.bg, text)
}

CloseEditor(saved) {
    global ED, editing
    if !ED
        return
    ED.gui.Destroy()
    ED := 0
    editing := false
    if !saved
        ApplyCurrent()
}

EdPreview() {
    ED.buf := BuildToneRamp(ED.P, BaseBuf(ED.P.src))
    ok := true
    for dev in Devices() {
        if SetRamp(dev, ED.buf)
            TOUCHED[dev] := true
        else
            ok := false
    }
    ApplyVibrance(ED.P.vib != "" ? ED.P.vib : cfg.vibOn ? cfg.vib : "")
    ED.note.Text := ok ? "" : "Windows не принял такую кривую — ослабьте настройки (или см. «?» в главном окне)"
    EdDraw()
}

EdSync() {
    for key, sl in ED.sl {
        sl.Value := EdSliderValue(key, ED.P)
        ED.val[key].Text := EdFormat(key, ED.P.%key%)
    }
    if ED.vibOn.Enabled
        ED.vibOn.Value := ED.P.vib != ""
}

EdPresetChange(*) {
    i := ED.preset.Value
    if i = 1
        return
    P := DefaultParams()
    P.src := ED.P.src
    for k, v in PRESETS[i - 1][2].OwnProps()
        P.%k% := v
    if P.vib != "" && !ED.vibOn.Enabled
        P.vib := ""
    ED.P := P
    EdSync()
    EdPreview()
}

EdReset() {
    base := ED.P.src
    ED.P := DefaultParams()
    ED.P.src := base
    ED.preset.Value := 1
    EdSync()
    EdPreview()
}

EdVibToggle(*) {
    ED.P.vib := ED.vibOn.Value ? ED.sl["vib"].Value : ""
    ED.val["vib"].Text := EdFormat("vib", ED.P.vib)
    EdPreview()
}

; WM_HSCROLL от ползунков редактора — приходит непрерывно, пока тянут
EdScroll(wParam, lParam, msg, hwnd) {
    if !ED || !ED.keyOf.Has(lParam)
        return
    key := ED.keyOf[lParam], v := ED.sl[key].Value
    if key = "vib" {
        ED.vibOn.Value := 1
        ED.P.vib := v
    } else {
        ED.P.%key% := key = "temp" ? v * 100 : v
    }
    ED.val[key].Text := EdFormat(key, ED.P.%key%)
    ED.preset.Value := 1
    EdPreview()
}

;--- кривая мышкой ----------------------------------------------------
EdGeom() {
    S := Round(300 * A_ScreenDPI / 96), pad := Round(14 * A_ScreenDPI / 96)
    return {S: S, pad: pad, span: S - 2 * pad}
}

EdMouse(wParam, lParam, msg, hwnd) {
    if !ED || hwnd != ED.pic.Hwnd
        return
    geo := EdGeom()
    x := lParam & 0xFFFF
    k := Max(1, Min(9, Round((x - geo.pad) / geo.span * 8) + 1))
    if msg = 0x203 {                                   ; двойной клик — точку на место
        ED.P.pts[k] := (k - 1) / 8
        ED.preset.Value := 1
        EdPreview()
        return 0
    }
    pt := Buffer(8)
    loop {
        DllCall("GetCursorPos", "ptr", pt)
        DllCall("ScreenToClient", "ptr", ED.pic.Hwnd, "ptr", pt)
        v := Max(0, Min(1, Round(1 - (NumGet(pt, 4, "Int") - geo.pad) / geo.span, 3)))
        if v != ED.P.pts[k] {
            ED.P.pts[k] := v
            ED.preset.Value := 1
            EdPreview()
        }
        if !GetKeyState("LButton", "P")
            break
        Sleep(15)
    }
    return 0
}

EdDraw() {
    geo := EdGeom(), S := geo.S, pad := geo.pad, span := geo.span
    X(f) => Round(pad + f * span)
    Y(f) => Round(pad + (1 - f) * span)

    hdc := DllCall("CreateCompatibleDC", "ptr", 0, "ptr")
    bi := Buffer(40, 0)
    NumPut("UInt", 40, bi, 0), NumPut("Int", S, bi, 4), NumPut("Int", -S, bi, 8)
    NumPut("UShort", 1, bi, 12), NumPut("UShort", 24, bi, 14)
    pBits := 0
    hbm := DllCall("CreateDIBSection", "ptr", hdc, "ptr", bi, "uint", 0, "ptr*", &pBits, "ptr", 0, "uint", 0, "ptr")
    obm := DllCall("SelectObject", "ptr", hdc, "ptr", hbm, "ptr")
    DllCall("SetBkMode", "ptr", hdc, "int", 1)
    rc := Buffer(16, 0)
    NumPut("Int", S, rc, 8), NumPut("Int", S, rc, 12)
    br := DllCall("CreateSolidBrush", "uint", BGR(C.panel), "ptr")
    DllCall("FillRect", "ptr", hdc, "ptr", rc, "ptr", br)
    DllCall("DeleteObject", "ptr", br)

    loop 5 {
        f := (A_Index - 1) / 4
        GdiPoly(hdc, [X(f), X(f)], [Y(0), Y(1)], C.grid, 1)
        GdiPoly(hdc, [X(0), X(1)], [Y(f), Y(f)], C.grid, 1)
    }
    GdiPoly(hdc, [X(0), X(1)], [Y(0), Y(1)], C.muted, 1, 2)          ; стандарт — пунктир

    xs := [], ys := []
    for v in PtsLut(ED.P.pts)
        xs.Push(X((A_Index - 1) / 255)), ys.Push(Y(v))
    GdiPoly(hdc, xs, ys, C.muted, 1)                                  ; кривая точек

    w := Max(2, Round(2 * A_ScreenDPI / 96))
    chans := Abs(ED.P.temp - 6500) < 50 ? [[-1, C.accentText]] : [[0, "E5736B"], [1, "3FB97F"], [2, "6F9BFF"]]
    for chan in chans {
        xs := [], ys := []
        loop 256 {
            o := (A_Index - 1) * 2
            v := chan[1] < 0 ? (NumGet(ED.buf, o, "UShort") + NumGet(ED.buf, 512 + o, "UShort") + NumGet(ED.buf, 1024 + o, "UShort")) / 3
                : NumGet(ED.buf, chan[1] * 512 + o, "UShort")
            xs.Push(X((A_Index - 1) / 255)), ys.Push(Y(v / 65535))
        }
        GdiPoly(hdc, xs, ys, chan[2], w)
    }

    r := Round(5 * A_ScreenDPI / 96)
    pen := DllCall("CreatePen", "int", 0, "int", 1, "uint", BGR("FFFFFF"), "ptr")
    br := DllCall("CreateSolidBrush", "uint", BGR(C.accent), "ptr")
    op := DllCall("SelectObject", "ptr", hdc, "ptr", pen, "ptr"), ob := DllCall("SelectObject", "ptr", hdc, "ptr", br, "ptr")
    for v in ED.P.pts {
        cx := X((A_Index - 1) / 8), cy := Y(v)
        DllCall("Ellipse", "ptr", hdc, "int", cx - r, "int", cy - r, "int", cx + r + 1, "int", cy + r + 1)
    }
    DllCall("SelectObject", "ptr", hdc, "ptr", op), DllCall("SelectObject", "ptr", hdc, "ptr", ob)
    DllCall("DeleteObject", "ptr", pen), DllCall("DeleteObject", "ptr", br)

    DllCall("SelectObject", "ptr", hdc, "ptr", obm)
    DllCall("DeleteDC", "ptr", hdc)
    old := SendMessage(0x172, 0, hbm, ED.pic.Hwnd)                   ; STM_SETIMAGE
    if old
        DllCall("DeleteObject", "ptr", old)
    if SendMessage(0x173, 0, 0, ED.pic.Hwnd) != hbm
        DllCall("DeleteObject", "ptr", hbm)
}

GdiPoly(hdc, xs, ys, color, width, style := 0) {
    n := xs.Length, pts := Buffer(n * 8)
    loop n
        NumPut("Int", xs[A_Index], pts, (A_Index - 1) * 8), NumPut("Int", ys[A_Index], pts, (A_Index - 1) * 8 + 4)
    pen := DllCall("CreatePen", "int", style, "int", width, "uint", BGR(color), "ptr")
    old := DllCall("SelectObject", "ptr", hdc, "ptr", pen, "ptr")
    DllCall("Polyline", "ptr", hdc, "ptr", pts, "int", n)
    DllCall("SelectObject", "ptr", hdc, "ptr", old)
    DllCall("DeleteObject", "ptr", pen)
}

BGR(hex) {
    v := Integer("0x" hex)
    return ((v & 0xFF) << 16) | (v & 0xFF00) | ((v >> 16) & 0xFF)
}

;--- сохранение ---------------------------------------------------------
EdSave() {
    name := Trim(ED.name.Value)
    if name = "" {
        ED.note.Text := "Введите название режима"
        return
    }
    file := SafeFileName(name)
    for b in BUILTIN
        if b.file = file {
            ED.note.Text := "Так называется встроенный режим — выберите другое название"
            return
        }
    if file = ED.P.src {
        ED.note.Text := "Название совпадает с основой — выберите другое"
        return
    }
    isNew := file != ED.target && !FileExist(CURVE_DIR file)
    if isNew && ED.target = "" && MODES.Length >= MAX_MODES {
        ED.note.Text := "Уже " (MAX_MODES - 1) " кривых — удалите лишний режим (правый клик по нему)"
        return
    }
    if file != ED.target && FileExist(CURVE_DIR file)
        && MsgBox("Режим «" name "» уже есть. Заменить?", "Lumen", "YesNo Icon? Owner" ED.gui.Hwnd) != "Yes"
        return
    WriteCurve(CURVE_DIR file, name, BuildToneRamp(ED.P, BaseBuf(ED.P.src)), ParamsToString(ED.P))
    if ED.target != "" && ED.target != file && FileExist(CURVE_DIR ED.target)
        FileRecycle(CURVE_DIR ED.target)
    CloseEditor(true)
    RestartLumen()
}
