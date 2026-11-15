;=====================================================================
; Lumen — переключатель режимов освещённости для игр
; AutoHotkey v2. Меняет гамма-кривую монитора (SetDeviceGammaRamp).
; Кривые режимов лежат в папке curves\ (формат .crv3: индекс R G B).
; Настройки сохраняются в lumen.ini рядом со скриптом.
;=====================================================================
#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent
SetWorkingDir A_ScriptDir

global INI := A_ScriptDir "\lumen.ini"

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
; Режимы и слоты горячих клавиш
;---------------------------------------------------------------------
global MODES := [
    {name: "Стандартная настройка",     file: ""},
    {name: "Ночь, вариант 1",           file: "night1.crv3"},
    {name: "Ночь, вариант 2",           file: "night2.crv3"},
    {name: "Сумерки / тени, вариант 1", file: "dusk1.crv3"},
    {name: "Сумерки / тени, вариант 2", file: "dusk2.crv3"}
]
; слоты 1..5 — режимы, 6 — цикл вниз, 7 — цикл вверх
global SLOT_IDS := ["Mode1", "Mode2", "Mode3", "Mode4", "Mode5", "CycleDown", "CycleUp"]
global SLOT_NAMES := ["Стандарт", "Ночь 1", "Ночь 2", "Сумерки 1", "Сумерки 2", "Цикл ↓", "Цикл ↑"]

global C := {
    bg: "111318", panel: "1B1E26", panel2: "242833", text: "E6E8EE", muted: "8A91A3",
    accent: "5B7CFA", accentDim: "26304F", accentText: "B9C6FF",
    ok: "3FB97F", warn: "E5A13A"
}

global cfg := {}
global RAMPS := []
global current := 1                    ; активный режим
global cycleFlags := [1, 1, 1, 1, 1]   ; 1 — режим ещё не был выбран в текущем круге цикла
global inGame := true                  ; блокировка выключена или окно игры активно
global registered := ["", "", "", "", "", "", ""]
global capturing := 0, captureHook := 0, pendingMouse := ""
global detectLeft := 0
global G := 0, ui := {}
global CLICK_MAP := Map(), TIPS := Map(), tipHwnd := 0

LoadConfig()
LoadRamps()
BuildGui()
SelectMode(1, true)
ApplyHotkeys()
SetTimer(CheckGame, 250)
OnExit(RestoreAll)

;=====================================================================
; Настройки
;=====================================================================
LoadConfig() {
    cfg.admin := IniRead(INI, "Main", "RunAsAdmin", "1") = "1"
    cfg.monitor := Integer(IniRead(INI, "Main", "Monitor", "0"))
    if cfg.monitor < 0 || cfg.monitor > MonitorGetCount()
        cfg.monitor := 0
    cfg.lockOn := IniRead(INI, "Main", "LockToGame", "0") = "1"
    cfg.game := IniRead(INI, "Main", "GameWindow", "ahk_exe EscapeFromTarkov.exe")
    cfg.keys := [], cfg.block := [], cfg.cycle := []
    defaults := ["^1", "^2", "^3", "^4", "^5", "", ""]
    for i, id in SLOT_IDS {
        cfg.keys.Push(IniRead(INI, "Keys", id, defaults[i]))
        cfg.block.Push(IniRead(INI, "Block", id, "0") = "1")
    }
    loop 5
        cfg.cycle.Push(IniRead(INI, "Cycle", "Mode" A_Index, "0") = "1")
}

SaveConfig() {
    IniWrite(cfg.admin ? 1 : 0, INI, "Main", "RunAsAdmin")
    IniWrite(cfg.monitor, INI, "Main", "Monitor")
    IniWrite(cfg.lockOn ? 1 : 0, INI, "Main", "LockToGame")
    IniWrite(cfg.game, INI, "Main", "GameWindow")
    for i, id in SLOT_IDS {
        IniWrite(cfg.keys[i], INI, "Keys", id)
        IniWrite(cfg.block[i] ? 1 : 0, INI, "Block", id)
    }
    loop 5
        IniWrite(cfg.cycle[A_Index] ? 1 : 0, INI, "Cycle", "Mode" A_Index)
}

;=====================================================================
; Гамма-кривые
;=====================================================================
; GAMMARAMP: WORD Red[256], Green[256], Blue[256]
LoadRamps() {
    missing := ""
    for m in MODES {
        buf := Buffer(1536, 0)
        if m.file = "" {
            loop 256 {
                v := (A_Index - 1) * 257, o := (A_Index - 1) * 2
                NumPut("UShort", v, buf, o), NumPut("UShort", v, buf, 512 + o), NumPut("UShort", v, buf, 1024 + o)
            }
            RAMPS.Push(buf)
            continue
        }
        path := A_ScriptDir "\curves\" m.file
        count := 0
        if FileExist(path) {
            loop parse FileRead(path), "`n", "`r" {
                if !RegExMatch(A_LoopField, "^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)", &r) || r[1] > 255
                    continue
                o := r[1] * 2
                NumPut("UShort", Min(r[2], 65535), buf, o)
                NumPut("UShort", Min(r[3], 65535), buf, 512 + o)
                NumPut("UShort", Min(r[4], 65535), buf, 1024 + o)
                count++
            }
        }
        if count = 256 {
            RAMPS.Push(buf)
        } else {
            RAMPS.Push(0)
            missing .= "`n   curves\" m.file
        }
    }
    if missing != ""
        MsgBox("Не найдены или повреждены файлы кривых:" missing "`n`nЭти режимы будут недоступны.", "Lumen", "Icon!")
}

