// audiokit.core.truepeak: ITU-R BS.1770-4 Annex 2 true-peak estimation,
// 4x oversampling with the 48-tap (4 phases x 12 taps) interpolation filter
// given in the recommendation. Shared by the loudness meter and the
// limiter. Nothing here allocates after make.

// Phase p, tap k is Taps[12 * p + k]; tap 0 multiplies the newest sample.
E> Taps :(f64[48])= [
    0.0017089843750, 0.0109863281250, -0.0196533203125, 0.0332031250000, -0.0594482421875, 0.1373291015625,
    0.9721679687500, -0.1022949218750, 0.0476074218750, -0.0266113281250, 0.0148925781250, -0.0083007812500,
    -0.0291748046875, 0.0292968750000, -0.0517578125000, 0.0891113281250, -0.1665039062500, 0.4650878906250,
    0.7797851562500, -0.2003173828125, 0.1015625000000, -0.0582275390625, 0.0330810546875, -0.0189208984375,
    -0.0189208984375, 0.0330810546875, -0.0582275390625, 0.1015625000000, -0.2003173828125, 0.7797851562500,
    0.4650878906250, -0.1665039062500, 0.0891113281250, -0.0517578125000, 0.0292968750000, -0.0291748046875,
    -0.0083007812500, 0.0148925781250, -0.0266113281250, 0.0476074218750, -0.1022949218750, 0.9721679687500,
    0.1373291015625, -0.0594482421875, 0.0332031250000, -0.0196533203125, 0.0109863281250, 0.0017089843750,
]

E> Length :(usize)= 12

// Per-channel history of the last 12 samples. Each sample is stored twice
// (at `at` and `at + 12`), so the 12 newest are always the contiguous run
// ending at `at + 12`: no wrap-around arithmetic in the filter loop.
// `line` is the block kernels' work line: one channel's 11 previous samples
// followed by up to Block new ones.
E> History :(type)= { channels:usize, at:usize, past:f32[], line:f32[], }

// Frames the block kernels (highest, framePeaks) take per inner pass.
E> Block :(usize)= 256

// Larger than the largest sum of |taps| over one phase (2.0228271484375,
// phases 1 and 2): |interpolated value| <= Bound * max |sample| over its
// 12-sample support, with room for the f64 rounding of the sum.
E> Bound :(f64)= 2.0229

// Positions per skip test in the block kernels.
Run :(usize)= 16

// Bound on |f32 estimate - exact f64 value| relative to max |x| over the
// support: the taps are exact in f32, 12 rounded products and 11 rounded
// sums stay below 23 * 2^-24 * sum |h x| <= 2.8e-6 max |x|.
E> Slack :(f64)= 1.0e-5

// Above this max |x| the f32 estimate could overflow: exact path only.
E> Huge :(f64)= 1.0e30

// Below this max |x| the f32 products can land in the denormal range,
// where each rounds with an absolute error up to 2^-150 that Slack (relative
// to max |x|) does not cover: exact path only. At and above it, 24 such
// errors (< 2e-44) stay far inside the spare (Slack - 2.8e-6) * Tiny.
E> Tiny :(f64)= 1.0e-36

E> make :<History>= (channels:usize) {
    w := channels == 0 ? 1 : channels
    R> { channels:w, at:0, past:@allocate[f32](2 * Length * w), line:@allocate[f32](Length - 1 + Block), }
}

E> reset := (&h:History) {
    L> (h.past.>@len : k) { h.past[k] = 0 }
    h.at = 0
}

// Pushes one sample of channel c (call for every channel of a frame, then
// advance) and returns the largest |interpolated value| among the four
// phases ending at this sample.
E> push :<f32>= (&h:History, c:usize, x:f32) {
    base := 2 * c * Length
    h.past[base + h.at] = x
    h.past[base + h.at + Length] = x
    newest := base + h.at + Length
    top :[f64]= 0
    L> (4 : p) {
        sum :[f64]= 0
        L> (Length : k) { sum += Taps[12 * p + k] * @cast[f64](h.past[newest - k]) }
        a := sum < 0 ? -sum : sum
        if (a > top) { top = a }
    }
    R> @cast[f32](top)
}

// Moves to the next frame after every channel was pushed.
E> advance := (&h:History) {
    h.at += 1
    if (h.at == Length) { h.at = 0 }
}

// True peak (linear) of whole interleaved frames, from silence.
E> measure :<f32>= (samples:f32[], channels:usize) {
    h := make(channels)
    w := h.channels
    frames := samples.>@len / w
    top :[f32]= 0
    L> (frames + Length : i) {
        L> (w : c) {
            x :[f32]= i < frames ? samples[i * w + c] : 0
            v := push(&h, c, x)
            if (v > top) { top = v }
        }
        advance(&h)
    }
    R> top
}

