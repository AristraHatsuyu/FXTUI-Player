// engine: the player's audio pipeline. Everything here runs on the main
// loop, never on the audio thread. One step decodes a small chunk, remixes
// it to stereo, resamples it to the output rate, applies the volume ramp,
// the EQ and the loudness stage, keeps a copy for the analyzers and queues
// it on the stream's ring. The device callback (audio module) only reads that
// ring: no decoding, allocation, locks or I/O happen on the realtime side.
//
// Timeline. Output frames are numbered in the order they sound. A frame
// queued and later discarded (seek, track change) is "dropped" and does not
// count, so kept = written - dropped. The limiter delays everything by
// `latency` frames, so the next frame handed to it sounds at kept + latency.
// A Mark records where a stretch of one track starts to sound; the frame
// sounding now is heard = rendered - dropped.
I>io
I>audio
I>codec
I>dsp.mix
I>dsp.resample
I>dsp.level
I>math.ieee
I>audiokit.eq
I>audiokit.limiter
I>audiokit.loudness
I>("playlist.fx", playlist)
I>("analysis.fx", analysis)

E> Chunk :(usize)= 512             // native frames decoded per step (at most)
E> OutFrames :(usize)= 8192        // output frames one step may produce
E> Target :(f64)= -14              // LUFS in loudness mode
E> Ceiling :(f64)= -1              // dBTP in loudness mode
E> SeekSeconds :(i64)= 5
E> VolumeStep :(u32)= 5
ScanFrames :(usize)= 4096          // native frames the loudness scan reads per step
MaxBoost :(f64)= 20
MaxCut :(f64)= -30
E> EqBands :(usize)= 10           // graphic equalizer: octave bands from 31.25 Hz to 16 kHz
E> EqRange :(i32)= 12              // each band is -12 .. +12 dB
RestartSeconds :(f64)= 3           // p within this time of the start goes to the previous track

// From output frame `at` on, track `track` sounds from its native frame
// `origin`. track == tracks.>@len marks the silence after the last track.
E> Mark :(type)= { at:u64, track:usize, origin:u64, }

E> Engine :(type)= {
    stream:audio.Stream,
    dry:bl,
    log:bl,
    display:bl,                   // a screen shows the analyzers (else neither monitor nor history is fed)
    silent:bl,                    // test hook: the ring only ever gets zeros (digital silence)
    rate:u32,                     // output rate
    tracks:playlist.Track[],
    // decoding
    current:usize,                // track being decoded
    decoder:codec.Decoder?,
    position:u64,                 // next native frame of the current track
    decoded:u64,                  // native frames decoded from the current track
    chunk:usize,                  // native frames per step for the current track
    finished:bl,                  // everything decoded and the limiter flushed
    matrix:mix.Matrix,
    resampler:resample.Resampler?,
    native:f32[],
    stereo:f32[],
    output:f32[],
    // processing
    volume:u32,                   // 0..100
    program:f32,                  // program gain reached at the end of the last block
    level:f32,                    // volume gain reached at the end of the last block
    equalizer:eq.Eq,
    eqOn:bl,
    eqGains:i32[],                // dB per band
    eqPreamp:f32,                 // gain before the EQ: minus the curve's highest boost
    limiter:limiter.Limiter,
    loudOn:bl,
    latency:u64,
    gains:f64[],                  // loudness-mode gain per track, dB
    scanned:bl[],                 // the gain comes from the whole track
    scanner:codec.Decoder?,
    scanTrack:usize,
    scanMeter:loudness.Meter,
    scanBuffer:f32[],
    meter:loudness.Meter,         // programme loudness and true peak (before the volume) since the current stretch started (--log only)
    monitor:loudness.Meter,       // loudness of what is heard, continuous (only with a display; no true peak)
    // timeline
    written:u64,
    dropped:u64,
    marks:Mark[],
    history:analysis.History,
    paused:bl,
    message:str,
    // underruns: once the last frame is queued (finished) the ring can only
    // run dry because the playlist ended, so those callbacks do not count
    tail:u32,                     // stream underruns when finished was set
    ignored:u32,                  // underruns counted while finished (end of the playlist)
}

E> kept :<u64>= (e:Engine) { R> e.written - e.dropped }
E> heard :<u64>= (e:Engine) { R> audio.rendered(e.stream) - e.dropped }

