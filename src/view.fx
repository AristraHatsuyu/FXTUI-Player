// view: draws one frame of the player on a term screen buffer. From the
// top: a title bar, the track and its format, the progress bar, one row of
// controls (previous, play/pause, next, volume, EQ and loudness chips; two
// rows in a narrow window), the spectrum analyzer filling the middle (with
// the ten-band equalizer beside it, or in its place in a narrow window,
// while the EQ is on), the stereo level meters, the playlist and a help
// line. A tall window gets a blank row between the groups. Every clickable
// part is recorded in u.hits as it is drawn (see controls.fx): the frame
// and its hit table come from the same numbers.
//
// Colours: one blue accent (#2689CA; pressed #096FAF; text on the accent
// #16161A). The mouse has no hover (no any-motion reporting), so the hover
// shade only marks a seek being dragged.
I>term
I>term.screen
I>term.style
I>(term.width, measure)
I>codec
I>math.ieee
I>("playlist.fx", playlist)
I>("engine.fx", engine)
I>("analysis.fx", analysis)
I>("controls.fx", controls)

// The help line: the longest that fits the width (the window less a column
// each side): Full, Short, Narrow (fits an 80x24 window; leaves out 0-9,
// PgUp/PgDn and the equalizer keys) or Tiny (keys only, down to 40 columns).
HelpFull :(str)= "空格 播放/暂停 · ←/→ ±5 秒 · 0–9 跳到 0–90% · ↑/↓ 音量 · n/p 下一首/上一首 · j/k 选择 · Enter 播放所选 · PgUp/PgDn 翻页 · e 均衡器 · [ ] 选频段 · -/= 增减 · r 归零 · l 响度 · q 退出"
HelpShort :(str)= "空格 播放 · ←/→ 跳转 · ↑/↓ 音量 · n/p 曲目 · j/k Enter 选曲 · e 均衡 · l 响度 · q 退出 · 可用鼠标"
HelpNarrow :(str)= "空格 暂停  ←→ 跳转  ↑↓ 音量  n/p 换曲  j/k Enter 选曲  e/l 均衡/响度  q 退出"
HelpTiny :(str)= "空格 ←→ ↑↓ n p j k e l q · 可用鼠标"

// Which help line (0 Full .. 3 Tiny) fits `room` columns.
helpFor :<u8>= (room:usize) {
    if (measure.textWidth(HelpFull) <= room) { R> 0 }
    if (measure.textWidth(HelpShort) <= room) { R> 1 }
    if (measure.textWidth(HelpNarrow) <= room) { R> 2 }
    R> 3
}

helpText :<str>= (which:u8) {
    if (which == 0) { R> HelpFull }
    if (which == 1) { R> HelpShort }
    if (which == 2) { R> HelpNarrow }
    R> HelpTiny
}

accentRgb :<u32>= () { R> style.rgb(38, 137, 202) }
hoverRgb :<u32>= () { R> style.rgb(25, 125, 189) }       // #197DBD
pressedRgb :<u32>= () { R> style.rgb(9, 111, 175) }      // #096FAF
onAccentRgb :<u32>= () { R> style.rgb(22, 22, 26) }      // #16161A
chipRgb :<u32>= () { R> style.rgb(44, 47, 60) }          // a control at rest
trackRgb :<u32>= () { R> style.rgb(62, 65, 78) }         // the unfilled part of a bar
barRgb :<u32>= () { R> style.rgb(30, 32, 42) }           // title bar

accent :<term.Style>= () { R> { fg:accentRgb(), } }
quiet :<term.Style>= () { R> { fg:style.rgb(130, 132, 145), } }
strong :<term.Style>= () { R> { fg:style.rgb(240, 240, 245), attrs:style.Bold, } }

// Writes text at (x, y) and returns the column after it.
write :<u16>= (&back:term.Screen, x:u16, y:u16, value:str, st:term.Style) { R> x + screen.put(&back, x, y, value, st) }

// m:ss for a duration in seconds.
E> clock :<str>= (seconds:f64) {
    whole := seconds > 0 ? ieee.floor(seconds).>@cast[u64] : 0
    minutes := whole / 60
    rest := whole % 60
    R> `{minutes}:{rest < 10 ? "0" : ""}{rest}`
}

