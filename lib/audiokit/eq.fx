// audiokit.eq: parametric equalizer, a cascade of RBJ biquads (the SDK's
// dsp.biquad).
//   e := eq.make(48000, 2, 4)                         // 4 bands, stereo
//   eq.setBand(&e, 0, { kind:eq.Kind.LowShelf, frequency:120, gain:3, })
//   eq.process(&e, &samples)                          // interleaved, in place
//   db := eq.responseDb(e, 1000)                      // for a UI curve
// Parameter changes glide: coefficients move linearly per sample from the
// old to the new design over `glide` samples (the stable region of a1/a2 is
// convex, so every intermediate filter is stable). process never
// allocates; make does.
I>math.ieee
I>(dsp.biquad, biquad)
I>("core/ramp.fx", ramp)
I>("core/bypass.fx", bypass)

E> Kind :(type)= enum(u8) { Peak, LowShelf, HighShelf, Lowpass, Highpass, Notch, Bandpass, }

// One band. Shelves use q as the cookbook shelf alpha (q = 1/sqrt(2) is
// slope S = 1); gain (dB) is used by Peak and the shelves.
E> Band :(type)= {
    kind:Kind = Kind.Peak,
    frequency:f64 = 1000,
    q:f64 = 0.7071067811865476,
    gain:f64 = 0,
    on:bl = true,
}

E> Eq :(type)= {
    rate:f64,
    channels:usize,
    count:usize,
    glide:u32,
    bands:Band[],
    now:f64[],      // 5 coefficients per band as they are right now
    goal:f64[],     // 5 per band, the designed target
    step:f64[],     // 5 per band, per-sample increment while gliding
    left:u32[],     // glide samples left per band
    state:f64[],    // 2 per channel per band (transposed direct form II)
    bypass:bypass.Bypass,
}

E> MaxBands :(usize)= 64

// rate in Hz; bands are all off at first. glide in milliseconds.
E> make :<Eq>= (rate:f64, channels:usize, bands:usize, glide:f64 = 10) {
    w := channels == 0 ? 1 : channels
    n := bands == 0 ? 1 : (bands > MaxBands ? MaxBands : bands)
    fade := ramp.samples(rate, glide)
    e :[Eq]= {
        rate,
        channels:w,
        count:n,
        glide:fade,
        bands:@allocate[Band](n),
        now:@allocate[f64](5 * n),
        goal:@allocate[f64](5 * n),
        step:@allocate[f64](5 * n),
        left:@allocate[u32](n),
        state:@allocate[f64](2 * w * n),
        bypass:bypass.make(w, 0, fade),
    }
    L> (n : b) {
        e.now[5 * b] = 1
        e.goal[5 * b] = 1
    }
    R> e
}

kindOf :<biquad.Kind>= (k:Kind) {
    R> if (k == Kind.Peak) { biquad.Kind.Peaking } (k == Kind.LowShelf) { biquad.Kind.Lowshelf } (k == Kind.HighShelf) { biquad.Kind.Highshelf } (k == Kind.Lowpass) { biquad.Kind.Lowpass } (k == Kind.Highpass) { biquad.Kind.Highpass } (k == Kind.Notch) { biquad.Kind.Notch } { biquad.Kind.Bandpass }
}

// Coefficients of one band (identity when off).
E> coefficients :<biquad.Coefficients>= (rate:f64, band:Band) {
    if (!band.on) { R> { b0:1, b1:0, b2:0, a1:0, a2:0, } }
    R> biquad.design(kindOf(band.kind), rate, band.frequency, q: band.q, gain: band.gain)
}

// Replace band i; the filter glides to it over the glide time.
E> setBand := (&e:Eq, i:usize, band:Band) {
    if (i >= e.count) { R> }
    e.bands[i] = band
    c := coefficients(e.rate, band)
    o := 5 * i
    e.goal[o] = c.b0
    e.goal[o + 1] = c.b1
    e.goal[o + 2] = c.b2
    e.goal[o + 3] = c.a1
    e.goal[o + 4] = c.a2
    if (e.glide == 0) {
        L> (5 : k) {
            e.now[o + k] = e.goal[o + k]
            e.step[o + k] = 0
        }
        e.left[i] = 0
        R>
    }
    inv := 1 / @cast[f64](e.glide)
    L> (5 : k) { e.step[o + k] = (e.goal[o + k] - e.now[o + k]) * inv }
    e.left[i] = e.glide
}

E> band :<Band>= (e:Eq, i:usize) { R> e.bands[i] }

E> setGain := (&e:Eq, i:usize, db:f64) {
    if (i >= e.count) { R> }
    b := e.bands[i]
    b.gain = db
    setBand(&e, i, b)
}

E> setFrequency := (&e:Eq, i:usize, hz:f64) {
    if (i >= e.count) { R> }
    b := e.bands[i]
    b.frequency = hz
    setBand(&e, i, b)
}

