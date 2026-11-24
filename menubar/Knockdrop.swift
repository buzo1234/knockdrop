// Knockdrop menu bar app. Built on each Mac by `knockdrop menubar` with the Command Line Tools'
// swiftc, so it needs no signing or Xcode project. All knock detection and networking stays in
// knockdrop.py; this app runs `knockdrop agent` (background receiver) and `knockdrop send --events`
// (sharing) and turns their JSON event lines into a menu, a notice and an overlay. It plays no sounds.
//
// Calm by default: nothing listens or pops up until you press a shortcut.
//   ⌃⌥K  receive: takes an offer knocked on your table at once, otherwise knock it (or tap
//        the space bar). Someone sharing nearby only gets a small notice under the menu bar
//        icon, held back while you're typing, and the tap count in the menu bar.
//   ⌃⌥C  share the clipboard; press it again to stop sharing. Locking the Mac stops it too.

import AppKit
import Carbon

let appID = "io.github.buzo1234.knockdrop"
let defaults = UserDefaults.standard
let home = FileManager.default.homeDirectoryForCurrentUser
let receiveKey = "⌃⌥K"
let shareKey = "⌃⌥C"

// MARK: - knockdrop child process speaking JSON lines

final class KDProcess {
    let process = Process()
    private let input = Pipe()
    private var buffer = Data()
    var onEvent: (([String: Any]) -> Void)?
    var onExit: ((Int32) -> Void)?
    var stopping = false

    init(command: [String], args: [String], log: FileHandle?) {
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst()) + args
        process.standardInput = input   // we never close it: when this app dies, the child sees EOF and exits
        let out = Pipe()
        process.standardOutput = out
        process.standardError = log ?? FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(d) }
        }
        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async { self?.onExit?(p.terminationStatus) }
        }
    }

    func start() -> Bool {
        do { try process.run(); return true } catch { return false }
    }

    func send(_ obj: [String: Any]) {
        guard process.isRunning, var d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        d.append(10)
        try? input.fileHandleForWriting.write(contentsOf: d)
    }

    func stop() {
        stopping = true
        if process.isRunning { process.terminate() }
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        while let i = buffer.firstIndex(of: 10) {
            let line = buffer.subdata(in: buffer.startIndex..<i)
            buffer.removeSubrange(buffer.startIndex...i)
            if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { onEvent?(obj) }
        }
    }
}

// MARK: - notice: a small card under the menu bar icon. Never takes focus; click it to act.

final class ClickView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with e: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
}

final class Notice {
    private let panel: NSPanel
    private let icon = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subField = NSTextField(labelWithString: "")
    private let keyField = NSTextField(labelWithString: "")
    private let keyBox = NSView()
    private let click = ClickView()
    private var hideTimer: Timer?
    private var waitTimer: Timer?
    private var onClick: (() -> Void)?
    var anchor: (() -> NSRect?)?   // the status item's frame on screen
    static let width: CGFloat = 330, height: CGFloat = 58

    init() {
        let r = NSRect(x: 0, y: 0, width: Notice.width, height: Notice.height)
        panel = NSPanel(contentRect: r, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let fx = NSVisualEffectView(frame: r)
        fx.material = .popover
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 13
        fx.layer?.masksToBounds = true
        panel.contentView = fx

        icon.symbolConfiguration = .init(pointSize: 17, weight: .medium)
        icon.contentTintColor = .controlAccentColor
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        subField.font = .systemFont(ofSize: 11.5)
        subField.textColor = .secondaryLabelColor
        for f in [titleField, subField] { f.lineBreakMode = .byTruncatingTail; f.maximumNumberOfLines = 1 }
        keyField.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        keyField.textColor = .labelColor
        keyBox.wantsLayer = true
        keyBox.layer?.cornerRadius = 6
        keyBox.layer?.borderWidth = 1
        keyBox.layer?.borderColor = NSColor.separatorColor.cgColor
        keyBox.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor

        let text = NSStackView(views: [titleField, subField])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        for v in [icon, text, keyBox, keyField, click] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        click.frame = fx.bounds
        fx.addSubview(click)
        click.addSubview(icon)
        click.addSubview(text)
        click.addSubview(keyBox)
        keyBox.addSubview(keyField)
        NSLayoutConstraint.activate([
            click.leadingAnchor.constraint(equalTo: fx.leadingAnchor), click.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            click.topAnchor.constraint(equalTo: fx.topAnchor), click.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
            icon.leadingAnchor.constraint(equalTo: click.leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: click.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            text.centerYAnchor.constraint(equalTo: click.centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: keyBox.leadingAnchor, constant: -10),
            keyBox.trailingAnchor.constraint(equalTo: click.trailingAnchor, constant: -14),
            keyBox.centerYAnchor.constraint(equalTo: click.centerYAnchor),
            keyField.leadingAnchor.constraint(equalTo: keyBox.leadingAnchor, constant: 7),
            keyField.trailingAnchor.constraint(equalTo: keyBox.trailingAnchor, constant: -7),
            keyField.topAnchor.constraint(equalTo: keyBox.topAnchor, constant: 3),
            keyField.bottomAnchor.constraint(equalTo: keyBox.bottomAnchor, constant: -3),
        ])
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        keyBox.setContentCompressionResistancePriority(.required, for: .horizontal)
        click.onClick = { [weak self] in
            let act = self?.onClick
            self?.hide()
            act?()
        }
    }

    var visible: Bool { panel.isVisible }

    /// Show now. `key` is the shortcut drawn as a keycap; clicking the card does the same thing.
    func show(_ title: String, _ sub: String = "", symbol: String = "hand.tap.fill", key: String? = nil,
              hideAfter: TimeInterval = 5, onClick: (() -> Void)? = nil) {
        waitTimer?.invalidate()
        titleField.stringValue = title
        subField.stringValue = sub
        subField.isHidden = sub.isEmpty
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        keyField.stringValue = key ?? ""
        keyBox.isHidden = key == nil
        self.onClick = onClick
        place()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        }
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: hideAfter, repeats: false) { [weak self] _ in self?.hide() }
    }

