import AppKit
import Combine
import CoreGraphics

/// A snapshot of what a player is doing.
struct NowPlaying: Equatable {
    enum Player: String, CaseIterable {
        case music = "com.apple.Music"
        case spotify = "com.spotify.client"
        case vlc = "org.videolan.vlc"
        case chrome = "com.google.Chrome"
        case brave = "com.brave.Browser"
        case edge = "com.microsoft.edgemac"

        var name: String {
            switch self {
            case .music: return "Music"
            case .spotify: return "Spotify"
            case .vlc: return "VLC"
            case .chrome: return "Google Chrome"
            case .brave: return "Brave Browser"
            case .edge: return "Microsoft Edge"
            }
        }

        /// A short label for the UI.
        var label: String {
            switch self {
            case .chrome: return "Chrome"
            case .brave: return "Brave"
            case .edge: return "Edge"
            default: return name
            }
        }

        /// Chromium browsers share one scripting dictionary and read media through page JavaScript.
        var isBrowser: Bool { self == .chrome || self == .brave || self == .edge }
    }

    var player: Player
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    var elapsed: TimeInterval
    var duration: TimeInterval
    var trackID: String
    var artworkHint: String      // Spotify/browser: artwork URL; VLC: file path
    var artwork: NSImage?
    var sampledAt: Date
    var sourceTabID: String = "" // browser: the tab to send commands to

    /// Elapsed time extrapolated from the last sample, so the progress bar moves between polls.
    var liveElapsed: TimeInterval {
        guard isPlaying else { return elapsed }
        let value = elapsed + Date().timeIntervalSince(sampledAt)
        return duration > 0 ? min(value, duration) : value
    }

    var subtitle: String {
        [artist, album].filter { !$0.isEmpty }.joined(separator: " — ")
    }

    static func == (a: NowPlaying, b: NowPlaying) -> Bool {
        a.player == b.player && a.trackID == b.trackID && a.title == b.title &&
        a.artist == b.artist && a.album == b.album && a.isPlaying == b.isPlaying &&
        Int(a.elapsed) == Int(b.elapsed) && Int(a.duration) == Int(b.duration) &&
        a.artwork === b.artwork
    }
}

/// Reads and controls what's playing, and the system output volume.
///
/// Scriptable desktop players (Music, Spotify, VLC) are read directly over AppleScript.
/// Chromium browsers (Chrome, Brave, Edge) are read by executing a little JavaScript in their
/// tabs — which the user must allow once (View ▸ Developer ▸ Allow JavaScript from Apple Events);
/// until then the island shows a hint. Apple's system-wide MediaRemote feed is not available to
/// third-party processes on current macOS, so this covers the players we can actually reach.
final class MediaController: ObservableObject {
    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var problem: String?
    /// System output volume, 0...1. Global: it moves whatever is making sound, browser included.
    @Published var systemVolume: Double = 0.5