// x with one decimal ("-12.3").
fixed :<str>= (x:f64) { R> analysis.decimal(x, 1) }

duration :<f64?>= (info:codec.Info) {
    frames := info.frames
    if (frames == null) { R> null }
    R> frames.>@cast[f64] / info.rate.>@cast[f64]
}

// The tag title when the file has one, else the file name.
label :<str>= (t:playlist.Track) {
    if (t.title.>@len > 0) { R> `{t.title}` }
    R> `{t.name}`
}

// Colour of a spectrum cell at fraction `h` (0 bottom .. 1 top): the
// pressed blue at the floor through the accent to a pale sky blue on top.
heat :<u32>= (h:f32) {
    if (h < 0.5) {
        t := h * 2
        R> style.rgb((9 + 29 * t).>@cast[u8], (111 + 26 * t).>@cast[u8], (175 + 27 * t).>@cast[u8])
    }
    t := (h - 0.5) * 2
    R> style.rgb((38 + 122 * t).>@cast[u8], (137 + 76 * t).>@cast[u8], (202 + 46 * t).>@cast[u8])
}

// Colour of a meter cell at `db`: the usual green / amber / red, toned to
// sit beside the blue (a teal green, a warm amber, a soft red).
meterColor :<u32>= (db:f32) {
    if (db > -6) { R> style.rgb(232, 86, 76) }
    if (db > -18) { R> style.rgb(228, 184, 76) }
    R> style.rgb(62, 190, 160)
}

// Eighth-block glyph for `eighths` (1..8) of a cell filled from below.
block :<u32>= (eighths:u32) { R> 0x2580 + eighths }

header := (&back:term.Screen, e:engine.Engine, y:u16) {
    w := back.width
    screen.fill(&back, 0, y, w, 1, 32, { bg:barRgb(), })
    screen.put(&back, 2, y, "FXTUI-Player", { fg:accentRgb(), bg:barRgb(), attrs:style.Bold, })
    index := engine.playing(e)
    count := e.tracks.>@len
    state := e.paused ? "⏸ 已暂停" : "▶ 播放中"
    right := index < count ? `{index + 1} / {count}   {state}` : `{state}`
    width := measure.textWidth(right).>@cast[u16]
    if (w > width + 18) {
        screen.put(&back, w - width - 2, y, right, { fg:style.rgb(200, 203, 216), bg:barRgb(), })
    }
}

// A square chip (no border): `label`, at rest, on (accent) or held down
// (pressed). Records it as `action`; returns the column after it.
chip :<u16>= (&back:term.Screen, &u:controls.Ui, x:u16, y:u16, label:str, action:u8, on:bl) {
    down := u.pressed == action
    st :[term.Style]= { fg:style.rgb(176, 180, 194), bg:chipRgb(), }
    if (on) { st = { fg:onAccentRgb(), bg:accentRgb(), attrs:style.Bold, } }
    if (down) { st = { fg:onAccentRgb(), bg:pressedRgb(), attrs:style.Bold, } }
    width := screen.put(&back, x, y, label, st)
    controls.mark(&u.hits, action, x, y, width, 1, 0)
    R> x + width
}

// Title and artist, then the format line.
nowPlaying := (&back:term.Screen, e:engine.Engine, y:u16) {
    index := engine.playing(e)
    if (index >= e.tracks.>@len) {
        screen.put(&back, 2, y, "播放列表已结束", quiet())
        R>
    }
    at := write(&back, 2, y, label(e.tracks[index]), strong())
    if (e.tracks[index].artist.>@len > 0) {
        screen.put(&back, at + 2, y, e.tracks[index].artist, { fg:style.rgb(168, 172, 188), })
    }
    info := e.tracks[index].info
    length := duration(info)
    bits := info.bits > 0 ? ` · {info.bits} 位` : ""
    rate := info.rate == e.rate ? "" : ` → {e.rate} Hz`
    total := length == null ? "未知时长" : clock(length)
    screen.put(&back, 2, y + 1, `{codec.codecName(info.codec)} · {info.rate} Hz{rate} · {info.channels} 声道{bits} · {total}`, quiet())
}