    /// Show when the person pauses typing (at most `maxWait` later), so it never lands mid-sentence.
    /// `stillWanted` is checked again right before showing.
    func showAtPause(maxWait: TimeInterval = 20, stillWanted: @escaping () -> Bool, _ show: @escaping () -> Void) {
        waitTimer?.invalidate()
        let start = Date()
        let check = { [weak self] (t: Timer?) in
            guard stillWanted() else { t?.invalidate(); return }
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
            if idle >= 1.5 || Date().timeIntervalSince(start) >= maxWait {
                t?.invalidate()
                self?.waitTimer = nil
                show()
            }
        }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        if idle >= 1.5 { show(); return }
        waitTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { check($0) }
    }

    func hide() {
        hideTimer?.invalidate()
        waitTimer?.invalidate()
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in
                                                 if self?.panel.alphaValue == 0 { self?.panel.orderOut(nil) }
                                             })
    }

    private func place() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let v = screen?.visibleFrame else { return }
        var x = v.maxX - Notice.width - 12
        if let a = anchor?(), a.width > 0, v.contains(NSPoint(x: a.midX, y: v.midY)) {
            x = min(max(a.midX - Notice.width / 2, v.minX + 8), v.maxX - Notice.width - 8)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: v.maxY - Notice.height - 8))
    }
}

// MARK: - overlay: knocking and space-bar rhythm entry (only while you asked for it)

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class TapView: NSView {
    var onKey: ((NSEvent) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) { onKey?(e) }
}

final class Overlay {
    private let panel: KeyPanel
    private let titleField = NSTextField(labelWithString: "")
    private let dotsField = NSTextField(labelWithString: "")
    private let subField = NSTextField(wrappingLabelWithString: "")
    private let tapView = TapView()
    private var hideTimer: Timer?
    private var tapTimer: Timer?
    private var idleTimer: Timer?
    private var taps: [TimeInterval] = []
    private var prompt = ""
    private var expected = 0
    private var onCaptured: (([Double]) -> Void)?
    private var onCancel: (() -> Void)?
    private var onFirstTap: (() -> Void)?
    private var previousApp: NSRunningApplication?
    private(set) var capturing = false
    private var checking = false