E> setQ := (&e:Eq, i:usize, q:f64) {
    if (i >= e.count) { R> }
    b := e.bands[i]
    b.q = q
    setBand(&e, i, b)
}

E> setBypass := (&e:Eq, on:bl) { bypass.set(&e.bypass, on) }

E> latency :<usize>= (e:Eq) { R> 0 }

E> reset := (&e:Eq) {
    L> (e.state.>@len : k) { e.state[k] = 0 }
}

// Linear magnitude of the whole cascade at frequency Hz, using the target
// design (what the filter settles to).
E> response :<f64>= (e:Eq, frequency:f64) {
    g :[f64]= 1
    L> (e.count : b) {
        if (e.bands[b].on) {
            o := 5 * b
            c :[biquad.Coefficients]= { b0:e.goal[o], b1:e.goal[o + 1], b2:e.goal[o + 2], a1:e.goal[o + 3], a2:e.goal[o + 4], }
            g = g * biquad.response(c, e.rate, frequency)
        }
    }
    R> g
}

E> responseDb :<f64>= (e:Eq, frequency:f64) {
    m := response(e, frequency)
    l := ieee.log10(m)
    R> 20 * l
}

// Fills db[k] with the response at frequencies[k] (a UI curve).
E> curve := (e:Eq, frequencies:f64[], &db:f64[]) {
    n := frequencies.>@len < db.>@len ? frequencies.>@len : db.>@len
    L> (n : k) { db[k] = responseDb(e, frequencies[k]) }
}

steady := (&e:Eq, &x:f32[], b:usize, first:usize, count:usize) {
    w := e.channels
    o := 5 * b
    b0 := e.now[o]
    b1 := e.now[o + 1]
    b2 := e.now[o + 2]
    a1 := e.now[o + 3]
    a2 := e.now[o + 4]
    s := 2 * w * b
    L> (w : c) {
        s1 := e.state[s + 2 * c]
        s2 := e.state[s + 2 * c + 1]
        L> (count : i) {
            at := (first + i) * w + c
            v := @cast[f64](x[at])
            y := b0 * v + s1
            s1 = b1 * v - a1 * y + s2
            s2 = b2 * v - a2 * y
            x[at] = @cast[f32](y)
        }
        e.state[s + 2 * c] = s1
        e.state[s + 2 * c + 1] = s2
    }
}

gliding := (&e:Eq, &x:f32[], b:usize, first:usize, count:usize) {
    w := e.channels
    o := 5 * b
    s := 2 * w * b
    L> (count : i) {
        if (e.left[b] != 0) {
            e.left[b] -= 1
            if (e.left[b] == 0) {
                L> (5 : k) { e.now[o + k] = e.goal[o + k] }
            } {
                L> (5 : k) { e.now[o + k] += e.step[o + k] }
            }
        }
        b0 := e.now[o]
        b1 := e.now[o + 1]
        b2 := e.now[o + 2]
        a1 := e.now[o + 3]
        a2 := e.now[o + 4]
        L> (w : c) {
            at := (first + i) * w + c
            v := @cast[f64](x[at])
            s1 := e.state[s + 2 * c]
            s2 := e.state[s + 2 * c + 1]
            y := b0 * v + s1
            e.state[s + 2 * c] = b1 * v - a1 * y + s2
            e.state[s + 2 * c + 1] = b2 * v - a2 * y
            x[at] = @cast[f32](y)
        }
    }
}

run := (&e:Eq, &x:f32[], first:usize, count:usize) {
    L> (e.count : b) {
        if (e.left[b] != 0) { gliding(&e, &x, b, first, count) } (e.bands[b].on) { steady(&e, &x, b, first, count) } {
            // off and settled: identity; clear the history so the band
            // starts from rest when it is switched back on
            s := 2 * e.channels * b
            L> (2 * e.channels : k) { e.state[s + k] = 0 }
        }
    }
}

// Filters frames [first, first + count) of interleaved samples in place.
E> span := (&e:Eq, &samples:f32[], first:usize, count:usize) {
    size := samples.>@len
    todo := bypass.fit(size, e.channels, first, count)
    done :[usize]= 0
    L> (done < todo) {
        left := todo - done
        n := left < bypass.Chunk ? left : bypass.Chunk
        at := first + done
        if (bypass.idle(e.bypass)) { bypass.pass(&e.bypass, &samples, at, n) } {
            bypass.capture(&e.bypass, &samples, at, n)
            run(&e, &samples, at, n)
            bypass.blend(&e.bypass, &samples, at, n)
        }
        done += n
    }
}

// Filters every whole frame of interleaved samples in place.
E> process := (&e:Eq, &samples:f32[]) {
    frames := samples.>@len / e.channels
    span(&e, &samples, 0, frames)
}
