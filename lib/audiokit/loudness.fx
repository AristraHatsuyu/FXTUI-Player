// audiokit.loudness: ITU-R BS.1770-4 / EBU R128 loudness meter.
//   m := loudness.make(48000, 2)
//   loudness.process(&m, samples)       // read only; any block size
//   loudness.momentary(m)               // LUFS, last 400 ms
//   loudness.shortTerm(m)               // LUFS, last 3 s
//   loudness.integrated(m)              // LUFS, gated (-70 LUFS, -10 LU)
//   loudness.range(m)                   // LU, EBU Tech 3342 (LRA)
//   loudness.truePeak(m)                // dBTP, 4x oversampled
//   loudness.make(48000, 2, false)      // no true peak (loudness only, cheaper)
// K-weighting (pre-filter shelf and RLB high-pass) per channel in f64;
// mean squares are gathered in 100 ms sub-blocks, so momentary blocks
// (4 sub-blocks) and short-term blocks (30) both step every 100 ms with
// the 75% overlap of the gating blocks. The K-weighting runs over each
// stretch up to the next sub-block boundary with the filter state in
// registers, two channels per f64x2 (every lane does the scalar recurrence,
// same operations, same order); the true peak uses the block kernels of
// core/truepeak. Gated statistics use energy
// histograms with 0.01 LU bins, so memory stays fixed however long the
// programme runs; process never allocates.
I>math.ieee
I>("core/truepeak.fx", truepeak)

Low :(f64)= -70
High :(f64)= 30
Bins :(usize)= 10000          // (High - Low) / 0.01
Step :(f64)= 0.01
Ring :(usize)= 30

E> Meter :(type)= {
    rate:f64,
    channels:usize,
    weight:f64[],             // G_i per channel
    k:f64[],                  // 10 coefficients: stage 1 b0 b1 b2 a1 a2, stage 2
    state:f64[],              // 4 per channel
    sub:usize,                // samples per 100 ms sub-block
    fill:usize,               // samples in the current sub-block
    sum:f64[],                // weighted mean-square sums per channel, current sub-block
    ring:f64[],               // last 30 sub-block powers (weighted sum of mean squares)
    ringAt:usize,
    subs:u64,                 // sub-blocks completed
    gateCount:u64[],          // integrated: 400 ms blocks per 0.01 LU bin
    gateEnergy:f64[],
    rangeCount:u64[],         // LRA: short-term values per bin
    rangeEnergy:f64[],
    peaked:bl,                // true peak measured (make's `peaks`)
    peak:truepeak.History,
    peaks:f32[],              // true peak per channel (linear)
    maxMomentary:f64,
    maxShort:f64,
}

// WAVE/SMPTE channel order (as dsp.mix): surround channels weigh 1.41,
// LFE 0.
weightFor :<f64>= (channels:usize, c:usize) {
    if (channels == 5 && c >= 3) { R> 1.41 }
    if (channels >= 6 && c == 3) { R> 0 }
    if (channels >= 6 && c >= 4) { R> 1.41 }
    R> 1
}

// peaks = false leaves the true peak out (truePeak and channelPeak then
// report -inf): the loudness values are the same, for about half the work.
E> make :<Meter>= (rate:f64, channels:usize, peaks:bl = true) {
    w := channels == 0 ? 1 : channels
    s0 := @cast[usize](rate / 10 + 0.5)
    m :[Meter]= {
        rate,
        channels:w,
        weight:@allocate[f64](w),
        k:@allocate[f64](10),
        state:@allocate[f64](4 * w),
        sub:s0 < 1 ? 1 : s0,
        fill:0,
        sum:@allocate[f64](w),
        ring:@allocate[f64](Ring),
        ringAt:0,
        subs:0,
        gateCount:@allocate[u64](Bins),
        gateEnergy:@allocate[f64](Bins),
        rangeCount:@allocate[u64](Bins),
        rangeEnergy:@allocate[f64](Bins),
        peaked:peaks,
        peak:truepeak.make(w),
        peaks:@allocate[f32](w),
        maxMomentary:-ieee.Inf,
        maxShort:-ieee.Inf,
    }
    L> (w : c) { m.weight[c] = weightFor(w, c) }
    design(&m)
    R> m
}

// Channel weight override (for layouts other than the default order).
E> setWeight := (&m:Meter, channel:usize, weight:f64) {
    if (channel < m.channels) { m.weight[channel] = weight }
}

