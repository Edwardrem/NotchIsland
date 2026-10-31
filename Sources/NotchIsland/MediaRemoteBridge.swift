import AppKit
import Foundation

/// The system-wide Now Playing feed, the one Control Center shows: TV, Music, Podcasts, QuickTime
/// Player, browsers, any app that publishes what it plays.
///
/// Since macOS 15.4 MediaRemote answers only Apple's own processes, so the feed is read through
/// `/usr/bin/perl`, which loads the adapter dylib (`Sources/MediaRemoteAdapter`) with its DynaLoader
/// and runs it: one JSON line per change plus a heartbeat every two seconds. The process is kept
/// alive here and restarted if it dies; transport commands run the same loader for one call.
final class MediaRemoteBridge {
    static let shared = MediaRemoteBridge()

    struct Snapshot {
        var bundleID: String?
        var pid: Int32
        var isPlaying: Bool
        var title: String
        var artist: String
        var album: String
        var duration: TimeInterval
        var elapsed: TimeInterval        // as of `receivedAt`
        var itemID: String
        var artworkKey: String
        var isVideo: Bool
        var receivedAt: Date
    }

    /// `libMediaRemoteAdapter.dylib`: in the bundle's Frameworks folder, or next to the executable
    /// for a `swift build` / `swift run` tree.
    static let adapterURL: URL? = {
        let name = "libMediaRemoteAdapter.dylib"
        var candidates: [URL] = []
        if let frameworks = Bundle.main.privateFrameworksURL { candidates.append(frameworks.appendingPathComponent(name)) }
        if let exe = Bundle.main.executableURL { candidates.append(exe.deletingLastPathComponent().appendingPathComponent(name)) }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0.path) }
    }()

    var isAvailable: Bool { Self.adapterURL != nil }

    private let lock = NSLock()
    private var latest: Snapshot?
    private var artworks: [String: NSImage] = [:]
    private var process: Process?
    private var buffer = Data()
    private var running = false
    private var restartDelay: TimeInterval = 1
    private var exitsLogged = 0
    private let queue = DispatchQueue(label: "NotchIsland.mediaremote", qos: .utility)
    private let logging = ProcessInfo.processInfo.environment["NOTCHISLAND_MEDIA_LOG"] != nil
    private static let staleAfter: TimeInterval = 10

    /// Loads the dylib and calls the named XSUB-shaped function: `perl -e <loader> <dylib> <function>`.
    private static let loader = """
    use DynaLoader; my ($lib, $fn) = @ARGV; \
    my $h = DynaLoader::dl_load_file($lib, 0x01) or die DynaLoader::dl_error(); \
    my $s = DynaLoader::dl_find_symbol($h, $fn) or die DynaLoader::dl_error(); \
    DynaLoader::dl_install_xsub("main::go", $s); go();
    """

    // MARK: Lifecycle

    func start() {
        guard Self.adapterURL != nil else {
            NSLog("NotchIsland media: libMediaRemoteAdapter.dylib not found; the system Now Playing feed is off")
            return
        }
        queue.async { [self] in
            guard !running else { return }
            running = true
            spawn()
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            process?.terminate()
            process = nil
            lock.lock(); latest = nil; lock.unlock()
        }
    }

    /// The current item, or nil when nothing is published or the feed has gone quiet.
    var snapshot: Snapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let s = latest, Date().timeIntervalSince(s.receivedAt) < Self.staleAfter else { return nil }
        return s
    }

    func artwork(forKey key: String) -> NSImage? {
        lock.lock(); defer { lock.unlock() }
        return artworks[key]
    }

    /// play | pause | toggle | next | previous | seek:<seconds>
    func send(_ command: String) {
        guard let adapter = Self.adapterURL else { return }
        queue.async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            p.arguments = ["-e", Self.loader, adapter.path, "notchisland_mra_command"]
            var env = ProcessInfo.processInfo.environment
            env["NOTCHISLAND_MRA_COMMAND"] = command
            p.environment = env
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { NSLog("NotchIsland media: could not send %@: %@", command, error.localizedDescription); return }
            p.waitUntilExit()
            if p.terminationStatus != 0 { NSLog("NotchIsland media: command %@ failed (%d)", command, p.terminationStatus) }
        }
    }

    // MARK: Stream

    private func spawn() {
        guard running, let adapter = Self.adapterURL else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", Self.loader, adapter.path, "notchisland_mra_stream"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = logging ? FileHandle.standardError : FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            self?.queue.async { self?.exited(proc) }
        }
        do {
            try p.run()
            process = p
            buffer.removeAll()
        } catch {
            NSLog("NotchIsland media: could not start the Now Playing feed: %@", error.localizedDescription)
            retryLater()
        }
    }

    private func exited(_ proc: Process) {
        guard proc === process else { return }
        process = nil
        lock.lock(); latest = nil; lock.unlock()
        guard running else { return }
        if exitsLogged < 3 {
            exitsLogged += 1
            NSLog("NotchIsland media: the Now Playing feed ended (status %d), restarting", proc.terminationStatus)
        }
        retryLater()
    }

    private func retryLater() {
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 30)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.spawn() }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            parse(Data(line))
        }
    }

    private func parse(_ line: Data) {
        guard let d = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        let now = Date()
        restartDelay = 1
        let pid = (d["pid"] as? NSNumber)?.int32Value ?? 0
        let title = (d["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = (d["artist"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let playing = (d["playing"] as? Bool) ?? false
        var elapsed = (d["elapsed"] as? NSNumber)?.doubleValue ?? 0
        let rate = (d["rate"] as? NSNumber)?.doubleValue ?? (playing ? 1 : 0)
        if playing, let stamp = (d["timestamp"] as? NSNumber)?.doubleValue {
            // MediaRemote reports the position as of its timestamp; bring it up to now.
            elapsed += max(0, now.timeIntervalSince1970 - stamp) * max(rate, 0)
        }
        let artworkKey = d["artworkKey"] as? String ?? ""
        if !artworkKey.isEmpty, let b64 = d["artwork"] as? String,
           let data = Data(base64Encoded: b64), let image = NSImage(data: data) {
            lock.lock()
            if artworks.count > 20 { artworks.removeAll() }
            artworks[artworkKey] = image
            lock.unlock()
        }
        let mediaType = (d["mediaType"] as? String ?? "").lowercased()
        let snapshot: Snapshot? = (pid == 0 && title.isEmpty && artist.isEmpty) ? nil : Snapshot(
            bundleID: d["bundle"] as? String,
            pid: pid, isPlaying: playing, title: title, artist: artist,
            album: (d["album"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            duration: (d["duration"] as? NSNumber)?.doubleValue ?? 0,
            elapsed: elapsed,
            itemID: (d["id"] as? String) ?? "",
            artworkKey: artworkKey,
            isVideo: mediaType.contains("video"),
            receivedAt: now)
        lock.lock(); latest = snapshot; lock.unlock()
    }
}
