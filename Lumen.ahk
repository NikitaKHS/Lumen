;=====================================================================
; Lumen — переключатель режимов освещённости для игр
; AutoHotkey v2. Меняет гамма-кривую монитора (SetDeviceGammaRamp).
; Кривые режимов лежат в папке curves\ (формат .crv3: индекс R G B).
; Любой .crv3 в этой папке становится режимом. Первая строка вида
; «; Название» задаёт имя режима.
; Настройки сохраняются в lumen.ini рядом со скриптом.
;=====================================================================
#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent
SetWorkingDir A_ScriptDir

global INI := A_ScriptDir "\lumen.ini"
global CURVE_DIR := A_ScriptDir "\curves\"
global MAX_MODES := 12                 ; стандарт + до 11 кривых

; Права администратора нужны, чтобы горячие клавиши срабатывали,
; когда игра запущена от администратора. Отключается в lumen.ini: RunAsAdmin=0
if !A_IsAdmin && IniRead(INI, "Main", "RunAsAdmin", "1") = "1"
    && !InStr(DllCall("GetCommandLine", "str"), " /restart") {
    try {
        if A_IsCompiled
            Run '*RunAs "' A_ScriptFullPath '" /restart'
        else
            Run '*RunAs "' A_AhkPath '" /restart "' A_ScriptFullPath '"'
        ExitApp
    }
    ; если UAC отклонён — работаем без повышенных прав
}

; иконка окна, трея и панели задач
try TraySetIcon(A_ScriptDir "\lumen.ico")

;---------------------------------------------------------------------
; Режимы
;---------------------------------------------------------------------
; Встроенные кривые: фиксированный порядок, имена и id (id совпадают
; со старыми ключами Mode2..Mode5 в lumen.ini)
global BUILTIN := [
    {file: "night1.crv3", name: "Ночь, вариант 1",           id: "Mode2"},
    {file: "night2.crv3", name: "Ночь, вариант 2",           id: "Mode3"},
    {file: "dusk1.crv3",  name: "Сумерки / тени, вариант 1", id: "Mode4"},
    {file: "dusk2.crv3",  name: "Сумерки / тени, вариант 2", id: "Mode5"}
]

global C := {
    bg: "111318", panel: "1B1E26", panel2: "242833", text: "E6E8EE", muted: "8A91A3",
    accent: "5B7CFA", accentDim: "26304F", accentText: "B9C6FF",
    ok: "3FB97F", warn: "E5A13A", grid: "2E3340", gridOn: "8BA2FC"
}

global IDENTITY := MakeIdentity()
global MODES := [], CURVES := []       ; MODES[i] — {name, file, id}; CURVES[i] — исходная кривая
global SLOT_IDS := []                  ; слоты 1..N — режимы, N+1 — цикл вниз, N+2 — цикл вверх
global cfg := {}
global current := 1                    ; выбранный режим
global cycleFlags := []                ; 1 — режим ещё не был выбран в текущем круге цикла
global inGame := true                  ; блокировка выключена или окно игры активно
global showing := true                 ; кривая режима на экране (иначе — стандарт вне игры)
global registered := []
global expected := 0, guardFails := 0  ; что должно стоять на мониторе (0 — стандарт, не следим)
global TOUCHED := Map()                ; мониторы, которым Lumen менял кривую
global capturing := 0, captureHook := 0, pendingMouse := ""
global detectLeft := 0
global G := 0, ui := {}, OSD := 0, osdText := 0
global CLICK_MAP := Map(), TIPS := Map(), tipHwnd := 0

LoadCurves()
LoadConfig()
inGame := !OutsideGame()
BuildGui()
showing := inGame || !!WinActive("ahk_id " G.Hwnd)
SelectMode(1, true)
ApplyHotkeys()
SetTimer(CheckGame, 250)
SetTimer(GuardRamp, 1500)
OnMessage(0x7E, OnDisplayChange)       ; WM_DISPLAYCHANGE
OnMessage(0x218, OnPower)              ; WM_POWERBROADCAST
OnExit(RestoreAll)

;=====================================================================
; Кривые
;=====================================================================
; GAMMARAMP: WORD Red[256], Green[256], Blue[256]
MakeIdentity() {
    buf := Buffer(1536)
    loop 256 {
        v := (A_Index - 1) * 257, o := (A_Index - 1) * 2
        NumPut("UShort", v, buf, o), NumPut("UShort", v, buf, 512 + o), NumPut("UShort", v, buf, 1024 + o)
    }
    return buf
}