design := (&m:Meter) {
    if (m.rate == 48000) {
        // BS.1770-4 Table 1 and 2.
        m.k[0] = 1.53512485958697
        m.k[1] = -2.69169618940638
        m.k[2] = 1.19839281085285
        m.k[3] = -1.69065929318241
        m.k[4] = 0.73248077421585
        m.k[5] = 1
        m.k[6] = -2
        m.k[7] = 1
        m.k[8] = -1.99004745483398
        m.k[9] = 0.99007225036621
        R>
    }
    // The same analog prototypes for other rates (bilinear transform).
    pi :[f64]= 3.141592653589793
    f0 :[f64]= 1681.974450955533
    g :[f64]= 3.999843853973347
    q :[f64]= 0.7071752369554196
    t1 :[f64]= pi * f0 / m.rate
    k := ieee.tan(t1)
    vh := ieee.exp2(g * 0.16609640474436813)
    vb := ieee.pow(vh, 0.4996667741545416)
    a0 := 1 + k / q + k * k
    m.k[0] = (vh + vb * k / q + k * k) / a0
    m.k[1] = 2 * (k * k - vh) / a0
    m.k[2] = (vh - vb * k / q + k * k) / a0
    m.k[3] = 2 * (k * k - 1) / a0
    m.k[4] = (1 - k / q + k * k) / a0
    f1 :[f64]= 38.13547087602444
    q1 :[f64]= 0.5003270373238773
    t2 :[f64]= pi * f1 / m.rate
    k1 := ieee.tan(t2)
    d := 1 + k1 / q1 + k1 * k1
    m.k[5] = 1
    m.k[6] = -2
    m.k[7] = 1
    m.k[8] = 2 * (k1 * k1 - 1) / d
    m.k[9] = (1 - k1 / q1 + k1 * k1) / d
}

E> reset := (&m:Meter) {
    L> (m.state.>@len : i) { m.state[i] = 0 }
    L> (m.channels : c) {
        m.sum[c] = 0
        m.peaks[c] = 0
    }
    L> (Ring : i) { m.ring[i] = 0 }
    L> (Bins : i) {
        m.gateCount[i] = 0
        m.gateEnergy[i] = 0
        m.rangeCount[i] = 0
        m.rangeEnergy[i] = 0
    }
    m.fill = 0
    m.ringAt = 0
    m.subs = 0
    m.maxMomentary = -ieee.Inf
    m.maxShort = -ieee.Inf
    truepeak.reset(&m.peak)
}

E> latency :<usize>= (m:Meter) { R> 0 }

// LUFS of a weighted power (sum of G_i * mean square).
E> lufs :<f64>= (power:f64) {
    if (power <= 0) { R> -ieee.Inf }
    l := ieee.log10(power)
    R> -0.691 + 10 * l
}

binOf :<usize>= (l:f64) {
    x := (l - Low) / Step
    if (x <= 0) { R> 0 }
    if (x >= @cast[f64](Bins - 1)) { R> Bins - 1 }
    R> @cast[usize](x)
}

centre :<f64>= (bin:usize) { R> Low + (@cast[f64](bin) + 0.5) * Step }

// Mean of the last n sub-blocks (n <= 30).
recent :<f64>= (m:Meter, n:usize) {
    s :[f64]= 0
    L> (n : i) {
        at := (m.ringAt + Ring - 1 - i) % Ring
        s += m.ring[at]
    }
    R> s / @cast[f64](n)
}

closeSub := (&m:Meter) {
    inv := 1 / @cast[f64](m.sub)
    p :[f64]= 0
    L> (m.channels : c) {
        p += m.weight[c] * m.sum[c] * inv
        m.sum[c] = 0
    }
    m.ring[m.ringAt] = p
    m.ringAt = m.ringAt + 1 == Ring ? 0 : m.ringAt + 1
    m.subs += 1
    m.fill = 0
    if (m.subs >= 4) {
        z := recent(m, 4)
        l := lufs(z)
        if (l > m.maxMomentary) { m.maxMomentary = l }
        if (l > Low) {
            b := binOf(l)
            m.gateCount[b] += 1
            m.gateEnergy[b] += z
        }
    }
    if (m.subs >= 30) {
        z := recent(m, 30)
        l := lufs(z)
        if (l > m.maxShort) { m.maxShort = l }
        if (l > Low) {
            b := binOf(l)
            m.rangeCount[b] += 1
            m.rangeEnergy[b] += z
        }
    }
}

// K-weighting of frames [first, first + n) for channels c and c + 1 (lane
// 1 idle when c is the last channel), adding z^2 to their sub-block sums.
weigh := (&m:Meter, samples:f32[], first:usize, n:usize, c:usize) {
    w := m.channels
    pair := c + 1 < w
    b0 := m.k[0]
    b1 := m.k[1]
    b2 := m.k[2]
    a1 := m.k[3]
    a2 := m.k[4]
    c0 := m.k[5]
    c1 := m.k[6]
    c2 := m.k[7]
    d1 := m.k[8]
    d2 := m.k[9]
    s := 4 * c
    t := pair ? s + 4 : s
    s0 :[f64x2]= [m.state[s], m.state[t]]
    s1 :[f64x2]= [m.state[s + 1], m.state[t + 1]]
    s2 :[f64x2]= [m.state[s + 2], m.state[t + 2]]
    s3 :[f64x2]= [m.state[s + 3], m.state[t + 3]]
    sum :[f64x2]= [m.sum[c], pair ? m.sum[c + 1] : 0]
    next := pair ? 1 : 0
    L> (n : i) {
        at := (first + i) * w + c
        x :[f64x2]= [@cast[f64](samples[at]), @cast[f64](samples[at + next])]
        y := x * b0 + s0
        s0 = x * b1 - y * a1 + s1
        s1 = x * b2 - y * a2
        z := y * c0 + s2
        s2 = y * c1 - z * d1 + s3
        s3 = y * c2 - z * d2
        sum = sum + z * z
    }
    m.state[s] = s0.x
    m.state[s + 1] = s1.x
    m.state[s + 2] = s2.x
    m.state[s + 3] = s3.x
    m.sum[c] = sum.x
    if (pair) {
        m.state[t] = s0.y
        m.state[t + 1] = s1.y
        m.state[t + 2] = s2.y
        m.state[t + 3] = s3.y
        m.sum[c + 1] = sum.y
    }
}

