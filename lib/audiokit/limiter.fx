// audiokit.limiter: brickwall lookahead limiter with a true-peak ceiling.
//   l := limiter.make(48000, 2)                       // -1 dBTP, 1.5 ms
//   limiter.process(&l, &samples)                     // in place
//   limiter.latency(l)                                // frames of delay
// Two stages, one shared gain for all channels.
// 1. Main stage. Every input sample's 4x-oversampled true peak (the BS.1770
//    interpolator in core/truepeak, plus the sample itself) sets a required
//    gain. A sliding minimum over W = L + 11 samples, an exponential
//    release, then a box average over L samples, with the audio delayed by
//    L + 10, keep the gain at or below the requirement over the whole
//    12-sample support of every interpolated point; the box makes the gain
//    curve smooth.
// 2. Guard. A gain that changes inside a point's support can still lift
//    that point a little (about 0.01 dB). The guard looks at the main
//    stage's output v and, for every interpolated point with value Z and
//    absolute sum B = sum |h||v|, requires q <= (C - E B) / |Z| over the
//    support, where q is its own gain, kept within [1 - Depth, 1] and
//    smoothed by a box of Box samples, so q varies by at most
//    E = 11 Depth / Box inside any support. Then
//    |sum h q v| <= min(q) |Z| + E B <= C for every point: the output never
//    exceeds the ceiling C in 4x true peak (C carries a 1e-5 margin for
//    rounding) as long as no guard requirement falls below 1 - Depth
//    (`clamped` counts those; the main stage's error stays far inside the
//    depth once L >= MinLookahead samples: in 21000 adversarial signals the
//    deepest requirement was 0.93 against a floor of 0.88). The guard shaves
//    at most a few hundredths of a dB, only where the main stage's output
//    already touches the ceiling.
// Non-finite input samples (NaN, Inf) are treated as 0.
// process never allocates.
// Block form. run takes a chunk (at most bypass.Chunk frames) in passes:
// the ceiling ramp and the input clean-up, the true peaks of the whole
// chunk (core/truepeak's block kernel, which only computes points that can
// reach the ceiling), then the serial gain smoothing and the main delay,
// the guard requirements (a frame whose v is everywhere small enough that no
// point can reach C - E B needs no work: its requirement is exactly 1), and
// the guard's smoothing and output. Every value is computed by the same
// operations in the same order as the per-sample form, so the output is
// bit-identical to it.
I>math.ieee
I>("core/ramp.fx", ramp)
I>("core/bypass.fx", bypass)
I>("core/truepeak.fx", truepeak)

E> Settings :(type)= {
    ceiling:f64 = -1,      // dBTP
    release:f64 = 80,      // ms
}

// Sliding minimum over `window` samples (monotonic deque in a ring) and a
// box average over `box` samples.
Smoother :(type)= {
    box:usize,
    window:usize,
    minIndex:u64[],
    minValue:f32[],
    head:usize,
    size:usize,
    clock:u64,
    ring:f64[],
    at:usize,
    sum:f64,
}

smoother :<Smoother>= (box:usize, window:usize) {
    s :[Smoother]= {
        box,
        window,
        minIndex:@allocate[u64](window),
        minValue:@allocate[f32](window),
        head:0,
        size:0,
        clock:0,
        ring:@allocate[f64](box),
        at:0,
        sum:@cast[f64](box),
    }
    L> (box : k) { s.ring[k] = 1 }
    R> s
}

clear := (&s:Smoother) {
    s.head = 0
    s.size = 0
    s.clock = 0
    L> (s.box : k) { s.ring[k] = 1 }
    s.at = 0
    s.sum = @cast[f64](s.box)
}

// x mod w by subtraction (x is below 2w in every use: no division on the
// per-sample path).
wrap :<usize>= @inline (x:usize, w:usize) {
    y := x
    L> (y >= w) { y -= w }
    R> y
}