MonitorDevice(sel) {
    n := (sel >= 1 && sel <= MonitorGetCount()) ? sel : MonitorGetPrimary()
    return MonitorGetName(n)
}

SetRamp(device, buf) {
    hdc := DllCall("CreateDC", "str", device, "ptr", 0, "ptr", 0, "ptr", 0, "ptr")
    if !hdc
        return false
    ok := DllCall("SetDeviceGammaRamp", "ptr", hdc, "ptr", buf, "int")
    DllCall("DeleteDC", "ptr", hdc)
    return ok != 0
}

RestoreAll(*) {
    loop MonitorGetCount()
        SetRamp(MonitorGetName(A_Index), RAMPS[1])
}

;=====================================================================
; Логика режимов (поведение как у Nocto)
;=====================================================================
SelectMode(i, force := false) {
    global current
    if !force && i = current
        return
    if !RAMPS[i] {
        Notify("Нет файла кривой для режима «" MODES[i].name "»", "warn")
        return
    }
    if SetRamp(MonitorDevice(cfg.monitor), RAMPS[i]) {
        current := i
        if ui.HasProp("note") && ui.noteKind = "warn"
            Notify("")
    } else {
        Notify("Windows не принял кривую яркости — нажмите «?» справа", "warn")
    }
    UpdateModeRows()
}

; Блокировка включена, а окно игры не активно
OutsideGame() => cfg.lockOn && cfg.game != "" && !WinActive(cfg.game)

; Горячая клавиша режима: вне игры возвращает стандарт,
; повторное нажатие активного режима ничего не делает
OnModeKey(i) {
    if OutsideGame() {
        SelectMode(1)
        return
    }
    SelectMode(i)
}

; Цикл: выбирает следующий отмеченный режим, ещё не выбранный в этом круге.
; Когда круг пройден — начинается заново. Вниз: 1→5, вверх: 5→1.
OnCycleKey(dir) {
    if OutsideGame() {
        SelectMode(1)
        return
    }
    loop 2 {
        idx := dir > 0 ? 0 : 6
        loop 5 {
            idx += dir
            if cycleFlags[idx] && cfg.cycle[idx] {
                SelectMode(idx)
                cycleFlags[idx] := 0
                return
            }
        }
        loop 5
            cycleFlags[A_Index] := 1
    }
}

;=====================================================================
; Горячие клавиши
;=====================================================================
SlotCallback(i) => i <= 5 ? ((*) => OnModeKey(i)) : ((*) => OnCycleKey(i = 6 ? 1 : -1))

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
    global inGame
    now := !OutsideGame()
    if now != inGame {
        inGame := now
        ApplyHotkeys()
        UpdateStatus()
    }
}

