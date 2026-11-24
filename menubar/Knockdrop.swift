// Knockdrop menu bar app. Built on each Mac by `knockdrop menubar` with the Command Line Tools'
// swiftc, so it needs no signing or Xcode project. All knock detection and networking stays in
// knockdrop.py; this app runs `knockdrop agent` (background receiver) and `knockdrop send --events`
// (sharing) and turns their JSON event lines into a menu, an overlay, sounds and notifications.

import AppKit
import Carbon

let appID = "io.github.buzo1234.knockdrop"
let defaults = UserDefaults.standard
let home = FileManager.default.homeDirectoryForCurrentUser

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

// MARK: - overlay: knock feedback, results, and space-bar rhythm entry (keyboard only, no mouse)

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
    private var taps: [TimeInterval] = []
    private var capturePrompt = ""
    private var onCaptured: (([Double]) -> Void)?
    private var onCancel: (() -> Void)?
    private var previousApp: NSRunningApplication?
    private(set) var capturing = false

    init() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 118),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 380, height: 118))
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

    /// Take the keyboard briefly and record space-bar taps. Esc cancels, Return finishes early.
    func capture(title: String, prompt: String, onCaptured: @escaping ([Double]) -> Void, onCancel: @escaping () -> Void) {
        if capturing { return }
        capturing = true
        taps = []
        capturePrompt = prompt
        self.onCaptured = onCaptured
        self.onCancel = onCancel
        previousApp = NSWorkspace.shared.frontmostApplication
        show(title, dots: "· · ·", sub: prompt)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(tapView)
    }

    private func key(_ e: NSEvent) {
        guard capturing else { return }
        switch e.keyCode {
        case 49:  // space
            if e.isARepeat { return }
            taps.append(e.timestamp)
            NSSound(named: "Tink")?.play()
            dotsField.stringValue = String(repeating: "● ", count: taps.count).trimmingCharacters(in: .whitespaces)
            dotsField.isHidden = false
            tapTimer?.invalidate()
            tapTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in self?.finish() }
        case 36, 76:  // return / enter
            finish()
        case 53:  // esc
            end()
            onCancel?()
        default:
            break
        }
    }

    private func finish() {
        tapTimer?.invalidate()
        if taps.count < 3 {
            taps = []
            show(titleField.stringValue, dots: "· · ·", sub: "At least 3 taps — try again. " + capturePrompt)
            return
        }
        let t0 = taps[0]
        let times = taps.map { $0 - t0 }
        end()
        onCaptured?(times)
    }

    private func end() {
        tapTimer?.invalidate()
        capturing = false
        panel.orderOut(nil)
        previousApp?.activate(options: [])
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
    var command: [String] = []
    var log: FileHandle?

    var agent: KDProcess?
    var agentRestarts = 0
    var agentInfo = "Starting…"
    var offers: [[String: Any]] = []
    var hasSensor = true
    var outDir = home.appendingPathComponent("Downloads").path
    var version = ""
    var appStale = false
    var receivingKeys = false

    var sender: KDProcess?
    var shareInfo: String?
    var shareRhythm: String?
    var sharedWith: [String] = []
    var recents: [Recent] = []

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
        if !defaults.bool(forKey: "loginConfigured") {   // first run: start at login (toggle in the menu)
            setLogin(true)
            defaults.set(true, forKey: "loginConfigured")
        }
        let hk = installHotKeys([
            (id: 1, keyCode: kVK_ANSI_K, action: { [weak self] in self?.logLine("hotkey ⌃⌥K"); self?.tapToReceive() }),
            (id: 2, keyCode: kVK_ANSI_C, action: { [weak self] in self?.logLine("hotkey ⌃⌥C"); self?.shareClipboard() }),
        ])
        logLine("started \(command.joined(separator: " ")); hotkeys \(hk.allSatisfy { $0 == noErr } ? "ok" : "FAILED \(hk)")")
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
        case "status":
            offers = e["offers"] as? [[String: Any]] ?? []
            if offers.isEmpty {
                agentInfo = tableOn ? "Listening — feeling the table for knocks" : "Listening — no one nearby is sharing"
            } else {
                let o = offers[0]
                let who = o["from"] as? String ?? "Someone"
                let what = o["label"] as? String ?? "something"
                let more = offers.count > 1 ? " (+\(offers.count - 1) more)" : ""
                agentInfo = "\(who) is sharing \(what)\(more) — " + (hasSensor ? "knock their rhythm" : "press ⌃⌥K")
            }
            updateIcon()
        case "knock":
            guard !offers.isEmpty, !receivingKeys else { return }   // only show knocks when they can matter
            let n = e["n"] as? Int ?? 1
            NSSound(named: "Tink")?.play()
            overlay.show("Knocking…", dots: dotString(n), sub: "Knock \(offerSummary())", hideAfter: 4)
        case "pattern":
            let result = e["result"] as? String ?? ""
            let via = e["via"] as? String ?? ""
            if result == "no_match" && via != "table" {
                NSSound(named: "Basso")?.play()
                overlay.show("Rhythm didn't match", sub: "Try again — \(offerSummary())", hideAfter: 3)
            } else if result == "no_offer" && via != "table" {
                let counts = (e["offer_knocks"] as? [Int] ?? []).map(String.init).joined(separator: " or ")
                NSSound(named: "Funk")?.play()
                overlay.show("\(e["knocks"] as? Int ?? 0) knocks", sub: counts.isEmpty ? "No one is sharing right now"
                                                                     : "They knocked \(counts) times — try again", hideAfter: 3)
            }
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

    func received(_ e: [String: Any]) {
        let who = e["sender"] as? String ?? "someone"
        let items = e["items"] as? [[String: Any]] ?? []
        NSSound(named: "Glass")?.play()
        var title = "From \(who)", body = ""
        if let first = items.first, let kind = first["clipboard"] as? String, first["copied"] as? Bool == true {
            switch kind {
            case "text":
                body = "“\(first["preview"] as? String ?? "")”"
                title = "Copied text from \(who) — ⌘V to paste"
                recents.insert(Recent(title: "Text from \(who): \(body)", path: nil), at: 0)
            case "image":
                title = "Copied image from \(who) — ⌘V to paste"
                recents.insert(Recent(title: "Image from \(who) (copied)", path: nil), at: 0)
            default:
                let names = items.compactMap { $0["name"] as? String }
                title = "Copied \(names.count) file\(names.count == 1 ? "" : "s") from \(who) — ⌘V in Finder"
                body = names.joined(separator: ", ")
                for it in items { recents.insert(Recent(title: it["name"] as? String ?? "file", path: it["path"] as? String), at: 0) }
            }
        } else {
            let names = items.compactMap { $0["name"] as? String }
            title = "Received \(names.count) file\(names.count == 1 ? "" : "s") from \(who)"
            body = names.joined(separator: ", ") + " — in Downloads"
            for it in items { recents.insert(Recent(title: it["name"] as? String ?? "file", path: it["path"] as? String), at: 0) }
        }
        recents = Array(recents.prefix(6))
        overlay.show("✓ " + title, sub: body, hideAfter: 4)
        notify(title, body)
    }

    func offerSummary() -> String {
        guard let o = offers.first else { return "" }
        return "\(o["from"] as? String ?? "?")'s rhythm (\(o["knocks"] as? Int ?? 0) knocks)"
    }

    // MARK: receive with the keyboard (⌃⌥K)

    func tapToReceive() {
        guard let agent = agent else {
            notify("Knockdrop", "Turn on “Receive by Knocking” first")
            return
        }
        receivingKeys = true
        agent.send(["cmd": "keys", "on": true])
        let who = offers.isEmpty ? "the sender's rhythm" : offerSummary()
        overlay.capture(title: "Tap \(who)", prompt: "on the space bar · Esc to cancel",
                        onCaptured: { [weak self] times in
                            self?.receivingKeys = false
                            self?.agent?.send(["cmd": "pattern", "times": times])
                        },
                        onCancel: { [weak self] in
                            self?.receivingKeys = false
                            self?.agent?.send(["cmd": "keys", "on": false])
                        })
    }

    // MARK: share

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
        guard !command.isEmpty else { return }
        if sender != nil {
            overlay.show("Already sharing", sub: "Stop the current share from the menu first", hideAfter: 3)
            return
        }
        if hasSensor {
            launchSender(pattern: nil, files: files)
        } else {
            overlay.capture(title: "Tap a rhythm to share with", prompt: "on the space bar · Esc to cancel",
                            onCaptured: { [weak self] t in self?.launchSender(pattern: t, files: files) },
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
        shareInfo = "Starting…"
        p.onEvent = { [weak self] e in self?.senderEvent(e) }
        p.onExit = { [weak self] _ in
            guard let self = self else { return }
            self.sender = nil
            self.shareInfo = nil
            self.updateIcon()
        }
        if p.start() { sender = p } else { shareInfo = nil }
        updateIcon()
    }

    @objc func stopShare() {
        sender?.stop()
        overlay.hide()
    }

    func senderEvent(_ e: [String: Any]) {
        switch e["event"] as? String ?? "" {
        case "sharing":
            shareInfo = "Sharing \(e["what"] as? String ?? "")"
        case "calibrating":
            overlay.show("Hands off for a second…", sub: shareInfo ?? "")
        case "knock_now":
            NSSound(named: "Pop")?.play()
            overlay.show("Knock a rhythm on the table", dots: "· · ·",
                         sub: "Teammates at your table get it automatically", hideAfter: 30)
        case "knock":
            NSSound(named: "Tink")?.play()
            overlay.show("Knock a rhythm on the table", dots: dotString(e["n"] as? Int ?? 1),
                         sub: "Mix short and long gaps", hideAfter: 30)
        case "pattern_rejected":
            NSSound(named: "Funk")?.play()
            overlay.show("Knock again", dots: "· · ·", sub: e["reason"] as? String ?? "", hideAfter: 30)
        case "waiting":
            let times = e["times"] as? [Double] ?? []
            shareRhythm = rhythmString(times)
            shareInfo = (shareInfo ?? "Sharing") + " — waiting"
            NSSound(named: "Pop")?.play()
            overlay.show("Shared for 5 minutes", dots: shareRhythm ?? "",
                         sub: "Your table gets it automatically. Anyone else: knock this rhythm.", hideAfter: 6)
            notify("Shared — knock \(shareRhythm ?? "")", "Others on your Wi-Fi can knock this rhythm to get it")
        case "sent":
            let who = e["who"] as? String ?? "someone"
            sharedWith.append(who)
            NSSound(named: "Glass")?.play()
            overlay.show("✓ \(who) got it", sub: "Still sharing — stop from the menu bar", hideAfter: 3)
        case "wrong":
            logLine("share: \(e["who"] as? String ?? "?") knocked a different rhythm")
        case "expired", "closed":
            notify("Knockdrop", "Your share \(e["event"] as? String == "expired" ? "expired" : "closed")")
        case "error":
            let msg = e["message"] as? String ?? "Couldn't share"
            NSSound(named: "Basso")?.play()
            overlay.show(msg, hideAfter: 4)
        default:
            break
        }
        updateIcon()
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let head = NSMenuItem(title: "Knockdrop" + (version.isEmpty ? "" : " \(version)"), action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        if appStale {
            menu.addItem(item("Restart to Finish Updating", #selector(finishUpdate)))
        }
        menu.addItem(.separator())

        menu.addItem(item("Receive by Knocking", #selector(toggleReceive), state: receiveOn))
        menu.addItem(info(receiveOn ? agentInfo : "Off — nothing is listening"))
        if hasSensor {
            menu.addItem(item("Auto-receive from My Table", #selector(toggleTable), state: tableOn, enabled: receiveOn))
            menu.addItem(info("Get what's knocked on your table, hands-free (uses the motion sensor continuously)"))
        }
        let keys = item("Tap Rhythm on Keyboard…", #selector(tapToReceiveAction), enabled: agent != nil)
        keys.keyEquivalent = "k"
        keys.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(keys)
        menu.addItem(.separator())

        if let s = shareInfo {
            menu.addItem(info(s))
            if let r = shareRhythm { menu.addItem(info("Rhythm: \(r)")) }
            if !sharedWith.isEmpty { menu.addItem(info("Got it: " + sharedWith.joined(separator: ", "))) }
            menu.addItem(item("Stop Sharing", #selector(stopShare)))
        } else {
            let clip = item("Share Clipboard", #selector(shareClipboardAction))
            clip.keyEquivalent = "c"
            clip.keyEquivalentModifierMask = [.control, .option]
            menu.addItem(clip)
            menu.addItem(item("Share Files…", #selector(shareFiles)))
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

    @objc func tapToReceiveAction() { tapToReceive() }
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

    func updateIcon() {
        guard let button = statusItem?.button else { return }
        let active = sender != nil || !offers.isEmpty
        let name = active ? "hand.tap.fill" : "hand.tap"
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: "Knockdrop")
            ?? NSImage(systemSymbolName: active ? "hand.raised.fill" : "hand.raised", accessibilityDescription: "Knockdrop") {
            img.isTemplate = true
            button.image = img
            button.title = ""
        } else {
            button.title = "👊"
        }
        button.appearsDisabled = !receiveOn && sender == nil
    }

    func notify(_ title: String, _ body: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "on run argv", "-e", "display notification (item 2 of argv) with title (item 1 of argv)",
                       "-e", "end run", title, body]
        try? p.run()
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

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