// The progress bar; while a seek is dragged it shows where the release will land.
progress := (&back:term.Screen, e:engine.Engine, &u:controls.Ui, y:u16) {
    w := back.width
    index := engine.playing(e)
    if (index >= e.tracks.>@len) { R> }
    length := duration(e.tracks[index].info)
    dragging := u.pressed == controls.Seek && length != null
    now :[f64]= engine.elapsed(e)
    if (u.pressed == controls.Seek && length != null) { now = u.preview * length }
    left := clock(now)
    right := length == null ? "--:--" : clock(length)
    x := write(&back, 2, y, left, dragging ? accent() : strong())
    span :[u16]= w > x + 10 + right.>@len.>@cast[u16] ? w - x - 4 - right.>@len.>@cast[u16] : 0
    if (span > 0) {
        fraction :[f64]= length == null || length <= 0 ? 0 : now / length
        if (fraction > 1) { fraction = 1 }
        filled := (fraction * span.>@cast[f64]).>@cast[u16]
        lit :[term.Style]= { fg:dragging ? hoverRgb() : accentRgb(), }
        knob :[term.Style]= dragging ? strong() : accent()
        rest :[term.Style]= { fg:trackRgb(), }
        L> (span : i) {
            if (i == filled) {
                screen.set(&back, x + 1 + i, y, 0x25CF, knob)
            } {
                screen.set(&back, x + 1 + i, y, 0x2501, i < filled ? lit : rest)
            }
        }
        screen.put(&back, x + 2 + span, y, right, quiet())
        if (length != null) { controls.mark(&u.hits, controls.Seek, x + 1, y, span, 1, 0) }
    }
}

// Previous, play/pause and next; returns the column after them.
transport :<u16>= (&back:term.Screen, e:engine.Engine, &u:controls.Ui, x:u16, y:u16) {
    at := chip(&back, &u, x, y, "  ⏮  ", controls.Previous, false)
    at = chip(&back, &u, at + 1, y, e.paused ? "  ▶  " : "  ⏸  ", controls.Play, true)
    R> chip(&back, &u, at + 1, y, "  ⏭  ", controls.Next, false)
}

// A chip per on/off feature; returns the column after them.
toggles :<u16>= (&back:term.Screen, e:engine.Engine, &u:controls.Ui, x:u16, y:u16) {
    at := chip(&back, &u, x, y, " EQ ", controls.Eq, e.eqOn)
    R> chip(&back, &u, at + 1, y, " 响度 ", controls.Loudness, e.loudOn)
}

// The volume bar (20 cells of 5%) and its value; returns the column after
// them (the value keeps four columns so nothing after it moves).
volume :<u16>= (&back:term.Screen, e:engine.Engine, &u:controls.Ui, x:u16, y:u16) {
    v := write(&back, x, y, "音量 ", quiet())
    on :[term.Style]= { fg:accentRgb(), }
    off :[term.Style]= { fg:chipRgb(), }
    L> (20 : i) {
        screen.set(&back, v + i, y, 0x2588, (i + 1) * 5 <= e.volume ? on : off)
    }
    controls.mark(&u.hits, controls.Volume, v, y, 20, 1, 0)
    screen.put(&back, v + 21, y, `{e.volume}%`, strong())
    R> v + 25
}

// Momentary loudness of the output and, in loudness mode, the track's gain.
readout :<str>= (e:engine.Engine) {
    index := engine.playing(e)
    lufs := engine.momentary(e)
    loud := lufs > -70 ? `{fixed(lufs)} LUFS` : "-- LUFS"
    gain := e.loudOn && index < e.gains.>@len ? `   增益 {fixed(e.gains[index])} dB → {engine.Target} LUFS` : ""
    R> `{loud}{gain}`
}