LoadCurves() {
    MODES.Push({name: "Стандартная настройка", file: "", id: "Mode1"})
    CURVES.Push(IDENTITY)

    known := Map()
    known.CaseSense := false
    list := []
    for b in BUILTIN {
        known[b.file] := true
        if FileExist(CURVE_DIR b.file)
            list.Push({name: b.name, file: b.file, id: b.id})
    }
    extra := ""
    loop files CURVE_DIR "*.crv3"
        if !known.Has(A_LoopFileName)
            extra .= A_LoopFileName "`n"
    if extra != ""
        for f in StrSplit(Sort(RTrim(extra, "`n")), "`n") {
            base := RegExReplace(f, "i)\.crv3$")
            list.Push({name: base, file: f, id: "Curve_" RegExReplace(base, "[\s=\[\];]", "_")})
        }

    broken := "", skipped := 0
    for m in list {
        if MODES.Length >= MAX_MODES {
            skipped++
            continue
        }
        buf := ParseCurve(CURVE_DIR m.file, &title)
        if !buf {
            broken .= "`n   curves\" m.file
            continue
        }
        if title != ""
            m.name := title
        MODES.Push(m), CURVES.Push(buf)
    }

    msg := ""
    if MODES.Length = 1
        msg .= "В папке curves нет файлов кривых (.crv3) — доступен только стандартный режим.`n`n"
    if broken != ""
        msg .= "Повреждённые файлы кривых (нужно 256 строк «индекс R G B»):" broken "`n`n"
    if skipped
        msg .= "Кривых больше, чем помещается в окно: пропущено " skipped ".`n`n"
    if msg != ""
        MsgBox(RTrim(msg, "`n"), "Lumen", "Icon!")
}