// Device callbacks that ran out of frames while there was still something
// to play. audio.underruns also counts the callbacks after the last queued
// frame (the end of the playlist, and the tail the player waits out before
// stopping the device); those are not dropouts.
E> underruns :<u32>= (e:Engine) {
    if (e.finished) { R> e.tail - e.ignored }
    R> audio.underruns(e.stream) - e.ignored
}

// One line of the --log event log (stderr), for tests.
E> note := (e:Engine, text:str) {
    if (e.log) { io.writeAll(`{text}\n`, 2) }
}

// A message for the status line, also logged.
say := (&e:Engine, text:str) {
    e.message = `{text}`
    note(e, `message {text}`)
}

// Centre frequency of band `band`: 31.25 Hz and up by octaves.
E> eqFrequency :<f64>= (band:usize) {
    f :[f64]= 31.25
    L> (band : i) { f = f * 2 }
    R> f
}

// The curve the player starts with (dB per band): a little more bass and
// treble. `r` flattens it.
startGain :<i32>= (band:usize) {
    if (band == 0) { R> 4 }
    if (band == 1) { R> 3 }
    if (band == 2) { R> 2 }
    if (band == 5 || band == 6) { R> -1 }
    if (band == 7) { R> 1 }
    if (band == 8) { R> 2 }
    if (band == 9) { R> 3 }
    R> 0
}

// Ten peaking bands an octave apart (q 1.41), bypassed until the EQ is on.
graphic :<eq.Eq>= (rate:f64, gains:i32[]) {
    e := eq.make(rate, 2, EqBands)
    L> (EqBands : b) {
        eq.setBand(&e, b, { kind:eq.Kind.Peak, frequency:eqFrequency(b), q:1.41, gain:gains[b].>@cast[f64], })
    }
    eq.setBypass(&e, true)
    R> e
}

// Gain that keeps the curve from clipping: minus its highest boost, found
// by sampling the response at third-octave points from 20 Hz to 20 kHz.
headroom :<f32>= (e:eq.Eq) {
    top :[f64]= 0
    f :[f64]= 20
    L> (31 : i) {
        db := eq.responseDb(e, f)
        if (db > top) { top = db }
        f = f * 1.2599210498948732
    }
    R> level.fromDb((0 - top).>@cast[f32])
}

E> make :<Engine>= (stream:audio.Stream, tracks:playlist.Track[], dry:bl, log:bl) {
    rate := audio.format(stream).rate
    r := rate.>@cast[f64]
    count := tracks.>@len
    gains :[f64[]]= @allocate[f64](count)
    scanned :[bl[]]= @allocate[bl](count)
    l := limiter.make(r, 2, { ceiling:Ceiling, release:80, })
    limiter.setBypass(&l, true)
    latency := limiter.latency(l).>@cast[u64]
    capacity := audio.writable(stream) + 4 * analysis.Size.>@cast[u64]
    eqGains :[i32[]]= @allocate[i32](EqBands)
    L> (EqBands : b) { eqGains[b] = startGain(b) }
    equalizer := graphic(r, eqGains)
    eqPreamp := headroom(equalizer)
    R> {
        stream, dry, log, display:false, silent:false, rate, tracks,
        current:0, decoder:null, position:0, decoded:0, chunk:Chunk, finished:false,
        matrix:mix.matrix(2, 2), resampler:null,
        native:[], stereo:@allocate[f32](2 * Chunk), output:@allocate[f32](2 * OutFrames),
        volume:80, program:1, level:0, equalizer, eqOn:false, eqGains, eqPreamp, limiter:l, loudOn:false, latency,
        gains, scanned, scanner:null, scanTrack:0, scanMeter:loudness.make(r, 2, false), scanBuffer:[],
        meter:loudness.make(r, 2), monitor:loudness.make(r, 2, false),
        written:0, dropped:0, marks:[], history:analysis.history(capacity), paused:false, message:"",
        tail:0, ignored:0,
    }
}

// ---- gain ----

volumeGain :<f32>= (volume:u32) {
    v := volume.>@cast[f32] / 100
    R> v * v
}

decibels :<f32>= (db:f64) { R> level.fromDb(db.>@cast[f32]) }

// Gain before the EQ: the EQ curve's headroom and the loudness-mode gain.
// The volume comes after the limiter, so loudness mode sets the programme
// to -14 LUFS / -1 dBTP and the volume only turns that down.
programGain :<f32>= (e:Engine) {
    g :[f32]= 1
    if (e.eqOn) { g *= e.eqPreamp }
    if (e.loudOn && e.current < e.gains.>@len) { g *= decibels(e.gains[e.current]) }
    R> g
}

