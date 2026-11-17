// FXTUI-Player: a full-screen terminal music player on the FLYEX SDK's
// term, audio, codec and dsp modules and the audiokit effects in
// lib/audiokit (README.md at the project root).
//   fxtui-player [--dry] [--rate HZ] [--script KEYS] [--log] [--silent] FILE|DIRECTORY...
// The main loop is the only non-realtime thread: it reads keys, keeps the
// stream's ring about 0.2 s full (engine.fill; more after a dropout, up to
// 0.8 s), runs the analyzers and draws. The device's IO thread only reads
// the ring.
//   --dry       the reference backend instead of a device: silent, as fast
//               as decoding allows, on a virtual clock (tests)
//   --rate HZ   output rate for --dry (default 48000; a device uses its own)
//   --script S  timed key presses and mouse events, see script.fx (test hook)
//   --log       one line per event on stderr, with main-loop timing and
//               every underrun (test hook)
//   --silent    the ring only ever receives zeros: a device run is digital
//               silence from its first callback (test hook)
I>io
I>time
I>audio
I>audio.device
I>term
I>term.screen
I>term.render
I>(process.arguments, process)
I>("playlist.fx", playlist)
I>("engine.fx", engine)
I>("analysis.fx", analysis)
I>("view.fx", view)
I>("script.fx", script)
I>("controls.fx", controls)

Block :(usize)= 512               // frames per --dry pump (one virtual device callback)
FrameMs :(i64)= 33                // redraw interval
FillSeconds :(u32)= 5             // keep 1/5 s queued to begin with
MaxFill :(u64)= 4                 // after dropouts at most 4/5 s (doubling per dropout)

Options :(type)= { dry:bl, rate:u32, script:str, log:bl, silent:bl, paths:str[], help:bl, }
Parsed :(type)= enum(u8) { Ok:Options, Err:str, }

Usage :(str)= "用法：fxtui-player [--dry] [--rate HZ] [--script 按键脚本] [--log] [--silent] 文件或目录..."

number :<u32?>= (text:str) {
    value :[u32]= 0
    if (text.>@len == 0 || text.>@len > 7) { R> null }
    L> (text.>@len : i) {
        c := text[i]
        if (c < "0" || c > "9") { R> null }
        value = value * 10 + (c - "0").>@cast[u32]
    }
    R> value
}

options :<Parsed>= (argv:str[]) {
    o :[Options]= { dry:false, rate:48000, script:"", log:false, silent:false, paths:[], help:false, }
    i :[usize]= 0
    L> (i < argv.>@len) {
        arg := `{argv[i]}`
        if (arg == "--dry") {
            o.dry = true
        } (arg == "--log") {
            o.log = true
        } (arg == "--silent") {
            o.silent = true
        } (arg == "--help" || arg == "-h") {
            o.help = true
        } (arg == "--rate" || arg == "--script") {
            if (i + 1 >= argv.>@len) { R> Parsed.Err(`{arg} 后面缺少参数`) }
            i += 1
            if (arg == "--script") {
                o.script = `{argv[i]}`
            } {
                rate := number(argv[i])
                if (rate == null || rate < 8000 || rate > 384000) { R> Parsed.Err(`--rate {argv[i]} 不是 8000 到 384000 之间的采样率`) }
                o.rate = rate
            }
        } {
            o.paths += [`{arg}`]
        }
        i += 1
    }
    R> Parsed.Ok(o)
}

// Milliseconds since `start` on the monotonic clock.
since :<i64>= (start:time.Instant) {
    now := time.monotonic()
    R> (now.seconds - start.seconds) * 1000 + (now.nanoseconds - start.nanoseconds) / 1000000
}

// Microseconds since `start` on the monotonic clock (--log timing).
micros :<i64>= (start:time.Instant) {
    now := time.monotonic()
    R> (now.seconds - start.seconds) * 1000000 + (now.nanoseconds - start.nanoseconds) / 1000
}

// CPU time of this thread in microseconds (macOS CLOCK_THREAD_CPUTIME_ID).
// The --log step timing reports it beside wall time: wall time alone mostly
// measures how loaded the machine is, CPU time is the player's own work.
extern("C") clock_gettime_nsec_np :<u64>= (clock:i32)
cpuMicros :<i64>= () { R> unsafe(clock_gettime_nsec_np(16) / 1000).>@cast[i64] }