// The controls: one row in a wide window (transport, volume, chips, and
// the loudness readout at the right edge), two rows otherwise.
controlRows := (&back:term.Screen, e:engine.Engine, &u:controls.Ui, y:u16, wide:bl) {
    w := back.width
    x := transport(&back, e, &u, 2, y)
    text := readout(e)
    if (wide) {
        x = volume(&back, e, &u, x + 3, y)
        x = toggles(&back, e, &u, x + 3, y)
        width := measure.textWidth(text).>@cast[u16]
        if (w > x + width + 4) { screen.put(&back, w - width - 2, y, text, quiet()) }
        R>
    }
    toggles(&back, e, &u, x + 2, y)
    x = volume(&back, e, &u, 2, y + 1)
    screen.put(&back, x + 1, y + 1, text, quiet())
}

spectrumArea := (&back:term.Screen, sp:analysis.Spectrum, y:u16, height:u16, bands:usize, slot:u16) {
    if (height == 0 || bands == 0 || sp.levels.>@len != bands) { R> }
    barWidth := slot > 1 ? slot - 1 : 1
    total :[f32]= height.>@cast[f32] * 8
    range :[f32]= 0 - analysis.Floor
    L> (bands : b) {
        x := 1 + b.>@cast[u16] * slot
        level := (sp.levels[b] - analysis.Floor) / range
        eighths := (level * total).>@cast[u32]
        peak := (sp.peaks[b] - analysis.Floor) / range
        peakRow := (peak * height.>@cast[f32]).>@cast[u16]
        L> (height : r) {
            row := y + height - 1 - r                 // r counts up from the bottom
            have := r.>@cast[u32] * 8
            glyph :[u32]= 32
            if (eighths >= have + 8) { glyph = 0x2588 } (eighths > have) { glyph = block(eighths - have) }
            colour := heat(r.>@cast[f32] / height.>@cast[f32])
            if (glyph == 32 && r == peakRow && peak > 0.02 && peakRow > 0) {
                L> (barWidth : k) { screen.set(&back, x + k, row, 0x2594, { fg:style.rgb(235, 235, 240), }) }
            } (glyph != 32) {
                L> (barWidth : k) { screen.set(&back, x + k, row, glyph, { fg:colour, }) }
            }
        }
    }
}

PanelWidth :(u16)= 46            // the equalizer beside the spectrum
SideFrom :(u16)= 100             // window width from which they sit side by side

eqLabel :<str>= (band:usize) {
    if (band == 0) { R> "31" }
    if (band == 1) { R> "62" }
    if (band == 2) { R> "125" }
    if (band == 3) { R> "250" }
    if (band == 4) { R> "500" }
    if (band == 5) { R> "1k" }
    if (band == 6) { R> "2k" }
    if (band == 7) { R> "4k" }
    if (band == 8) { R> "8k" }
    R> "16k"
}

// Columns the spectrum gets: the window, less the equalizer panel when it
// sits beside it.
E> spectrumWidth :<u16>= (w:u16, e:engine.Engine) {
    R> e.eqOn && w >= SideFrom ? w - PanelWidth - 2 : w
}