// Moves toward the goal by at most about 1 dB per block (and 0.01 near
// silence), so volume and loudness changes glide instead of jumping.
approach :<f32>= (from:f32, to:f32) {
    up := from * 1.12 > from + 0.01 ? from * 1.12 : from + 0.01
    down := from / 1.12 < from - 0.01 ? from / 1.12 : from - 0.01
    if (to > from) { R> to < up ? to : up }
    if (to > down) { R> to }
    R> down > 0 ? down : 0
}

// Gain ramp over the first `frames` frames: per sample, no zipper noise.
// A steady gain (from == to, every block once a glide is over) is one
// multiply per sample, and none at all for 1: the same values the ramp
// gives (its step is then 0).
ramp := (&block:f32[], frames:usize, from:f32, to:f32) {
    if (from == to) {
        if (from == 1) { R> }
        L> (2 * frames : k) { block[k] = block[k] * from }
        R>
    }
    step := (to - from) / frames.>@cast[f32]
    L> (frames : i) {
        g := from + step * i.>@cast[f32]
        block[2 * i] = block[2 * i] * g
        block[2 * i + 1] = block[2 * i + 1] * g
    }
}

// Processes the first `frames` frames of e.output and queues them.
emit := (&e:Engine, frames:usize) {
    if (frames == 0) { R> }
    program := approach(e.program, programGain(e))
    ramp(&e.output, frames, e.program, program)
    e.program = program
    eq.span(&e.equalizer, &e.output, 0, frames)
    limiter.span(&e.limiter, &e.output, 0, frames)
    if (e.log) { loudness.span(&e.meter, e.output, 0, frames) }
    level := approach(e.level, volumeGain(e.volume))
    ramp(&e.output, frames, e.level, level)
    e.level = level
    if (e.display) { loudness.span(&e.monitor, e.output, 0, frames) }
    if (e.display) {
        at := kept(e)
        analysis.store(&e.history, at, e.output, frames)
    }
    if (e.silent) { L> (2 * frames : k) { e.output[k] = 0 } }
    put := audio.write(e.stream, e.output[:2 * frames])
    e.written += put.>@cast[u64]
}

// Converts the first `frames` stereo frames of e.stereo to the output rate.
convert := (&e:Engine, frames:usize) {
    if (e.resampler == null) {
        L> (2 * frames : i) { e.output[i] = e.stereo[i] }
        emit(&e, frames)
        R>
    }
    used :[usize]= 0
    L> (used < frames && e.resampler != null) {
        took, made := resample.process(&e.resampler, e.stereo[2 * used:2 * frames], &e.output)
        used += took
        emit(&e, made)
        if (took == 0 && made == 0) { B> }
    }
}

// ---- tracks and the timeline ----

// The next frame handed to the limiter sounds at kept + latency. Marks
// after that point belong to frames that were dropped before they sounded.
startSegment := (&e:Engine, track:usize, origin:u64) {
    at := kept(e) + e.latency
    L> (e.marks.>@len > 0 && e.marks[e.marks.>@len - 1].at >= at) { removed := &e.marks.>@pop }
    e.marks += [{ at, track, origin, }]
    loudness.reset(&e.meter)
    note(e, `segment {track} origin={origin}`)
}

// The mark in effect at output frame `frame`.
markAt :<Mark>= (e:Engine, frame:u64) {
    if (e.marks.>@len == 0) { R> { at:0, track:0, origin:0, } }
    found := e.marks[0]
    L> (e.marks : m) {
        if (m.at > frame) { B> }
        found = m
    }
    R> found
}

// The track sounding now (tracks.>@len after the last one).
E> playing :<usize>= (e:Engine) { R> markAt(e, heard(e)).track }

// Native frame of the playing track that is sounding now.
E> nativePosition :<u64>= (e:Engine) {
    frame := heard(e)
    m := markAt(e, frame)
    if (m.track >= e.tracks.>@len || frame < m.at) { R> m.origin }
    rate := e.tracks[m.track].info.rate.>@cast[u64]
    R> m.origin + (frame - m.at) * rate / e.rate.>@cast[u64]
}

