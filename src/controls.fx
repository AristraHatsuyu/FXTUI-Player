// controls: what the keys and the mouse do.
//
// Hit testing has one source of truth: while view.draw paints a frame it
// records every clickable rectangle with its action in a fixed-capacity
// table (Hits, inline in Ui, no heap). The main loop presents that frame
// and hit-tests mouse events against the table, so a click always means
// what the last presented frame showed there; nothing here repeats the
// layout. A resize clears the table (and cancels a drag) until the next
// frame is presented at the new size.
//
// Mouse (SGR 1002 + 1006: press, release, drag with a button down, wheel;
// no hover):
//   progress bar  press/drag previews the position, release seeks once;
//                 past either end of the bar it stays on the end cell
//   volume bar    press/drag sets the volume; wheel steps it
//   playlist      click selects a row; a double click (<= DoubleMs, same
//                 row) or a click on the selected row plays it, but the
//                 playing row restarts only on a double click (the selection
//                 rests on it, so a stray click would lose the position);
//                 wheel scrolls
//   equalizer     press/drag on a band sets its gain; wheel steps it by 1 dB
//   buttons       previous, play/pause, next and the EQ/loudness chips act
//                 on release inside the button they were pressed on
// Every mouse action has a key (see key and README.md).
I>term
I>("engine.fx", engine)

// Action ids of the regions.
E> Nothing :(u8)= 0
E> Seek :(u8)= 1
E> Volume :(u8)= 2
E> List :(u8)= 3
E> Previous :(u8)= 4
E> Play :(u8)= 5
E> Next :(u8)= 6
E> Eq :(u8)= 7
E> Loudness :(u8)= 8
E> EqBand :(u8)= 9                    // the equalizer's sliders (one region; value: columns per band)

E> Capacity :(usize)= 16             // regions one frame can record (a frame uses 8)
DoubleMs :(i64)= 400                  // double click: second press on the same row within this
Never :(i64)= -1000000                // a click time that is never "recent"

// A clickable rectangle. value: the playlist's first shown track (List).
E> Region :(type)= { x:u16, y:u16, w:u16, h:u16, action:u8, value:u32, }
E> Hits :(type)= { regions:Region[16], count:usize, }

// Pointer and playlist state. pressed is the action held down (Nothing when
// no button is), held the region it was pressed on (drags map through it),
// preview the progress fraction a seek drag shows. selected is the playlist
// row the keys and clicks work on; it follows the playing track (follow) and
// scroll is the list's offset from its automatic position, both kept by
// view.draw; reveal asks the next frame to bring the selection into view.
E> Ui :(type)= {
    hits:Hits,
    pressed:u8, held:Region, preview:f64,
    selected:usize, follow:usize, scroll:i64, reveal:bl, rows:u16,
    clickRow:usize, clickAt:i64, playRow:usize, playAt:i64,
    band:usize,                      // equalizer band the keys work on (and the one being dragged)
    help:u8, helpWidth:u16,          // view: which help line fits, for the width it was measured at
}

E> ui :<Ui>= () {
    u :[Ui]= @zero()
    u.clickAt = Never
    u.playAt = Never
    R> u
}

// ---- the table (view.draw writes, the main loop reads) ----

E> clear := (&t:Hits) { t.count = 0 }

// Records a region; empty rectangles and regions past Capacity are dropped.
E> mark := (&t:Hits, action:u8, x:u16, y:u16, w:u16, h:u16, value:u32) {
    if (w == 0 || h == 0 || t.count >= Capacity) { R> }
    t.regions[t.count] = { x, y, w, h, action, value, }
    t.count += 1
}

inside :<bl>= (r:Region, x:u16, y:u16) { R> x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h }

// The region at (x, y); the last recorded wins where regions overlap.
E> find :<Region?>= (t:Hits, x:u16, y:u16) {
    L> (i :[usize]= t.count; i > 0; i -= 1) {
        r := t.regions[i - 1]
        if (inside(r, x, y)) { R> r }
    }
    R> null
}

E> same :<bl>= (a:Hits, b:Hits) {
    if (a.count != b.count) { R> false }
    L> (a.count : i) {
        p := a.regions[i]
        q := b.regions[i]
        if (p.x != q.x || p.y != q.y || p.w != q.w || p.h != q.h || p.action != q.action || p.value != q.value) { R> false }
    }
    R> true
}

E> actionName :<str>= (action:u8) {
    if (action == Seek) { R> "seek" }
    if (action == Volume) { R> "volume" }
    if (action == List) { R> "list" }
    if (action == Previous) { R> "previous" }
    if (action == Play) { R> "play" }
    if (action == Next) { R> "next" }
    if (action == Eq) { R> "eq" }
    if (action == Loudness) { R> "loudness" }
    if (action == EqBand) { R> "band" }
    R> "none"
}