// Pushes r and returns the minimum of the last `window` values.
slide :<f32>= (&s:Smoother, r:f32) {
    w := s.window
    L> (s.size > 0) {
        last := wrap(s.head + s.size - 1, w)
        if (s.minValue[last] < r) { B> }
        s.size -= 1
    }
    tail := wrap(s.head + s.size, w)
    s.minIndex[tail] = s.clock
    s.minValue[tail] = r
    s.size += 1
    L> (s.minIndex[s.head] + @cast[u64](w) <= s.clock) {
        s.head = s.head + 1 == w ? 0 : s.head + 1
        s.size -= 1
    }
    s.clock += 1
    R> s.minValue[s.head]
}

// Pushes v into the box and returns the average of the last `box` values.
average :<f64>= (&s:Smoother, v:f64) {
    s.sum += v - s.ring[s.at]
    s.ring[s.at] = v
    s.at = s.at + 1 == s.box ? 0 : s.at + 1
    R> s.sum / @cast[f64](s.box)
}

E> Limiter :(type)= {
    rate:f64,
    channels:usize,
    delay:usize,           // main stage: L + 10
    settings:Settings,
    ceiling:ramp.Ramp,     // linear, with the rounding margin
    recover:f64,           // release coefficient
    history:truepeak.History,
    main:Smoother,
    held:f64,              // released requirement
    line:f32[],            // main stage audio delay
    at:usize,
    // guard
    guardDelay:usize,      // Box + 10
    guardHistory:f32[],    // 12 frames of v per channel, stored twice (see truepeak)
    guardAt:usize,
    guard:Smoother,
    guardLine:f32[],
    guardTo:usize,
    clamped:u64,           // guard requirements below 1 - Depth (should stay 0)
    gain:f32,
    deepest:f32,
    bypass:bypass.Bypass,
    // per-chunk work buffers (bypass.Chunk frames)
    ceilings:f32[],        // c per frame
    peaks:f32[],           // largest |x| per frame
    points:f32[],          // largest true peak per frame (or <= the lowest c)
    gains:f32[],           // main-stage g per frame
    needs:f32[],           // guard requirement q0 per frame
    lines:f32[],           // main-stage output v: per channel 11 earlier frames, then the chunk
    passes:bl[],           // per frame: the f32 estimate shows no guard point can bind
}

Safety :(f64)= 0.99999
Depth :(f32)= 0.12
Box :(usize)= 320
// Shortest main-stage lookahead in samples (shorter requests are raised to
// it; at 48 kHz that is 0.17 ms). Below it the main stage's gain can move so
// fast inside a 12-sample support that the guard's depth is not enough.
E> MinLookahead :(usize)= 8

E> make :<Limiter>= (rate:f64, channels:usize, settings:Settings = {}, lookahead:f64 = 1.5, glide:f64 = 10) {
    w := channels == 0 ? 1 : channels
    l0 := @cast[usize](rate * lookahead * 0.001 + 0.5)
    l := l0 < MinLookahead ? MinLookahead : l0
    n := truepeak.Length
    delay := l + n - 2
    guardDelay := Box + n - 2
    fade := ramp.samples(rate, glide)
    m :[Limiter]= {
        rate,
        channels:w,
        delay,
        settings,
        ceiling:ramp.make(1),
        recover:0,
        history:truepeak.make(w),
        main:smoother(l, l + n - 1),
        held:1,
        line:@allocate[f32](delay * w),
        at:0,
        guardDelay,
        guardHistory:@allocate[f32](2 * n * w),
        guardAt:0,
        guard:smoother(Box, Box + n - 1),
        guardLine:@allocate[f32](guardDelay * w),
        guardTo:0,
        clamped:0,
        gain:1,
        deepest:1,
        bypass:bypass.make(w, delay + guardDelay, fade),
        ceilings:@allocate[f32](bypass.Chunk),
        peaks:@allocate[f32](bypass.Chunk),
        points:@allocate[f32](bypass.Chunk),
        gains:@allocate[f32](bypass.Chunk),
        needs:@allocate[f32](bypass.Chunk),
        lines:@allocate[f32](w * (n - 1 + bypass.Chunk)),
        passes:@allocate[bl](bypass.Chunk),
    }
    set(&m, settings, 0)
    R> m
}

