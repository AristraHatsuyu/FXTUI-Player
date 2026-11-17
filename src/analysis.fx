// analysis: what the screen shows about the sound. The engine keeps a copy
// of every stereo frame it queues (History, indexed by output frame); the
// main loop reads the frames that are sounding right now and turns them into
// the spectrum analyzer (FFT bars on log-spaced bands, peak hold with decay)
// and the stereo level meters (peak and RMS in dBFS). Nothing here runs on
// the audio thread.
I>dsp.fft
I>dsp.window
I>dsp.level
I>math.ieee

E> Floor :(f32)= -72          // dB shown as an empty bar
E> MeterFloor :(f32)= -60

// x with `places` decimals (0..6), "-inf"/"inf"/"nan" for those values.
E> decimal :<str>= (x:f64, places:u32) {
    if (x != x) { R> "nan" }
    if (x > 1e15) { R> "inf" }
    if (x < -1e15) { R> "-inf" }
    scale :[f64]= 1
    L> [places] { scale *= 10 }
    magnitude := x < 0 ? 0 - x : x
    units := ieee.round(magnitude * scale).>@cast[u64]
    step := scale.>@cast[u64]
    whole := units / step
    sign := x < 0 && units > 0 ? "-" : ""
    if (places == 0) { R> `{sign}{whole}` }
    part := `{units % step}`
    L> (part.>@len < places.>@cast[usize]) { part = `0{part}` }
    R> `{sign}{whole}.{part}`
}

// Stereo frames by output frame number; capacity is a power of two.
E> History :(type)= { samples:f32[], capacity:u64, }

E> history :<History>= (frames:u64) {
    capacity :[u64]= 1
    L> (capacity < frames) { capacity *= 2 }
    R> { samples:@allocate[f32]((capacity * 2).>@cast[usize]), capacity, }
}

// Keeps the first `frames` frames of block, which start at output frame `at`.
// Copied in at most two contiguous runs (before and after the wrap).
E> store := (&h:History, at:u64, block:f32[], frames:usize) {
    mask := h.capacity - 1
    done :[usize]= 0
    L> (done < frames) {
        slot := ((at + done.>@cast[u64]) & mask).>@cast[usize]
        room := h.capacity.>@cast[usize] - slot
        n := frames - done < room ? frames - done : room
        to := 2 * slot
        from := 2 * done
        L> (2 * n : k) { h.samples[to + k] = block[from + k] }
        done += n
    }
}

// Fills out (stereo) with the frames that end just before output frame
// `end`; frames before the start of the stream are silence.
E> recent := (h:History, end:u64, &out:f32[]) {
    count := out.>@len / 2
    mask := h.capacity - 1
    L> (count : i) {
        back := (count - i).>@cast[u64]
        if (back > end) {
            out[2 * i] = 0
            out[2 * i + 1] = 0
        } {
            slot := ((end - back) & mask).>@cast[usize] * 2
            out[2 * i] = h.samples[slot]
            out[2 * i + 1] = h.samples[slot + 1]
        }
    }
}

// A value that rises at once and falls at `fall` dB per second.
fallTo :<f32>= (shown:f32, value:f32, fall:f32, dt:f32) {
    lowered := shown - fall * dt
    R> value > lowered ? value : lowered
}

// Below `floor` (also -inf and NaN) reads as floor.
atLeast :<f32>= (db:f32, floor:f32) { R> db > floor ? db : floor }

// ---- spectrum analyzer ----

E> Size :(usize)= 2048
HoldSeconds :(f32)= 0.6
PeakFall :(f32)= 20          // dB per second once the hold is over
BarFall :(f32)= 54

E> Spectrum :(type)= {
    plan:fft.RealPlan,
    window:f32[],
    frames:f32[],            // stereo window from the history
    mono:f32[],
    re:f32[],
    im:f32[],
    levels:f32[],            // dB per band as drawn
    peaks:f32[],             // held peak per band
    holds:f32[],             // seconds left before the peak starts to fall
}

E> spectrum :<Spectrum>= () {
    R> {
        plan:fft.realPlan(Size),
        window:window.make(Size, window.Kind.Hann),
        frames:@allocate[f32](2 * Size),
        mono:@allocate[f32](Size),
        re:@allocate[f32](Size / 2 + 1),
        im:@allocate[f32](Size / 2 + 1),
        levels:[],
        peaks:[],
        holds:[],
    }
}

setBands := (&s:Spectrum, bands:usize) {
    s.levels = @allocate[f32](bands)
    s.peaks = @allocate[f32](bands)
    s.holds = @allocate[f32](bands)
    L> (bands : b) {
        s.levels[b] = Floor
        s.peaks[b] = Floor
    }
}