// "hits seek=X,Y,W,H,VALUE ..." for --log (tests place clicks with it).
E> describe :<str>= (t:Hits) {
    out :[str]= "hits"
    L> (t.count : i) {
        r := t.regions[i]
        out = `{out} {actionName(r.action)}={r.x},{r.y},{r.w},{r.h},{r.value}`
    }
    R> out
}

// ---- geometry through a region ----

// Progress fraction at column x: the cell's left edge, so the knob lands
// on the clicked cell. Columns left of the bar clamp to its first cell and
// columns right of it to its last, so the result is always below 1: a drag
// that overshoots the bar never reaches the end of the track (engine.seekTo
// would go to the next track there, or end the playlist on the last one).
E> fraction :<f64>= (r:Region, x:u16) {
    if (x <= r.x || r.w == 0) { R> 0 }
    cell := x - r.x
    if (cell >= r.w) { cell = r.w - 1 }
    R> cell.>@cast[f64] / r.w.>@cast[f64]
}

// Volume at column x: cell i of the bar is (i + 1) / w of full scale, left
// of the bar is 0 (reachable by dragging).
volumeAt :<u32>= (r:Region, x:u16) {
    if (x < r.x) { R> 0 }
    cell := x - r.x
    if (cell >= r.w) { R> 100 }
    R> ((cell + 1).>@cast[u32] * 100 + r.w.>@cast[u32] / 2) / r.w.>@cast[u32]
}

// Equalizer band at column x of the sliders (value: columns per band).
bandAt :<usize>= (r:Region, x:u16) {
    if (x <= r.x || r.value == 0) { R> 0 }
    band := (x - r.x).>@cast[usize] / r.value.>@cast[usize]
    R> band < engine.EqBands ? band : engine.EqBands - 1
}

// Gain (dB) at row y of the sliders: the top row is +EqRange, the bottom
// row -EqRange; rows above and below clamp.
gainAt :<i32>= (r:Region, y:u16) {
    if (y <= r.y || r.h < 2) { R> engine.EqRange }
    row := y - r.y
    if (row >= r.h) { row = r.h - 1 }
    span := (r.h - 1).>@cast[i32]
    R> engine.EqRange - (row.>@cast[i32] * 2 * engine.EqRange + span / 2) / span
}

// ---- playlist ----

// The selection follows the playing track: when it changes, select it and
// return the list to its automatic position.
E> follow := (&u:Ui, e:engine.Engine) {
    current := engine.playing(e)
    if (current == u.follow) { R> }
    u.follow = current
    if (current < e.tracks.>@len) { u.selected = current }
    u.scroll = 0
}

select := (&u:Ui, e:engine.Engine, row:usize) {
    if (row >= e.tracks.>@len || row == u.selected) { R> }
    u.selected = row
    u.reveal = true
    engine.note(e, `select {row}`)
}

scroll := (&u:Ui, e:engine.Engine, rows:i64) {
    u.scroll += rows
    u.reveal = false
    engine.note(e, `scroll {rows}`)
}

play := (&e:engine.Engine, &u:Ui, row:usize, now:i64, target:u64) {
    u.selected = row
    u.playRow = row
    u.playAt = now
    u.clickAt = Never
    engine.play(&e, row, target)
    follow(&u, e)
}

// A press on playlist row `row` at `now` (ms).
rowClick := (&e:engine.Engine, &u:Ui, row:usize, now:i64, target:u64) {
    if (row >= e.tracks.>@len) { R> }
    // the second press of a double click whose first press already played the row
    if (row == u.playRow && now - u.playAt <= DoubleMs) { R> }
    twice := row == u.clickRow && now - u.clickAt <= DoubleMs
    // one click plays the selected row, except the row already playing: the
    // selection follows the playing track, so that click would restart it
    if (twice || (row == u.selected && row != engine.playing(e))) {
        play(&e, &u, row, now, target)
        R>
    }
    u.clickRow = row
    u.clickAt = now
    if (row == u.selected) { R> }
    u.selected = row
    engine.note(e, `select {row}`)
}

// ---- buttons ----

button := (&e:engine.Engine, action:u8, target:u64) {
    if (action == Previous) { engine.previous(&e, target) }
    if (action == Play) { engine.togglePause(&e) }
    if (action == Next) { engine.next(&e, target) }
    if (action == Eq) { engine.toggleEq(&e) }
    if (action == Loudness) { engine.toggleLoudness(&e) }
}

isButton :<bl>= (action:u8) { R> action >= Previous && action <= Loudness }

// ---- input ----

// Ends a press without acting (resize, a new press without a release).
E> cancel := (&u:Ui) { u.pressed = Nothing }