// New settings; the ceiling glides over `glide` samples.
E> set := (&m:Limiter, s:Settings, glide:u32 = 480) {
    m.settings = s
    db := s.ceiling > 0 ? 0.0 : s.ceiling
    e := db * 0.16609640474436813
    linear := ieee.exp2(e) * Safety
    ramp.set(&m.ceiling, @cast[f32](linear), glide)
    ms := s.release <= 0 ? 1.0 : s.release
    m.recover = ieee.exp(-1000 / (ms * m.rate))
}

E> setBypass := (&m:Limiter, on:bl) { bypass.set(&m.bypass, on) }

// Frames of delay the limiter adds (lookahead plus guard).
E> latency :<usize>= (m:Limiter) { R> m.delay + m.guardDelay }

// Lowest gain since the last call (linear, 1 = no reduction); resets it.
E> takeReduction :<f32>= (&m:Limiter) {
    g := m.deepest
    m.deepest = 1
    R> g
}

// Guard requirements that hit the depth limit (0 in every test; while it is
// 0 the true-peak bound holds).
E> clamped :<u64>= (m:Limiter) { R> m.clamped }

E> reset := (&m:Limiter) {
    truepeak.reset(&m.history)
    clear(&m.main)
    clear(&m.guard)
    m.held = 1
    L> (m.line.>@len : k) { m.line[k] = 0 }
    L> (m.guardLine.>@len : k) { m.guardLine[k] = 0 }
    L> (m.guardHistory.>@len : k) { m.guardHistory[k] = 0 }
    m.at = 0
    m.guardAt = 0
    m.guardTo = 0
    m.gain = 1
    bypass.reset(&m.bypass)
}

// The guard's E (see the header).
slope :<f64>= () { R> 11 * @cast[f64](Depth) / @cast[f64](Box) }

// Stride of one channel's run in `lines`.
Stride :(usize)= truepeak.Length - 1 + bypass.Chunk

// Guard requirement for frame i of the chunk, for the points whose newest
// sample is that frame's v: r <= (C - E B) / |Z| for each, and |v| r <= C,
// folded per channel (the sample, then phases 0..3) as a running minimum,
// before the clamp at 1 - Depth. z and b for the four phases run in the lanes of an
// f64x4 (each lane the scalar sums, in the scalar order).
needAt :<f64>= (lines:f32[], w:usize, i:usize, c:f32) {
    n := truepeak.Length
    e := slope()
    top :[f64]= @cast[f64](c)
    r :[f64]= 1
    L> (w : ch) {
        p := ch * Stride + n - 1 + i
        v0 := lines[p]
        a0 := v0 < 0 ? -v0 : v0
        if (@cast[f64](a0) * r > top) { r = top / @cast[f64](a0) }
        z := @splat[f64x4](0.0)
        b := @splat[f64x4](0.0)
        zero := @splat[f64x4](0.0)
        L> (n : k) {
            h :[f64x4]= [truepeak.Taps[k], truepeak.Taps[12 + k], truepeak.Taps[24 + k], truepeak.Taps[36 + k]]
            hv := h * @cast[f64](lines[p - k])
            z = z + hv
            b = b + @select(hv < zero, -hv, hv)
        }
        r = fold(r, top, e, z.x, b.x)
        r = fold(r, top, e, z.y, b.y)
        r = fold(r, top, e, z.z, b.z)
        r = fold(r, top, e, z.w, b.w)
    }
    R> r
}

// One phase's constraint: r = min(r, (C - E B) / |Z|) in the guard's form.
fold :<f64>= @inline (r:f64, top:f64, e:f64, z:f64, b:f64) {
    az := z < 0 ? -z : z
    allowed := top - e * b
    R> az * r > allowed ? allowed / az : r
}

