// audiokit.core.ramp: linear per-sample parameter ramps.
//   g := ramp.make(1.0)
//   ramp.set(&g, 0.5, 480)        // reach 0.5 after 480 samples
//   L> (frames : i) { gain := ramp.next(&g) ... }
// A ramp moves by a constant step every sample and lands exactly on the
// target, so a parameter change never jumps (no zipper noise). Nothing
// here allocates.

E> Ramp :(type)= { value:f32, target:f32, step:f32, left:u32, }

E> make :<Ramp>= (value:f32) { R> { value, target:value, step:0, left:0, } }

// Start moving towards target; samples = 0 jumps immediately.
E> set := (&r:Ramp, target:f32, samples:u32) {
    if (samples == 0 || target == r.value) {
        r.value = target
        r.target = target
        r.step = 0
        r.left = 0
        R>
    }
    r.target = target
    r.step = (target - r.value) / @cast[f32](samples)
    r.left = samples
}

// Value for the next sample.
E> next :<f32>= @inline (&r:Ramp) {
    if (r.left == 0) { R> r.value }
    r.left -= 1
    r.value = r.left == 0 ? r.target : r.value + r.step
    R> r.value
}

// Advance n samples at once (used when a block is skipped).
E> skip := (&r:Ramp, n:usize) {
    if (r.left == 0) { R> }
    if (n >= @cast[usize](r.left)) {
        r.value = r.target
        r.left = 0
        R>
    }
    r.left -= @cast[u32](n)
    r.value = r.target - r.step * @cast[f32](r.left)
}

E> moving :<bl>= (r:Ramp) { R> r.left != 0 }

// Samples in `ms` milliseconds at `rate` Hz, rounded.
E> samples :<u32>= (rate:f64, ms:f64) {
    n := rate * ms * 0.001 + 0.5
    if (n <= 0) { R> 0 }
    R> @cast[u32](n)
}
