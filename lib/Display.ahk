;=====================================================================
; Насыщенность NVIDIA (Digital Vibrance) и проверка HDR
;=====================================================================
; NVAPI: функции получаем по id через nvapi_QueryInterface.
; Уровень DVC «Ex» — 0..100, 50 — стандарт (как в панели NVIDIA).
global NV := {ok: false, tried: false, fn: Map(), handles: Map()}

NvInit() {
    if NV.tried
        return NV.ok
    NV.tried := true
    try {
        if DllCall("LoadLibrary", "str", "nvapi64.dll", "ptr")
            NV.ok := DllCall(NvFn(0x0150E828), "cdecl int") = 0      ; NvAPI_Initialize
    }
    return NV.ok
}

NvFn(id) {
    if !NV.fn.Has(id)
        NV.fn[id] := DllCall("nvapi64\nvapi_QueryInterface", "uint", id, "cdecl ptr")
    return NV.fn[id]
}

; Дескриптор дисплея NVIDIA по имени \\.\DISPLAYn (0 — не NVIDIA)
NvHandle(dev) {
    if !NvInit()
        return 0
    if NV.handles.Has(dev)
        return NV.handles[dev]
    h := 0, fn := NvFn(0x35C29134)                                   ; GetAssociatedNvidiaDisplayHandle
    r := fn ? DllCall(fn, "astr", dev, "ptr*", &h, "cdecl int") : -1
    NV.handles[dev] := r = 0 ? h : 0
    return NV.handles[dev]
}

NvGetVib(dev) {
    h := NvHandle(dev), fn := NvFn(0x0E45002D)                       ; GetDVCInfoEx
    if !h || !fn
        return ""
    ex := Buffer(20, 0)
    NumPut("uint", 20 | 0x10000, ex)
    return DllCall(fn, "ptr", h, "uint", 0, "ptr", ex, "cdecl int") = 0 ? NumGet(ex, 4, "int") : ""
}

NvSetVib(dev, level) {
    h := NvHandle(dev), fn := NvFn(0x4A82C2B1)                       ; SetDVCLevelEx
    if !h || !fn
        return false
    ex := Buffer(20, 0)
    NumPut("uint", 20 | 0x10000, ex), NumPut("int", Max(0, Min(100, level)), ex, 4)
    return DllCall(fn, "ptr", h, "uint", 0, "ptr", ex, "cdecl int") = 0
}

; Есть ли хоть один монитор на NVIDIA
NvAvailable() {
    loop MonitorGetCount()
        if NvHandle(MonitorGetName(A_Index))
            return true
    return false
}

; Включён ли HDR («расширенный цвет») на мониторе \\.\DISPLAYn
HdrOn(dev) {
    np := 0, nm := 0
    if DllCall("GetDisplayConfigBufferSizes", "uint", 2, "uint*", &np, "uint*", &nm, "int") != 0
        return false
    paths := Buffer(np * 72, 0), modes := Buffer(nm * 64, 0)
    if DllCall("QueryDisplayConfig", "uint", 2, "uint*", &np, "ptr", paths, "uint*", &nm, "ptr", modes, "ptr", 0, "int") != 0
        return false
    loop np {
        p := (A_Index - 1) * 72
        src := Buffer(84, 0)                                         ; DISPLAYCONFIG_SOURCE_DEVICE_NAME
        NumPut("int", 1, src, 0), NumPut("uint", 84, src, 4)
        NumPut("int64", NumGet(paths, p, "int64"), src, 8), NumPut("uint", NumGet(paths, p + 8, "uint"), src, 16)
        if DllCall("DisplayConfigGetDeviceInfo", "ptr", src, "int") != 0
            continue
        if StrGet(src.Ptr + 20, 32, "UTF-16") != dev
            continue
        aci := Buffer(32, 0)                                         ; ..._GET_ADVANCED_COLOR_INFO
        NumPut("int", 9, aci, 0), NumPut("uint", 32, aci, 4)
        NumPut("int64", NumGet(paths, p + 20, "int64"), aci, 8), NumPut("uint", NumGet(paths, p + 28, "uint"), aci, 16)
        if DllCall("DisplayConfigGetDeviceInfo", "ptr", aci, "int") != 0
            return false
        return (NumGet(aci, 20, "uint") >> 1) & 1
    }
    return false
}