// One mouse event at `now` (ms on the player's clock) against the last
// presented frame's regions.
E> pointer := (&e:engine.Engine, &u:Ui, m:term.MouseEvent, now:i64, target:u64) {
    if (m.action == term.Wheel) {
        found := find(u.hits, m.x, m.y)
        up := m.button == 0
        if (found == null || m.button > 1) {
            engine.note(e, `mouse wheel {m.x},{m.y} none`)
            R>
        }
        engine.note(e, `mouse wheel {m.x},{m.y} {actionName(found.action)}`)
        if (found.action == Volume) { engine.louder(&e, up) }
        if (found.action == List) { scroll(&u, e, up ? -1 : 1) }
        if (found.action == EqBand) {
            u.band = bandAt(found, m.x)
            engine.stepEq(&e, u.band, up ? 1 : -1)
        }
        R>
    }
    if (m.action == term.Press) {
        cancel(&u)
        if (m.button != 0) { R> }               // left button only
        found := find(u.hits, m.x, m.y)
        if (found == null) {
            engine.note(e, `mouse press {m.x},{m.y} none`)
            R>
        }
        engine.note(e, `mouse press {m.x},{m.y} {actionName(found.action)}`)
        u.held = found
        u.pressed = found.action
        if (found.action == Seek) { u.preview = fraction(found, m.x) }
        if (found.action == Volume) { engine.setVolume(&e, volumeAt(found, m.x)) }
        if (found.action == EqBand) {
            u.band = bandAt(found, m.x)
            engine.setEqGain(&e, u.band, gainAt(found, m.y))
        }
        if (found.action == List) {
            u.pressed = Nothing
            follow(&u, e)
            rowClick(&e, &u, found.value.>@cast[usize] + (m.y - found.y).>@cast[usize], now, target)
        }
        R>
    }
    if (m.action == term.Drag) {
        if (u.pressed == Seek) { u.preview = fraction(u.held, m.x) }
        if (u.pressed == Volume) { engine.setVolume(&e, volumeAt(u.held, m.x)) }
        if (u.pressed == EqBand) { engine.setEqGain(&e, u.band, gainAt(u.held, m.y)) }
        R>
    }
    if (m.action == term.Release) {
        held := u.pressed
        u.pressed = Nothing
        if (held == Nothing) { R> }
        engine.note(e, `mouse release {m.x},{m.y} {actionName(held)}`)
        if (held == Seek) { engine.seekTo(&e, fraction(u.held, m.x), target) }
        if (isButton(held) && inside(u.held, m.x, m.y)) { button(&e, held, target) }
    }
}

// What one key does. Returns false for quit.
E> key :<bl>= (&e:engine.Engine, &u:Ui, code:u32, mods:u8, target:u64) {
    if ((code == 113 && mods == 0) || (code == 99 && mods == term.Ctrl)) { R> false }
    if (mods != 0 && mods != term.Shift) { R> true }
    if (code == 32) { engine.togglePause(&e) }
    if (code == term.Left) { engine.seekBy(&e, 0 - engine.SeekSeconds, target) }
    if (code == term.Right) { engine.seekBy(&e, engine.SeekSeconds, target) }
    if (code >= 48 && code <= 57) { engine.seekTo(&e, (code - 48).>@cast[f64] / 10, target) }
    if (code == term.Up) { engine.louder(&e, true) }
    if (code == term.Down) { engine.louder(&e, false) }
    if (code == 110) { engine.next(&e, target) }
    if (code == 112) { engine.previous(&e, target) }
    if (code == 101) { engine.toggleEq(&e) }
    if (code == 108) { engine.toggleLoudness(&e) }
    // equalizer: [ and ] pick a band, - and = (or +) change it by 1 dB, r flattens the curve
    if (code == 91 && u.band > 0) { u.band -= 1 }
    if (code == 93 && u.band + 1 < engine.EqBands) { u.band += 1 }
    if (code == 45) { engine.stepEq(&e, u.band, -1) }
    if (code == 61 || code == 43) { engine.stepEq(&e, u.band, 1) }
    if (code == 114) { engine.resetEq(&e) }
    if (code == 106 || code == 107) {
        follow(&u, e)
        at := u.selected
        if (code == 106) { select(&u, e, at + 1) }
        if (code == 107 && at > 0) { select(&u, e, at - 1) }
    }
    if (code == term.Enter) {
        follow(&u, e)
        engine.play(&e, u.selected, target)
        follow(&u, e)
    }
    if (code == term.PageUp || code == term.PageDown) {
        page :[i64]= u.rows > 1 ? (u.rows - 1).>@cast[i64] : 1
        scroll(&u, e, code == term.PageUp ? 0 - page : page)
    }
    R> true
}