// f32 estimate of the largest |Z| + E B over the four phases for the
// points whose newest sample is lines[p]: |Z| and B each within about
// 2.8e-6 max |v| of their exact values (the taps are exact in f32, see
// core/truepeak), E B and the final sum add about 1.3e-7 max |v|; callers
// allow (1 + E) Slack max |v| = 1.0e-5 max |v|.
pressure :<f32>= @inline (lines:f32[], p:usize, e:f32) {
    zero := @splat[f32x4](0.0)
    z := zero
    b := zero
    L> (12 : k) {
        h :[f32x4]= [@cast[f32](truepeak.Taps[k]), @cast[f32](truepeak.Taps[12 + k]), @cast[f32](truepeak.Taps[24 + k]), @cast[f32](truepeak.Taps[36 + k])]
        hv := h * lines[p - k]
        z = z + hv
        b = b + @select(hv < zero, -hv, hv)
    }
    t := @select(z < zero, -z, z) + b * e
    R> @lanesMax(t)
}

// Largest |v| of channel ch over the supports of chunk frames [from, to).
largest :<f32>= (lines:f32[], ch:usize, from:usize, to:usize) {
    top :[f32]= 0
    L> (j := ch * Stride + from; j < ch * Stride + to + truepeak.Length - 1; j++) {
        a := lines[j] < 0 ? -lines[j] : lines[j]
        top = a > top ? a : top
    }
    R> top
}

// Guard requirements for chunk frames [from, to) (at most GuardRun). With
// M = max |v| over their supports: when (1 + E) Bound M stays below C (with
// 1e-6 to spare), |Z| + E B < C at every point, so with r = 1 nothing binds
// and every requirement is exactly 1. Otherwise the f32 estimate clears the
// frames whose every point stays below C - E B by more than its error
// (and |v| <= C), and the rest get the exact requirement. Returns the
// requirements that fell below 1 - Depth (clamped).
guardRun :<u64>= (lines:f32[], ceilings:f32[], w:usize, from:usize, to:usize, &needs:f32[], &passes:bl[]) {
    e := slope()
    least :[f32]= 3.0e38
    L> (i := from; i < to; i++) { least = ceilings[i] < least ? ceilings[i] : least }
    top :[f32]= 0
    L> (w : ch) {
        a := largest(lines, ch, from, to)
        top = a > top ? a : top
    }
    bar := @cast[f64](least) * 0.999999
    if (@cast[f64](top) * truepeak.Bound * (1 + e) <= bar) {
        L> (i := from; i < to; i++) { needs[i] = 1 }
        R> 0
    }
    exact := !(@cast[f64](top) <= truepeak.Huge)
    slack := @cast[f64](top) * truepeak.Slack * (1 + e)
    L> (i := from; i < to; i++) { passes[i] = !exact }
    if (!exact) {
        ef := @cast[f32](e)
        L> (w : ch) {
            L> (i := from; i < to; i++) {
                p := ch * Stride + truepeak.Length - 1 + i
                v := lines[p] < 0 ? -lines[p] : lines[p]
                ok := @cast[f64](pressure(lines, p, ef)) + slack <= bar && v <= least
                passes[i] = passes[i] && ok
            }
        }
    }
    clamps :[u64]= 0
    low :[f64]= @cast[f64](1 - Depth)
    L> (i := from; i < to; i++) {
        if (passes[i]) { needs[i] = 1 } {
            r := needAt(lines, w, i, ceilings[i])
            if (r < low) { clamps += 1 }
            needs[i] = @cast[f32](r < low ? low : r)
        }
    }
    R> clamps
}

GuardRun :(usize)= 16