    init() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 118),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 400, height: 118))
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 16
        fx.layer?.masksToBounds = true
        panel.contentView = fx

        titleField.font = .systemFont(ofSize: 15, weight: .semibold)
        dotsField.font = .monospacedSystemFont(ofSize: 20, weight: .bold)
        subField.font = .systemFont(ofSize: 12)
        subField.textColor = .secondaryLabelColor
        for f in [titleField, dotsField, subField] {
            f.alignment = .center
            f.translatesAutoresizingMaskIntoConstraints = false
        }
        titleField.lineBreakMode = .byTruncatingTail
        subField.maximumNumberOfLines = 2
        let stack = NSStackView(views: [titleField, dotsField, subField])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        tapView.frame = fx.bounds
        tapView.autoresizingMask = [.width, .height]
        fx.addSubview(tapView)
        tapView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: tapView.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: tapView.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: tapView.trailingAnchor, constant: -18),
            subField.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        tapView.onKey = { [weak self] e in self?.key(e) }
    }

    func show(_ title: String, dots: String = "", sub: String = "", hideAfter: TimeInterval? = nil) {
        titleField.stringValue = title
        dotsField.stringValue = dots
        dotsField.isHidden = dots.isEmpty
        subField.stringValue = sub
        subField.isHidden = sub.isEmpty
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.midX - panel.frame.width / 2, y: v.maxY - panel.frame.height - 14))
        }
        panel.orderFrontRegardless()
        hideTimer?.invalidate()
        if let t = hideAfter {
            hideTimer = Timer.scheduledTimer(withTimeInterval: t, repeats: false) { [weak self] _ in self?.hide() }
        }
    }

    func hide() {
        hideTimer?.invalidate()
        if !capturing { panel.orderOut(nil) }
    }

    /// Take the keyboard while the person enters a rhythm: space-bar taps, or knocks fed in with
    /// `knocked(_:)`. Esc cancels, Return finishes early, and it gives up after 25 s of nothing.
    /// The caller ends it with `endCapture()` (done) or `retry(_:)` (try again).
    func capture(title: String, prompt: String, expected: Int = 0, onFirstTap: (() -> Void)? = nil,
                 onCaptured: @escaping ([Double]) -> Void, onCancel: @escaping () -> Void) {
        if capturing { return }
        capturing = true
        checking = false
        taps = []
        self.prompt = prompt
        self.expected = expected
        self.onFirstTap = onFirstTap
        self.onCaptured = onCaptured
        self.onCancel = onCancel
        previousApp = NSWorkspace.shared.frontmostApplication
        show(title, dots: dots(0), sub: prompt)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(tapView)
        touch()
    }

    /// A knock felt by the sensor (n so far). Ignored once the space bar is in use.
    func knocked(_ n: Int) {
        guard capturing, !checking, taps.isEmpty else { return }
        dotsField.stringValue = dots(n)
        touch()
    }

    func setPrompt(_ s: String) {
        prompt = s
        if capturing && !checking { subField.stringValue = s; subField.isHidden = s.isEmpty }
    }

    func setChecking(_ s: String) {
        guard capturing else { return }
        checking = true
        tapTimer?.invalidate()
        subField.stringValue = s
        touch()
    }

    /// Start over with a message, still listening.
    func retry(_ message: String?) {
        guard capturing else { return }
        checking = false
        taps = []
        tapTimer?.invalidate()
        dotsField.stringValue = dots(0)
        subField.stringValue = message.map { "\($0) · \(prompt)" } ?? prompt
        touch()
    }

    func endCapture() {
        guard capturing else { return }
        tapTimer?.invalidate()
        idleTimer?.invalidate()
        capturing = false
        checking = false
        panel.orderOut(nil)
        previousApp?.activate(options: [])
    }

    private func touch() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in self?.cancel() }
    }

    private func cancel() {
        endCapture()
        onCancel?()
    }

    private func key(_ e: NSEvent) {
        guard capturing else { return }
        switch e.keyCode {
        case 49:  // space
            if e.isARepeat || checking { return }
            if taps.isEmpty { onFirstTap?() }
            taps.append(e.timestamp)
            dotsField.stringValue = dots(taps.count)
            touch()
            tapTimer?.invalidate()
            tapTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in self?.finish() }
        case 36, 76:  // return / enter
            if !checking { finish() }
        case 53:  // esc
            cancel()
        default:
            break
        }
    }

    private func finish() {
        tapTimer?.invalidate()
        if taps.count < 3 {
            retry(taps.isEmpty ? nil : "At least 3 taps")
            return
        }
        let t0 = taps[0]
        let times = taps.map { $0 - t0 }
        taps = []
        onCaptured?(times)
    }

    /// "● ● ○ ○ ○" when we know how many knocks the sharer used, else "● ●" / "· · ·".
    private func dots(_ n: Int) -> String {
        if expected > 0 && n <= expected {
            return (Array(repeating: "●", count: n) + Array(repeating: "○", count: expected - n)).joined(separator: " ")
        }
        return n == 0 ? "· · ·" : Array(repeating: "●", count: min(n, 16)).joined(separator: " ")
    }
}

// MARK: - global shortcuts (Carbon hot keys need no Accessibility permission)

var hotKeyActions: [UInt32: () -> Void] = [:]

@discardableResult
func installHotKeys(_ keys: [(id: UInt32, keyCode: Int, action: () -> Void)]) -> [OSStatus] {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    var results: [OSStatus] = []
    results.append(InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
        var hk = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
        let id = hk.id
        DispatchQueue.main.async { hotKeyActions[id]?() }
        return noErr
    }, 1, &spec, nil, nil))
    for k in keys {
        hotKeyActions[k.id] = k.action
        var ref: EventHotKeyRef?
        results.append(RegisterEventHotKey(UInt32(k.keyCode), UInt32(controlKey | optionKey),
                                           EventHotKeyID(signature: OSType(0x4B4E_4B44), id: k.id),
                                           GetApplicationEventTarget(), 0, &ref))
    }
    return results
}

// MARK: - app

struct Recent {
    let title: String
    let path: String?
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    let overlay = Overlay()
    let notice = Notice()
    var command: [String] = []
    var log: FileHandle?

    var agent: KDProcess?
    var agentRestarts = 0
    var agentInfo = "Starting…"
    var offers: [[String: Any]] = []
    var announced: Set<String> = []        // offer ids we showed a notice for ("id" or "id/felt")
    var hasSensor = true
    var outDir = home.appendingPathComponent("Downloads").path
    var version = ""
    var appStale = false
    var armed = false                      // ⌃⌥K overlay open: knock or tap the space bar
    var sensorReady = false
    var taking: String?                    // offer id being taken with the rhythm felt on the table

    var sender: KDProcess?
    var shareInfo: String?
    var shareRhythm: String?
    var shareEnds: Date?
    var sharedWith: [String] = []
    var tick: Timer?
    var recents: [Recent] = []

    var installSig: String?                // knockdrop's files when we started; brew upgrade changes them
    var seenSig: String?
    var triedSig: String?                  // one automatic update per version, so a failed build can't loop
    var updatePending = false

    var receiveOn: Bool {
        get { defaults.bool(forKey: "receiveEnabled") }
        set { defaults.set(newValue, forKey: "receiveEnabled") }
    }
    var tableOn: Bool {
        get { defaults.bool(forKey: "tableMode") }
        set { defaults.set(newValue, forKey: "tableMode") }
    }
    var loginURL: URL { home.appendingPathComponent("Library/LaunchAgents/\(appID).plist") }