    private let queue = DispatchQueue(label: "NotchIsland.media", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var tick = 0
    private var scripts: [String: NSAppleScript] = [:]
    private var artworkCache: [String: NSImage?] = [:]
    private var pendingArtwork: [String: Data] = [:]
    private var preferred: NowPlaying.Player?
    private var denied: Set<NowPlaying.Player> = []        // Automation permission declined
    private var browserJS: [NowPlaying.Player: Bool] = [:] // nil unknown, false off, true on
    private var reportedErrors: Set<Int> = []
    private var pendingVolume: Int?
    private var volumeHeldUntil = Date.distantPast
    private var volumeInitialized = false
    /// Fired (main thread) when the system volume changes from outside the island, e.g. the volume keys.
    var onVolumeChanged: ((Double) -> Void)?

    func start() {
        queue.async { [self] in
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: 1.0)
            t.setEventHandler { [weak self] in self?.poll() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            DispatchQueue.main.async { self.nowPlaying = nil }
        }
    }

    deinit { timer?.cancel() }

    // MARK: - Transport (call on the main thread)

    func togglePlayPause() {
        guard var np = nowPlaying else { return }
        np.elapsed = np.liveElapsed
        np.sampledAt = Date()
        np.isPlaying.toggle()
        nowPlaying = np                                    // optimistic; the next poll confirms
        if np.player.isBrowser {
            runBrowserCommand(np, js: Self.toggleJS)
        } else {
            send(np.player == .vlc ? "play" : "playpause", to: np.player)
        }
    }

    func next() {
        guard let np = nowPlaying else { return }
        if np.player.isBrowser { SystemMediaKey.post(SystemMediaKey.next) }
        else { send(np.player == .vlc ? "next" : "next track", to: np.player) }
    }

    func previous() {
        guard let np = nowPlaying else { return }
        if np.player.isBrowser { SystemMediaKey.post(SystemMediaKey.previous) }
        else { send(np.player == .vlc ? "previous" : "previous track", to: np.player) }
    }

    func seek(to seconds: TimeInterval) {
        guard var np = nowPlaying else { return }
        np.elapsed = seconds
        np.sampledAt = Date()
        nowPlaying = np
        let value = Int(seconds)
        if np.player.isBrowser {
            runBrowserCommand(np, js: "(function(){var e=[].slice.call(document.querySelectorAll('video,audio'));var m=e.filter(function(x){return !x.paused;})[0]||e.filter(function(x){return x.readyState>2;})[0];if(m){m.currentTime=\(value);}})()")
        } else {
            send(np.player == .vlc ? "set current time to \(value)" : "set player position to \(value)",
                 to: np.player, cache: false)
        }
    }

    func openPlayer() {
        guard let player = nowPlaying?.player, let url = AppIconCache.url(for: player.rawValue) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    private func send(_ verb: String, to player: NowPlaying.Player, cache: Bool = true) {
        queue.async { [self] in
            run("tell application \"\(player.name)\" to \(verb)",
                cacheKey: cache ? "cmd:\(player.rawValue):\(verb)" : nil, player: player)
            queue.asyncAfter(deadline: .now() + 0.3) { self.poll() }
        }
    }

    private func runBrowserCommand(_ np: NowPlaying, js: String) {
        guard !np.sourceTabID.isEmpty else { return }
        let name = np.player.name, tab = np.sourceTabID, player = np.player
        queue.async { [self] in
            let src = """
            tell application "\(name)"
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            if (id of t) is \(tab) then
                                execute t javascript "\(js)"
                                return
                            end if
                        end try
                    end repeat
                end repeat
            end tell
            """
            run(src, cacheKey: nil, player: player)
            queue.asyncAfter(deadline: .now() + 0.3) { self.poll() }
        }
    }

    // MARK: - Polling

    private func poll() {
        tick &+= 1
        var candidates: [NowPlaying] = []

        for player in NowPlaying.Player.allCases where !denied.contains(player) && isRunning(player) {
            if player.isBrowser {
                if let np = pollBrowser(player) { candidates.append(np) }
            } else if let np = query(player) {
                candidates.append(np)
            }
        }

        var pick = candidates.first { $0.isPlaying }
            ?? candidates.first { $0.player == preferred }
            ?? candidates.first
        if let chosen = pick {
            preferred = chosen.player
            pick?.artwork = artwork(for: chosen)
        }
        DispatchQueue.main.async {
            if self.nowPlaying != pick { self.nowPlaying = pick }
        }
        updateProblem()
        pollVolume()
    }

    private func isRunning(_ player: NowPlaying.Player) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: player.rawValue).isEmpty
    }

    // MARK: - App players

    private func query(_ player: NowPlaying.Player) -> NowPlaying? {
        guard let output = run(Self.statusScript(for: player),
                               cacheKey: "status:\(player.rawValue)", player: player)?.stringValue
        else { return nil }
        let lines = output.components(separatedBy: "\n")
        guard lines.count >= 8, lines[0] != "stopped" else { return nil }
        var duration = Self.number(lines[5])
        if player == .spotify { duration /= 1000 }
        return NowPlaying(player: player, title: lines[1], artist: lines[2], album: lines[3],
                          isPlaying: lines[0] == "playing",
                          elapsed: Self.number(lines[4]), duration: duration,
                          trackID: lines[6].isEmpty ? lines[1] : lines[6],
                          artworkHint: lines[7], artwork: nil, sampledAt: Date())
    }