// Main-loop timing for --log: the longest gap between two iterations (wall,
// includes the key wait and any time the thread was not scheduled) and the
// longest iteration body (wall and thread CPU).
Timing :(type)= { iterations:u64, gap:i64, work:i64, cpu:i64, slow:u64, over100:u64, over200:u64, }
SlowMicros :(i64)= 50000          // --log reports iteration bodies longer than this (wall or CPU)

// macOS: the main loop has a deadline the listener hears (the ring lasts
// about 0.2 s), so on a device it asks for the user-interactive QoS class,
// the one a GUI app's main thread runs at. At the default class, on a
// machine with dozens of other runnable threads, it can wait for a core
// longer than the ring lasts.
extern("C") pthread_set_qos_class_self_np :<i32>= (qos:u32, relative:i32)
InteractiveQoS :(u32)= 0x21

// The device's own rate, so AUHAL has nothing to convert (the engine
// resamples each track itself); 48000 when it cannot be read.
deviceRate :<u32>= () {
    found := device.defaultDevice(audio.Direction.Output)
    if (found:Ok) {
        if (found.rate >= 8000 && found.rate <= 384000) { R> found.rate }
    }
    R> 48000
}

// Dropouts: a dropout is one stretch of silence the listener hears, one or
// more consecutive callbacks that ran dry (audio.underruns counts callbacks).
Dropouts :(type)= { events:u32, callbacks:u32, }

// --dry --log: FNV-1a over the bits of every sample the virtual device
// takes, so runs can be compared bit for bit (README "测试钩子").
digest := (&h:u64, block:f32[]) {
    L> (block : x) { h = (h ^ x.>@bitcast[u32].>@cast[u64]) * 1099511628211 }
}

summary := (e:engine.Engine, clock:i64, timing:Timing, dropouts:Dropouts, pcm:u64) {
    frames := engine.heardFrames(e)
    L> (frames.>@len : i) { engine.note(e, `heard {i} frames={frames[i]}`) }
    engine.note(e, `loop iterations={timing.iterations} max-gap={timing.gap} gaps-over-100ms={timing.over100} gaps-over-200ms={timing.over200} max-work={timing.work} max-cpu={timing.cpu} slow={timing.slow}`)
    engine.note(e, `total heard={engine.heard(e)} written={e.written} dropped={e.dropped} underruns={engine.underruns(e)} dropouts={dropouts.events} stream-underruns={audio.underruns(e.stream)} latency={e.latency} clock={clock} pcm={pcm}`)
}