// Power of the strongest bin in [first, last], in dB relative to a
// full-scale sine (a Hann window gives such a sine a bin magnitude of Size/4).
bandDb :<f32>= (s:Spectrum, first:usize, last:usize) {
    top :[f64]= 0
    L> (k := first; k <= last; k++) {
        a := s.re[k].>@cast[f64]
        b := s.im[k].>@cast[f64]
        power := a * a + b * b
        if (power > top) { top = power }
    }
    quarter := (Size / 4).>@cast[f64]
    ratio :[f64]= top / (quarter * quarter)
    if (ratio <= 0) { R> Floor }
    decibels :[f64]= 10 * ieee.log10(ratio)
    R> atLeast(decibels.>@cast[f32], Floor)
}

// Analyzes the Size frames that end at output frame `end`: `bands` bars on
// logarithmic bands from 40 Hz to 16 kHz (or just below Nyquist), each
// falling smoothly, with a peak that holds and then decays. dt: seconds
// since the last update.
E> update := (&s:Spectrum, h:History, end:u64, rate:u32, bands:usize, dt:f32) {
    if (bands == 0) { R> }
    if (s.levels.>@len != bands) { setBands(&s, bands) }
    recent(h, end, &s.frames)
    L> (Size : i) { s.mono[i] = 0.5 * (s.frames[2 * i] + s.frames[2 * i + 1]) * s.window[i] }
    fft.forwardReal(&s.plan, s.mono, &s.re, &s.im)
    nyquist :[f64]= rate.>@cast[f64] * 0.475
    low :[f64]= 40
    high :[f64]= nyquist < 16000 ? nyquist : 16000
    binHz :[f64]= rate.>@cast[f64] / Size.>@cast[f64]
    span :[f64]= high / low
    last := Size / 2
    L> (bands : b) {
        from :[f64]= b.>@cast[f64] / bands.>@cast[f64]
        to :[f64]= (b + 1).>@cast[f64] / bands.>@cast[f64]
        f0 :[f64]= low * ieee.pow(span, from)
        f1 :[f64]= low * ieee.pow(span, to)
        k0 := ieee.round(f0 / binHz).>@cast[usize]
        k1 := ieee.round(f1 / binHz).>@cast[usize]
        if (k0 < 1) { k0 = 1 }
        if (k0 > last) { k0 = last }
        if (k1 < k0) { k1 = k0 }
        if (k1 > last) { k1 = last }
        value := bandDb(s, k0, k1)
        level := atLeast(fallTo(s.levels[b], value, BarFall, dt), Floor)
        s.levels[b] = level
        if (level >= s.peaks[b]) {
            s.peaks[b] = level
            s.holds[b] = HoldSeconds
        } (s.holds[b] > 0) {
            s.holds[b] -= dt
        } {
            s.peaks[b] = atLeast(s.peaks[b] - PeakFall * dt, Floor)
        }
    }
}

// ---- level meters ----

MeterFrames :(usize)= 2048   // about 43 ms at 48 kHz
MeterFall :(f32)= 26
MeterHold :(f32)= 1.0

E> Meters :(type)= {
    frames:f32[],
    peak:f32[],              // dBFS per channel as drawn
    rms:f32[],
    hold:f32[],              // held peak
    holds:f32[],
}

E> meters :<Meters>= () {
    m :[Meters]= {
        frames:@allocate[f32](2 * MeterFrames),
        peak:@allocate[f32](2),
        rms:@allocate[f32](2),
        hold:@allocate[f32](2),
        holds:@allocate[f32](2),
    }
    L> (2 : c) {
        m.peak[c] = MeterFloor
        m.rms[c] = MeterFloor
        m.hold[c] = MeterFloor
    }
    R> m
}

// Measures the frames that end at output frame `end`.
E> measure := (&m:Meters, h:History, end:u64, dt:f32) {
    recent(h, end, &m.frames)
    L> (2 : c) {
        peak := atLeast(level.toDb(level.peak(m.frames, 2, c)), MeterFloor)
        rms := atLeast(level.toDb(level.rms(m.frames, 2, c)), MeterFloor)
        m.peak[c] = atLeast(fallTo(m.peak[c], peak, MeterFall, dt), MeterFloor)
        m.rms[c] = atLeast(fallTo(m.rms[c], rms, MeterFall, dt), MeterFloor)
        if (peak >= m.hold[c]) {
            m.hold[c] = peak
            m.holds[c] = MeterHold
        } (m.holds[c] > 0) {
            m.holds[c] -= dt
        } {
            m.hold[c] = atLeast(m.hold[c] - MeterFall * dt, MeterFloor)
        }
    }
}