    func applicationDidFinishLaunching(_ n: Notification) {
        signal(SIGPIPE, SIG_IGN)
        if NSRunningApplication.runningApplications(withBundleIdentifier: appID).count > 1 { NSApp.terminate(nil) }
        defaults.register(defaults: ["receiveEnabled": true, "tableMode": false])
        command = (Bundle.main.object(forInfoDictionaryKey: "KDCommand") as? [String]) ?? []
        openLog()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "Knockdrop"
        menu.delegate = self
        statusItem.menu = menu
        notice.anchor = { [weak self] in
            guard let b = self?.statusItem.button, let w = b.window else { return nil }
            return w.convertToScreen(b.convert(b.bounds, to: nil))
        }
        if !defaults.bool(forKey: "loginConfigured") {   // first run: start at login (toggle in the menu)
            setLogin(true)
            defaults.set(true, forKey: "loginConfigured")
        }
        let hk = installHotKeys([
            (id: 1, keyCode: kVK_ANSI_K, action: { [weak self] in self?.logLine("hotkey ⌃⌥K"); self?.receive() }),
            (id: 2, keyCode: kVK_ANSI_C, action: { [weak self] in self?.logLine("hotkey ⌃⌥C"); self?.shareOrStop() }),
        ])
        logLine("started \(command.joined(separator: " ")); hotkeys \(hk.allSatisfy { $0 == noErr } ? "ok" : "FAILED \(hk)")")

        // Walking away ends a share: nobody should pick up your clipboard from an empty desk.
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil,
                                                            queue: .main) { [weak self] _ in self?.walkedAway("locked") }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                                          queue: .main) { [weak self] _ in self?.walkedAway("went to sleep") }

        installSig = installSignature()
        seenSig = installSig
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.checkInstall() }

        if command.isEmpty {
            agentInfo = "Can't find knockdrop — run `knockdrop menubar` again"
        } else if receiveOn {
            startAgent()
        } else {
            agentInfo = "Off"
        }
        updateIcon()
    }

    func applicationWillTerminate(_ n: Notification) {
        agent?.stop()
        sender?.stop()
    }

    // MARK: log

    func openLog() {
        let url = home.appendingPathComponent("Library/Logs/Knockdrop.log")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           (attrs[.size] as? Int ?? 0) > 2_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        log = try? FileHandle(forWritingTo: url)
        log?.seekToEndOfFile()
    }

    func logLine(_ s: String) {
        try? log?.write(contentsOf: Data("[app \(Date())] \(s)\n".utf8))
    }

    // MARK: background receiver

    func startAgent() {
        guard !command.isEmpty, agent == nil else { return }
        var args = ["agent"]
        if tableOn { args.append("--table") }
        let p = KDProcess(command: command, args: args, log: log)
        p.onEvent = { [weak self] e in self?.agentEvent(e) }
        p.onExit = { [weak self, weak p] code in
            guard let self = self, let p = p else { return }
            self.agent = nil
            self.offers = []
            self.disarm(tellAgent: false)
            self.updateIcon()
            if p.stopping || !self.receiveOn { return }
            self.agentRestarts += 1
            self.logLine("receiver exited (\(code)), restart #\(self.agentRestarts)")
            if self.agentRestarts > 5 {
                self.agentInfo = "Receiver keeps stopping — see ~/Library/Logs/Knockdrop.log"
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if self.receiveOn { self.startAgent() } }
        }
        agentInfo = "Starting…"
        if p.start() { agent = p } else { agentInfo = "Couldn't start knockdrop" }
    }

    func stopAgent() {
        disarm()
        agent?.stop()
        agent = nil
        offers = []
        updateIcon()
    }

    func restartAgent() {
        stopAgent()
        agentRestarts = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if self.receiveOn { self.startAgent() } }
    }

    func agentEvent(_ e: [String: Any]) {
        switch e["event"] as? String ?? "" {
        case "hello":
            version = e["version"] as? String ?? ""
            outDir = e["out"] as? String ?? outDir
            hasSensor = e["sensor"] as? Bool ?? true
            appStale = e["app_stale"] as? Bool ?? false
            agentRestarts = 0
            if appStale { applyUpdate() }   // e.g. first login after a brew upgrade
        case "status":
            offers = e["offers"] as? [[String: Any]] ?? []
            if offers.isEmpty {
                agentInfo = "No one nearby is sharing"
                if armed {
                    disarm()
                    notice.show("The share ended", "It expired, was stopped, or got too many wrong rhythms",
                                symbol: "hand.raised.slash")
                }
            } else {
                agentInfo = "\(offerTitle(offers[0]))" + (offers.count > 1 ? " (+\(offers.count - 1) more)" : "")
            }
            announceOffers()
            updateIcon()
        case "ready":
            sensorReady = true
            if armed { overlay.setPrompt(armPrompt()) }
        case "knock":   // only sent while armed
            overlay.knocked(e["n"] as? Int ?? 1)
        case "trying":
            if armed { overlay.setChecking("Checking the rhythm…") }
        case "pattern":
            patternResult(e)
        case "received":
            received(e)
        case "error":
            let msg = e["message"] as? String ?? "error"
            logLine("receiver: \(msg)")
            if msg.contains("Local Network") {
                agentInfo = "Blocked: allow Knockdrop in System Settings › Privacy & Security › Local Network"
            }
        default:
            break
        }
    }

    /// Someone started sharing: a small card under the menu bar icon, once per offer, held back
    /// while you're typing. No focus change, no sensor. ⌃⌥K or a click takes it.
    func announceOffers() {
        for o in offers {
            guard let id = o["id"] as? String else { continue }
            let felt = o["felt"] as? Bool == true
            let tag = felt ? id + "/felt" : id
            if announced.contains(tag) { continue }
            announced.insert(tag)
            announced.insert(id)
            let title = felt ? "\(who(o)) knocked on your table" : "\(who(o)) is sharing \(what(o))"
            let sub = felt ? "\(what(o).capitalizedFirst) · press to take it, no knocking"
                           : "\(o["knocks"] as? Int ?? 0) knocks · press to knock it in"
            notice.showAtPause(stillWanted: { [weak self] in
                guard let self = self, !self.armed, self.taking == nil else { return false }
                return self.offers.contains { $0["id"] as? String == id }
            }) { [weak self] in
                self?.notice.show(title, sub, symbol: felt ? "hand.tap.fill" : "hand.tap", key: receiveKey,
                                  hideAfter: 7, onClick: { self?.receive(id) })
            }
        }
    }

    func received(_ e: [String: Any]) {
        disarm()
        taking = nil
        overlay.hide()
        let who = e["sender"] as? String ?? "someone"
        let items = e["items"] as? [[String: Any]] ?? []
        var title = "From \(who)", sub = "", symbol = "checkmark.circle.fill"
        var open: String?
        if let first = items.first, let kind = first["clipboard"] as? String, first["copied"] as? Bool == true {
            switch kind {
            case "text":
                let preview = first["preview"] as? String ?? ""
                title = "Copied \(who)'s text"
                sub = "⌘V to paste · “\(preview)”"
                symbol = "doc.on.clipboard.fill"
                recents.insert(Recent(title: "Text from \(who): “\(preview)”", path: nil), at: 0)
            case "image":
                title = "Copied \(who)'s image"
                sub = "⌘V to paste"
                symbol = "photo.fill"
                recents.insert(Recent(title: "Image from \(who) (copied)", path: nil), at: 0)
            default:
                let names = items.compactMap { $0["name"] as? String }
                title = "Copied \(names.count) file\(names.count == 1 ? "" : "s") from \(who)"
                sub = "⌘V in Finder · " + names.joined(separator: ", ")
                open = items.first?["path"] as? String
                for it in items { recents.insert(Recent(title: it["name"] as? String ?? "file", path: it["path"] as? String), at: 0) }
            }
        } else {
            let names = items.compactMap { $0["name"] as? String }
            title = "Got \(names.count) file\(names.count == 1 ? "" : "s") from \(who)"
            sub = "In Downloads · " + names.joined(separator: ", ")
            symbol = "arrow.down.circle.fill"
            open = items.first?["path"] as? String
            for it in items { recents.insert(Recent(title: it["name"] as? String ?? "file", path: it["path"] as? String), at: 0) }
        }
        recents = Array(recents.prefix(6))
        notice.show(title, sub, symbol: symbol, hideAfter: 5, onClick: open.map { p in
            { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
        })
    }

    func patternResult(_ e: [String: Any]) {
        let result = e["result"] as? String ?? ""
        let via = e["via"] as? String ?? ""
        if via == "table" {   // the felt rhythm didn't work out: knock it instead
            guard taking != nil else { return }
            taking = nil
            overlay.hide()
            arm(note: result == "no_match" ? "What your table felt didn't match" : nil)
            return
        }
        guard armed else { return }
        switch result {
        case "no_match":
            overlay.retry("Didn't match")
        case "no_offer":
            let counts = (e["offer_knocks"] as? [Int] ?? []).map(String.init).joined(separator: " or ")
            overlay.retry("You knocked \(e["knocks"] as? Int ?? 0), they knocked \(counts.isEmpty ? "?" : counts)")
        default:   // a stray bump or two: start over quietly
            overlay.retry(nil)
        }
    }

    // MARK: receive (⌃⌥K, a click on the notice, or the menu)

    /// One key does the right thing: take what was knocked on your table, otherwise open the
    /// knock overlay. Nothing is received without this.
    func receive(_ id: String? = nil) {
        guard let agent = agent else {
            notice.show("Receiving is off", "Turn on “Receive by Knocking” in the menu", symbol: "hand.raised.slash")
            return
        }
        if armed || taking != nil { return }
        notice.hide()
        if offers.isEmpty {
            notice.show("No one nearby is sharing", "When someone shares, you'll see it here", symbol: "hand.raised")
            return
        }
        let target = offers.first { $0["id"] as? String == id } ?? offers.first { $0["felt"] as? Bool == true }
        if let o = target, o["felt"] as? Bool == true, let oid = o["id"] as? String {
            taking = oid
            overlay.show("Taking \(who(o))'s \(what(o))…", sub: "Knocked on your table", hideAfter: 10)
            agent.send(["cmd": "take", "id": oid])
            return
        }
        arm(for: target)
    }

    func arm(for target: [String: Any]? = nil, note: String? = nil) {
        guard let agent = agent, !armed else { return }
        guard !offers.isEmpty else {
            notice.show("No one nearby is sharing", "When someone shares, you'll see it here", symbol: "hand.raised")
            return
        }
        let o = target ?? offers.first
        armed = true
        sensorReady = false
        agent.send(["cmd": "arm", "on": true])
        let n = offers.allSatisfy { $0["knocks"] as? Int == o?["knocks"] as? Int } ? (o?["knocks"] as? Int ?? 0) : 0
        let title = o.map { "Knock \(who($0))'s rhythm" } ?? "Knock the sharer's rhythm"
        overlay.capture(title: title, prompt: armPrompt(), expected: n,
                        onFirstTap: { [weak self] in self?.agent?.send(["cmd": "keys", "on": true]) },
                        onCaptured: { [weak self] times in
                            self?.overlay.setChecking("Checking the rhythm…")
                            self?.agent?.send(["cmd": "pattern", "times": times])
                        },
                        onCancel: { [weak self] in self?.disarm() })
        if let note = note { overlay.retry(note) }
        updateIcon()
    }

    func armPrompt() -> String {
        if !hasSensor { return "Tap it on the space bar · Esc cancels" }
        return sensorReady ? "Knock on your Mac, or tap the space bar · Esc cancels"
                           : "Hands still a sec… or tap the space bar · Esc cancels"
    }

    func disarm(tellAgent: Bool = true) {
        guard armed else { return }
        armed = false
        overlay.endCapture()
        if tellAgent { agent?.send(["cmd": "arm", "on": false]) }
        updateIcon()
        if updatePending { DispatchQueue.main.async { self.applyUpdate() } }
    }

    // MARK: share (⌃⌥C shares, ⌃⌥C again stops)

    func shareOrStop() {
        if sender != nil { stopShare() } else { shareClipboard() }
    }

    func shareClipboard() { startShare(files: []) }

    @objc func shareFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Share"
        panel.message = "Choose files to share by knocking"
        if panel.runModal() == .OK {
            startShare(files: panel.urls.map { $0.path })
        }
    }

    func startShare(files: [String]) {
        guard !command.isEmpty, sender == nil else { return }
        if hasSensor {
            launchSender(pattern: nil, files: files)
        } else {
            overlay.capture(title: "Tap a rhythm to share with", prompt: "On the space bar · Esc cancels",
                            onCaptured: { [weak self] t in
                                self?.overlay.endCapture()
                                self?.launchSender(pattern: t, files: files)
                            },
                            onCancel: {})
        }
    }

    func launchSender(pattern: [Double]?, files: [String]) {
        var args: [String] = []
        if let p = pattern { args += ["--pattern", p.map { String(format: "%.3f", $0) }.joined(separator: ",")] }
        args += ["send", "--events", "--multi"] + files
        let p = KDProcess(command: command, args: args, log: log)
        sharedWith = []
        shareRhythm = nil
        shareEnds = nil
        shareInfo = "Starting…"
        p.onEvent = { [weak self] e in self?.senderEvent(e) }
        p.onExit = { [weak self] _ in
            guard let self = self else { return }
            self.sender = nil
            self.shareInfo = nil
            self.shareEnds = nil
            self.tick?.invalidate()
            self.overlay.hide()
            self.updateIcon()
            if self.updatePending { self.applyUpdate() }
        }
        if p.start() { sender = p } else { shareInfo = nil }
        updateIcon()
    }

    @objc func stopShare() {
        guard let s = sender else { return }
        let got = sharedWith.count
        s.stop()
        overlay.hide()
        notice.show("Stopped sharing", got == 0 ? "No one took it" : "\(got) got it: " + sharedWith.joined(separator: ", "),
                    symbol: "stop.circle.fill", hideAfter: 3)
    }

    func walkedAway(_ how: String) {
        disarm()
        guard sender != nil else { return }
        logLine("stopping the share: Mac \(how)")
        sender?.stop()
        overlay.hide()
        notify("Knockdrop stopped sharing", "Your Mac \(how), so your share ended")
    }

    func senderEvent(_ e: [String: Any]) {
        switch e["event"] as? String ?? "" {
        case "sharing":
            shareInfo = "Sharing \(e["what"] as? String ?? "")"
        case "calibrating":
            overlay.show("Hands off for a second…", sub: "\(shareKey) again cancels")
        case "knock_now":
            overlay.show("Knock a rhythm on the table", dots: "· · ·",
                         sub: "Mix short and long gaps · \(shareKey) again cancels", hideAfter: 30)
        case "knock":
            overlay.show("Knock a rhythm on the table", dots: dotString(e["n"] as? Int ?? 1),
                         sub: "Mix short and long gaps · \(shareKey) again cancels", hideAfter: 30)
        case "pattern_rejected":
            overlay.show("Knock again", dots: "· · ·", sub: e["reason"] as? String ?? "", hideAfter: 30)
        case "waiting":
            let times = e["times"] as? [Double] ?? []
            shareRhythm = rhythmString(times)
            shareEnds = Date().addingTimeInterval(e["expires_in"] as? Double ?? 300)
            overlay.hide()
            notice.show("Sharing for 5 min · \(shareRhythm ?? "")",
                        "Others knock this rhythm · \(shareKey) or click to stop",
                        symbol: "dot.radiowaves.left.and.right", key: shareKey, hideAfter: 6,
                        onClick: { [weak self] in self?.stopShare() })
            tick?.invalidate()
            tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateIcon() }
        case "sent":
            let who = e["who"] as? String ?? "someone"
            sharedWith.append(who)
            notice.show("\(who) got it", "Still sharing · \(shareKey) or click to stop", symbol: "checkmark.circle.fill",
                        key: shareKey, hideAfter: 4, onClick: { [weak self] in self?.stopShare() })
        case "wrong":
            logLine("share: \(e["who"] as? String ?? "?") knocked a different rhythm")
        case "expired", "closed":
            let expired = e["event"] as? String == "expired"
            notice.show(expired ? "Your share expired" : "Your share closed",
                        expired ? (sharedWith.isEmpty ? "No one took it" : "\(sharedWith.count) got it")
                                : (e["reason"] as? String ?? ""), symbol: "clock")
        case "error":
            let msg = e["message"] as? String ?? "Couldn't share"
            overlay.hide()
            notice.show(msg, "", symbol: "exclamationmark.triangle.fill")
        default:
            break
        }
        updateIcon()
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        notice.hide()
        let head = NSMenuItem(title: "Knockdrop" + (version.isEmpty ? "" : " \(version)"), action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        if appStale {
            menu.addItem(item("Restart to Finish Updating", #selector(finishUpdate)))
        }
        menu.addItem(.separator())

        if let s = shareInfo {
            menu.addItem(info(s + (shareEnds.map { " · ends in \(clock($0))" } ?? "")))
            if let r = shareRhythm { menu.addItem(info("Rhythm: \(r)")) }
            if !sharedWith.isEmpty { menu.addItem(info("Got it: " + sharedWith.joined(separator: ", "))) }
            let stop = item("Stop Sharing", #selector(stopShare))
            stop.keyEquivalent = "c"
            stop.keyEquivalentModifierMask = [.control, .option]
            menu.addItem(stop)
        } else {
            let clip = item("Share Clipboard", #selector(shareClipboardAction))
            clip.keyEquivalent = "c"
            clip.keyEquivalentModifierMask = [.control, .option]
            menu.addItem(clip)
            menu.addItem(item("Share Files…", #selector(shareFiles)))
        }
        menu.addItem(.separator())

        if receiveOn {
            if offers.isEmpty {
                menu.addItem(info(agentInfo))
            } else {
                menu.addItem(info("Nearby — click to receive"))
                for o in offers {
                    let felt = o["felt"] as? Bool == true
                    let it = item("\(offerTitle(o))" + (felt ? " · knocked on your table" : ""), #selector(receiveOffer(_:)))
                    it.representedObject = o["id"] as? String
                    it.image = NSImage(systemSymbolName: felt ? "hand.tap.fill" : "hand.tap", accessibilityDescription: nil)
                    menu.addItem(it)
                }
            }
            let rcv = item("Receive…", #selector(receiveAction), enabled: agent != nil)
            rcv.keyEquivalent = "k"
            rcv.keyEquivalentModifierMask = [.control, .option]
            menu.addItem(rcv)
        } else {
            menu.addItem(info("Receiving is off"))
        }

        if !recents.isEmpty {
            menu.addItem(.separator())
            menu.addItem(info("Recently received"))
            for (i, r) in recents.enumerated() {
                let it = item(trim(r.title, 60), #selector(openRecent(_:)), enabled: r.path != nil)
                it.tag = i
                menu.addItem(it)
            }
        }
        menu.addItem(.separator())
        menu.addItem(item("Receive by Knocking", #selector(toggleReceive), state: receiveOn))
        if hasSensor {
            menu.addItem(item("Notice Knocks on My Table", #selector(toggleTable), state: tableOn, enabled: receiveOn))
            menu.addItem(info("Offers knocked on your table: \(receiveKey) takes them, no knocking"))
        }
        menu.addItem(item("Open Downloads", #selector(openDownloads)))
        menu.addItem(item("Open at Login", #selector(toggleLogin), state: FileManager.default.fileExists(atPath: loginURL.path)))
        menu.addItem(item("Quit Knockdrop", #selector(quit), key: "q"))
    }

    func item(_ title: String, _ action: Selector, state: Bool? = nil, enabled: Bool = true, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: key)
        it.target = self
        if let s = state { it.state = s ? .on : .off }
        return it
    }

    func info(_ text: String) -> NSMenuItem {
        let it = NSMenuItem(title: trim(text, 70), action: nil, keyEquivalent: "")
        it.isEnabled = false
        it.indentationLevel = 1
        it.toolTip = text
        return it
    }

    @objc func toggleReceive() {
        receiveOn.toggle()
        if receiveOn { agentRestarts = 0; startAgent() } else { stopAgent(); agentInfo = "Off" }
        updateIcon()
    }

    @objc func toggleTable() {
        tableOn.toggle()
        if receiveOn { restartAgent() }
    }

    @objc func receiveAction() { receive() }
    @objc func receiveOffer(_ sender: NSMenuItem) { receive(sender.representedObject as? String) }
    @objc func shareClipboardAction() { shareClipboard() }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard sender.tag < recents.count, let p = recents[sender.tag].path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }

    @objc func openDownloads() { NSWorkspace.shared.open(URL(fileURLWithPath: outDir)) }

    @objc func toggleLogin() { setLogin(!FileManager.default.fileExists(atPath: loginURL.path)) }

    @objc func finishUpdate() {
        guard !command.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: command[0])
        p.arguments = Array(command.dropFirst()) + ["menubar", "--rebuild"]
        try? p.run()   // rebuilds the app, quits this copy and opens the new one
    }

    @objc func quit() { NSApp.terminate(nil) }

    // MARK: updates

    /// `brew upgrade` swaps the files under us but can't touch running programs, so this app and
    /// its receiver kept running the old version until the next login. Watch knockdrop's files
    /// (what the `knockdrop` command resolves to, plus the app source) and follow them.
    func installSignature() -> String? {
        guard let last = command.last else { return nil }
        let real = URL(fileURLWithPath: last).resolvingSymlinksInPath()
        let dir = real.deletingLastPathComponent()   // the `knockdrop` launcher or knockdrop.py: both sit next to the rest
        var parts: [String] = []
        for f in ["knockdrop.py", "menubar/Knockdrop.swift"] {
            let path = dir.appendingPathComponent(f).path
            guard let a = try? FileManager.default.attributesOfItem(atPath: path),
                  let m = a[.modificationDate] as? Date else { return nil }   // missing: mid-upgrade, look again later
            parts.append("\(path)|\(m.timeIntervalSince1970)|\((a[.size] as? Int) ?? 0)")
        }
        return parts.joined(separator: ";")
    }

    func checkInstall() {
        guard let sig = installSignature() else { return }
        defer { seenSig = sig }
        // act once the new files have sat still for a whole check, not halfway through the upgrade
        if sig != installSig && sig == seenSig { applyUpdate() }
    }

    /// Runs `knockdrop menubar` with the installed knockdrop: if the app is out of date it rebuilds
    /// it, quits this copy and opens the new one. If we're still here afterwards, only the CLI
    /// changed: restart the receiver so it runs the new code. Waits while you share or receive.
    func applyUpdate() {
        guard !command.isEmpty else { return }
        if sender != nil || armed || taking != nil { updatePending = true; return }
        updatePending = false
        let sig = installSignature()
        if sig != nil && sig == triedSig { return }
        triedSig = sig
        logLine("knockdrop changed on disk; updating")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: command[0])
        p.arguments = Array(command.dropFirst()) + ["menubar"]
        p.standardOutput = log ?? FileHandle.nullDevice
        p.standardError = log ?? FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.logLine("update finished (\(proc.terminationStatus)); restarting the receiver")
                self.installSig = sig
                if self.receiveOn { self.restartAgent() }
            }
        }
        do { try p.run() } catch { logLine("couldn't run knockdrop to update: \(error)") }
    }

    func setLogin(_ on: Bool) {
        if on {
            let plist: [String: Any] = [
                "Label": appID,
                "ProgramArguments": [Bundle.main.executablePath ?? ""],
                "RunAtLoad": true,
                "LimitLoadToSessionType": "Aqua",
                "ProcessType": "Interactive",
            ]
            try? FileManager.default.createDirectory(at: loginURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let d = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? d.write(to: loginURL)
            }
        } else {
            try? FileManager.default.removeItem(at: loginURL)
        }
    }

    // MARK: helpers

    /// The menu bar is the ambient display: a live countdown while you share, the tap count
    /// while someone nearby shares. Glanceable, never in the way.
    func updateIcon() {
        guard let button = statusItem?.button else { return }
        let active = sender != nil || !offers.isEmpty || armed
        let name = sender != nil ? "dot.radiowaves.left.and.right" : (active ? "hand.tap.fill" : "hand.tap")
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: "Knockdrop")
            ?? NSImage(systemSymbolName: active ? "hand.raised.fill" : "hand.raised", accessibilityDescription: "Knockdrop") {
            img.isTemplate = true
            button.image = img
            button.imagePosition = .imageLeading
        }
        var badge = ""
        if let end = shareEnds, sender != nil {
            badge = clock(end) + (sharedWith.isEmpty ? "" : " ✓\(sharedWith.count)")
        } else if sender != nil {
            badge = "…"
        } else if let o = offers.first {
            badge = "\(o["knocks"] as? Int ?? 0)"
        }
        button.attributedTitle = NSAttributedString(string: badge.isEmpty ? "" : " " + badge, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .baselineOffset: 0.5,
        ])
        button.toolTip = sender != nil ? (shareInfo ?? "Sharing") + " · \(shareKey) stops"
            : offers.first.map { offerTitle($0) + " · \(receiveKey) to receive" } ?? "Knockdrop"
        button.appearsDisabled = !receiveOn && sender == nil
    }

    func notify(_ title: String, _ body: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "on run argv", "-e", "display notification (item 2 of argv) with title (item 1 of argv)",
                       "-e", "end run", title, body]
        try? p.run()
    }

    func who(_ o: [String: Any]) -> String { o["from"] as? String ?? "Someone" }
    func what(_ o: [String: Any]) -> String { o["label"] as? String ?? "something" }
    func offerTitle(_ o: [String: Any]) -> String { "\(who(o)) · \(what(o)) · \(o["knocks"] as? Int ?? 0) knocks" }

    func clock(_ end: Date) -> String {
        let s = max(0, Int(end.timeIntervalSinceNow.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    func dotString(_ n: Int) -> String {
        String(repeating: "● ", count: max(0, min(n, 16))).trimmingCharacters(in: .whitespaces)
    }

    /// 0, 0.4, 0.6, 1.4 -> "●──●─●────●": gaps drawn to scale so others can knock it.
    func rhythmString(_ times: [Double]) -> String {
        guard times.count > 1, let total = times.last, total > 0 else { return dotString(times.count) }
        var s = "●"
        for (a, b) in zip(times, times.dropFirst()) {
            s += String(repeating: "─", count: max(1, Int(((b - a) / total * 16).rounded()))) + "●"
        }
        return s
    }

    func trim(_ s: String, _ n: Int) -> String { s.count <= n ? s : String(s.prefix(n - 1)) + "…" }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