// ---- block kernels ----
// The same interpolator over a run of frames, one channel at a time. An f32
// pass (the four phases in the lanes of one f32x4) estimates every point to
// within Slack * max |x|; only points whose estimate comes within that of the
// threshold the caller cares about are computed exactly, by the f64 code of
// push (same operations, same order: bit-identical values). Runs of Run
// positions whose samples are all small enough that Bound * max |x| stays at
// or below the threshold are skipped outright.

// Largest |value| of the four interpolated points whose newest sample is
// line[j] (j >= 11): exactly what push returns, in f64.
peakAt :<f64>= @inline (line:f32[], j:usize) {
    top :[f64]= 0
    L> (4 : p) {
        sum :[f64]= 0
        L> (Length : k) { sum += Taps[12 * p + k] * @cast[f64](line[j - k]) }
        a := sum < 0 ? -sum : sum
        if (a > top) { top = a }
    }
    R> top
}

// f32 estimate of peakAt(line, j), within Slack * max |x| of it while
// Tiny <= max |x| <= Huge (NaN when the support holds a NaN).
estimate :<f32>= @inline (line:f32[], j:usize) {
    k0 :[f32x4]= [@cast[f32](Taps[0]), @cast[f32](Taps[12]), @cast[f32](Taps[24]), @cast[f32](Taps[36])]
    k1 :[f32x4]= [@cast[f32](Taps[1]), @cast[f32](Taps[13]), @cast[f32](Taps[25]), @cast[f32](Taps[37])]
    k2 :[f32x4]= [@cast[f32](Taps[2]), @cast[f32](Taps[14]), @cast[f32](Taps[26]), @cast[f32](Taps[38])]
    k3 :[f32x4]= [@cast[f32](Taps[3]), @cast[f32](Taps[15]), @cast[f32](Taps[27]), @cast[f32](Taps[39])]
    k4 :[f32x4]= [@cast[f32](Taps[4]), @cast[f32](Taps[16]), @cast[f32](Taps[28]), @cast[f32](Taps[40])]
    k5 :[f32x4]= [@cast[f32](Taps[5]), @cast[f32](Taps[17]), @cast[f32](Taps[29]), @cast[f32](Taps[41])]
    k6 :[f32x4]= [@cast[f32](Taps[6]), @cast[f32](Taps[18]), @cast[f32](Taps[30]), @cast[f32](Taps[42])]
    k7 :[f32x4]= [@cast[f32](Taps[7]), @cast[f32](Taps[19]), @cast[f32](Taps[31]), @cast[f32](Taps[43])]
    k8 :[f32x4]= [@cast[f32](Taps[8]), @cast[f32](Taps[20]), @cast[f32](Taps[32]), @cast[f32](Taps[44])]
    k9 :[f32x4]= [@cast[f32](Taps[9]), @cast[f32](Taps[21]), @cast[f32](Taps[33]), @cast[f32](Taps[45])]
    k10 :[f32x4]= [@cast[f32](Taps[10]), @cast[f32](Taps[22]), @cast[f32](Taps[34]), @cast[f32](Taps[46])]
    k11 :[f32x4]= [@cast[f32](Taps[11]), @cast[f32](Taps[23]), @cast[f32](Taps[35]), @cast[f32](Taps[47])]
    s := k0 * line[j]
    s = s + k1 * line[j - 1]
    s = s + k2 * line[j - 2]
    s = s + k3 * line[j - 3]
    s = s + k4 * line[j - 4]
    s = s + k5 * line[j - 5]
    s = s + k6 * line[j - 6]
    s = s + k7 * line[j - 7]
    s = s + k8 * line[j - 8]
    s = s + k9 * line[j - 9]
    s = s + k10 * line[j - 10]
    s = s + k11 * line[j - 11]
    zero := @splat[f32x4](0.0)
    a := @select(s < zero, -s, s)
    R> @lanesMax(a)
}

// max |x| over line[from .. to + 11), the supports of positions [from, to)
// (NaN samples are passed over).
largest :<f64>= @inline (line:f32[], from:usize, to:usize) {
    top :[f32]= 0
    L> (j := from; j < to + Length - 1; j++) {
        a := line[j] < 0 ? -line[j] : line[j]
        top = a > top ? a : top
    }
    R> @cast[f64](top)
}

// line = channel c's 11 previous samples (history read at `at`), then
// frames [first, first + n) of interleaved samples.
load := (past:f32[], at:usize, w:usize, c:usize, samples:f32[], first:usize, n:usize, &line:f32[]) {
    base := 2 * c * Length + at + 1
    L> (Length - 1 : j) { line[j] = past[base + j] }
    L> (n : i) { line[Length - 1 + i] = samples[(first + i) * w + c] }
}