// Measures frames [first, first + count) of interleaved samples.
E> span := (&m:Meter, samples:f32[], first:usize, count:usize) {
    w := m.channels
    // frames past the end of samples are not there to measure
    frames := samples.>@len / w
    todo := first >= frames ? 0 : (count < frames - first ? count : frames - first)
    if (m.peaked) { truepeak.highest(&m.peak, samples, first, todo, &m.peaks) }
    done :[usize]= 0
    L> (done < todo) {
        room := m.sub - m.fill
        n := todo - done < room ? todo - done : room
        L> (c := @cast[usize](0); c < w; c += 2) { weigh(&m, samples, first + done, n, c) }
        done += n
        m.fill += n
        if (m.fill == m.sub) { closeSub(&m) }
    }
}

E> process := (&m:Meter, samples:f32[]) {
    frames := samples.>@len / m.channels
    span(&m, samples, 0, frames)
}

// LUFS over the last 400 ms; -inf before 400 ms have been measured.
E> momentary :<f64>= (m:Meter) {
    if (m.subs < 4) { R> -ieee.Inf }
    R> lufs(recent(m, 4))
}

// LUFS over the last 3 s; -inf before 3 s have been measured.
E> shortTerm :<f64>= (m:Meter) {
    if (m.subs < 30) { R> -ieee.Inf }
    R> lufs(recent(m, 30))
}

E> maxMomentary :<f64>= (m:Meter) { R> m.maxMomentary }
E> maxShortTerm :<f64>= (m:Meter) { R> m.maxShort }

// Energy mean of the bins above `from` (bin index), as LUFS.
gatedMean :<f64>= (count:u64[], energy:f64[], from:usize) {
    n :[u64]= 0
    e :[f64]= 0
    L> (i := from; i < Bins; i++) {
        n += count[i]
        e += energy[i]
    }
    if (n == 0) { R> -ieee.Inf }
    R> lufs(e / @cast[f64](n))
}

// Integrated loudness (BS.1770-4 gating): -inf when nothing passed the
// absolute gate.
E> integrated :<f64>= (m:Meter) {
    ungated := gatedMean(m.gateCount, m.gateEnergy, 0)
    if (ungated == -ieee.Inf) { R> ungated }
    gate := ungated - 10
    R> gatedMean(m.gateCount, m.gateEnergy, binOf(gate) + 1)
}

// Loudness range (EBU Tech 3342): spread between the 10th and 95th
// percentile of short-term loudness after the -70 LUFS and -20 LU gates.
E> range :<f64>= (m:Meter) {
    ungated := gatedMean(m.rangeCount, m.rangeEnergy, 0)
    if (ungated == -ieee.Inf) { R> 0 }
    from := binOf(ungated - 20) + 1
    n :[u64]= 0
    L> (i := from; i < Bins; i++) { n += m.rangeCount[i] }
    if (n == 0) { R> 0 }
    low := percentile(m.rangeCount, from, n, 0.10)
    high := percentile(m.rangeCount, from, n, 0.95)
    R> high - low
}

// Nearest-rank percentile over bins from `from`, as the bin centre.
percentile :<f64>= (count:u64[], from:usize, n:u64, p:f64) {
    rank0 := @cast[u64](p * @cast[f64](n - 1) + 0.5)
    seen :[u64]= 0
    L> (i := from; i < Bins; i++) {
        seen += count[i]
        if (seen > rank0) { R> centre(i) }
    }
    R> centre(Bins - 1)
}

// Highest true peak so far over all channels, dBTP.
E> truePeak :<f64>= (m:Meter) {
    top :[f32]= 0
    L> (m.channels : c) { if (m.peaks[c] > top) { top = m.peaks[c] } }
    if (top <= 0) { R> -ieee.Inf }
    l := ieee.log10(@cast[f64](top))
    R> 20 * l
}

// True peak of one channel, dBTP.
E> channelPeak :<f64>= (m:Meter, channel:usize) {
    if (channel >= m.channels || m.peaks[channel] <= 0) { R> -ieee.Inf }
    l := ieee.log10(@cast[f64](m.peaks[channel]))
    R> 20 * l
}