    // MARK: - Browser players

    private func pollBrowser(_ player: NowPlaying.Player) -> NowPlaying? {
        // Until we know JavaScript-from-Apple-Events is on, probe (without a try that would hide
        // the "turned off" error) every few ticks so the hint can appear or clear.
        if browserJS[player] != true, tick % 4 == 0 {
            if run("tell application \"\(player.name)\" to execute (active tab of front window) javascript \"1\"",
                   cacheKey: "probe:\(player.rawValue)", player: player) != nil {
                browserJS[player] = true
            }
        }
        guard browserJS[player] == true else { return nil }

        guard let output = run(Self.browserStatusScript(for: player),
                               cacheKey: "status:\(player.rawValue)", player: player)?.stringValue,
              !output.isEmpty else { return nil }
        browserJS[player] = true   // it answered

        let parts = output.components(separatedBy: "\n")
        guard let json = parts.first, let data = json.data(using: .utf8),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let tab = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        let title = (d["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = (d["artist"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let album = (d["album"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let playing = (d["playing"] as? Bool) ?? false
        let pos = (d["pos"] as? NSNumber)?.doubleValue ?? 0
        let dur = (d["dur"] as? NSNumber)?.doubleValue ?? 0
        let art = (d["art"] as? String) ?? ""
        return NowPlaying(player: player, title: title, artist: artist, album: album,
                          isPlaying: playing, elapsed: pos, duration: dur,
                          trackID: "\(tab)|\(title)", artworkHint: art, artwork: nil,
                          sampledAt: Date(), sourceTabID: tab)
    }

    // MARK: - Artwork

    private func artwork(for np: NowPlaying) -> NSImage? {
        // A track whose duration is still unknown has not finished loading (streaming), and Music
        // may still report the previous cover for it; keying on that re-fetches once it loads.
        let key = "\(np.player.rawValue)|\(np.trackID)|\(np.duration > 0)"
        if let cached = artworkCache[key] { return cached }
        var image: NSImage?
        var confirmed = true
        if np.player == .music {
            // Music fills in a new track's artwork asynchronously; only cache once two fetches agree.
            let data = run("tell application \"Music\" to get data of artwork 1 of current track",
                           cacheKey: "art:music", player: .music)?.data ?? Data()
            image = data.isEmpty ? nil : NSImage(data: data)
            confirmed = pendingArtwork[key] == data
            if pendingArtwork.count > 8 { pendingArtwork.removeAll() }
            pendingArtwork[key] = data
        } else if np.artworkHint.hasPrefix("http"), let url = URL(string: np.artworkHint),
                  let data = download(url) {
            image = NSImage(data: data)
        } else if !np.artworkHint.isEmpty, FileManager.default.fileExists(atPath: np.artworkHint) {
            image = NSWorkspace.shared.icon(forFile: np.artworkHint)
        }
        guard confirmed else { return image }
        pendingArtwork[key] = nil
        if artworkCache.count > 40 { artworkCache.removeAll() }
        artworkCache[key] = .some(image)
        return image
    }

    private func download(_ url: URL) -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            result = data
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        return result
    }

    // MARK: - System volume (global)

    private func pollVolume() {
        guard Date() >= volumeHeldUntil, pendingVolume == nil else { return }
        guard let desc = run("output volume of (get volume settings)",
                             cacheKey: "volume:get", player: .music) else { return }
        let muted = run("output muted of (get volume settings)", cacheKey: "volume:muted", player: .music)?.booleanValue ?? false
        let value = muted ? 0.0 : Double(desc.int32Value) / 100.0
        DispatchQueue.main.async {
            let changed = abs(self.systemVolume - value) > 0.001
            if changed { self.systemVolume = value }
            if changed, self.volumeInitialized { self.onVolumeChanged?(value) }
            self.volumeInitialized = true
        }
    }

    /// Call on the main thread while dragging the volume slider.
    func setSystemVolume(_ fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        systemVolume = clamped                               // optimistic
        volumeHeldUntil = Date().addingTimeInterval(0.6)
        let value = Int((clamped * 100).rounded())
        queue.async { [self] in
            let wasIdle = pendingVolume == nil
            pendingVolume = value
            guard wasIdle else { return }                    // a flush is already scheduled
            queue.asyncAfter(deadline: .now() + 0.06) { self.flushVolume() }
        }
    }

    private func flushVolume() {
        guard let value = pendingVolume else { return }
        pendingVolume = nil
        run("set volume output volume \(value)", cacheKey: nil, player: .music)
    }

    // MARK: - AppleScript plumbing

    @discardableResult
    private func run(_ source: String, cacheKey: String?, player: NowPlaying.Player) -> NSAppleEventDescriptor? {
        let script: NSAppleScript
        if let cacheKey, let cached = scripts[cacheKey] {
            script = cached
        } else {
            guard let fresh = NSAppleScript(source: source) else { return nil }
            script = fresh
            if let cacheKey { scripts[cacheKey] = script }
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            handle(code: errorInfo[NSAppleScript.errorNumber] as? Int ?? 0,
                   message: errorInfo[NSAppleScript.errorMessage] as? String ?? "",
                   player: player)
            return nil
        }
        return result
    }

    private func handle(code: Int, message: String, player: NowPlaying.Player) {
        let lower = message.lowercased()
        if player.isBrowser, lower.contains("javascript"),
           lower.contains("turned off") || lower.contains("apple events") {
            browserJS[player] = false   // the user hasn't allowed JS from Apple Events yet
            return
        }
        switch code {
        case -1743:   // errAEEventNotPermitted: the user declined the Automation prompt
            denied.insert(player)
            let text = "Allow NotchIsland to control \(player.label) in System Settings → Privacy & Security → Automation."
            DispatchQueue.main.async { self.problem = text }
        case -600, -609, -1712, -1719, -1728, -10000:
            // Not running / connection invalid / timed out / no window / no current item / internal:
            // transient, nothing to tell the user.
            break
        default:
            if reportedErrors.insert(code).inserted {
                NSLog("NotchIsland: AppleScript error %d talking to %@: %@", code, player.name, message)
            }
        }
    }

    /// Builds the hint shown in the island: Automation first, then the browser JS toggle.
    private func updateProblem() {
        var text: String?
        if !denied.isEmpty {
            let names = denied.map(\.label).sorted().joined(separator: ", ")
            text = "Allow NotchIsland to control \(names) in System Settings → Privacy & Security → Automation."
        } else {
            let off = NowPlaying.Player.allCases.filter {
                $0.isBrowser && isRunning($0) && browserJS[$0] == false
            }
            if !off.isEmpty {
                let names = off.map(\.label).joined(separator: " / ")
                text = "Playing in \(names)? Turn on ‘Allow JavaScript from Apple Events’ (\(off[0].label) ▸ View ▸ Developer)."
            }
        }
        DispatchQueue.main.async {
            if self.problem != text { self.problem = text }
        }
    }

    private static func number(_ text: String) -> Double {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    // MARK: - Scripts

    /// JS (no double quotes, so it nests inside the AppleScript string) that toggles the page's media.
    static let toggleJS = "(function(){var e=[].slice.call(document.querySelectorAll('video,audio'));var m=e.filter(function(x){return !x.paused;})[0]||e.filter(function(x){return x.readyState>2;})[0];if(m){if(m.paused){m.play();}else{m.pause();}}})()"

    /// JS that reports the first playing (or loaded) media element as compact JSON, or ''.
    static let statusJS = "(function(){var e=[].slice.call(document.querySelectorAll('video,audio'));var m=e.filter(function(x){return !x.paused&&x.currentTime>0;})[0]||e.filter(function(x){return x.readyState>2;})[0];if(!m)return '';var s=(navigator.mediaSession&&navigator.mediaSession.metadata)||{};var a='';try{if(s.artwork&&s.artwork.length){a=s.artwork[s.artwork.length-1].src;}}catch(err){}var d=isFinite(m.duration)?Math.floor(m.duration):0;return JSON.stringify({playing:!m.paused,pos:Math.floor(m.currentTime||0),dur:d,title:(s.title||document.title||''),artist:(s.artist||''),album:(s.album||''),art:a});})()"

    /// Walks a Chromium browser's tabs, returns the first media tab's JSON plus its tab id.
    static func browserStatusScript(for player: NowPlaying.Player) -> String {
        """
        tell application "\(player.name)"
            set theResult to ""
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set r to execute t javascript "\(statusJS)"
                        if r is not missing value and r is not "" then
                            set theResult to r & linefeed & (id of t)
                            exit repeat
                        end if
                    end try
                end repeat
                if theResult is not "" then exit repeat
            end repeat
            return theResult
        end tell
        """
    }

    /// Each app script answers eight linefeed-separated fields:
    /// state, title, artist, album, position (s), duration (s; Spotify: ms), track id, artwork hint.
    private static func statusScript(for player: NowPlaying.Player) -> String {
        switch player {
        case .music:
            return """
            tell application "Music"
                set playerState to (player state as text)
                if playerState is "stopped" then return "stopped"
                set t to current track
                set nm to ""
                set ar to ""
                set al to ""
                set pos to "0"
                set dur to "0"
                set tid to ""
                try
                    set nm to name of t
                end try
                try
                    set ar to artist of t
                end try
                try
                    set al to album of t
                end try
                try
                    set pos to (player position) as text
                end try
                try
                    set dur to (duration of t) as text
                end try
                try
                    set tid to persistent ID of t
                end try
                return playerState & linefeed & nm & linefeed & ar & linefeed & al & linefeed & pos & linefeed & dur & linefeed & tid & linefeed & ""
            end tell
            """
        case .spotify:
            return """
            tell application "Spotify"
                set playerState to (player state as text)
                if playerState is "stopped" then return "stopped"
                set t to current track
                set nm to ""
                set ar to ""
                set al to ""
                set pos to "0"
                set dur to "0"
                set tid to ""
                set art to ""
                try
                    set nm to name of t
                end try
                try
                    set ar to artist of t
                end try
                try
                    set al to album of t
                end try
                try
                    set pos to (player position) as text
                end try
                try
                    set dur to (duration of t) as text
                end try
                try
                    set tid to id of t
                end try
                try
                    set art to artwork url of t
                end try
                return playerState & linefeed & nm & linefeed & ar & linefeed & al & linefeed & pos & linefeed & dur & linefeed & tid & linefeed & art
            end tell
            """
        default:   // VLC
            return """
            tell application "VLC"
                set nm to ""
                try
                    set nm to (name of current item) as text
                on error
                    set nm to ""
                end try
                if nm is "" then return "stopped"
                set playerState to "paused"
                try
                    if playing then set playerState to "playing"
                end try
                set pos to "0"
                set dur to "0"
                set pth to ""
                try
                    set pos to (current time) as text
                end try
                try
                    set dur to (duration of current item) as text
                end try
                try
                    set pth to (path of current item) as text
                end try
                return playerState & linefeed & nm & linefeed & "" & linefeed & "" & linefeed & pos & linefeed & dur & linefeed & pth & linefeed & pth
            end tell
            """
        }
    }
}

/// Posts the hardware media keys (next / previous / play) as system-defined events. Used for
/// browser next/previous, which page JavaScript can't do reliably; most media sites honour them.
/// Needs Accessibility permission, which the app already requests for the ⌥Space hotkey.
enum SystemMediaKey {
    static let playPause: Int32 = 16
    static let next: Int32 = 17
    static let previous: Int32 = 18

    static func post(_ key: Int32) {
        func event(_ down: Bool) -> CGEvent? {
            let data1 = Int((key << 16) | ((down ? 0xA : 0xB) << 8))
            let ns = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                subtype: 8, data1: data1, data2: -1)
            return ns?.cgEvent
        }
        event(true)?.post(tap: .cghidEventTap)
        event(false)?.post(tap: .cghidEventTap)
    }
}