SetSlotKey(i, key) {
    if key != "" {
        for j, other in cfg.keys {
            if j != i && other = key {
                Notify(KeyLabel(key) " уже назначена на «" SLOT_NAMES[j] "»", "warn")
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
; Интерфейс
;=====================================================================
BuildGui() {
    global G
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
    ui.status := G.Add("Text", "x404 y22 w172 h30 Center 0x200 Background" C.panel, "")

    ; монитор
    Section(92, "МОНИТОР")
    G.SetFont("s10 norm c" C.text)
    ui.mon := G.Add("DropDownList", "x24 y112 w552 R6 Background" C.panel, MonitorList())
    ui.mon.Value := cfg.monitor + 1
    ui.mon.OnEvent("Change", OnMonitorChange)
    try DllCall("uxtheme\SetWindowTheme", "ptr", ui.mon.Hwnd, "str", "DarkMode_CFD", "ptr", 0)

    ; режимы
    Section(158, "РЕЖИМЫ")
    G.SetFont("s8 bold c" C.muted)
    G.Add("Text", "x284 y158 w144 h16 Center Background" C.bg, "КЛАВИША")
    G.Add("Text", "x436 y158 w68 h16 Center Background" C.bg, "ЦИКЛ")
    G.Add("Text", "x512 y158 w64 h16 Center Background" C.bg, "БЛОК")
    ui.modeBtn := [], ui.chip := [], ui.cyc := [], ui.blk := []
    loop 5 {
        i := A_Index, y := 180 + (i - 1) * 46
        G.SetFont("s10 norm c" C.text)
        b := G.Add("Text", "x24 y" y " w252 h38 0x200 0x100 Background" C.panel, "")
        Clickable(b, ModeClick(i), "Включить режим")
        ui.modeBtn.Push(b)
        AddChip(i, y)
        pill := AddPill(436, y, 68, "Цикл")
        Clickable(pill, CycleToggle(i), "Режим участвует в циклическом переключении ↓ / ↑")
        ui.cyc.Push(pill)
        AddBlock(i, y)
    }

    ; цикл
    Section(418, "ЦИКЛИЧЕСКОЕ ПЕРЕКЛЮЧЕНИЕ")
    for row in [[6, "↓     Следующий режим"], [7, "↑     Предыдущий режим"]] {
        y := 440 + (row[1] - 6) * 46
        G.SetFont("s10 norm c" C.text)
        G.Add("Text", "x24 y" y " w252 h38 0x200 Background" C.panel, "     " row[2])
        AddChip(row[1], y)
        AddBlock(row[1], y)
    }

    ; игра
    Section(542, "ИГРА")
    ui.lock := AddPill(24, 564, 150, "Только в игре")
    Clickable(ui.lock, (*) => ToggleLock(), "Горячие клавиши работают только в окне игры.`nВне игры любая клавиша освещения включает стандартный режим.")
    G.SetFont("s10 norm c" C.text)
    ui.game := G.Add("Text", "x182 y564 w246 h38 0x200 0x100 Background" C.panel2, "")
    TIPS[ui.game.Hwnd] := "Окно игры, к которому привязаны горячие клавиши"
    G.SetFont("s10 bold c" C.accentText)
    ui.detect := G.Add("Text", "x436 y564 w140 h38 Center 0x200 0x100 Background" C.accentDim, "Определить")
    Clickable(ui.detect, (*) => DetectGame(), "Через 5 секунд запомнить активное окно как окно игры")

    ; подсказка и уведомления
    G.SetFont("s8 norm c" C.muted)
    G.Add("Text", "x24 y616 w552 h30 Background" C.bg,
        "Клик по режиму — включить.  Клик по клавише — назначить (Backspace — удалить, Esc — отмена).`n«Блок» — нажатие не дойдёт до Windows и игры.")
    G.SetFont("s9 norm c" C.muted)
    ui.note := G.Add("Text", "x24 y654 w520 h20 0x200 Background" C.bg, "")
    ui.noteKind := ""
    G.SetFont("s9 bold c" C.accentText)
    h := G.Add("Text", "x552 y652 w24 h24 Center 0x200 0x100 Background" C.accentDim, "?")
    Clickable(h, (*) => ShowHelp(), "Что делать, если яркость не меняется")

    OnMessage(0x20, WM_SETCURSOR)
    OnMessage(0x200, WM_MOUSEMOVE)

    A_IconTip := "Lumen"
    tray := A_TrayMenu
    tray.Delete()
    tray.Add("Открыть", (*) => G.Show())
    tray.Add("Стандартная настройка", (*) => SelectMode(1, true))
    tray.Add()
    tray.Add("Выход", (*) => ExitApp())
    tray.Default := "Открыть"

    loop 7
        ShowChip(A_Index), ShowBlock(A_Index)
    loop 5
        SetPill(ui.cyc[A_Index], cfg.cycle[A_Index])
    SetPill(ui.lock, cfg.lockOn)
    ShowGame()
    UpdateModeRows()
    UpdateStatus()
    G.Show("w600 h688")
}

Section(y, text) {
    G.SetFont("s8 bold c" C.muted)
    G.Add("Text", "x24 y" y " w250 h16 Background" C.bg, text)
}

AddChip(i, y) {
    G.SetFont("s10 bold c" C.text)
    chip := G.Add("Text", "x284 y" y " w144 h38 Center 0x200 0x100 Background" C.panel2, "")
    Clickable(chip, ChipClick(i), "Клик — назначить клавишу")
    ui.chip.Push(chip)   ; индексы совпадают с номерами слотов: 1..5, затем 6, 7
}

AddBlock(i, y) {
    b := AddPill(512, y, 64, "Блок")
    Clickable(b, BlockToggle(i), "Монопольный режим: нажатие этой клавиши`nне передаётся в Windows и игру")
    ui.blk.Push(b)
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

ShowBlock(i) => SetPill(ui.blk[i], cfg.block[i])

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
        b.SetFont((on ? "bold " : "norm ") "c" (on ? "FFFFFF" : (RAMPS[i] ? C.text : C.muted)))
        b.Text := "     " (on ? "●" : "○") "     " MODES[i].name
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
    return list
}

OnMonitorChange(*) {
    old := MonitorDevice(cfg.monitor)
    cfg.monitor := ui.mon.Value - 1
    SaveConfig()
    if old != MonitorDevice(cfg.monitor) && current != 1 {
        SetRamp(old, RAMPS[1])
        SelectMode(current, true)
    }
}

ToggleLock() {
    cfg.lockOn := !cfg.lockOn
    SetPill(ui.lock, cfg.lockOn)
    SaveConfig()
    CheckGame()
    UpdateStatus()
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
        "игра может сбрасывать гамму.",
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