run := (&m:Limiter, &x:f32[], first:usize, count:usize) {
    w := m.channels
    n := truepeak.Length
    // 1. ceiling per frame, non-finite input to 0, largest |x| per frame
    lowest :[f32]= 3.0e38
    L> (count : i) {
        c := ramp.next(&m.ceiling)
        m.ceilings[i] = c
        lowest = c < lowest ? c : lowest
        frame := (first + i) * w
        peak :[f32]= 0
        L> (w : ch) {
            v0 := x[frame + ch]
            a0 := v0 < 0 ? -v0 : v0
            // NaN fails the comparison, Inf exceeds it: both become 0
            finite := a0 <= 3.0e38
            x[frame + ch] = finite ? v0 : 0
            a := finite ? a0 : 0
            peak = a > peak ? a : peak
        }
        m.peaks[i] = peak
    }
    // 2. true peaks that can reach the ceiling
    truepeak.framePeaks(&m.history, x, first, count, @cast[f64](lowest), &m.points)
    // 3. main stage: requirement, sliding minimum, release, box; delay.
    // v goes to each channel's run in `lines` after its 11 earlier frames
    // (from the guard history, newest at guardAt + Length).
    L> (w : ch) {
        L> (n - 1 : j) { m.lines[ch * Stride + j] = m.guardHistory[2 * ch * n + m.guardAt + 2 + j] }
    }
    L> (count : i) {
        c := m.ceilings[i]
        peak := m.points[i] > m.peaks[i] ? m.points[i] : m.peaks[i]
        r :[f32]= peak > c ? c / peak : 1
        low := slide(&m.main, r)
        up := 1 - (1 - m.held) * m.recover
        m.held = @cast[f64](low) < up ? @cast[f64](low) : up
        g := @cast[f32](average(&m.main, m.held))
        m.gains[i] = g
        line := m.at * w
        frame := (first + i) * w
        L> (w : ch) {
            d := m.line[line + ch]
            m.line[line + ch] = x[frame + ch]
            m.lines[ch * Stride + n - 1 + i] = d * g
        }
        m.at = m.at + 1 == m.delay ? 0 : m.at + 1
    }
    // 4. guard requirements
    L> (s := @cast[usize](0); s < count; s += GuardRun) {
        e := s + GuardRun < count ? s + GuardRun : count
        clamps := guardRun(m.lines, m.ceilings, w, s, e, &m.needs, &m.passes)
        m.clamped += clamps
    }
    // 5. guard: sliding minimum and box, output through the guard delay
    L> (count : i) {
        q1 := slide(&m.guard, m.needs[i])
        q := @cast[f32](average(&m.guard, @cast[f64](q1)))
        total := m.gains[i] * q
        m.gain = total
        if (total < m.deepest) { m.deepest = total }
        out := m.guardTo * w
        frame := (first + i) * w
        L> (w : ch) {
            d := m.guardLine[out + ch]
            m.guardLine[out + ch] = m.lines[ch * Stride + n - 1 + i]
            x[frame + ch] = d * q
        }
        m.guardTo = m.guardTo + 1 == m.guardDelay ? 0 : m.guardTo + 1
    }
    // the guard history keeps the last 12 frames of v (newest at
    // guardAt + Length with guardAt = 11: positions j and j + 12 alike)
    L> (w : ch) {
        base := 2 * ch * n
        L> (n : j) {
            v := m.lines[ch * Stride + count - 1 + j]
            m.guardHistory[base + j] = v
            m.guardHistory[base + j + n] = v
        }
    }
    m.guardAt = n - 1
}

// Frames [first, first + count) in place.
E> span := (&m:Limiter, &samples:f32[], first:usize, count:usize) {
    size := samples.>@len
    todo := bypass.fit(size, m.channels, first, count)
    done :[usize]= 0
    L> (done < todo) {
        left := todo - done
        n := left < bypass.Chunk ? left : bypass.Chunk
        at := first + done
        if (bypass.idle(m.bypass)) { bypass.pass(&m.bypass, &samples, at, n) } {
            bypass.capture(&m.bypass, &samples, at, n)
            run(&m, &samples, at, n)
            bypass.blend(&m.bypass, &samples, at, n)
        }
        done += n
    }
}

E> process := (&m:Limiter, &samples:f32[]) {
    frames := samples.>@len / m.channels
    span(&m, &samples, 0, frames)
}