// The last 12 samples of line become channel c's history, stored for
// at = 0 (the caller sets at once every channel was loaded).
keep := (&past:f32[], c:usize, line:f32[], n:usize) {
    base := 2 * c * Length
    L> (Length : j) {
        v := line[n - 1 + j]
        past[base + j] = v
        past[base + j + Length] = v
    }
}

// Largest value over positions 0..n of line (position i ends at
// line[i + 11]) when it is above floor; otherwise some value <= floor.
highestIn :<f64>= (line:f32[], n:usize, floor:f64) {
    top :[f64]= 0
    L> (s := @cast[usize](0); s < n; s += Run) {
        e := s + Run < n ? s + Run : n
        bar := top > floor ? top : floor
        m := largest(line, s, e)
        if (m * Bound <= bar) { N> }
        slack := m * Slack
        exact := !(m <= Huge) || m < Tiny
        L> (i := s; i < e; i++) {
            j := i + Length - 1
            if (exact || !(@cast[f64](estimate(line, j)) + slack <= bar)) {
                v := peakAt(line, j)
                if (v > top) { top = v }
                bar = top > floor ? top : floor
            }
        }
    }
    R> top
}

// out[at + i] = max(out[at + i], value at position i) wherever the value
// is above floor (elsewhere out is left alone).
raiseIn := (line:f32[], n:usize, floor:f64, &out:f32[], at:usize) {
    L> (s := @cast[usize](0); s < n; s += Run) {
        e := s + Run < n ? s + Run : n
        m := largest(line, s, e)
        if (m * Bound <= floor) { N> }
        slack := m * Slack
        exact := !(m <= Huge) || m < Tiny
        L> (i := s; i < e; i++) {
            j := i + Length - 1
            if (exact || !(@cast[f64](estimate(line, j)) + slack <= floor)) {
                v := @cast[f32](peakAt(line, j))
                o := out[at + i]
                out[at + i] = v > o ? v : o
            }
        }
    }
}

// Frames [first, first + count) of interleaved samples (clamped to the
// whole frames there): raises peaks[c] to every channel's true peak, exactly
// as push per sample followed by `if (t > peaks[c]) { peaks[c] = t }`.
// Leaves the history as push and advance would.
E> highest := (&h:History, samples:f32[], first:usize, count:usize, &peaks:f32[]) {
    w := h.channels
    total := samples.>@len / w
    todo := first >= total ? 0 : (count < total - first ? count : total - first)
    done :[usize]= 0
    L> (done < todo) {
        n := todo - done < Block ? todo - done : Block
        at := h.at
        L> (w : c) {
            load(h.past, at, w, c, samples, first + done, n, &h.line)
            floor :[f64]= c < peaks.>@len ? @cast[f64](peaks[c]) : 0
            t := @cast[f32](highestIn(h.line, n, floor))
            if (c < peaks.>@len && t > peaks[c]) { peaks[c] = t }
            keep(&h.past, c, h.line, n)
        }
        h.at = 0
        done += n
    }
}

// The largest f32 value <= floor (floor itself when it is one, or when it
// is not above 0). The kernels decide in f64 and skip a point only when its
// exact value is <= this, so push's f32 rounding of it stays <= floor too.
below :<f64>= (floor:f64) {
    if (!(floor > 0)) { R> floor }
    f := @cast[f32](floor)
    if (@cast[f64](f) <= floor) { R> @cast[f64](f) }
    R> @cast[f64]((f.>@bitcast[u32] - 1).>@bitcast[f32])
}

// Frames [first, first + count) of interleaved samples (clamped as above,
// and to out's length): out[i] = the largest true peak over all channels at
// frame first + i (the largest value push returns for that frame), except
// that a frame where no channel goes above floor gets some value <= floor.
// floor may be any f64 (it is lowered to an f32 value first; callers that
// pass an f32 value, like the limiter's ceiling, see no change).
// Leaves the history as push and advance would.
E> framePeaks := (&h:History, samples:f32[], first:usize, count:usize, floor:f64, &out:f32[]) {
    bar := below(floor)
    w := h.channels
    total := samples.>@len / w
    fit := first >= total ? 0 : (count < total - first ? count : total - first)
    todo := fit < out.>@len ? fit : out.>@len
    L> (todo : i) { out[i] = 0 }
    done :[usize]= 0
    L> (done < todo) {
        n := todo - done < Block ? todo - done : Block
        at := h.at
        L> (w : c) {
            load(h.past, at, w, c, samples, first + done, n, &h.line)
            raiseIn(h.line, n, bar, &out, done)
            keep(&h.past, c, h.line, n)
        }
        h.at = 0
        done += n
    }
}