run :<i32>= () {
    parsed := options(process.args())
    if (parsed:Err) { io.println(`FXTUI-Player：{parsed.Err}`); io.println(Usage); R> 2 }
    o := parsed
    if (o.help || o.paths.>@len == 0) { io.println(Usage); R> o.help ? 0 : 2 }
    steps :[script.Step[]]= []
    if (o.script.>@len > 0) {
        read := script.parse(o.script)
        if (read:Err) { io.println(`FXTUI-Player：{read.Err}`); R> 2 }
        steps = read
    }

    built := playlist.build(o.paths)
    L> (built.skipped : line) {
        io.println(`FXTUI-Player：{line}`)
        if (o.log) { io.writeAll(`skip {line}\n`, 2) }
    }
    if (built.tracks.>@len == 0) { io.println("FXTUI-Player：没有可以播放的文件"); R> 1 }

    rate := o.dry ? o.rate : deviceRate()
    queue := rate > 65536 ? rate : 65536       // room for the largest fill target (MaxFill) plus a step
    config :[audio.Config]= { format:{ rate, channels:2, }, frames:Block.>@cast[u32], queue, }
    made := o.dry ? audio.reference(config) : device.open(config)
    if (made:Err) {
        failure := made
        io.println(if (failure:NoDevice) { "FXTUI-Player：没有输出设备" } (failure:Format) { "FXTUI-Player：设备不接受这个格式" } { "FXTUI-Player：无法打开输出" })
        R> 1
    }
    e := engine.make(made, built.tracks, o.dry, o.log)
    e.silent = o.silent
    if (built.skipped.>@len > 0) { e.message = `已跳过 {built.skipped.>@len} 个文件（见退出后的输出）` }
    target :[u64]= (rate / FillSeconds).>@cast[u64]
    most := rate.>@cast[u64] * MaxFill / FillSeconds.>@cast[u64]
    if (!o.dry) {
        qos := unsafe(pthread_set_qos_class_self_np(InteractiveQoS, 0))
        engine.note(e, `qos interactive={qos == 0}`)
    }
    // The terminal UI needs a terminal on stdin and stdout; without one the
    // player runs headless (useful with --script) and nothing measures the
    // momentary loudness the screen would show.
    ui := term.isTerminal(0) && term.isTerminal(1)
    e.display = ui
    engine.begin(&e, target)
    if (!o.dry) {
        if (audio.start(e.stream):Err) { io.println("FXTUI-Player：无法启动输出"); R> 1 }
    }

    // mouse: presses, releases, drags and the wheel (1002 + 1006), no hover
    opened := ui ? term.open({ mouse:true, }) : term.Opened.Err(term.NotTerminal)
    if (ui && opened:Err) { io.println(`FXTUI-Player：无法打开终端（错误 {opened}）`); R> 1 }
    s :[term.Session?]= opened:Ok ? opened.Ok : null
    size := s != null ? s.size : { cols:80, rows:24, }
    r := render.renderer(size.cols, size.rows)
    if (s != null) { r = term.renderer(s) }
    back := screen.make(size.cols, size.rows)
    spectrum := analysis.spectrum()
    meters := analysis.meters()
    pump := @allocate[f32](2 * Block)
    u := controls.ui()
    logged :[controls.Hits]= @zero()       // --log: the hit table last written to the log
    pcm :[u64]= 14695981039346656037       // --dry --log: digest of the rendered samples
    hashing := o.dry && o.log

    start := time.monotonic()
    ticks :[i64]= 0              // --dry: virtual callbacks so far
    nextStep :[usize]= 0
    lastDraw :[i64]= 0 - FrameMs
    timing :[Timing]= { iterations:0, gap:0, work:0, cpu:0, slow:0, over100:0, over200:0, }
    lastTop :[i64]= 0
    seen := engine.underruns(e)
    dropouts :[Dropouts]= { events:0, callbacks:0, }
    loud :[u64]= 0               // --dry --silent: rendered samples that were not zero
    running := true
    L> (running) {
        clock := o.dry ? ticks * Block.>@cast[i64] * 1000 / rate.>@cast[i64] : since(start)
        // --log timing only: without it the loop reads no clocks of its own
        top := o.log ? micros(start) : 0
        gap := timing.iterations > 0 ? top - lastTop : 0
        if (gap > timing.gap) { timing.gap = gap }
        if (gap > 100000) { timing.over100 += 1 }
        if (gap > 200000) { timing.over200 += 1 }
        lastTop = top
        timing.iterations += 1
        low := audio.queued(e.stream)
        L> (running && nextStep < steps.>@len && steps[nextStep].at <= clock) {
            step := steps[nextStep]
            if (step.stall > 0) {
                engine.note(e, `stall {step.stall} ms`)
                if (o.dry) {
                    // the virtual device keeps rendering while the loop is away
                    blocks := step.stall * rate.>@cast[i64] / 1000 / Block.>@cast[i64]
                    L> (blocks.>@cast[usize] : k) {
                        if (!e.paused) {
                            audio.pump(e.stream, &pump)
                            if (hashing) { digest(&pcm, pump) }
                        }
                        ticks += 1
                    }
                } {
                    time.sleep(step.stall.>@cast[u32])
                }
            } (step.pointer != 0) {
                controls.pointer(&e, &u, { action:step.pointer, button:step.button, x:step.x, y:step.y, mods:0, }, clock, target)
            } {
                running = controls.key(&e, &u, step.code, step.mods, target)
            }
            nextStep += 1
        }
        if (s != null && running) {
            wait := o.dry ? 0 : FrameMs - (clock - lastDraw)
            if (wait > 20) { wait = 20 }
            if (wait < 0) { wait = 0 }
            ev := term.poll(&s, wait.>@cast[i32])
            if (ev != null) {
                if (ev:Key) { running = controls.key(&e, &u, ev.code, ev.mods, target) }
                if (ev:Mouse) { controls.pointer(&e, &u, ev, clock, target) }
                if (ev:Resize) {
                    // The regions on record belong to the old layout: drop them (and
                    // any drag) and draw the new size at once.
                    screen.resize(&back, ev.cols, ev.rows)
                    render.resize(&r, ev.cols, ev.rows)
                    controls.clear(&u.hits)
                    controls.cancel(&u)
                    lastDraw = clock - FrameMs
                    engine.note(e, `resize {ev.cols}x{ev.rows}`)
                }
                if (ev:Resume) { render.invalidate(&r) }
                if (ev:Closed) { running = false }
            }
        }
        if (!running) { B> }
        bodyWall := o.log ? micros(start) : 0
        bodyCpu := o.log ? cpuMicros() : 0
        engine.fill(&e, target)
        engine.scanStep(&e)
        filled := o.log ? micros(start) : 0
        if (o.dry) {
            left := audio.queued(e.stream)
            if (e.paused) {
                // a paused device takes nothing
            } (e.finished && left < Block.>@cast[u64]) {
                last := @allocate[f32](2 * left.>@cast[usize])      // the end: no underrun for the short tail
                audio.pump(e.stream, &last)
                if (hashing) { digest(&pcm, last) }
            } {
                audio.pump(e.stream, &pump)
                if (hashing) { digest(&pcm, pump) }
                if (o.silent) { L> (pump : x) { if (x != 0) { loud += 1 } } }
            }
            ticks += 1
        }
        if (engine.done(e)) { B> }
        if (audio.lost(e.stream)) { e.message = "输出设备已断开"; engine.note(e, "lost"); B> }
        drawn := o.log ? micros(start) : 0
        painted :[i64]= drawn
        if (clock - lastDraw >= FrameMs) {
            dt := (clock - lastDraw).>@cast[f32] / 1000
            lastDraw = clock
            if (s != null) {
                bands, slot := view.bandsFor(view.spectrumWidth(back.width, e))
                analysis.update(&spectrum, e.history, engine.heard(e), e.rate, bands, dt > 0.2 ? 0.2 : dt)
                analysis.measure(&meters, e.history, engine.heard(e), dt > 0.2 ? 0.2 : dt)
                view.draw(&back, e, spectrum, meters, &u)
                painted = o.log ? micros(start) : 0
                if (o.log && !controls.same(u.hits, logged)) {
                    logged = u.hits
                    engine.note(e, controls.describe(u.hits))
                }
                term.present(&s, &r, back)
            }
        }
        presented := o.log ? micros(start) : 0
        // A dropout: the ring ran dry since the last look. Keep more queued
        // from now on (double, up to MaxFill/5 s): a stall that long is
        // likely to come again on this machine.
        now := engine.underruns(e)
        if (now > seen) {
            dropouts.events += 1
            dropouts.callbacks += now - seen
            engine.note(e, `underrun +{now - seen} track={engine.playing(e)} clock={clock} queued={low} gap={gap}`)
            seen = now
            if (target < most) {
                target = target * 2 < most ? target * 2 : most
                engine.note(e, `buffer target={target}`)
            }
        }
        if (o.log) {
            wall := micros(start) - bodyWall
            cpu := cpuMicros() - bodyCpu
            if (wall > timing.work) { timing.work = wall }
            if (cpu > timing.cpu) { timing.cpu = cpu }
            if (wall > SlowMicros || cpu > SlowMicros) {
                timing.slow += 1
                engine.note(e, `slow track={engine.playing(e)} wall={wall} cpu={cpu} fill={filled - bodyWall} draw={painted - drawn} present={presented - painted} clock={clock}`)
            }
        }
        if (s == null && !o.dry) { time.sleep(10) }
        if (o.dry && e.paused) { time.sleep(1) }      // the virtual clock still runs; spare the CPU
    }
    if (s != null) { term.close(&s) }
    // On a device, let the last queued frames reach the speaker before stopping.
    if (!o.dry && engine.done(e)) {
        tail :[u32]= audio.latency(e.stream) * 1000 / rate + 20
        time.sleep(tail)
    }
    audio.stop(e.stream)
    final := engine.underruns(e)
    if (final > seen) { dropouts.events += 1; dropouts.callbacks += final - seen }
    clock := o.dry ? ticks * Block.>@cast[i64] * 1000 / rate.>@cast[i64] : since(start)
    summary(e, clock, timing, dropouts, pcm)
    if (o.silent && o.dry) { engine.note(e, `silent nonzero={loud}`) }
    L> (built.skipped : line) { io.println(`FXTUI-Player：{line}`) }
    track := engine.playing(e)
    where := track < e.tracks.>@len ? `停在第 {track + 1}/{e.tracks.>@len} 首` : `播放完 {e.tracks.>@len} 首`
    missed := dropouts.callbacks.>@cast[u64] * audio.bufferFrames(e.stream).>@cast[u64] * 10 / rate.>@cast[u64]
    io.println(dropouts.events == 0 ? `FXTUI-Player：{where}，没有欠载` : `FXTUI-Player：{where}，欠载 {dropouts.events} 次（约 {missed / 10}.{missed % 10} 秒无声）`)
    if (audio.close(e.stream):Err) { R> 1 }
    R> 0
}

main :<i32>= () { R> run() }
