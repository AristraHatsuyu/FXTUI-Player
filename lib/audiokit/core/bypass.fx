// audiokit.core.bypass: click-free bypass with latency compensation.
// Every effect owns one; its span loop is
//   if (bypass.idle(b)) { bypass.pass(&b, &x, at, n) } {
//       bypass.capture(&b, x, at, n); run(...); bypass.blend(&b, &x, at, n)
//   }
// in chunks of at most Chunk frames. The dry signal goes through a delay of
// `latency` frames all the time, so switching never shifts the timing and a
// bypassed effect with latency still delays by the same amount.
I>("ramp.fx", ramp)

E> Chunk :(usize)= 256

E> Bypass :(type)= {
    channels:usize,
    latency:usize,     // frames
    wet:ramp.Ramp,     // 1 = processed, 0 = bypassed
    fade:u32,          // crossfade samples
    dry:f32[],         // Chunk * channels, the current chunk's dry input
    line:f32[],        // latency * channels ring of earlier input
    at:usize,          // ring position (sample index)
}

E> make :<Bypass>= (channels:usize, latency:usize, fade:u32) {
    w := channels == 0 ? 1 : channels
    size := latency * w
    R> {
        channels:w,
        latency,
        wet:ramp.make(1),
        fade,
        dry:@allocate[f32](Chunk * w),
        line:@allocate[f32](size == 0 ? 1 : size),
        at:0,
    }
}

// Frames of [first, first + count) that lie inside a buffer of `length`
// samples of `channels` channels: span calls clamp their count once with it,
// so a range past the end is cut short instead of indexing out of bounds.
E> fit :<usize>= (length:usize, channels:usize, first:usize, count:usize) {
    frames := length / (channels == 0 ? 1 : channels)
    if (first >= frames) { R> 0 }
    R> count < frames - first ? count : frames - first
}

// on = true bypasses the effect (with a crossfade).
E> set := (&b:Bypass, on:bl) { ramp.set(&b.wet, on ? 0.0 : 1.0, b.fade) }

E> bypassed :<bl>= (b:Bypass) { R> b.wet.target == 0 }

// Fully bypassed and settled: the effect need not run.
E> idle :<bl>= (b:Bypass) { R> b.wet.left == 0 && b.wet.value == 0 }

// Fully processed and settled: blend has nothing to do.
full :<bl>= (b:Bypass) { R> b.wet.left == 0 && b.wet.value == 1 }

// Delays samples[first*ch ..] by latency through the ring; out = dry copy.
// Works in stretches up to the ring's wrap, so the inner loop is a plain
// exchange between two contiguous runs.
delay := (&b:Bypass, &samples:f32[], first:usize, count:usize, keep:bl) {
    w := b.channels
    size := b.latency * w
    base := first * w
    total := count * w
    k :[usize]= 0
    L> (k < total) {
        room := size - b.at
        n := total - k < room ? total - k : room
        at := b.at
        if (keep) {
            L> (n : j) {
                b.dry[k + j] = b.line[at + j]
                b.line[at + j] = samples[base + k + j]
            }
        } {
            L> (n : j) {
                d := b.line[at + j]
                b.line[at + j] = samples[base + k + j]
                samples[base + k + j] = d
            }
        }
        k += n
        b.at = at + n == size ? 0 : at + n
    }
}

// Bypassed and settled: output is the input delayed by latency.
E> pass := (&b:Bypass, &samples:f32[], first:usize, count:usize) {
    if (b.latency != 0) { delay(&b, &samples, first, count, false) }
}

// Before the effect runs over [first, first + count) (count <= Chunk):
// remember the (delayed) dry signal.
E> capture := (&b:Bypass, &samples:f32[], first:usize, count:usize) {
    if (b.latency != 0) {
        delay(&b, &samples, first, count, true)
        R>
    }
    if (full(b)) { R> }
    base := first * b.channels
    total := count * b.channels
    L> (total : k) { b.dry[k] = samples[base + k] }
}

// After the effect: crossfade between the processed samples and the dry copy.
E> blend := (&b:Bypass, &samples:f32[], first:usize, count:usize) {
    if (full(b)) { R> }
    w := b.channels
    base := first * w
    L> (count : i) {
        g := ramp.next(&b.wet)
        d := 1 - g
        L> (w : c) {
            k := i * w + c
            samples[base + k] = g * samples[base + k] + d * b.dry[k]
        }
    }
}

E> reset := (&b:Bypass) {
    L> (b.line.>@len : k) { b.line[k] = 0 }
    b.at = 0
}