E> elapsed :<f64>= (e:Engine) {
    track := playing(e)
    if (track >= e.tracks.>@len) { R> 0 }
    R> nativePosition(e).>@cast[f64] / e.tracks[track].info.rate.>@cast[f64]
}

// Output frames each track has sounded so far (over all its stretches).
E> heardFrames :<u64[]>= (e:Engine) {
    out :[u64[]]= @allocate[u64](e.tracks.>@len)
    now := heard(e)
    L> (e.marks.>@len : i) {
        m := e.marks[i]
        if (m.track >= e.tracks.>@len || m.at >= now) { N> }
        end := i + 1 < e.marks.>@len && e.marks[i + 1].at < now ? e.marks[i + 1].at : now
        out[m.track] += end - m.at
    }
    R> out
}

// Native frames per step so one step never produces more than OutFrames.
chunkFor :<usize>= (rate:u32, output:u32) {
    room := (OutFrames - 64).>@cast[u64] * rate.>@cast[u64] / output.>@cast[u64]
    R> room < Chunk.>@cast[u64] ? room.>@cast[usize] : Chunk
}

// Opens track i for decoding from native frame `frame`.
load :<bl>= (&e:Engine, i:usize, frame:u64) {
    name := `{e.tracks[i].name}`
    opened := codec.openFile(e.tracks[i].path)
    if (opened:Err) {
        say(&e, `{name}：无法打开（{playlist.reason(opened)}），已跳过`)
        R> false
    }
    d := opened
    info := codec.info(d)
    channels := info.channels.>@cast[usize]
    if (channels == 0 || channels > mix.MaxChannels || !resample.valid(info.rate, e.rate, 2)) {
        say(&e, `{name}：{info.channels} 声道 {info.rate} Hz 无法播放，已跳过`)
        R> false
    }
    landed :[u64]= 0
    if (frame > 0) {
        sought := codec.seek(&d, frame)
        if (sought:Ok) { landed = sought }
    }
    e.matrix = mix.matrix(channels, 2)
    if (channels > 2) { mix.normalize(&e.matrix) }
    e.chunk = chunkFor(info.rate, e.rate)
    e.native = @allocate[f32](e.chunk * channels)
    out := e.rate
    if (info.rate == out) { e.resampler = null } { e.resampler = resample.create(info.rate, out, 2) }
    e.decoder = d
    e.current = i
    e.position = landed
    e.decoded = 0
    e.finished = false
    startSegment(&e, i, landed)
    note(e, `open {i} {name} codec={codec.codecName(info.codec)} rate={info.rate} channels={info.channels} frames={info.frames ?? 0} at={landed}`)
    R> true
}

// Everything is decoded: L zero frames push the limiter's tail out.
finish := (&e:Engine) {
    e.decoder = null
    if (e.finished) { R> }
    end := e.tracks.>@len
    startSegment(&e, end, 0)
    left := e.latency.>@cast[usize]
    L> (left > 0) {
        n := left < OutFrames ? left : OutFrames
        L> (2 * n : k) { e.output[k] = 0 }
        emit(&e, n)
        left -= n
    }
    e.finished = true
    e.tail = audio.underruns(e.stream)
    note(e, "finished")
}

// Opens the first track from i on that can be played, else finishes.
openFrom := (&e:Engine, i:usize, frame:u64) {
    L> (t := i; t < e.tracks.>@len; t++) {
        if (load(&e, t, t == i ? frame : 0)) { R> }
    }
    finish(&e)
}

lufsText :<str>= (value:f64) { R> analysis.decimal(value, 2) }

// The current track decoded to its end: drain the resampler and go on with
// the next track without a gap.
endTrack := (&e:Engine) {
    L> (e.resampler != null) {
        n := resample.flush(&e.resampler, &e.output)
        if (n == 0) { B> }
        emit(&e, n)
    }
    note(e, `decoded {e.current} frames={e.decoded} lufs={lufsText(loudness.integrated(e.meter))} tp={lufsText(loudness.truePeak(e.meter))}`)
    e.decoder = null
    following := e.current + 1
    openFrom(&e, following, 0)
}

