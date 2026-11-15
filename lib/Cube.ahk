;=====================================================================
; Импорт и экспорт LUT (.cube)
;=====================================================================
; 1D LUT переносится как есть. 3D LUT упрощается до кривой по серой оси:
; общий тон и оттенок сохраняются, а перекрёстные эффекты между каналами
; (например, изменение насыщенности отдельных цветов) — нет.

ImportCube() {
    path := FileSelect(1, , "Lumen — импорт LUT", "LUT (*.cube)")
    if path = ""
        return
    buf := CubeToRamp(path, &title, &is3d, &err)
    if !buf {
        MsgBox(err, "Lumen", "Icon!")
        return
    }
    SplitPath(path, , , , &base)
    name := title != "" ? title : base
    file := SafeFileName(name)
    for b in BUILTIN
        if b.file = file
            file := SafeFileName(name " (LUT)")
    if FileExist(CURVE_DIR file)
        && MsgBox("Режим «" name "» уже есть. Заменить?", "Lumen", "YesNo Icon?") != "Yes"
        return
    WriteCurve(CURVE_DIR file, name, buf)
    MsgBox("Режим «" name "» добавлен" (is3d ? " (3D LUT упрощён до кривой по серой оси)" : "")
        . ".`nLumen перезапустится, чтобы показать его.", "Lumen", "Iconi")
    RestartLumen()
}

; Читает .cube и возвращает буфер GAMMARAMP (или 0 и текст ошибки в err)
CubeToRamp(path, &title, &is3d, &err) {
    title := "", is3d := false, err := ""
    try text := FileRead(path, "UTF-8")
    catch {
        err := "Не удалось прочитать файл."
        return 0
    }
    n1 := 0, n3 := 0, dmin := [0, 0, 0], dmax := [1, 1, 1], data := []
    num := "([-+]?[\d.]+(?:[eE][-+]?\d+)?)"
    loop parse text, "`n", "`r" {
        t := Trim(A_LoopField)
        if t = "" || SubStr(t, 1, 1) = "#"
            continue
        if RegExMatch(t, 'i)^TITLE\s+"?(.*?)"?$', &m)
            title := m[1]
        else if RegExMatch(t, "i)^LUT_1D_SIZE\s+(\d+)", &m)
            n1 := Integer(m[1])
        else if RegExMatch(t, "i)^LUT_3D_SIZE\s+(\d+)", &m)
            n3 := Integer(m[1])
        else if RegExMatch(t, "i)^DOMAIN_MIN\s+" num "\s+" num "\s+" num, &m)
            dmin := [Number(m[1]), Number(m[2]), Number(m[3])]
        else if RegExMatch(t, "i)^DOMAIN_MAX\s+" num "\s+" num "\s+" num, &m)
            dmax := [Number(m[1]), Number(m[2]), Number(m[3])]
        else if RegExMatch(t, "i)^LUT_1D_INPUT_RANGE\s+" num "\s+" num, &m)
            dmin := [Number(m[1]), Number(m[1]), Number(m[1])], dmax := [Number(m[2]), Number(m[2]), Number(m[2])]
        else if RegExMatch(t, "^" num "\s+" num "\s+" num "$", &m)
            data.Push([Number(m[1]), Number(m[2]), Number(m[3])])
    }
    if n1 >= 2 && data.Length = n1 {
        n := n1, idx := (k) => k + 1
    } else if n3 >= 2 && data.Length = n3 ** 3 {
        n := n3, is3d := true
        idx := (k) => k + k * n3 + k * n3 * n3 + 1                  ; точка (k, k, k) на серой оси
    } else {
        err := "Файл не похож на LUT .cube: нет LUT_1D_SIZE / LUT_3D_SIZE или не совпадает число строк."
        return 0
    }
    buf := Buffer(1536)
    loop 3 {
        ch := A_Index, prev := 0
        span := dmax[ch] - dmin[ch]
        loop 256 {
            x := (A_Index - 1) / 255
            pos := span > 0 ? (x - dmin[ch]) / span * (n - 1) : x * (n - 1)
            pos := Max(0, Min(n - 1, pos))
            k0 := Floor(pos), k1 := Min(k0 + 1, n - 1), f := pos - k0
            y := data[idx(k0)][ch] + (data[idx(k1)][ch] - data[idx(k0)][ch]) * f
            v := Max(prev, Round(Max(0, Min(1, y)) * 65535)), prev := v
            NumPut("UShort", v, buf, (ch - 1) * 512 + (A_Index - 1) * 2)
        }
    }
    return buf
}

ExportCube(i) {
    path := FileSelect("S16", MODES[i].name ".cube", "Lumen — экспорт LUT", "LUT (*.cube)")
    if path = ""
        return
    if !RegExMatch(path, "i)\.cube$")
        path .= ".cube"
    WriteCube(path, i)
    Notify("Сохранено: " path, "ok")
}

; Записывает режим (с учётом силы) как 1D LUT на 256 точек
WriteCube(path, i) {
    buf := MixedRamp(i)
    text := 'TITLE "' MODES[i].name '"' "`r`n# Lumen, сила " cfg.strength[i] "%`r`nLUT_1D_SIZE 256`r`n"
    loop 256 {
        o := (A_Index - 1) * 2
        text .= Format("{:.6f} {:.6f} {:.6f}`r`n", NumGet(buf, o, "UShort") / 65535,
            NumGet(buf, 512 + o, "UShort") / 65535, NumGet(buf, 1024 + o, "UShort") / 65535)
    }
    if FileExist(path)
        FileDelete(path)
    FileAppend(text, path, "UTF-8-RAW")
}
