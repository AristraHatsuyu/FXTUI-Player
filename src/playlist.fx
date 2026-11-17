// playlist: turns the command-line paths into the list of tracks to play.
// A file is taken as given; a directory contributes its audio files (by
// extension, not recursive), sorted by name. Every candidate is opened once
// with codec.openFile so unsupported or corrupt files are dropped up front
// with a message instead of failing during playback.
I>fs
I>codec

E> Track :(type)= {
    path:str,
    name:str,          // file name without the directory
    title:str,         // TITLE tag, "" when absent
    artist:str,        // ARTIST tag, "" when absent
    info:codec.Info,
}

E> Built :(type)= { tracks:Track[], skipped:str[], }

DirectoryKind :(u32)= 16384
RegularEntry :(u8)= 8

lower :<str>= (text:u8[]) {
    out :[u8[]]= []
    L> (text.>@len : i) {
        c :[u8]= text[i]
        if (c >= "A" && c <= "Z") { c += 32 }
        out += [c]
    }
    R> out.>@cast[str]
}

// The part after the last dot, lower case; "" when there is none.
extension :<str>= (name:str) {
    at :[usize]= name.>@len
    L> (at > 0) {
        if (name[at - 1] == ".") { B> }
        if (name[at - 1] == "/") { R> "" }
        at -= 1
    }
    if (at == 0) { R> "" }
    R> lower(name[at:])
}

// Extensions a directory scan picks up (every container the codec module reads).
E> isAudioName :<bl>= (name:str) {
    x := extension(name)
    pcm := x == "wav" || x == "wave" || x == "aif" || x == "aiff" || x == "aifc" || x == "caf"
    mpeg := x == "mp3" || x == "mp2" || x == "mp1" || x == "aac" || x == "adts" || x == "m4a" || x == "mp4"
    R> pcm || mpeg || x == "flac" || x == "ogg" || x == "oga" || x == "opus"
}

baseName :<str>= (path:str) {
    at :[usize]= path.>@len
    L> (at > 0 && path[at - 1] != "/") { at -= 1 }
    name :[u8[]]= []
    name += path[at:]
    R> name.>@cast[str]
}

sortNames := (&names:str[]) {
    L> (i := 1; i < names.>@len; i++) {
        j := i
        L> (j > 0 && names[j] < names[j - 1]) {
            &names.>@swap(j, j - 1)
            j -= 1
        }
    }
}

// Audio files directly inside a directory, sorted.
scan :<str[]>= (directory:str, &skipped:str[]) {
    found :[str[]]= []
    opened := fs.openDirectory(directory)
    if (opened:Err) {
        skipped += [`{directory}：无法读取目录（错误 {opened}）`]
        R> found
    }
    dir := opened
    L> {
        next := fs.readDirectory(&dir)
        if (next:End) { B> }
        if (next:Err) { skipped += [`{directory}：读取目录出错（错误 {next}）`]; B> }
        entry := next
        name := entry.name.>@cast[str]
        if (entry.kind == RegularEntry && name[0] != "." && isAudioName(name)) { found += [name] }
    }
    sortNames(&found)
    paths :[str[]]= []
    slash := directory.>@len > 0 && directory[directory.>@len - 1] == "/" ? "" : "/"
    L> (found : name) { paths += [`{directory}{slash}{name}`] }
    R> paths
}

// Opens one file to read its facts; the decoder is dropped again.
probe := (path:str, &tracks:Track[], &skipped:str[]) {
    opened := codec.openFile(path)
    if (opened:Err) {
        error := opened
        if (error:NoAudio) { skipped += [`{baseName(path)}：没有音轨，已跳过`] } (error:Encoding) {
            skipped += [`{baseName(path)}：不支持的编码 {codec.fourcc(error.Encoding)}，已跳过`]
        } { skipped += [`{baseName(path)}：不支持或已损坏（{reason(error)}），已跳过`] }
        R>
    }
    d := opened
    info := codec.info(d)
    if (info.channels == 0 || info.channels > 8 || info.rate < 1000 || info.rate > 384000) {
        skipped += [`{baseName(path)}：{info.channels} 声道 {info.rate} Hz 超出播放器范围，已跳过`]
        R>
    }
    tracks += [{ path:`{path}`, name:baseName(path), title:codec.tag(d, "TITLE"), artist:codec.tag(d, "ARTIST"), info, }]
}

E> reason :<str>= (error:codec.Error) {
    R> if (error:Unsupported) { "格式不支持" } (error:Malformed) { "数据损坏" } (error:Truncated) { "文件不完整" } (error:Limit) { "超出限制" } (error:Checksum) { "校验失败" } (error:Memory) { "内存不足" } (error:Io) { `读取错误 {error.Io}` } (error:NoAudio) { "没有音轨" } (error:Encoding) { `不支持的编码 {codec.fourcc(error.Encoding)}` } { "参数超出范围" }
}

// Builds the playlist from the arguments in order.
E> build :<Built>= (paths:str[]) {
    tracks :[Track[]]= []
    skipped :[str[]]= []
    L> (paths : path) {
        st := fs.stat(path)
        if (st:Err) {
            skipped += [`{path}：找不到文件（错误 {st}）`]
            N>
        }
        if (st.kind == DirectoryKind) {
            files := scan(path, &skipped)
            if (files.>@len == 0) { skipped += [`{path}：目录里没有可识别的音频文件`] }
            L> (files : file) { probe(file, &tracks, &skipped) }
        } {
            probe(path, &tracks, &skipped)
        }
    }
    R> { tracks, skipped, }
}
