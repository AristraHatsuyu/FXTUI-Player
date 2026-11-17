// script: the --script test hook. A script is a list of timed key presses,
//   "0.5:right 1:up,up 2.25:n 3:space 4:space 6:q"
// TIME is seconds (up to three decimals) on the player's clock: virtual
// stream time in --dry mode (so runs are deterministic), wall time on a
// device. KEY is space, left, right, up, down, pageup, pagedown, enter,
// ctrl-c, or one character;
// several keys at one time are separated by commas. Times must not go back.
// "stallS" is a simulated main-loop stall of S seconds (see Step).
// Mouse events at cell (X, Y), zero-based like term.MouseEvent, go through
// the same hit test as the terminal's: "pressXxY", "dragXxY", "releaseXxY",
// "clickXxY" (press then release), "wheelupXxY", "wheeldownXxY", e.g.
//   "1:click40x3 2:press10x3,drag60x3,release60x3 3:wheelup12x5"
I>term

// at: milliseconds. stall > 0 is not a key: the main loop stops for that
// many milliseconds (the device keeps taking frames), as when the machine
// is too loaded to schedule it; written "stall0.3" for 0.3 s. pointer != 0
// is not a key either but a mouse event (term.Press, Drag, Release or
// Wheel with button 0 up / 1 down) at (x, y).
E> Step :(type)= { at:i64, code:u32, mods:u8, stall:i64 = 0, pointer:u8 = 0, button:u8 = 0, x:u16 = 0, y:u16 = 0, }
E> Parsed :(type)= enum(u8) { Ok:Step[], Err:str, }

keyOf :<Step?>= (name:str, at:i64) {
    if (name == "space") { R> { at, code:32, mods:0, } }
    if (name == "left") { R> { at, code:term.Left, mods:0, } }
    if (name == "right") { R> { at, code:term.Right, mods:0, } }
    if (name == "up") { R> { at, code:term.Up, mods:0, } }
    if (name == "down") { R> { at, code:term.Down, mods:0, } }
    if (name == "pageup") { R> { at, code:term.PageUp, mods:0, } }
    if (name == "pagedown") { R> { at, code:term.PageDown, mods:0, } }
    if (name == "enter") { R> { at, code:term.Enter, mods:0, } }
    if (name == "ctrl-c") { R> { at, code:99, mods:term.Ctrl, } }
    if (name.>@len > 5 && name[0] == "s" && name[1] == "t" && name[2] == "a" && name[3] == "l" && name[4] == "l") {
        rest :[u8[]]= []
        rest += name[5:]
        length := milliseconds(rest.>@cast[str])
        if (length == null || length == 0) { R> null }
        R> { at, code:0, mods:0, stall:length, }
    }
    if (name.>@len == 1 && name[0] > 32 && name[0] < 127) { R> { at, code:name[0], mods:0, } }
    R> null
}

Point :(type)= { x:u16, y:u16, }

// "40x3" -> (40, 3); null unless two plain numbers below 10000.
cell :<Point?>= (text:str) {
    x :[u32]= 0
    y :[u32]= 0
    seen :[u8]= 0              // 0 in x, 1 in y
    digits :[usize]= 0
    L> (text.>@len : i) {
        c := text[i]
        if (c == "x" && seen == 0 && digits > 0) { seen = 1; digits = 0; N> }
        if (c < "0" || c > "9" || digits >= 4) { R> null }
        digits += 1
        if (seen == 0) { x = x * 10 + (c - "0").>@cast[u32] } { y = y * 10 + (c - "0").>@cast[u32] }
    }
    if (seen == 0 || digits == 0) { R> null }
    R> { x:x.>@cast[u16], y:y.>@cast[u16], }
}

starts :<bl>= (text:str, prefix:str) {
    if (text.>@len <= prefix.>@len) { R> false }
    L> (prefix.>@len : i) { if (text[i] != prefix[i]) { R> false } }
    R> true
}

// "pressXxY" and the other mouse names -> steps (two for a click).
mouseOf :<Step[]?>= (name:str, at:i64) {
    names :[str[]]= ["press", "drag", "release", "click", "wheelup", "wheeldown"]
    L> (names : prefix) {
        if (!starts(name, prefix)) { N> }
        rest :[u8[]]= []
        rest += name[prefix.>@len:]
        p := cell(rest.>@cast[str])
        if (p == null) { R> null }
        x := p.x
        y := p.y
        if (prefix == "press") { R> [{ at, code:0, mods:0, pointer:term.Press, x, y, }] }
        if (prefix == "drag") { R> [{ at, code:0, mods:0, pointer:term.Drag, x, y, }] }
        if (prefix == "release") { R> [{ at, code:0, mods:0, pointer:term.Release, x, y, }] }
        if (prefix == "click") { R> [{ at, code:0, mods:0, pointer:term.Press, x, y, }, { at, code:0, mods:0, pointer:term.Release, x, y, }] }
        R> [{ at, code:0, mods:0, pointer:term.Wheel, button:prefix == "wheelup" ? 0 : 1, x, y, }]
    }
    R> null
}

// "1.25" -> 1250; null when it is not a plain decimal.
milliseconds :<i64?>= (text:str) {
    whole :[i64]= 0
    part :[i64]= 0
    scale :[i64]= 1000
    digits :[usize]= 0
    dot := false
    L> (text.>@len : i) {
        c := text[i]
        if (c == "." && !dot) { dot = true; N> }
        if (c < "0" || c > "9") { R> null }
        digits += 1
        if (dot) {
            if (scale == 1) { N> }
            scale /= 10
            part += (c - "0").>@cast[i64] * scale
        } {
            if (whole > 100000000) { R> null }
            whole = whole * 10 + (c - "0").>@cast[i64]
        }
    }
    if (digits == 0) { R> null }
    R> whole * 1000 + part
}

// Splits on one separator byte, dropping empty pieces.
split :<str[]>= (text:str, separator:u8) {
    out :[str[]]= []
    start :[usize]= 0
    L> (i := 0; i <= text.>@len; i++) {
        if (i == text.>@len || text[i] == separator) {
            if (i > start) {
                piece :[u8[]]= []
                piece += text[start:i]
                out += [piece.>@cast[str]]
            }
            start = i + 1
        }
    }
    R> out
}

E> parse :<Parsed>= (text:str) {
    steps :[Step[]]= []
    last :[i64]= 0
    L> (split(text, " ") : token) {
        pieces := split(token, ":")
        if (pieces.>@len != 2) { R> Parsed.Err(`脚本项 "{token}" 应写成 时间:按键`) }
        at := milliseconds(pieces[0])
        if (at == null) { R> Parsed.Err(`脚本项 "{token}" 的时间不是数字`) }
        if (at < last) { R> Parsed.Err(`脚本项 "{token}" 的时间早于前一项`) }
        last = at
        L> (split(pieces[1], ",") : name) {
            events := mouseOf(name, at)
            if (events != null) { steps += events; N> }
            step := keyOf(name, at)
            if (step == null) { R> Parsed.Err(`脚本项 "{token}" 的按键 "{name}" 不认识`) }
            steps += [step]
        }
    }
    R> Parsed.Ok(steps)
}