// The ten-band equalizer: a vertical slider per band (top +12 dB, middle
// 0, bottom -12), its gain and its frequency under it. The band the keys
// work on is brighter. One region covers the sliders (value: columns per
// band); controls.fx turns a column into a band and a row into a gain.
eqPanel := (&back:term.Screen, e:engine.Engine, &u:controls.Ui, x:u16, y:u16, width:u16, height:u16) {
    if (height < 6 || width < 45) { R> }
    slot :[u16]= (width - 5) / 10
    if (slot > 6) { slot = 6 }
    rows :[u16]= height - 3
    if (rows > 25) { rows = 25 }
    if (rows % 2 == 0) { rows -= 1 }
    left := x + (width - slot * 10 - 4) / 2 + 4       // four columns of scale before the first band
    top := y + (height - rows - 3) / 2
    sy := top + 1
    centre := (rows - 1) / 2
    range := engine.EqRange
    screen.put(&back, left - 4, top, "均衡器", { fg:style.rgb(200, 203, 216), attrs:style.Bold, })
    hint := "[ ] 选频段  -/= 增减  r 归零"
    hintWidth := measure.textWidth(hint).>@cast[u16]
    if (slot * 10 > hintWidth + 6) { screen.put(&back, left + slot * 10 - hintWidth, top, hint, quiet()) }
    screen.put(&back, left - 4, sy, "+12", quiet())
    screen.put(&back, left - 4, sy + centre, "  0", quiet())
    screen.put(&back, left - 4, sy + rows - 1, "-12", quiet())
    L> (slot * 10 : i) { screen.set(&back, left + i, sy + centre, 0x2500, { fg:style.rgb(52, 55, 68), }) }
    L> (engine.EqBands : b) {
        bx := left + b.>@cast[u16] * slot + (slot - 2) / 2
        g := e.eqGains[b]
        knob := (((range - g) * (rows - 1).>@cast[i32] + range) / (2 * range)).>@cast[u16]
        chosen := b == u.band
        L> (rows : r) {
            colour :[u32]= chipRgb()
            if (r == knob) {
                colour = chosen ? style.rgb(240, 240, 245) : accentRgb()
            } ((r > knob && r <= centre) || (r < knob && r >= centre)) {
                colour = pressedRgb()
            }
            screen.set(&back, bx, sy + r, 0x2588, { fg:colour, })
            screen.set(&back, bx + 1, sy + r, 0x2588, { fg:colour, })
        }
        value := g > 0 ? `+{g}` : `{g}`
        screen.put(&back, value.>@len > 2 ? bx - 1 : bx, sy + rows, value, chosen ? strong() : quiet())
        name := eqLabel(b)
        screen.put(&back, name.>@len > 2 ? bx - 1 : bx, sy + rows + 1, name, chosen ? accent() : quiet())
    }
    controls.mark(&u.hits, controls.EqBand, left, sy, slot * 10, rows, slot.>@cast[u32])
}

meterLine := (&back:term.Screen, mt:analysis.Meters, c:usize, y:u16) {
    w := back.width
    x := write(&back, 2, y, c == 0 ? "L " : "R ", strong())
    span :[u16]= w > x + 30 ? w - x - 26 : 0
    range :[f32]= 0 - analysis.MeterFloor
    if (span > 0) {
        peakCells := ((mt.peak[c] - analysis.MeterFloor) / range * span.>@cast[f32]).>@cast[u16]
        rmsCells := ((mt.rms[c] - analysis.MeterFloor) / range * span.>@cast[f32]).>@cast[u16]
        holdCell := ((mt.hold[c] - analysis.MeterFloor) / range * span.>@cast[f32]).>@cast[u16]
        L> (span : i) {
            db := analysis.MeterFloor + range * i.>@cast[f32] / span.>@cast[f32]
            colour := meterColor(db)
            if (i < rmsCells) {
                screen.set(&back, x + i, y, 0x2588, { fg:colour, })
            } (i < peakCells) {
                screen.set(&back, x + i, y, 0x2593, { fg:colour, })
            } (i == holdCell && holdCell > 0) {
                screen.set(&back, x + i, y, 0x2502, { fg:style.rgb(235, 235, 240), })
            } {
                screen.set(&back, x + i, y, 0x2500, { fg:style.rgb(52, 55, 68), })
            }
        }
    }
    peak := mt.hold[c] > analysis.MeterFloor ? `{fixed(mt.hold[c])}` : "-inf"
    rms := mt.rms[c] > analysis.MeterFloor ? `{fixed(mt.rms[c])}` : "-inf"
    screen.put(&back, x + span + 1, y, `峰 {peak}  RMS {rms} dBFS`, quiet())
}