// One decoding step.
step := (&e:Engine) {
    if (e.finished) { R> }
    if (e.decoder == null) {
        from := e.current
        openFrom(&e, from, 0)
        R>
    }
    got := codec.read(&e.decoder, &e.native)
    if (got:Err) {
        text := `{e.tracks[e.current].name}：解码出错（{playlist.reason(got)}），跳到下一首`
        say(&e, text)
        endTrack(&e)
        R>
    }
    if (got == 0) { endTrack(&e); R> }
    e.position += got.>@cast[u64]
    e.decoded += got.>@cast[u64]
    channels := e.matrix.inputs
    mix.remix(&e.stereo, e.native[:got * channels], e.matrix)
    convert(&e, got)
}

// Keeps about `target` frames queued (never blocks).
E> fill := (&e:Engine, target:u64) {
    L> (!e.finished && audio.queued(e.stream) < target && audio.writable(e.stream) >= (OutFrames + 2 * e.latency.>@cast[usize]).>@cast[u64]) {
        step(&e)
    }
}

E> done :<bl>= (e:Engine) { R> e.finished && audio.queued(e.stream) == 0 }

E> begin := (&e:Engine, target:u64) {
    note(e, `rate out={e.rate} latency={e.latency} tracks={e.tracks.>@len}`)
    openFrom(&e, 0, 0)
    fill(&e, target)
}

// Discards what is queued: those frames will never sound. The device is
// stopped first (synchronously), so this thread is the ring's only reader.
drain := (&e:Engine) {
    if (!e.dry && !e.paused) { audio.stop(e.stream) }
    left := audio.queued(e.stream)
    if (left == 0) { R> }
    discard := @allocate[f32](2 * left.>@cast[usize])
    taken := audio.pump(e.stream, &discard)
    e.dropped += taken.>@cast[u64]
}

// Plays track i from native frame `frame` as soon as possible.
restart := (&e:Engine, i:usize, frame:u64, target:u64) {
    drain(&e)
    if (e.finished) { e.ignored += audio.underruns(e.stream) - e.tail }
    if (i < e.tracks.>@len && e.decoder != null && e.current == i) {
        sought := codec.seek(&e.decoder, frame)
        landed := sought:Ok ? sought.Ok : e.position
        e.position = landed
        if (e.resampler != null) { resample.reset(&e.resampler) }
        e.finished = false
        startSegment(&e, i, landed)
    } {
        e.decoder = null
        e.finished = false
        openFrom(&e, i, frame)
    }
    fill(&e, target)
    if (!e.dry && !e.paused) { audio.start(e.stream) }
}

// ---- controls ----

E> seekBy := (&e:Engine, seconds:i64, target:u64) {
    track := playing(e)
    if (track >= e.tracks.>@len) { R> }
    info := e.tracks[track].info
    now := nativePosition(e)
    size := seconds < 0 ? 0 - seconds : seconds
    delta := size.>@cast[u64] * info.rate.>@cast[u64]
    goal :[u64]= if (seconds >= 0) { now + delta } (now > delta) { now - delta } { 0 }
    length := info.frames
    if (length != null && goal >= length) {
        note(e, `seek {track} from={now} past-end`)
        restart(&e, track + 1, 0, target)
        R>
    }
    note(e, `seek {track} from={now} target={goal}`)
    restart(&e, track, goal, target)
}

// Jumps to `fraction` (0..1) of the playing track; nothing when its length
// is unknown. Logged like seekBy, so a mouse seek and a key seek read alike.
E> seekTo := (&e:Engine, fraction:f64, target:u64) {
    track := playing(e)
    if (track >= e.tracks.>@len) { R> }
    length := e.tracks[track].info.frames
    if (length == null || length == 0) { R> }
    part := fraction < 0 ? 0 : (fraction > 1 ? 1 : fraction)
    goal := (part * length.>@cast[f64]).>@cast[u64]
    now := nativePosition(e)
    if (goal >= length) {
        note(e, `seek {track} from={now} past-end`)
        restart(&e, track + 1, 0, target)
        R>
    }
    note(e, `seek {track} from={now} target={goal}`)
    restart(&e, track, goal, target)
}

// Plays track i from its start (and resumes when paused).
E> play := (&e:Engine, i:usize, target:u64) {
    if (i >= e.tracks.>@len) { R> }
    note(e, `play {i} from={playing(e)} at={nativePosition(e)}`)
    restart(&e, i, 0, target)
    if (e.paused) { togglePause(&e) }
}

E> next := (&e:Engine, target:u64) {
    track := playing(e)
    note(e, `next from={track} at={nativePosition(e)}`)
    restart(&e, track + 1, 0, target)
}