; Возвращает буфер GAMMARAMP или 0, если файл неполный.
; Первая строка-комментарий («; Название» или «# Название») — имя режима.
ParseCurve(path, &title) {
    title := ""
    try text := FileRead(path, "UTF-8")
    catch
        return 0
    buf := Buffer(1536, 0), seen := Map()
    loop parse text, "`n", "`r" {
        if A_Index = 1 && RegExMatch(A_LoopField, "^\s*[;#]\s*(?:name\s*[:=]\s*)?(.+?)\s*$", &t) {
            title := t[1]
            continue
        }
        if !RegExMatch(A_LoopField, "^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)", &r) || r[1] > 255
            continue
        i := Integer(r[1]), o := i * 2
        NumPut("UShort", Min(r[2], 65535), buf, o)
        NumPut("UShort", Min(r[3], 65535), buf, 512 + o)
        NumPut("UShort", Min(r[4], 65535), buf, 1024 + o)
        seen[i] := true
    }
    return seen.Count = 256 ? buf : 0
}

; Кривая режима с учётом силы: смешивание со стандартной
MixedRamp(i) {
    s := cfg.strength[i]
    if i = 1 || s >= 100
        return CURVES[i]
    buf := Buffer(1536)
    src := CURVES[i]
    loop 768 {
        o := (A_Index - 1) * 2
        a := NumGet(IDENTITY, o, "UShort"), b := NumGet(src, o, "UShort")
        NumPut("UShort", Round(a + (b - a) * s / 100), buf, o)
    }
    return buf
}

;=====================================================================
; Мониторы и гамма
;=====================================================================
MonitorDevice(sel) {
    n := (sel >= 1 && sel <= MonitorGetCount()) ? sel : MonitorGetPrimary()
    return MonitorGetName(n)
}

; Мониторы, к которым применяется режим (cfg.monitor = -1 — все)
Devices() {
    if cfg.monitor = -1 {
        list := []
        loop MonitorGetCount()
            list.Push(MonitorGetName(A_Index))
        return list
    }
    return [MonitorDevice(cfg.monitor)]
}

SetRamp(device, buf) {
    hdc := DllCall("CreateDC", "str", device, "ptr", 0, "ptr", 0, "ptr", 0, "ptr")
    if !hdc
        return false
    ok := DllCall("SetDeviceGammaRamp", "ptr", hdc, "ptr", buf, "int")
    DllCall("DeleteDC", "ptr", hdc)
    return ok != 0
}

; Совпадает ли кривая на мониторе с ожидаемой (небольшие расхождения драйвера допустимы)
RampMatches(device, buf) {
    hdc := DllCall("CreateDC", "str", device, "ptr", 0, "ptr", 0, "ptr", 0, "ptr")
    if !hdc
        return true
    cur := Buffer(1536, 0)
    ok := DllCall("GetDeviceGammaRamp", "ptr", hdc, "ptr", cur, "int")
    DllCall("DeleteDC", "ptr", hdc)
    if !ok
        return true
    bad := 0
    loop 768 {
        o := (A_Index - 1) * 2
        if Abs(NumGet(cur, o, "UShort") - NumGet(buf, o, "UShort")) > 512 && ++bad > 8
            return false
    }
    return true
}

; Ставит на мониторы то, что должно быть видно сейчас:
; выбранный режим, либо стандарт, если «Только в игре» и игра не активна
ApplyCurrent() {
    global expected, guardFails
    std := !showing || current = 1
    buf := std ? IDENTITY : MixedRamp(current)
    ok := true
    for dev in Devices() {
        if SetRamp(dev, buf)
            TOUCHED[dev] := true
        else
            ok := false
    }
    expected := std ? 0 : buf
    guardFails := 0
    return ok
}

; Игра, драйвер или Windows могут сбросить кривую (смена разрешения,
; Alt+Tab, выход из сна) — проверяем и ставим заново
GuardRamp() {
    global guardFails
    if !expected || guardFails >= 3 || capturing
        return
    for dev in Devices() {
        if !RampMatches(dev, expected) {
            guardFails++
            for d in Devices()
                SetRamp(d, expected)
            if guardFails >= 3
                Notify("Кривую постоянно сбрасывает другая программа или драйвер — см. «?»", "warn")
            return
        }
    }
    guardFails := 0
}

Reapply() => ApplyCurrent()

OnDisplayChange(*) {
    SetTimer(Reapply, -1000)
}

OnPower(wParam, *) {
    if wParam = 0x7 || wParam = 0x12      ; PBT_APMRESUMESUSPEND / PBT_APMRESUMEAUTOMATIC
        SetTimer(Reapply, -2000)
}

RestoreAll(*) {
    for dev in TOUCHED
        SetRamp(dev, IDENTITY)
}

;=====================================================================
; Настройки
;=====================================================================
LoadConfig() {
    cfg.admin := IniRead(INI, "Main", "RunAsAdmin", "1") = "1"
    v := IniRead(INI, "Main", "Monitor", "0")
    cfg.monitor := IsInteger(v) ? Integer(v) : 0
    if cfg.monitor != -1 && (cfg.monitor < 0 || cfg.monitor > MonitorGetCount())
        cfg.monitor := 0
    cfg.lockOn := IniRead(INI, "Main", "LockToGame", "0") = "1"
    cfg.game := IniRead(INI, "Main", "GameWindow", "ahk_exe EscapeFromTarkov.exe")
    cfg.osd := IniRead(INI, "Main", "OSD", "1") = "1"

    for m in MODES
        SLOT_IDS.Push(m.id)
    SLOT_IDS.Push("CycleDown", "CycleUp")

    cfg.keys := [], cfg.block := [], cfg.cycle := [], cfg.strength := []
    for id in SLOT_IDS {
        def := RegExMatch(id, "^Mode([1-5])$", &d) ? "^" d[1] : ""
        cfg.keys.Push(IniRead(INI, "Keys", id, def))
        cfg.block.Push(IniRead(INI, "Block", id, "0") = "1")
        registered.Push("")
    }
    for m in MODES {
        cfg.cycle.Push(IniRead(INI, "Cycle", m.id, "0") = "1")
        s := IniRead(INI, "Strength", m.id, "100")
        cfg.strength.Push(IsInteger(s) ? Max(10, Min(100, Integer(s))) : 100)
        cycleFlags.Push(1)
    }
}

SaveConfig() {
    IniWrite(cfg.admin ? 1 : 0, INI, "Main", "RunAsAdmin")
    IniWrite(cfg.monitor, INI, "Main", "Monitor")
    IniWrite(cfg.lockOn ? 1 : 0, INI, "Main", "LockToGame")
    IniWrite(cfg.game, INI, "Main", "GameWindow")
    IniWrite(cfg.osd ? 1 : 0, INI, "Main", "OSD")
    for i, id in SLOT_IDS {
        IniWrite(cfg.keys[i], INI, "Keys", id)
        IniWrite(cfg.block[i] ? 1 : 0, INI, "Block", id)
    }
    for i, m in MODES {
        IniWrite(cfg.cycle[i] ? 1 : 0, INI, "Cycle", m.id)
        IniWrite(cfg.strength[i], INI, "Strength", m.id)
    }
}

;=====================================================================
; Логика режимов
;=====================================================================
SelectMode(i, force := false) {
    global current
    if !force && i = current
        return false
    prev := current
    current := i
    if !ApplyCurrent() {
        current := prev
        ApplyCurrent()
        Notify("Windows не принял кривую яркости — нажмите «?» справа", "warn")
        UpdateModeRows()
        return false
    }
    if ui.HasProp("noteKind") && ui.noteKind = "warn"
        Notify("")
    UpdateModeRows()
    return true
}

; Блокировка включена, а окно игры не активно
OutsideGame() => cfg.lockOn && cfg.game != "" && !WinActive(cfg.game)

; Горячая клавиша режима. Вне игры ничего не делает: там и так стандарт,
; а выбранный режим вернётся, когда вы переключитесь обратно в игру.
OnModeKey(i) {
    if OutsideGame()
        return
    SelectMode(i)
    ShowOSD(MODES[i].name)
}

; Цикл: выбирает следующий отмеченный режим, ещё не выбранный в этом круге.
; Когда круг пройден — начинается заново. Вниз: 1→N, вверх: N→1.
OnCycleKey(dir) {
    if OutsideGame()
        return
    n := MODES.Length
    loop 2 {
        idx := dir > 0 ? 0 : n + 1
        loop n {
            idx += dir
            if cycleFlags[idx] && cfg.cycle[idx] {
                SelectMode(idx)
                cycleFlags[idx] := 0
                ShowOSD(MODES[idx].name)
                return
            }
        }
        loop n
            cycleFlags[A_Index] := 1
    }
}

;=====================================================================
; Горячие клавиши
;=====================================================================
SlotCallback(i) {
    n := MODES.Length
    if i <= n
        return (*) => OnModeKey(i)
    d := i = n + 1 ? 1 : -1
    return (*) => OnCycleKey(d)
}

SlotName(i) {
    n := MODES.Length
    return i <= n ? MODES[i].name : i = n + 1 ? "Цикл ↓" : "Цикл ↑"
}

; «Блок» перехватывает нажатие только когда блокировка выключена или игра активна,
; иначе нажатие проходит в Windows как обычно
ApplyHotkeys() {
    allowBlock := !(cfg.lockOn && !inGame)
    for i, key in cfg.keys {
        if registered[i] != "" && registered[i] != key {
            try Hotkey(registered[i], "Off")
            registered[i] := ""
        }
        if key = ""
            continue
        try {
            Hotkey((cfg.block[i] && allowBlock ? "" : "~") key, SlotCallback(i), "On")
            registered[i] := key
        } catch {
            Notify("Не удалось назначить клавишу " KeyLabel(key), "warn")
            cfg.keys[i] := "", registered[i] := ""
            ShowChip(i)
        }
    }
}

CheckGame() {
    global inGame, showing
    ; внимание: имена в AHK не различают регистр, локальная «g» перекрыла бы окно G
    nowIn := !OutsideGame()
    ; окно Lumen активно — показываем выбранный режим, чтобы его можно было посмотреть
    s := nowIn || !!WinActive("ahk_id " G.Hwnd)
    if nowIn != inGame {
        inGame := nowIn
        ApplyHotkeys()
        UpdateStatus()
    }
    if s != showing {
        showing := s
        ApplyCurrent()
    }
}

SetSlotKey(i, key) {
    if key != "" {
        for j, other in cfg.keys {
            if j != i && other = key {
                Notify(KeyLabel(key) " уже назначена на «" SlotName(j) "»", "warn")
                return
            }
        }
    }
    cfg.keys[i] := key
    ApplyHotkeys()
    SaveConfig()
}

; Буквы храним как vkXX — так клавиша работает в любой раскладке
NormalizeKey(k) {
    vk := GetKeyVK(k)
    if vk >= 0x41 && vk <= 0x5A
        return Format("vk{:02X}", vk)
    name := GetKeyName(k)
    return name != "" ? name : k
}

KeyLabel(hk) {
    if hk = ""
        return "не назначено"
    RegExMatch(hk, "^([\^!+#]*)(.+)$", &m)
    out := ""
    for pair in [["^", "Ctrl"], ["!", "Alt"], ["+", "Shift"], ["#", "Win"]]
        if InStr(m[1], pair[1])
            out .= pair[2] " + "
    k := m[2]
    if RegExMatch(k, "i)^vk([0-9A-F]{2})$", &v)
        k := Chr(Integer("0x" v[1]))
    else if RegExMatch(k, "i)^Numpad(\d)$", &n)
        k := "Num " n[1]
    else
        k := Map("LWin", "Win", "RWin", "Win (прав.)", "XButton1", "Мышь 4", "XButton2", "Мышь 5",
                 "MButton", "Колесо", "Space", "Пробел", "CapsLock", "Caps Lock").Get(k, k)
    return out . StrUpper(SubStr(k, 1, 1)) . SubStr(k, 2)
}

;--- назначение клавиши: клик по полю → нажать клавишу ---------------
StartCapture(i) {
    global capturing, captureHook, pendingMouse
    if capturing
        return
    capturing := i, pendingMouse := ""
    Suspend(true)
    ShowChip(i)
    captureHook := InputHook("L0 T8")
    captureHook.KeyOpt("{All}", "ES")
    captureHook.KeyOpt("{LCtrl}{RCtrl}{LShift}{RShift}{LAlt}{RAlt}", "-ES")
    captureHook.OnEnd := EndCapture
    for k in ["XButton1", "XButton2", "MButton"]
        Hotkey("*" k, MouseCapture.Bind(k), "On S")
    captureHook.Start()
}

MouseCapture(k, *) {
    global pendingMouse := k
    captureHook.Stop()
}

EndCapture(hook) {
    global capturing
    i := capturing
    for k in ["XButton1", "XButton2", "MButton"]
        try Hotkey("*" k, "Off")
    Suspend(false)
    capturing := 0
    mods := ""
    if hook.EndReason = "Stopped" && pendingMouse != "" {
        for pair in [["Ctrl", "^"], ["Alt", "!"], ["Shift", "+"]]
            if GetKeyState(pair[1])
                mods .= pair[2]
        SetSlotKey(i, mods pendingMouse)
    } else if hook.EndReason = "EndKey" {
        k := hook.EndKey
        if k = "Backspace" {
            SetSlotKey(i, "")
        } else if k != "Escape" {
            for ch in ["^", "!", "+", "#"]
                if InStr(hook.EndMods, ch)
                    mods .= ch
            SetSlotKey(i, mods NormalizeKey(k))
        }
    }
    ShowChip(i)
}

;=====================================================================
; Подпись поверх игры
;=====================================================================
ShowOSD(text, force := false) {
    global OSD, osdText
    if !cfg.osd && !force
        return
    if !OSD {
        ; без рамки, поверх всех окон, не забирает фокус (NOACTIVATE) и пропускает клики (TRANSPARENT)
        OSD := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000020", "Lumen OSD")
        OSD.BackColor := C.panel
        OSD.MarginX := 0, OSD.MarginY := 0
        OSD.SetFont("s14 bold c" C.text, "Segoe UI")
        osdText := OSD.Add("Text", "x0 y0 w340 h54 Center 0x200 Background" C.panel, "")
        try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", OSD.Hwnd, "int", 33, "int*", 2, "int", 4)
    }
    osdText.Text := "●   " text
    n := cfg.monitor >= 1 && cfg.monitor <= MonitorGetCount() ? cfg.monitor : MonitorGetPrimary()
    MonitorGetWorkArea(n, &l, &t, &r, &b)
    w := Round(340 * A_ScreenDPI / 96)
    OSD.Show("NoActivate x" (l + (r - l - w) // 2) " y" (t + Round(48 * A_ScreenDPI / 96)) " w340 h54")
    WinSetTransparent(235, "ahk_id " OSD.Hwnd)
    SetTimer(HideOSD, -1200)
}

HideOSD() {
    if OSD
        OSD.Hide()
}

;=====================================================================
; Интерфейс
;=====================================================================
; Колонки: график 24..62, режим 66..266, сила 274..382, клавиша 390..534,
;          цикл 542..610, блок 618..682
BuildGui() {
    global G
    n := MODES.Length
    G := Gui("-MaximizeBox", "Lumen")
    G.BackColor := C.bg
    G.MarginX := 0, G.MarginY := 0
    G.OnEvent("Close", (*) => ExitApp())
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", G.Hwnd, "int", 20, "int*", 1, "int", 4)

    ; шапка
    G.SetFont("s20 bold c" C.text, "Segoe UI")
    G.Add("Text", "x24 y14 w200 h38 Background" C.bg, "Lumen")
    G.SetFont("s9 norm c" C.muted)
    G.Add("Text", "x26 y52 w300 h18 Background" C.bg, "режимы освещённости для игры")
    G.SetFont("s9 bold")
    ui.status := G.Add("Text", "x510 y22 w172 h30 Center 0x200 Background" C.panel, "")

    ; монитор
    Section(92, "МОНИТОР")
    G.SetFont("s10 norm c" C.text)
    ui.mon := G.Add("DropDownList", "x24 y112 w658 R8 Background" C.panel, MonitorList())
    ui.mon.Value := cfg.monitor = -1 ? MonitorGetCount() + 2 : cfg.monitor + 1
    ui.mon.OnEvent("Change", OnMonitorChange)
    try DllCall("uxtheme\SetWindowTheme", "ptr", ui.mon.Hwnd, "str", "DarkMode_CFD", "ptr", 0)

    ; режимы
    Section(158, "РЕЖИМЫ")
    G.SetFont("s8 bold c" C.muted)
    G.Add("Text", "x274 y158 w108 h16 Center Background" C.bg, "СИЛА")
    G.Add("Text", "x390 y158 w144 h16 Center Background" C.bg, "КЛАВИША")
    G.Add("Text", "x542 y158 w68 h16 Center Background" C.bg, "ЦИКЛ")
    G.Add("Text", "x618 y158 w64 h16 Center Background" C.bg, "БЛОК")
    ui.modeBtn := [], ui.graph := [], ui.chip := [], ui.cyc := [], ui.blk := [], ui.str := Map()
    loop n {
        i := A_Index, y := 180 + (i - 1) * 46
        pic := G.Add("Picture", "x24 y" y " w38 h38 0xE 0x100")    ; SS_BITMAP | SS_NOTIFY
        Clickable(pic, ModeClick(i), "Кривая режима (пунктир — стандарт)")
        ui.graph.Push(pic)
        G.SetFont("s10 norm c" C.text)
        b := G.Add("Text", "x66 y" y " w200 h38 0x200 0x100 Background" C.panel, "")
        Clickable(b, ModeClick(i), "Включить режим")
        ui.modeBtn.Push(b)
        if i > 1
            AddStrength(i, y)
        AddChip(i, y)
        pill := AddPill(542, y, 68, "Цикл")
        Clickable(pill, CycleToggle(i), "Режим участвует в циклическом переключении ↓ / ↑")
        ui.cyc.Push(pill)
        AddBlock(i, y)
    }

    ; цикл
    y := 180 + n * 46 + 12
    Section(y, "ЦИКЛИЧЕСКОЕ ПЕРЕКЛЮЧЕНИЕ")
    y += 22
    for row in [[n + 1, "↓     Следующий режим"], [n + 2, "↑     Предыдущий режим"]] {
        G.SetFont("s10 norm c" C.text)
        G.Add("Text", "x24 y" y " w358 h38 0x200 Background" C.panel, "     " row[2])
        AddChip(row[1], y)
        AddBlock(row[1], y)
        y += 46
    }

    ; игра
    y += 10
    Section(y, "ИГРА")
    y += 22
    ui.lock := AddPill(24, y, 150, "Только в игре")
    Clickable(ui.lock, (*) => ToggleLock(),
        "Режим действует только в окне игры.`nВне игры автоматически стоит стандарт, а при возврате в игру режим включается снова.")
    G.SetFont("s10 norm c" C.text)
    ui.game := G.Add("Text", "x182 y" y " w352 h38 0x200 0x100 Background" C.panel2, "")
    TIPS[ui.game.Hwnd] := "Окно игры, к которому привязаны горячие клавиши"
    G.SetFont("s10 bold c" C.accentText)
    ui.detect := G.Add("Text", "x542 y" y " w140 h38 Center 0x200 0x100 Background" C.accentDim, "Определить")
    Clickable(ui.detect, (*) => DetectGame(), "Через 5 секунд запомнить активное окно как окно игры")
    y += 46
    ui.osd := AddPill(24, y, 200, "Подпись на экране")
    Clickable(ui.osd, (*) => ToggleOsd(),
        "При переключении горячей клавишей на секунду показывать название режима поверх игры.`nНе видно в эксклюзивном полноэкранном режиме.")

    ; подсказка и уведомления
    y += 52
    G.SetFont("s8 norm c" C.muted)
    G.Add("Text", "x24 y" y " w658 h30 Background" C.bg,
        "Клик по режиму — включить.  Клик по клавише — назначить (Backspace — удалить, Esc — отмена).`n"
        "«Блок» — нажатие не дойдёт до Windows и игры.  Свои кривые — файлы .crv3 в папке curves.")
    y += 38
    G.SetFont("s9 norm c" C.muted)
    ui.note := G.Add("Text", "x24 y" (y + 2) " w620 h20 0x200 Background" C.bg, "")
    ui.noteKind := ""
    G.SetFont("s9 bold c" C.accentText)
    h := G.Add("Text", "x658 y" y " w24 h24 Center 0x200 0x100 Background" C.accentDim, "?")
    Clickable(h, (*) => ShowHelp(), "Что делать, если яркость не меняется")

    OnMessage(0x20, WM_SETCURSOR)
    OnMessage(0x200, WM_MOUSEMOVE)

    A_IconTip := "Lumen"
    tray := A_TrayMenu
    tray.Delete()
    tray.Add("Открыть", (*) => G.Show())
    tray.Add("Стандартная настройка", (*) => SelectMode(1, true))
    tray.Add()
    tray.Add("Перезапустить (перечитать кривые)", (*) => Reload())
    tray.Add("Выход", (*) => ExitApp())
    tray.Default := "Открыть"

    loop n + 2
        ShowChip(A_Index), ShowBlock(A_Index)
    loop n
        SetPill(ui.cyc[A_Index], cfg.cycle[A_Index])
    SetPill(ui.lock, cfg.lockOn)
    SetPill(ui.osd, cfg.osd)
    ShowGame()
    UpdateModeRows()
    UpdateStatus()
    G.Show("w706 h" (y + 34))
}

Section(y, text) {
    G.SetFont("s8 bold c" C.muted)
    G.Add("Text", "x24 y" y " w250 h16 Background" C.bg, text)
}

AddChip(i, y) {
    G.SetFont("s10 bold c" C.text)
    chip := G.Add("Text", "x390 y" y " w144 h38 Center 0x200 0x100 Background" C.panel2, "")
    Clickable(chip, ChipClick(i), "Клик — назначить клавишу")
    ui.chip.Push(chip)   ; индексы совпадают с номерами слотов: 1..N, затем N+1, N+2
}

AddBlock(i, y) {
    b := AddPill(618, y, 64, "Блок")
    Clickable(b, BlockToggle(i), "Монопольный режим: нажатие этой клавиши`nне передаётся в Windows и игру")
    ui.blk.Push(b)
}

; Сила режима: [−] 70% [+]
AddStrength(i, y) {
    G.SetFont("s11 bold c" C.muted)
    m := G.Add("Text", "x274 y" y " w26 h38 Center 0x200 0x100 Background" C.panel2, "−")
    Clickable(m, StrengthStep(i, -10), "Слабее")
    G.SetFont("s9 bold c" C.text)
    v := G.Add("Text", "x302 y" y " w52 h38 Center 0x200 0x100 Background" C.panel2, "")
    TIPS[v.Hwnd] := "Сила режима: 100% — кривая как есть,`nменьше — ближе к стандартной"
    G.SetFont("s11 bold c" C.muted)
    p := G.Add("Text", "x356 y" y " w26 h38 Center 0x200 0x100 Background" C.panel2, "+")
    Clickable(p, StrengthStep(i, 10), "Сильнее")
    ui.str[i] := v
    ShowStrength(i)
}

AddPill(x, y, w, label) {
    G.SetFont("s9 bold c" C.muted)
    p := G.Add("Text", "x" x " y" y " w" w " h38 Center 0x200 0x100 Background" C.panel2, label)
    p.label := label
    return p
}

SetPill(p, on) {
    p.Opt("+Background" (on ? C.accentDim : C.panel2))
    p.SetFont("c" (on ? C.accentText : C.muted))
    p.Text := (on ? "✓  " : "") p.label
}

Clickable(ctrl, fn, tip := "") {
    ctrl.OnEvent("Click", fn)
    ctrl.OnEvent("DoubleClick", fn)
    CLICK_MAP[ctrl.Hwnd] := true
    if tip != ""
        TIPS[ctrl.Hwnd] := tip
}

ModeClick(i) => (*) => SelectMode(i, true)
ChipClick(i) => (*) => StartCapture(i)
CycleToggle(i) => (*) => (cfg.cycle[i] := !cfg.cycle[i], SetPill(ui.cyc[i], cfg.cycle[i]), SaveConfig())
BlockToggle(i) => (*) => (cfg.block[i] := !cfg.block[i], ShowBlock(i), ApplyHotkeys(), SaveConfig())
StrengthStep(i, d) => (*) => SetStrength(i, cfg.strength[i] + d)

ShowBlock(i) => SetPill(ui.blk[i], cfg.block[i])

SetStrength(i, s) {
    s := Max(10, Min(100, s))
    if s = cfg.strength[i]
        return
    cfg.strength[i] := s
    ShowStrength(i)
    DrawGraph(i)
    SaveConfig()
    if i = current
        ApplyCurrent()
}

ShowStrength(i) {
    v := ui.str[i]
    v.SetFont("c" (cfg.strength[i] = 100 ? C.muted : C.accentText))
    v.Text := cfg.strength[i] "%"
}

ShowChip(i) {
    chip := ui.chip[i]
    if capturing = i {
        chip.Opt("+Background" C.accent)
        chip.SetFont("cFFFFFF")
        chip.Text := "нажмите клавишу…"
    } else {
        chip.Opt("+Background" C.panel2)
        chip.SetFont("c" (cfg.keys[i] = "" ? C.muted : C.text))
        chip.Text := cfg.keys[i] = "" ? "—" : KeyLabel(cfg.keys[i])
    }
}

UpdateModeRows() {
    if !ui.HasProp("modeBtn")
        return
    for i, b in ui.modeBtn {
        on := i = current
        b.Opt("+Background" (on ? C.accent : C.panel))
        b.SetFont((on ? "bold " : "norm ") "c" (on ? "FFFFFF" : C.text))
        b.Text := "   " (on ? "●" : "○") "   " MODES[i].name
        DrawGraph(i)
    }
}

;--- маленький график кривой ------------------------------------------
DrawGraph(i) {
    pic := ui.graph[i]
    on := i = current
    state := on "|" cfg.strength[i]
    if pic.HasProp("state") && pic.state = state
        return
    pic.state := state

    S := Round(38 * A_ScreenDPI / 96), pad := Round(S * 0.16), span := S - 2 * pad
    bits := Buffer(S * S * 4)
    bg := 0xFF000000 | Integer("0x" (on ? C.accent : C.panel))
    loop S * S
        NumPut("UInt", bg, bits, (A_Index - 1) * 4)
    if i > 1
        PlotRamp(bits, S, pad, span, IDENTITY, 0xFF000000 | Integer("0x" (on ? C.gridOn : C.grid)), true)
    PlotRamp(bits, S, pad, span, MixedRamp(i), 0xFF000000 | Integer("0x" (on ? "FFFFFF" : C.accentText)))

    bi := Buffer(40, 0)
    NumPut("UInt", 40, bi, 0), NumPut("Int", S, bi, 4), NumPut("Int", -S, bi, 8)
    NumPut("UShort", 1, bi, 12), NumPut("UShort", 32, bi, 14)
    pBits := 0
    hbm := DllCall("CreateDIBSection", "ptr", 0, "ptr", bi, "uint", 0, "ptr*", &pBits, "ptr", 0, "uint", 0, "ptr")
    if !hbm
        return
    DllCall("RtlMoveMemory", "ptr", pBits, "ptr", bits, "uptr", bits.Size)
    old := SendMessage(0x172, 0, hbm, pic.Hwnd)          ; STM_SETIMAGE
    if old
        DllCall("DeleteObject", "ptr", old)
    if SendMessage(0x173, 0, 0, pic.Hwnd) != hbm         ; контрол сделал копию — свою удаляем
        DllCall("DeleteObject", "ptr", hbm)
}

PlotRamp(bits, S, pad, span, ramp, col, dashed := false) {
    prev := -1
    loop span {
        x := A_Index - 1
        idx := Round(x * 255 / (span - 1)), o := idx * 2
        v := (NumGet(ramp, o, "UShort") + NumGet(ramp, 512 + o, "UShort") + NumGet(ramp, 1024 + o, "UShort")) / 3
        y := S - 1 - pad - Round(v * (span - 1) / 65535)
        y0 := prev < 0 ? y : prev
        prev := y
        if dashed && Mod(x // 2, 2)
            continue
        lo := Max(0, Min(y0, y) - (dashed ? 0 : 1))       ; сплошная линия — 2 px
        loop Max(y0, y) - lo + 1
            NumPut("UInt", col, bits, ((lo + A_Index - 1) * S + pad + x) * 4)
    }
}

UpdateStatus() {
    if !ui.HasProp("status")
        return
    if !cfg.lockOn
        t := "●   работает везде", fg := C.muted
    else if inGame
        t := "●   игра активна", fg := C.ok
    else
        t := "●   вне игры", fg := C.warn
    ui.status.SetFont("c" fg)
    ui.status.Text := t
}

ShowGame() {
    name := RegExReplace(cfg.game, "i)^ahk_exe\s+")
    ui.game.Text := "    " (name = "" ? "окно не выбрано" : name)
}

MonitorList() {
    list := ["Основной монитор"]
    loop MonitorGetCount() {
        MonitorGet(A_Index, &l, &t, &r, &b)
        list.Push("Монитор " A_Index "   ·   " (r - l) "×" (b - t) (A_Index = MonitorGetPrimary() ? "   (основной)" : ""))
    }
    list.Push("Все мониторы")
    return list
}

OnMonitorChange(*) {
    old := Devices()
    v := ui.mon.Value
    cfg.monitor := v = MonitorGetCount() + 2 ? -1 : v - 1
    SaveConfig()
    now := Devices()
    for d in old {
        keep := false
        for x in now
            if x = d
                keep := true
        if !keep
            SetRamp(d, IDENTITY)
    }
    ApplyCurrent()
}

ToggleLock() {
    cfg.lockOn := !cfg.lockOn
    SetPill(ui.lock, cfg.lockOn)
    SaveConfig()
    CheckGame()
    UpdateStatus()
}

ToggleOsd() {
    cfg.osd := !cfg.osd
    SetPill(ui.osd, cfg.osd)
    SaveConfig()
    if cfg.osd
        ShowOSD(MODES[current].name)
}

DetectGame() {
    global detectLeft
    if detectLeft
        return
    detectLeft := 5
    DetectTick()
    SetTimer(DetectTick, 1000)
}

DetectTick() {
    global detectLeft
    if detectLeft > 0 {
        ui.detect.Text := "Переключитесь… " detectLeft
        detectLeft--
        return
    }
    SetTimer(DetectTick, 0)
    ui.detect.Text := "Определить"
    hwnd := WinExist("A")
    if !hwnd || hwnd = G.Hwnd {
        Notify("Нужно было переключиться в окно игры", "warn")
        return
    }
    try exe := WinGetProcessName(hwnd)
    catch {
        Notify("Не удалось определить окно", "warn")
        return
    }
    cfg.game := "ahk_exe " exe
    SaveConfig()
    ShowGame()
    SoundBeep(1200, 80)
    Notify("Окно игры: " exe, "ok")
}

Notify(text, kind := "info") {
    if !ui.HasProp("note")
        return
    ui.noteKind := text = "" ? "" : kind
    ui.note.SetFont("c" (kind = "warn" ? C.warn : kind = "ok" ? C.ok : C.muted))
    ui.note.Text := text
    if text != ""
        SetTimer(ClearNote, -7000)
}

ClearNote() => Notify("")

ShowHelp() {
    MsgBox(
        "Если режимы не меняют яркость:`n`n"
        "1. Панель управления NVIDIA → Дисплей → «Регулировка параметров цвета рабочего стола» → "
        "снимите галочку «Приоритет эталонного режима».`n`n"
        "2. Windows может не принимать сильные изменения гаммы. Это снимается параметром реестра:`n"
        "    HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ICM`n"
        "    DWORD  GdiIcmGammaRange = 256`n"
        "и перезагрузкой.`n`n"
        "3. Запускайте игру в оконном режиме без рамки — в эксклюзивном полноэкранном режиме "
        "игра может сбрасывать гамму, и подпись режима не видна. Lumen сам ставит кривую заново, "
        "если её сбросили, но другие программы управления гаммой (f.lux и т.п.) лучше закрыть.`n`n"
        "Свои режимы: положите файл .crv3 в папку curves (256 строк «индекс R G B», значения 0–65535). "
        "Первая строка «; Название» задаёт имя режима. Затем в меню трея — «Перезапустить».",
        "Lumen — подсказка", "Iconi")
}

;--- курсор-рука и всплывающие подсказки -----------------------------
WM_SETCURSOR(wParam, *) {
    if CLICK_MAP.Has(wParam) {
        DllCall("SetCursor", "ptr", DllCall("LoadCursor", "ptr", 0, "ptr", 32649, "ptr"))
        return true
    }
}

WM_MOUSEMOVE(wParam, lParam, msg, hwnd) {
    global tipHwnd
    if hwnd = tipHwnd
        return
    tipHwnd := hwnd
    ToolTip()
    if TIPS.Has(hwnd)
        SetTimer(ShowTip, -600)
}

ShowTip() {
    if !TIPS.Has(tipHwnd)
        return
    MouseGetPos(, , , &ctl, 2)
    if ctl = tipHwnd {
        ToolTip(TIPS[tipHwnd])
        SetTimer(() => ToolTip(), -4000)
    }
}