// The playlist: centred on the playing track, moved by u.scroll (wheel,
// PgUp/PgDn) and brought to the selection when u.reveal asks. The playing
// row is the accent bar, the selected row a quieter one with a marker.
playlistArea := (&back:term.Screen, e:engine.Engine, &u:controls.Ui, y:u16, rows:u16) {
    if (rows == 0) { R> }
    w := back.width
    count := e.tracks.>@len
    controls.follow(&u, e)
    current := u.follow
    shown := rows.>@cast[usize]
    auto :[usize]= 0
    if (current < count && current >= shown / 2) { auto = current - shown / 2 }
    last :[usize]= count > shown ? count - shown : 0
    if (auto > last) { auto = last }
    wanted :[i64]= auto.>@cast[i64] + u.scroll
    if (wanted < 0) { wanted = 0 }
    if (wanted > last.>@cast[i64]) { wanted = last.>@cast[i64] }
    first := wanted.>@cast[usize]
    if (u.reveal && u.selected < count) {
        if (u.selected < first) { first = u.selected }
        if (u.selected >= first + shown) { first = u.selected + 1 - shown }
    }
    u.reveal = false
    u.scroll = first.>@cast[i64] - auto.>@cast[i64]
    u.rows = rows
    playing :[term.Style]= { fg:onAccentRgb(), bg:accentRgb(), }
    chosen :[term.Style]= { fg:style.rgb(232, 234, 242), bg:chipRgb(), }
    plain :[term.Style]= { fg:style.rgb(190, 192, 204), }
    used :[u16]= 0
    L> (rows : r) {
        i := first + r.>@cast[usize]
        if (i >= count) { B> }
        used += 1
        on := i == current
        picked := i == u.selected && !on
        line :[term.Style]= on ? playing : (picked ? chosen : plain)
        if (on || picked) { screen.fill(&back, 1, y + r, w - 2, 1, 32, line) }
        length := duration(e.tracks[i].info)
        right := length == null ? "" : clock(length)
        x := write(&back, 2, y + r, `{on ? "▶" : (picked ? "›" : " ")} {i + 1}. `, line)
        screen.put(&back, x, y + r, label(e.tracks[i]), line)
        if (w > 12) { screen.put(&back, w - 2 - right.>@len.>@cast[u16], y + r, right, line) }
    }
    controls.mark(&u.hits, controls.List, 1, y, w - 2, used, first.>@cast[u32])
}

// Bands that fit the width: one column of gap between bars.
E> bandsFor :<usize, u16>= (width:u16) {
    usable := width > 2 ? width - 2 : 0
    count := usable / 3
    if (count > 64) { count = 64 }
    if (count < 8) { count = usable / 2 }
    if (count == 0) { R> 0, 1 }
    R> count.>@cast[usize], usable / count
}

E> draw := (&back:term.Screen, e:engine.Engine, sp:analysis.Spectrum, mt:analysis.Meters, &u:controls.Ui) {
    screen.clear(&back)
    controls.clear(&u.hits)
    w := back.width
    h := back.height
    if (w < 40 || h < 12) {
        screen.put(&back, 0, 0, "窗口太小（至少 40×12）", strong())
        screen.put(&back, 0, 1, e.paused ? "已暂停" : "播放中", quiet())
        R>
    }
    gap :[u16]= h >= 30 ? 1 : 0              // a blank row between the groups when there is room
    wide := w >= 78
    header(&back, e, 0)
    nowPlaying(&back, e, 1 + gap)
    progress(&back, e, &u, 3 + 2 * gap)
    controlRows(&back, e, &u, 4 + 3 * gap, wide)
    listRows :[u16]= h / 5
    if (listRows < 2) { listRows = 2 }
    if (listRows.>@cast[usize] > e.tracks.>@len) { listRows = e.tracks.>@len.>@cast[u16] }
    top :[u16]= (wide ? 5 : 6) + 4 * gap
    bottom := h - 1 - listRows - 1 - 3 - gap  // help, playlist, gap, two meter rows and a gap
    if (bottom > top) {
        height := bottom - top
        panel := e.eqOn && height >= 6
        side := panel && w >= SideFrom
        full := panel && !side && w >= 47
        if (!full) {
            bands, slot := bandsFor(spectrumWidth(w, e))
            spectrumArea(&back, sp, top, height, bands, slot)
        }
        if (side) { eqPanel(&back, e, &u, w - PanelWidth - 1, top, PanelWidth, height) }
        if (full) { eqPanel(&back, e, &u, 1, top, w - 2, height) }
    }
    meterLine(&back, mt, 0, bottom + 1)
    meterLine(&back, mt, 1, bottom + 2)
    playlistArea(&back, e, &u, bottom + 4, listRows)
    if (e.message.>@len > 0) {
        screen.put(&back, 1, h - 1, e.message, accent())
    } {
        if (u.helpWidth != w) {
            // measured only when the width changes, not every frame
            u.help = helpFor((w - 2).>@cast[usize])
            u.helpWidth = w
        }
        screen.put(&back, 1, h - 1, helpText(u.help), quiet())
    }
}