E> previous := (&e:Engine, target:u64) {
    track := playing(e)
    if (track >= e.tracks.>@len) { track = e.tracks.>@len - 1 }
    back := track > 0 && elapsed(e) < RestartSeconds ? track - 1 : track
    note(e, `previous from={track} at={nativePosition(e)} to={back}`)
    restart(&e, back, 0, target)
}

E> louder := (&e:Engine, up:bl) {
    if (up) {
        e.volume = e.volume + VolumeStep > 100 ? 100 : e.volume + VolumeStep
    } {
        e.volume = e.volume < VolumeStep ? 0 : e.volume - VolumeStep
    }
    note(e, `volume {e.volume}`)
}

// Sets the volume (0..100); logged only when it changes.
E> setVolume := (&e:Engine, volume:u32) {
    v := volume > 100 ? 100 : volume
    if (v == e.volume) { R> }
    e.volume = v
    note(e, `volume {e.volume}`)
}

E> togglePause := (&e:Engine) {
    e.paused = !e.paused
    if (!e.dry) {
        if (e.paused) { audio.stop(e.stream) } { audio.start(e.stream) }
    }
    note(e, e.paused ? "pause" : "resume")
}

E> toggleEq := (&e:Engine) {
    e.eqOn = !e.eqOn
    eq.setBypass(&e.equalizer, !e.eqOn)
    note(e, e.eqOn ? "eq on" : "eq off")
}

// Sets band `band` to `db` (clamped to +-EqRange); the filter glides there.
E> setEqGain := (&e:Engine, band:usize, db:i32) {
    if (band >= EqBands) { R> }
    g :[i32]= db
    if (g > EqRange) { g = EqRange }
    if (g < 0 - EqRange) { g = 0 - EqRange }
    if (g == e.eqGains[band]) { R> }
    e.eqGains[band] = g
    eq.setGain(&e.equalizer, band, g.>@cast[f64])
    e.eqPreamp = headroom(e.equalizer)
    note(e, `eq band {band} {g}`)
}

// Moves band `band` by `by` dB.
E> stepEq := (&e:Engine, band:usize, by:i32) {
    if (band >= EqBands) { R> }
    now := e.eqGains[band]
    setEqGain(&e, band, now + by)
}

E> resetEq := (&e:Engine) {
    L> (EqBands : b) { setEqGain(&e, b, 0) }
}

E> toggleLoudness := (&e:Engine) {
    e.loudOn = !e.loudOn
    limiter.setBypass(&e.limiter, !e.loudOn)
    note(e, e.loudOn ? "loudness on" : "loudness off")
}

// Loudness mode needs each track's integrated loudness before it plays.
// A second decoder reads ahead of playback (ScanFrames per step); until it
// reaches the end the gain follows the loudness measured so far.
gainFor :<f64>= (lufs:f64) {
    if (!(lufs > -70)) { R> 0 }
    g := Target - lufs
    R> if (g > MaxBoost) { MaxBoost } (g < MaxCut) { MaxCut } { g }
}

E> scanStep := (&e:Engine) {
    if (!e.loudOn || e.finished) { R> }
    t := e.current
    if (t >= e.tracks.>@len || e.scanned[t]) { R> }
    if (e.scanner == null || e.scanTrack != t) {
        opened := codec.openFile(e.tracks[t].path)
        if (opened:Err) { e.scanned[t] = true; R> }
        d := opened
        info := codec.info(d)
        channels := info.channels.>@cast[usize]
        e.scanMeter = loudness.make(info.rate.>@cast[f64], channels, false)
        e.scanBuffer = @allocate[f32](ScanFrames * channels)
        e.scanner = d
        e.scanTrack = t
    }
    if (e.scanner == null) { R> }
    got := codec.read(&e.scanner, &e.scanBuffer)
    if (got:Ok) {
        if (got > 0) {
            loudness.span(&e.scanMeter, e.scanBuffer, 0, got)
            e.gains[t] = gainFor(loudness.integrated(e.scanMeter))
            R>
        }
    }
    lufs := loudness.integrated(e.scanMeter)
    e.gains[t] = gainFor(lufs)
    e.scanned[t] = true
    e.scanner = null
    note(e, `scan {t} lufs={lufsText(lufs)} gain={lufsText(e.gains[t])}`)
}

// Momentary loudness of the output (LUFS) for the display.
E> momentary :<f64>= (e:Engine) { R> loudness.momentary(e.monitor) }
