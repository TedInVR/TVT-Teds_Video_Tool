import AppKit
import AVKit

final class ClipOrderMenu: NSPopUpButton {
    override func scrollWheel(with event: NSEvent) {}
}

final class VideoDropView: NSView {
    var receive: (([URL]) -> Bool)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                        options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return receive?(urls) ?? false
    }
}

final class ProtectionPreview: NSImageView {
    var protectionDrawingEnabled = false
    var boxes: [NSRect] = []
    var origin: NSPoint?
    var pending: NSRect?

    var picture: NSRect {
        guard let size = image?.size, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    func point(_ event: NSEvent) -> NSPoint {
        let current = convert(event.locationInWindow, from: nil)
        let area = picture
        return NSPoint(x: min(1, max(0, (current.x - area.minX) / area.width)),
                       y: min(1, max(0, (area.maxY - current.y) / area.height)))
    }

    override func mouseDown(with event: NSEvent) {
        guard protectionDrawingEnabled, boxes.count < 8, picture.width > 0,
              picture.contains(convert(event.locationInWindow, from: nil)) else { return }
        origin = point(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = origin else { return }
        let end = point(event)
        pending = NSRect(x: min(origin.x, end.x), y: min(origin.y, end.y),
                         width: abs(end.x - origin.x), height: abs(end.y - origin.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let pending = pending, pending.width >= 0.01, pending.height >= 0.01 { boxes.append(pending) }
        pending = nil
        origin = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard protectionDrawingEnabled else { return }
        let area = picture
        let rectangles = boxes + (pending.map { [$0] } ?? [])
        for box in rectangles {
            let rect = NSRect(x: area.minX + box.minX * area.width, y: area.maxY - box.maxY * area.height,
                              width: box.width * area.width, height: box.height * area.height)
            NSColor.systemYellow.withAlphaComponent(0.14).setFill()
            NSBezierPath(rect: rect).fill()
            NSColor.systemYellow.setStroke()
            let outline = NSBezierPath(rect: rect)
            outline.lineWidth = 2
            outline.stroke()
        }
    }
}

final class RestoreComparison: NSObject {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 510),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let playerView = AVPlayerView()
    let job: URL
    let source: URL
    weak var app: TVT?
    let editor: TrimEditor?

    init(app: TVT, job: URL, source: URL, editor: TrimEditor?) {
        self.app = app
        self.job = job
        self.source = source
        self.editor = editor
        super.init()
        window.title = "AI Restore — Compare Preview"
        let content = NSView()
        window.contentView = content
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14)
        ])
        let caption = NSTextField(labelWithString: "ORIGINAL (LEFT)                                RESTORED (RIGHT)")
        caption.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(caption)
        playerView.player = AVPlayer(url: job.appendingPathComponent("comparison.mp4"))
        playerView.controlsStyle = .inline
        playerView.widthAnchor.constraint(equalToConstant: 828).isActive = true
        playerView.heightAnchor.constraint(equalToConstant: 405).isActive = true
        stack.addArrangedSubview(playerView)
        stack.addArrangedSubview(NSStackView(views: [
            NSButton(title: "Save Restored Clip…", target: self, action: #selector(save)),
            NSButton(title: "Close", target: self, action: #selector(close))
        ]))
    }

    @objc func save() {
        guard let app = app else { return }
        let name = source.deletingPathExtension().lastPathComponent + " Restored Sample.mp4"
        guard let path = app.save(name, near: source) else { return }
        do {
            let destination = URL(fileURLWithPath: path)
            try FileManager.default.copyItem(at: job.appendingPathComponent("restored.mp4"), to: destination)
            app.result = destination
            app.revealButton.isHidden = false
            app.endProcessing("Finished. Your restored sample is ready.", success: true)
            close()
        } catch { app.alert("Could not save restored sample", error.localizedDescription) }
    }

    @objc func close() {
        playerView.player?.pause()
        playerView.player = nil
        try? FileManager.default.removeItem(at: job)
        app?.window.endSheet(window)
        app?.restoreComparison = nil
        if let app = app, let editor = editor {
            app.window.beginSheet(editor.window)
        }
    }
}

final class VideoOrderList: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var videos: [URL]
    let table = NSTableView()

    init(_ videos: [URL]) {
        self.videos = videos
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 260))
        for (identifier, title, width) in [("position", "#", 35.0), ("name", "Video", 340.0), ("folder", "Folder", 200.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = CGFloat(width)
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false
        table.rowHeight = 25
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 40, width: 600, height: 220))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = table
        addSubview(scroll)
        let controls = NSStackView(views: [
            NSButton(title: "Move Up", target: self, action: #selector(moveSelectedVideoUp)),
            NSButton(title: "Move Down", target: self, action: #selector(moveSelectedVideoDown))
        ])
        controls.frame = NSRect(x: 0, y: 0, width: 230, height: 30)
        addSubview(controls)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func numberOfRows(in tableView: NSTableView) -> Int { videos.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let video = videos[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "position": text = String(row + 1)
        case "folder": text = video.deletingLastPathComponent().path
        default: text = video.lastPathComponent
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = video.path
        return label
    }

    func move(_ offset: Int) {
        let row = table.selectedRow
        let destination = row + offset
        guard videos.indices.contains(row), videos.indices.contains(destination) else { return }
        videos.swapAt(row, destination)
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false)
        table.scrollRowToVisible(destination)
    }

    @objc func moveSelectedVideoUp() { move(-1) }
    @objc func moveSelectedVideoDown() { move(1) }
}

final class TrimRange: NSView {
    var start = 0.0
    var end = 1.0

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds.insetBy(dx: 7, dy: 3)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        let selection = NSRect(x: track.minX + track.width * start, y: track.minY,
                               width: track.width * max(0, end - start), height: track.height)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: selection, xRadius: 3, yRadius: 3).fill()
    }
}

final class TrimEditor: NSObject {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 810, height: 590),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let image = ProtectionPreview()
    let playerView = AVPlayerView()
    let player = AVPlayer()
    let playButton = NSButton(title: "Play", target: nil, action: nil)
    var playbackObserver: Any?
    var playbackEndObserver: NSObjectProtocol?
    var playbackStart = 0.0
    var playbackEnd = 0.0
    var preparingPlayback = false
    var playbackGeneration = 0
    let timeline = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    let times = NSTextField(labelWithString: "")
    let previewState = NSTextField(labelWithString: "Loading preview…")
    let range = TrimRange()
    let comparisonButton = NSButton(title: "Preview 5 Seconds…", target: nil, action: nil)
    let saveButton = NSButton(title: "Export Clip…", target: nil, action: nil)
    let source: URL
    let duration: Double
    let restoring: Bool
    let directory: URL
    weak var app: TVT?
    var start = 0.0
    var end: Double
    var requestedTime: Double?
    var previewInFlight = false
    var closed = false

    init(app: TVT, source: URL, duration: Double, restoring: Bool = false) throws {
        self.app = app
        self.source = source
        self.duration = duration
        self.restoring = restoring
        self.end = duration
        directory = app.development.appendingPathComponent("Trim-" + UUID().uuidString, isDirectory: true)
        super.init()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        window.title = (restoring ? "AI Restore — " : "Trim Clip — ") + source.lastPathComponent
        if restoring {
            window.setContentSize(NSSize(width: 810, height: 620))
            image.protectionDrawingEnabled = true
            saveButton.title = "Restore Selection…"
        }
        let content = NSView()
        window.contentView = content
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14)
        ])
        image.wantsLayer = true
        image.layer?.backgroundColor = NSColor.black.cgColor
        image.imageScaling = .scaleProportionallyUpOrDown
        image.widthAnchor.constraint(equalToConstant: 778).isActive = true
        image.heightAnchor.constraint(equalToConstant: 405).isActive = true
        let preview = NSView()
        preview.widthAnchor.constraint(equalToConstant: 778).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 405).isActive = true
        image.frame = NSRect(x: 0, y: 0, width: 778, height: 405)
        preview.addSubview(image)
        playerView.frame = NSRect(x: 0, y: 0, width: 778, height: 405)
        playerView.player = player
        playerView.controlsStyle = .none
        playerView.isHidden = true
        preview.addSubview(playerView)
        stack.addArrangedSubview(preview)
        playButton.target = self
        playButton.action = #selector(togglePlayback)
        playButton.keyEquivalent = " "
        let volume = NSSlider(value: 1, minValue: 0, maxValue: 1, target: self, action: #selector(changeVolume(_:)))
        volume.widthAnchor.constraint(equalToConstant: 100).isActive = true
        stack.addArrangedSubview(NSStackView(views: [
            playButton, NSTextField(labelWithString: "Volume"), volume
        ]))
        window.setContentSize(NSSize(width: 810, height: restoring ? 655 : 625))
        playbackObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
                                                          queue: .main) { [weak self] time in
            guard let self = self, !self.closed, self.player.rate > 0, time.seconds.isFinite else { return }
            self.timeline.doubleValue = min(self.duration, self.playbackStart + time.seconds)
            self.updateTimes()
            self.previewState.stringValue = "Playing at " + self.timeText(self.timeline.doubleValue)
            if self.timeline.doubleValue >= self.playbackEnd - 0.08 {
                self.pausePlayback()
                self.previewState.stringValue = "Playback paused. Press Play to continue."
            }
        }
        playbackEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                                     object: nil, queue: .main) { [weak self] note in
            guard let self = self, let item = note.object as? AVPlayerItem,
                  item === self.player.currentItem, !self.closed else { return }
            self.timeline.doubleValue = self.playbackEnd
            self.pausePlayback()
            self.previewState.stringValue = "Playback paused. Press Play to continue."
        }
        stack.addArrangedSubview(previewState)
        timeline.maxValue = duration
        timeline.isContinuous = true
        timeline.target = self
        timeline.action = #selector(scrub)
        timeline.widthAnchor.constraint(equalToConstant: 778).isActive = true
        stack.addArrangedSubview(timeline)
        range.widthAnchor.constraint(equalToConstant: 778).isActive = true
        range.heightAnchor.constraint(equalToConstant: 12).isActive = true
        stack.addArrangedSubview(range)
        stack.addArrangedSubview(times)
        saveButton.target = self
        saveButton.action = #selector(saveSelection)
        let controls = NSStackView(views: [
            NSButton(title: "−0.1 s", target: self, action: #selector(back)),
            NSButton(title: "+0.1 s", target: self, action: #selector(forward)),
            NSButton(title: "Mark Start", target: self, action: #selector(markStart)),
            NSButton(title: "Mark End", target: self, action: #selector(markEnd)),
            saveButton, NSButton(title: "Cancel", target: self, action: #selector(cancel))
        ])
        if restoring {
            controls.insertArrangedSubview(NSButton(title: "Clear Boxes", target: self, action: #selector(clearBoxes)), at: 4)
            comparisonButton.target = self
            comparisonButton.action = #selector(compareSelection)
            controls.insertArrangedSubview(comparisonButton, at: 5)
        }
        stack.addArrangedSubview(controls)
        if restoring {
            stack.addArrangedSubview(NSTextField(labelWithString: "Restore the whole video or mark a shorter range. Draw boxes around areas to protect."))
        }
        updateTimes()
    }

    func timeText(_ seconds: Double) -> String {
        let ms = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3600000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
    }

    func updateTimes() {
        times.stringValue = "Position  \(timeText(timeline.doubleValue))     Start  \(timeText(start))     End  \(timeText(end))"
        range.start = start / duration
        range.end = end / duration
        range.needsDisplay = true
        saveButton.isEnabled = end > start
        comparisonButton.isEnabled = end > start
    }

    @objc func scrub() {
        let position = timeline.doubleValue
        pausePlayback()
        timeline.doubleValue = position
        playerView.isHidden = true
        updateTimes()
        requestedTime = min(timeline.doubleValue, max(0, duration - 0.15))
        loadPreview()
    }

    @objc func changeVolume(_ sender: NSSlider) { player.volume = Float(sender.doubleValue) }

    func pausePlayback() {
        if player.rate > 0 {
            let current = player.currentTime().seconds
            if current.isFinite { timeline.doubleValue = min(duration, playbackStart + current) }
        }
        player.pause()
        playButton.title = "Play"
        updateTimes()
    }

    @objc func togglePlayback() {
        guard !closed, !preparingPlayback, let app = app else { return }
        if player.rate > 0 { pausePlayback(); return }
        let position = timeline.doubleValue >= duration - 0.05 ? 0 : timeline.doubleValue
        timeline.doubleValue = position
        if player.currentItem != nil, position >= playbackStart, position < playbackEnd - 0.1 {
            playerView.isHidden = false
            player.seek(to: CMTime(seconds: position - playbackStart, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
            playButton.title = "Pause"
            return
        }
        preparingPlayback = true
        playbackGeneration += 1
        let generation = playbackGeneration
        let path = directory.appendingPathComponent("playback-\(generation).mp4")
        previewState.stringValue = "Preparing playback with sound…"
        playButton.isEnabled = false
        app.execute(app.resources.appendingPathComponent("engine.sh"),
                    ["playback-preview", app.mediaTime(position), source.path, path.path]) { success, detail in
            self.preparingPlayback = false
            self.playButton.isEnabled = true
            guard !self.closed else {
                try? FileManager.default.removeItem(at: self.directory)
                return
            }
            guard success else {
                self.previewState.stringValue = "Could not prepare playback."
                app.alert("Playback unavailable", String(detail.suffix(2400)))
                return
            }
            self.playbackStart = position
            self.playbackEnd = min(self.duration, position + 60)
            self.player.replaceCurrentItem(with: AVPlayerItem(url: path))
            // A scrub during preparation keeps its requested position.
            if abs(self.timeline.doubleValue - position) > 0.15 {
                self.previewState.stringValue = "Position changed. Press Play when ready."
                return
            }
            self.playerView.isHidden = false
            self.player.play()
            self.playButton.title = "Pause"
        }
    }

    func loadPreview() {
        guard !closed, !previewInFlight, let time = requestedTime, let app = app else { return }
        requestedTime = nil
        previewInFlight = true
        previewState.stringValue = "Finding preview frame…"
        let path = directory.appendingPathComponent("frame.png")
        let args = ["preview", app.mediaTime(time), source.path, path.path]
        app.execute(app.resources.appendingPathComponent("engine.sh"), args) { success, _ in
            self.previewInFlight = false
            if self.closed {
                guard !self.preparingPlayback else { return }
                try? FileManager.default.removeItem(at: self.directory)
                return
            }
            if success, let data = try? Data(contentsOf: path), let frame = NSImage(data: data) {
                self.image.image = frame
                self.previewState.stringValue = "Preview at " + self.timeText(time)
            } else {
                self.previewState.stringValue = "No frame at this position. Scrub to a different time."
            }
            self.loadPreview()
        }
    }

    @objc func back() { timeline.doubleValue = max(0, timeline.doubleValue - 0.1); scrub() }
    @objc func forward() { timeline.doubleValue = min(duration, timeline.doubleValue + 0.1); scrub() }
    @objc func clearBoxes() { image.boxes = []; image.needsDisplay = true }
    @objc func markStart() {
        pausePlayback()
        start = timeline.doubleValue
        updateTimes()
    }
    @objc func markEnd() { pausePlayback(); end = timeline.doubleValue; updateTimes() }
    @objc func cancel() { finish() }

    @objc func saveSelection() {
        guard let app = app, end > start else { return }
        if restoring {
            restoreSelection(preview: false)
            return
        }
        let profiles = app.conversionProfiles()
        guard !profiles.isEmpty,
              let choice = app.chooseOption("Export Clip", profiles.map { $0[1] },
                                            detail: "Exports the primary video and all audio tracks.", selected: 1) else { return }
        let format = profiles[choice][0]
        let name = source.deletingPathExtension().lastPathComponent + " Clip." + format
        guard let destination = app.save(name, near: source, fileExtension: format) else { return }
        finish()
        app.export(["trim", format, source.path, destination, app.mediaTime(start), app.mediaTime(end)])
    }

    @objc func compareSelection() {
        restoreSelection(preview: true)
    }

    func restoreSelection(preview: Bool) {
        pausePlayback()
        playerView.isHidden = true
        guard let app = app, end > start else { return }
        let length = preview ? min(5, end - start) : end - start
        let warning = preview
            ? "This preview processes up to five seconds. SeedVR2 can slow down other apps while it runs. The first run may also download the model."
            : "Selected video time: \(timeText(length)). On an M2 Max, a real-world test suggested that restoring an hour of video could take roughly a week. Actual time varies. AI Restore can heavily load your Mac and interrupt playback in apps such as Shield3D. Use Preview 5 Seconds first if you want to check the result."
        guard app.alert(preview ? "Run AI Restore Preview?" : "AI Restore Can Take Days", warning,
                        ["Cancel", preview ? "Run Preview" : "Proceed with Restoration"]) == 1 else { return }
        guard let level = app.chooseOption("AI cleanup strength", ["Gentle", "Balanced", "Strong"],
                                           detail: "Deep shadows and boxed areas keep source detail. Boxes stay fixed across the selected range.") else { return }
        var destination: String?
        if !preview {
            let name = source.deletingPathExtension().lastPathComponent + " Restored.mp4"
            guard let path = app.save(name, near: source) else { return }
            destination = path
        }
        let masks = image.boxes.map { [$0.minX, $0.minY, $0.maxX, $0.maxY].map { app.mediaTime(Double($0)) }.joined(separator: ",") }
        if !preview { finish() }
        app.runRestore(source, start: start, length: length,
                       strength: ["gentle", "balanced", "strong"][level], boxes: masks, destination: destination,
                       editor: preview ? self : nil)
    }

    func finish() {
        closed = true
        player.pause()
        if let observer = playbackObserver { player.removeTimeObserver(observer); playbackObserver = nil }
        if let observer = playbackEndObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackEndObserver = nil
        }
        player.replaceCurrentItem(with: nil)
        if !previewInFlight && !preparingPlayback { try? FileManager.default.removeItem(at: directory) }
        app?.window.endSheet(window)
        app?.trimEditor = nil
    }
}

final class TVT: NSObject, NSApplicationDelegate {
    let resources = Bundle.main.resourceURL!
    let development = URL(fileURLWithPath: "/Applications/VFLR Development", isDirectory: true)
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    var window: NSWindow!
    var status: NSTextField!
    var banner: NSView!
    var sourcesLabel: NSTextField!
    var browseButton: NSButton!
    var clearButton: NSButton!
    var revealButton: NSButton!
    var sources: [URL] = []
    var result: URL?
    var pulseTimer: Timer?
    var operations: [NSButton] = []
    var processing = false
    var checking = false
    var queued = false
    var timer: Timer?
    var reportWindow: NSWindow?
    var trimEditor: TrimEditor?
    var restoreComparison: RestoreComparison?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if FileManager.default.fileExists(atPath: development.appendingPathComponent(".install-lock").path) {
            NSApp.terminate(nil)
            return
        }
        let menu = NSMenu()
        let app = NSMenuItem()
        menu.addItem(app)
        app.submenu = NSMenu(title: "Ted's Video Tool")
        app.submenu?.addItem(withTitle: "About Ted's Video Tool", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        if let item = app.submenu?.addItem(withTitle: "Replace Videos and Move Originals to Trash",
                                           action: #selector(toggleVideoReplacement(_:)), keyEquivalent: "") {
            item.target = self
            item.state = replacesVideos ? .on : .off
        }
        app.submenu?.addItem(.separator())
        app.submenu?.addItem(withTitle: "Quit Ted's Video Tool", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = NSMenuItem()
        menu.addItem(edit)
        edit.submenu = NSMenu(title: "Edit")
        edit.submenu?.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.submenu?.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.submenu?.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.submenu?.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenu = NSMenuItem()
        menu.addItem(windowMenu)
        windowMenu.submenu = NSMenu(title: "Window")
        windowMenu.submenu?.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let help = NSMenuItem()
        menu.addItem(help)
        help.submenu = NSMenu(title: "Help")
        for (title, action) in [("TVT User Guide", #selector(showGuide)), ("Check for Updates…", #selector(checkManually))] {
            let item = help.submenu!.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        NSApp.mainMenu = menu
        NSApp.helpMenu = help.submenu

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 487),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Ted's Video Tool"
        window.isReleasedWhenClosed = false
        let dropView = VideoDropView()
        dropView.registerForDraggedTypes([.fileURL])
        dropView.receive = { [weak self] in self?.loadSources($0) ?? false }
        window.contentView = dropView

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        dropView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: dropView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: dropView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: dropView.topAnchor, constant: 16)
        ])

        let badge = NSImageView()
        if let logo = NSImage(contentsOf: resources.appendingPathComponent("TVT.png")) {
            badge.image = logo
            NSApp.applicationIconImage = logo
        }
        badge.imageScaling = .scaleProportionallyUpOrDown
        badge.setAccessibilityLabel("TVT")
        badge.widthAnchor.constraint(equalToConstant: 46).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 46).isActive = true

        let title = NSTextField(labelWithString: "Ted's Video Tool")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "for 2D, 3D, and VR")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 1
        let header = NSStackView(views: [badge, heading])
        header.spacing = 12
        header.alignment = .centerY
        stack.addArrangedSubview(header)
        sourcesLabel = NSTextField(labelWithString: "Drop videos here, or browse for files.")
        sourcesLabel.lineBreakMode = .byTruncatingMiddle
        sourcesLabel.widthAnchor.constraint(equalToConstant: 395).isActive = true
        browseButton = NSButton(title: "Browse…", target: self, action: #selector(browseSources))
        clearButton = NSButton(title: "Clear", target: self, action: #selector(clearSources))
        clearButton.isEnabled = false
        let sourcesRow = NSStackView(views: [sourcesLabel, browseButton, clearButton])
        stack.addArrangedSubview(sourcesRow)

        let editing = toolGroup("Edit and Assemble", [
            ("Trim Clip", #selector(trimClip)), ("Split Movie", #selector(split)),
            ("Join Parts", #selector(join)), ("Link Videos", #selector(link)),
            ("Import Disc Backup", #selector(importDiscBackup))
        ])
        let picture = toolGroup("Picture and Format", [
            ("Upscale Video", #selector(upscale)), ("Convert Video", #selector(convertVideo)),
            ("Change Aspect or Stereo Layout", #selector(changeLayout)), ("AI Restore", #selector(restoreClip))
        ])
        let tracks = toolGroup("Audio and Subtitles", [
            ("Extract or Remove Audio", #selector(audioTools)), ("Add Subtitles", #selector(addSubtitles))
        ])
        let other = toolGroup("Inspect and Download", [
            ("MediaInfo", #selector(inspectMedia)), ("Download Online", #selector(downloadOnline))
        ])
        for pair in [[editing, picture], [tracks, other]] {
            let row = NSStackView(views: pair)
            row.spacing = 12
            row.alignment = .top
            stack.addArrangedSubview(row)
        }

        banner = NSView()
        banner.wantsLayer = true
        banner.layer?.cornerRadius = 7
        banner.widthAnchor.constraint(equalToConstant: 580).isActive = true
        banner.heightAnchor.constraint(equalToConstant: 44).isActive = true
        status = NSTextField(labelWithString: "")
        status.textColor = NSColor(calibratedWhite: 0.14, alpha: 1)
        status.lineBreakMode = .byTruncatingMiddle
        revealButton = NSButton(title: "Show Result", target: self, action: #selector(revealResult))
        revealButton.isHidden = true
        let bannerRow = NSStackView(views: [status, revealButton])
        bannerRow.translatesAutoresizingMaskIntoConstraints = false
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        banner.addSubview(bannerRow)
        NSLayoutConstraint.activate([
            bannerRow.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 12),
            bannerRow.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -12),
            bannerRow.centerYAnchor.constraint(equalTo: banner.centerYAnchor)
        ])
        stack.addArrangedSubview(banner)
        setBanner("Ready. Drop a video or choose a tool.", color: NSColor(calibratedWhite: 0.92, alpha: 1))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            self?.checkUpdate(manual: false)
        }
        checkUpdate(manual: false)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard !processing, !queued, !filenames.isEmpty else { sender.reply(toOpenOrPrint: .failure); return }
        sender.reply(toOpenOrPrint: .success)
        DispatchQueue.main.async {
            if self.loadSources(filenames.map { URL(fileURLWithPath: $0) }) {
                self.window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func toolGroup(_ title: String, _ tools: [(String, Selector)]) -> NSBox {
        let box = NSBox()
        box.title = title
        box.contentViewMargins = NSSize(width: 8, height: 7)
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        box.contentView = list
        box.widthAnchor.constraint(equalToConstant: 284).isActive = true
        box.heightAnchor.constraint(equalToConstant: CGFloat(34 + tools.count * 27)).isActive = true
        for (name, action) in tools {
            let button = NSButton(title: name, target: self, action: action)
            button.bezelStyle = .rounded
            button.widthAnchor.constraint(equalToConstant: 250).isActive = true
            list.addArrangedSubview(button)
            operations.append(button)
        }
        return box
    }

    @discardableResult func loadSources(_ urls: [URL]) -> Bool {
        guard !processing, !queued, trimEditor == nil, restoreComparison == nil else { return false }
        var seen: Set<URL> = []
        let valid = urls.map { $0.standardizedFileURL }.filter {
            guard $0.isFileURL, seen.insert($0).inserted else { return false }
            guard let info = try? $0.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]) else { return false }
            return info.isRegularFile == true || info.isDirectory == true
        }
        guard !valid.isEmpty else { return false }
        sources = valid
        sourcesLabel.stringValue = valid.count == 1 ? valid[0].lastPathComponent : "\(valid.count) files loaded"
        sourcesLabel.toolTip = valid.map { $0.path }.joined(separator: "\n")
        clearButton.isEnabled = true
        return true
    }

    @objc func browseSources() {
        if let picked = files("Choose one or more source files.", multiple: true) { loadSources(picked) }
    }

    @objc func clearSources() {
        sources = []
        sourcesLabel.stringValue = "Drop videos here, or browse for files."
        sourcesLabel.toolTip = nil
        clearButton.isEnabled = false
    }

    func sourceFiles(_ prompt: String, multiple: Bool) -> [URL]? {
        if sources.isEmpty { return files(prompt, multiple: multiple) }
        if multiple {
            if sources.count >= 2 { return sources }
            guard let extras = files("Choose additional files to go with \(sources[0].lastPathComponent).",
                                     multiple: true, directory: sources[0].deletingLastPathComponent()) else { return nil }
            return sources + extras.filter { $0.standardizedFileURL != sources[0] }
        }
        if sources.count == 1 { return sources }
        let labels = sources.enumerated().map { "\($0.offset + 1). \($0.element.lastPathComponent)" }
        guard let choice = chooseOption("Choose a loaded file", labels) else { return nil }
        return [sources[choice]]
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if trimEditor != nil || restoreComparison != nil {
            return .terminateCancel
        }
        if processing {
            alert("Processing in progress", "Wait for the current operation to finish before quitting.")
            return .terminateCancel
        }
        if checking {
            alert("Update check in progress", "Wait for the current update check to finish before quitting.")
            return .terminateCancel
        }
        return .terminateNow
    }

    @discardableResult func alert(_ title: String, _ detail: String, _ buttons: [String] = ["OK"]) -> Int {
        let dialog = NSAlert()
        dialog.messageText = title
        dialog.informativeText = detail
        buttons.forEach { dialog.addButton(withTitle: $0) }
        return dialog.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    func files(_ prompt: String, multiple: Bool, directory: URL? = nil, allowFolders: Bool = false) -> [URL]? {
        let panel = NSOpenPanel()
        panel.message = prompt
        panel.directoryURL = directory
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = allowFolders
        return panel.runModal() == .OK ? panel.urls : nil
    }

    func save(_ name: String, near source: URL, fileExtension: String = "mp4") -> String? {
        let panel = NSSavePanel()
        panel.directoryURL = source.deletingLastPathComponent()
        panel.nameFieldStringValue = name
        panel.allowedFileTypes = [fileExtension]
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    var replacesVideos: Bool {
        UserDefaults.standard.object(forKey: "ReplaceVideos") as? Bool ?? true
    }

    @objc func toggleVideoReplacement(_ item: NSMenuItem) {
        let enabled = !replacesVideos
        UserDefaults.standard.set(enabled, forKey: "ReplaceVideos")
        item.state = enabled ? .on : .off
    }

    struct VideoReplacement {
        let source: URL
        let original: NSDictionary

        init(_ source: URL) throws {
            self.source = source
            original = try Self.identity(source)
        }

        private static func identity(_ url: URL) throws -> NSDictionary {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let file = attributes[.systemFileNumber], let device = attributes[.systemNumber],
                  let size = attributes[.size], let modified = attributes[.modificationDate] else {
                throw NSError(domain: "TVT", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Only regular files can be replaced."
                ])
            }
            return ["file": file, "device": device, "size": size, "modified": modified]
        }

        func install(_ output: URL) throws -> URL {
            let manager = FileManager.default
            let sameExtension = source.pathExtension.caseInsensitiveCompare(output.pathExtension) == .orderedSame
            let final = sameExtension ? source : source.deletingPathExtension().appendingPathExtension(output.pathExtension)
            let outputAttributes = try manager.attributesOfItem(atPath: output.path)
            guard try Self.identity(source).isEqual(original), output != source,
                  outputAttributes[.type] as? FileAttributeType == .typeRegular,
                  let size = outputAttributes[.size] as? NSNumber,
                  size.int64Value > 0 else {
                throw NSError(domain: "TVT", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "The source changed during processing or the new file is empty."
                ])
            }
            if !sameExtension {
                // Publish the new extension before touching the original. A name collision fails here.
                try manager.moveItem(at: output, to: final)
                do { try manager.trashItem(at: source, resultingItemURL: nil) }
                catch {
                    if (try? manager.moveItem(at: final, to: output)) == nil {
                        throw NSError(domain: "TVT", code: 3, userInfo: [
                            NSLocalizedDescriptionKey: "The original could not be moved to Trash. The new file is at \(final.path)."
                        ])
                    }
                    throw error
                }
                return final
            }
            var trashed: NSURL?
            try manager.trashItem(at: source, resultingItemURL: &trashed)
            do { try manager.moveItem(at: output, to: final) }
            catch {
                if let trashed = trashed { try? manager.moveItem(at: trashed as URL, to: source) }
                throw error
            }
            return final
        }
    }

    func exportVideo(_ arguments: [String], source: URL, name: String, fileExtension ext: String,
                     outputIndex: Int? = nil) {
        let replacement: VideoReplacement?
        let output: String
        if replacesVideos {
            do { replacement = try VideoReplacement(source) }
            catch {
                alert("Could not prepare video replacement", error.localizedDescription)
                return
            }
            output = source.deletingLastPathComponent()
                .appendingPathComponent("TVT Pending " + UUID().uuidString)
                .appendingPathExtension(ext).path
        } else {
            replacement = nil
            guard let path = save(name, near: source, fileExtension: ext) else { return }
            output = path
        }
        var job = arguments
        job.insert(output, at: outputIndex ?? job.count)
        export(job, replacement: replacement)
    }

    func execute(_ script: URL, _ arguments: [String], progressFile: URL? = nil, done: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: script.pathExtension == "py" ? "/usr/bin/python3" : "/bin/bash")
            task.arguments = [script.path] + arguments
            if script.pathExtension == "py" || progressFile != nil {
                var environment = ProcessInfo.processInfo.environment
                if script.pathExtension == "py" {
                    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
                }
                if let progressFile = progressFile { environment["TVT_PROGRESS_FILE"] = progressFile.path }
                task.environment = environment
            }
            task.standardOutput = pipe
            task.standardError = pipe
            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
                DispatchQueue.main.async { done(task.terminationStatus == 0, output) }
            } catch {
                DispatchQueue.main.async { done(false, error.localizedDescription) }
            }
        }
    }

    func setBanner(_ message: String, color: NSColor) {
        status.stringValue = message
        banner.layer?.backgroundColor = color.cgColor
    }

    func beginProcessing(_ message: String) {
        processing = true
        result = nil
        revealButton.isHidden = true
        operations.forEach { $0.isEnabled = false }
        browseButton.isEnabled = false
        clearButton.isEnabled = false
        let start = ProcessInfo.processInfo.systemUptime
        setBanner(message, color: NSColor(red: 0.78, green: 0.88, blue: 1, alpha: 1))
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let pulse = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                let phase = CGFloat((1 - cos(elapsed * 3)) / 2)
                self?.banner.layer?.backgroundColor = NSColor(red: 0.78 - phase * 0.20,
                                                               green: 0.88 - phase * 0.10, blue: 1, alpha: 1).cgColor
            }
            RunLoop.main.add(pulse, forMode: .common)
            pulseTimer = pulse
        }
    }

    func endProcessing(_ message: String, success: Bool) {
        pulseTimer?.invalidate()
        pulseTimer = nil
        processing = false
        operations.forEach { $0.isEnabled = !queued }
        browseButton.isEnabled = !queued
        clearButton.isEnabled = !queued && !sources.isEmpty
        let color = success ? NSColor(red: 0.79, green: 0.93, blue: 0.82, alpha: 1)
                            : NSColor(red: 1, green: 0.83, blue: 0.82, alpha: 1)
        setBanner(message, color: color)
    }

    @objc func revealResult() {
        if let result = result { NSWorkspace.shared.activateFileViewerSelecting([result]) }
    }

    func executeWithProgress(_ script: URL, _ arguments: [String], label: String,
                             done: @escaping (Bool, String) -> Void) {
        status.stringValue = label
        let progress = FileManager.default.temporaryDirectory.appendingPathComponent("TVT-" + UUID().uuidString)
        let duration = progress.appendingPathExtension("duration")
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let durationText = try? String(contentsOf: duration, encoding: .utf8),
                  let seconds = Double(durationText.trimmingCharacters(in: .whitespacesAndNewlines)), seconds > 0,
                  let handle = try? FileHandle(forReadingFrom: progress) else { return }
            defer { try? handle.close() }
            guard let size = try? handle.seekToEnd() else { return }
            do { try handle.seek(toOffset: size > 4096 ? size - 4096 : 0) } catch { return }
            guard let data = try? handle.read(upToCount: 4096) else { return }
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            let time = lines.dropLast().last { $0.hasPrefix("out_time_us=") }
            guard let time = time, let microseconds = Double(time.dropFirst("out_time_us=".count)),
                  microseconds.isFinite else { return }
            let percent = Int(min(99, max(0, 100 * microseconds / (seconds * 1_000_000))))
            self?.status.stringValue = "\(percent)% · " + label
        }
        RunLoop.main.add(timer, forMode: .common)
        execute(script, arguments, progressFile: progress) { success, output in
            timer.invalidate()
            try? FileManager.default.removeItem(at: progress)
            try? FileManager.default.removeItem(at: duration)
            done(success, output)
        }
    }

    func export(_ arguments: [String], replacement: VideoReplacement? = nil) {
        guard !processing, !queued else { return }
        let messages = ["split": "Splitting movie", "join": "Joining parts", "link": "Linking videos",
                        "upscale": "Upscaling video", "convert": "Converting video", "download": "Downloading media",
                        "audio": "Processing audio", "subtitles": "Preparing subtitles", "layout": "Changing video layout",
                        "trim": "Exporting selected clip"]
        let operation = arguments[0]
        let activity = messages[operation] ?? "Processing"
        let progressModes = ["upscale", "convert", "audio", "layout", "trim"]
        let label = progressModes.contains(operation)
            ? activity + " · " + URL(fileURLWithPath: arguments[operation == "layout" ? 3 : 2]).lastPathComponent
            : activity + "… Please wait."
        beginProcessing(label)
        let script = resources.appendingPathComponent("engine.sh")
        let finished: (Bool, String) -> Void = { success, output in
            let finished = success && !output.isEmpty
            self.endProcessing(finished ? "Finished. Your result is ready." : "Processing failed.", success: finished)
            if finished {
                let rendered = URL(fileURLWithPath: output)
                do {
                    self.result = try replacement?.install(rendered) ?? rendered
                    if let replacement = replacement, self.sources.contains(replacement.source) {
                        let updated = self.sources.map { $0 == replacement.source ? self.result ?? rendered : $0 }
                        self.loadSources(updated)
                    }
                    self.revealButton.isHidden = false
                } catch {
                    self.endProcessing("Video saved. Replacement could not finish.", success: false)
                    if FileManager.default.fileExists(atPath: rendered.path) {
                        self.result = rendered
                        self.revealButton.isHidden = false
                    }
                    self.alert("Could not replace the original",
                               error.localizedDescription + "\n\nCheck the output folder and Trash. Pending output: " + rendered.path)
                }
            } else {
                self.alert("Processing failed", output.isEmpty ? "No result was created." : String(output.suffix(4000)))
            }
        }
        if progressModes.contains(operation) { executeWithProgress(script, arguments, label: label, done: finished) }
        else { execute(script, arguments, done: finished) }
    }

    func batchSources() -> [URL]? {
        let selected: [URL]
        if sources.isEmpty {
            guard let picked = files("Choose one or more source videos.", multiple: true) else { return nil }
            selected = picked
        } else {
            selected = sources
        }
        let videos = selected.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        if videos.count != selected.count {
            alert("Choose individual video files", "Disc backup folders use Import Disc Backup.")
            return nil
        }
        return videos.isEmpty ? nil : videos
    }

    func batchExport(_ operation: String, setting: String, videos: [URL]) {
        guard !processing, !queued else { return }
        let replace = replacesVideos && (operation != "audio" || ["silent", "english"].contains(setting))
        let folder: URL
        if replace {
            folder = videos[0].deletingLastPathComponent()
        } else {
            let panel = NSOpenPanel()
            panel.message = "Choose one folder for all \(videos.count) outputs."
            panel.prompt = "Start Batch"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.directoryURL = videos[0].deletingLastPathComponent()
            guard panel.runModal() == .OK, let selected = panel.url else { return }
            folder = selected
        }
        let script = resources.appendingPathComponent("engine.sh")
        var failures: [String] = []
        var installed: [URL: URL] = [:]
        beginProcessing("Preparing batch…")

        func next(_ index: Int) {
            if index == videos.count {
                let completed = videos.count - failures.count
                self.endProcessing("Batch finished. \(completed) of \(videos.count) completed.", success: failures.isEmpty)
                if !installed.isEmpty, !self.sources.isEmpty {
                    self.loadSources(self.sources.map { installed[$0] ?? $0 })
                }
                if completed > 0 {
                    self.result = videos.compactMap { installed[$0] }.first?.deletingLastPathComponent() ?? folder
                    self.revealButton.isHidden = false
                }
                if !failures.isEmpty {
                    self.alert("Batch finished with errors", failures.prefix(6).joined(separator: "\n\n")
                               + (failures.count > 6 ? "\n\n… and \(failures.count - 6) more." : ""))
                }
                return
            }
            let video = videos[index]
            let label = "Video \(index + 1) of \(videos.count) · \(video.lastPathComponent)"
            let replacement: VideoReplacement?
            do { replacement = replace ? try VideoReplacement(video) : nil }
            catch {
                failures.append(video.lastPathComponent + ": " + error.localizedDescription)
                DispatchQueue.main.async { next(index + 1) }
                return
            }
            let directory = replace ? video.deletingLastPathComponent() : folder
            self.executeWithProgress(script, ["batch-item", operation, setting, video.path, directory.path], label: label) { success, output in
                if !success || output.isEmpty {
                    failures.append(video.lastPathComponent + ": " + String(output.suffix(350)))
                } else if let replacement = replacement {
                    do { installed[video] = try replacement.install(URL(fileURLWithPath: output)) }
                    catch { failures.append(video.lastPathComponent + ": " + error.localizedDescription + "\nOutput: " + output) }
                }
                next(index + 1)
            }
        }
        next(0)
    }

    func mediaTime(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    @objc func trimClip() {
        guard let source = sourceFiles("Choose the video to trim.", multiple: false)?.first else { return }
        openEditor(source, restoring: false)
    }

    func openEditor(_ source: URL, restoring: Bool) {
        beginProcessing(restoring ? "Opening restoration editor… Please wait." : "Opening trim editor… Please wait.")
        execute(resources.appendingPathComponent("engine.sh"), ["duration", source.path]) { success, output in
            guard success, let duration = Double(output), duration.isFinite, duration > 0 else {
                self.endProcessing("Could not open trim editor.", success: false)
                self.alert("Cannot trim this video", output)
                return
            }
            do {
                let editor = try TrimEditor(app: self, source: source, duration: duration, restoring: restoring)
                self.endProcessing(restoring ? "Restoration editor ready." : "Trim editor ready.", success: true)
                self.trimEditor = editor
                self.window.beginSheet(editor.window)
                editor.scrub()
            } catch {
                self.endProcessing("Could not open trim editor.", success: false)
                self.alert("Cannot open trim editor", error.localizedDescription)
            }
        }
    }

    @objc func restoreClip() {
        #if arch(arm64)
        guard let source = sourceFiles("Choose a video to restore.", multiple: false)?.first else { return }
        let script = resources.appendingPathComponent("restore.sh")
        execute(script, [development.path, "ready"]) { ready, _ in
            guard !self.processing, !self.queued, self.trimEditor == nil, self.restoreComparison == nil else { return }
            if ready {
                self.openEditor(source, restoring: true)
            } else if self.alert("Install AI Engine?",
                                 "TVT will install SeedVR2 3B under Applications. The first restoration downloads several gigabytes of model files. Restoration runs on this Mac.",
                                 ["Install AI Engine", "Cancel"]) == 0 {
                self.beginProcessing("Installing AI engine… Please wait.")
                self.execute(script, [self.development.path, "setup"]) { success, detail in
                    self.endProcessing(success ? "AI engine installed." : "AI engine setup failed.", success: success)
                    if success { self.openEditor(source, restoring: true) }
                    else { self.alert("Could not install AI engine", detail.isEmpty ? "See the TVT User Guide for setup." : detail) }
                }
            }
        }
        #else
        alert("Apple Silicon required", "AI Restore uses the GPU in Apple Silicon Macs.")
        #endif
    }

    func runRestore(_ source: URL, start: Double, length: Double, strength: String, boxes: [String],
                    destination: String?, editor: TrimEditor?) {
        let job = development.appendingPathComponent("Restoration-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        } catch { alert("Could not open restoration workspace", error.localizedDescription); return }
        if let editor = editor { window.endSheet(editor.window) }
        let preview = destination == nil
        let filename = source.lastPathComponent
        beginProcessing("Preparing AI Restore… · " + filename)
        let progressFile = job.appendingPathComponent("status")
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let raw = try? String(contentsOf: progressFile, encoding: .utf8) else { return }
            let stage = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stage.isEmpty { self?.status.stringValue = stage + " · " + filename }
        }
        RunLoop.main.add(timer, forMode: .common)
        let script = resources.appendingPathComponent("restore.sh")
        var args = [development.path, preview ? "preview" : "export", source.path, job.path,
                    mediaTime(start), mediaTime(length), strength]
        if let destination = destination { args.append(destination) }
        execute(script, args + boxes) { success, detail in
            timer.invalidate()
            if success && preview {
                self.endProcessing("Restored preview ready.", success: true)
                let comparison = RestoreComparison(app: self, job: job, source: source, editor: editor)
                self.restoreComparison = comparison
                self.window.beginSheet(comparison.window)
            } else {
                try? FileManager.default.removeItem(at: job)
                self.endProcessing(success ? "Finished. Your restored video is ready." : "Restoration failed.", success: success)
                if success, let destination = destination {
                    self.result = URL(fileURLWithPath: destination)
                    self.revealButton.isHidden = false
                } else {
                    self.alert("AI restoration failed", detail.isEmpty ? "The model did not create a result." : detail)
                    if let editor = editor { self.window.beginSheet(editor.window) }
                }
            }
        }
    }

    struct DiscTitle: Decodable {
        let id: Int
        let name: String
        let duration: String
        let mvc: Bool
    }

    @objc func importDiscBackup() {
        let loaded = sources.filter {
            ["iso", "ifo", "bdmv", "mkv"].contains($0.pathExtension.lowercased()) ||
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        let source: URL
        if loaded.count == 1 {
            source = loaded[0]
        } else if !loaded.isEmpty {
            let labels = loaded.enumerated().map { "\($0.offset + 1). \($0.element.lastPathComponent)" }
            guard let choice = chooseOption("Choose a loaded disc backup", labels) else { return }
            source = loaded[choice]
        } else {
            guard let picked = files("Choose an ISO, disc folder or index, or an MVC 3D MKV.", multiple: false, allowFolders: true)?.first else { return }
            source = picked
        }
        openDiscBackup(source)
    }

    func openDiscBackup(_ source: URL, preferDirectISO: Bool = false) {
        let script = resources.appendingPathComponent("disc_tools.py")
        if source.pathExtension.lowercased() == "mkv" {
            let name = source.deletingPathExtension().lastPathComponent + " Full SBS.mkv"
            guard alert("Convert MVC MKV to Full Side-by-Side?",
                        "Choose this for an MKV that still contains both Blu-ray 3D views.",
                        ["Continue", "Cancel"]) == 0,
                  let destination = save(name, near: source, fileExtension: "mkv") else { return }
            runDiscImport(script, source: source, title: 0, mode: "mvc", destination: destination)
            return
        }
        if source.pathExtension.lowercased() == "iso" {
            guard let choice = chooseOption("Import Blu-ray ISO",
                ["Convert 3D feature to Full Side-by-Side", "Scan disc and choose a title"],
                detail: "TVT uses MakeMKV and SBS Forge to convert the longest MVC 3D title. Scan the disc to choose an alternate title or keep the original format.",
                selected: preferDirectISO ? 0 : 1) else { return }
            if choice == 0 {
                let name = source.deletingPathExtension().lastPathComponent + " Full SBS.mkv"
                guard let destination = save(name, near: source, fileExtension: "mkv") else { return }
                runDiscImport(script, source: source, title: 0, mode: "mvc-iso", destination: destination)
                return
            }
        }
        beginProcessing("Scanning disc backup… Please wait.")
        execute(script, ["disc-scan", source.path]) { success, output in
            guard success, let titles = try? JSONDecoder().decode([DiscTitle].self, from: Data(output.utf8)), !titles.isEmpty else {
                self.endProcessing("Could not scan disc backup.", success: false)
                self.alert("Disc scan failed", String(output.suffix(2400)))
                return
            }
            self.endProcessing("Disc scan complete.", success: true)
            let labels = titles.map { "Title \($0.id) · \($0.duration) · \($0.name)" + ($0.mvc ? " · MVC 3D" : "") }
            let choice: Int
            if titles.count == 1 { choice = 0 }
            else {
                guard let selected = self.chooseOption("Choose a title", labels,
                    detail: "The longest title is selected first. Check the running time for episodes, extras, or alternate cuts.") else { return }
                choice = selected
            }
            let title = titles[choice]
            let names = ["Original MKV (2D or keep original 3D)",
                         "MVC Blu-ray 3D → Full Side-by-Side", "Full Over-Under → Full Side-by-Side",
                         "Half Over-Under → Full Side-by-Side", "Already Full Side-by-Side (tag only)",
                         "Already Half Side-by-Side (tag only)"]
            let modes = ["original", "mvc", "ou", "half-ou", "sbs", "half-sbs"]
            let note = title.mvc ? "MakeMKV reports an MVC 3D track. Side-by-Side conversion uses SBS Forge."
                                 : "Choose Original MKV if you are unsure. Preview it with Trim Clip before selecting a packed 3D layout."
            let outputChoices = title.mvc ? Array(names.prefix(2)) : names
            guard let format = self.chooseOption("Choose MKV output", outputChoices, detail: note, selected: title.mvc ? 1 : 0),
                  let destination = self.save("Disc Title \(title.id).mkv", near: source, fileExtension: "mkv") else { return }
            self.runDiscImport(script, source: source, title: title.id, mode: modes[format], destination: destination)
        }
    }

    func runDiscImport(_ script: URL, source: URL, title: Int, mode: String, destination: String) {
        beginProcessing((mode == "mvc" || mode == "mvc-iso") ? "Converting Blu-ray 3D to Full Side-by-Side…" : "Importing disc title… Please wait.")
        execute(script, ["disc-import", source.path, String(title), mode, destination]) { imported, detail in
            self.endProcessing(imported ? "Finished. Your disc title is ready." : "Disc import failed.", success: imported)
            if imported {
                self.result = URL(fileURLWithPath: destination)
                self.revealButton.isHidden = false
            } else { self.alert("Could not import disc title", String(detail.suffix(2400))) }
        }
    }

    @objc func split() {
        if let source = sourceFiles("Choose the movie to split.", multiple: false)?.first { splitFile(source) }
    }

    func splitFile(_ source: URL) {
        let dialog = NSAlert()
        dialog.messageText = "Split Movie"
        dialog.informativeText = "Choose 2–12 roughly equal parts. Cuts use nearby keyframes."
        let field = NSTextField(string: "4")
        field.frame.size.width = 90
        dialog.accessoryView = field
        dialog.addButton(withTitle: "Split")
        dialog.addButton(withTitle: "Cancel")
        guard dialog.runModal() == .alertFirstButtonReturn else { return }
        guard let count = Int(field.stringValue), (2...12).contains(count) else {
            alert("Invalid part count", "Enter a number from 2 through 12.")
            return
        }
        export(["split", String(count), source.path])
    }

    @objc func join() {
        if let selected = sourceFiles("Select all numbered movie parts.", multiple: true) { joinFiles(selected) }
    }

    func sorted(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func joinFiles(_ selected: [URL]) {
        guard selected.count >= 2 else { alert("Choose at least two parts", "Select all numbered parts to join."); return }
        guard let ordered = orderVideos(selected, title: "Join Parts") else { return }
        export(["join"] + ordered.map { $0.path })
    }

    func orderVideos(_ selected: [URL], title: String) -> [URL]? {
        let list = VideoOrderList(sorted(selected))
        let dialog = NSAlert()
        dialog.messageText = title + " — Choose the playback order"
        dialog.informativeText = "Read from top to bottom. Select a video and use Move Up or Move Down. The first clip sets the output size and frame rate. Link Videos uses each clip's first audio track."
        dialog.accessoryView = list
        dialog.addButton(withTitle: "Continue")
        dialog.addButton(withTitle: "Cancel")
        guard dialog.runModal() == .alertFirstButtonReturn else { return nil }
        return list.videos
    }

    @objc func link() {
        guard let selected = sourceFiles("Select the videos to link.", multiple: true) else { return }
        guard selected.count >= 2 else { alert("Choose at least two videos", "Select all clips you want to link."); return }
        guard let ordered = orderVideos(selected, title: "Link Videos"),
              let output = save("Linked Video.mp4", near: ordered[0]) else { return }
        export(["link", output] + ordered.map { $0.path })
    }

    @objc func upscale() {
        guard let videos = batchSources() else { return }
        let choice = alert("Upscale Video", "Fit the picture within the selected size while keeping its proportions.", ["1080p", "4K", "Cancel"])
        guard choice == 0 || choice == 1 else { return }
        let target = choice == 0 ? "1080" : "2160"
        if videos.count > 1 { batchExport("upscale", setting: target, videos: videos); return }
        let source = videos[0]
        let name = source.deletingPathExtension().lastPathComponent + (choice == 0 ? " 1080p.mp4" : " 4K.mp4")
        exportVideo(["upscale", target, source.path], source: source, name: name, fileExtension: "mp4")
    }

    let stereoLayouts = [("Full Side-by-Side", "sbsl"), ("Half Side-by-Side", "sbs2l"),
                         ("Full Over-Under", "abl"), ("Half Over-Under", "ab2l")]

    func chooseOption(_ title: String, _ labels: [String], detail: String = "", selected: Int = 0) -> Int? {
        let dialog = NSAlert()
        dialog.messageText = title
        dialog.informativeText = detail
        let popup = ClipOrderMenu(frame: NSRect(x: 0, y: 0, width: 300, height: 30), pullsDown: false)
        popup.addItems(withTitles: labels)
        popup.selectItem(at: selected)
        dialog.accessoryView = popup
        dialog.addButton(withTitle: "Continue")
        dialog.addButton(withTitle: "Cancel")
        return dialog.runModal() == .alertFirstButtonReturn ? popup.indexOfSelectedItem : nil
    }

    func textInput(_ title: String, _ value: String = "") -> String? {
        let dialog = NSAlert()
        dialog.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 350, height: 24))
        field.stringValue = value
        dialog.accessoryView = field
        dialog.window.initialFirstResponder = field
        dialog.addButton(withTitle: "Continue")
        dialog.addButton(withTitle: "Cancel")
        guard dialog.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    @objc func downloadOnline() {
        beginProcessing("Checking and setting up the video downloader…")
        execute(resources.appendingPathComponent("engine.sh"), ["download-setup"]) { success, detail in
            self.endProcessing(success ? "Video downloader ready." : "Downloader setup failed.", success: success)
            if success { self.downloadReady() }
            else { self.alert("Could not set up the video downloader", String(detail.suffix(3000))) }
        }
    }

    func downloadReady() {
        guard let url = textInput("Paste an online video page URL"),
              let choice = chooseOption("Download Online", ["Video (MKV)", "Audio Only (MP3)"]) else { return }
        let ext = choice == 0 ? "mkv" : "mp3"
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Online Video")
        guard let output = save("Online Video." + ext, near: home, fileExtension: ext) else { return }
        export(["download", choice == 0 ? "video" : "audio", url, output])
    }

    @objc func audioTools() {
        let options = [("Keep English Audio Only (MKV)", "english"),
                       ("Keep selected audio tracks (MKV)", "keep"),
                       ("MP3 audio", "mp3"), ("M4A audio", "m4a"), ("FLAC audio", "flac"),
                       ("WAV audio", "wav"), ("Remove audio (MKV)", "silent")]
        guard let videos = batchSources(),
              let choice = chooseOption("Extract or Remove Audio", options.map { $0.0 },
                                        detail: "English Only uses the language tags. Choose selected tracks if the tags are missing or incorrect. Audio extraction uses the first track.") else { return }
        let format = options[choice].1
        if format == "keep" {
            guard videos.count == 1 else {
                alert("Choose one video", "Audio track selection is specific to each video.")
                return
            }
            chooseAudioTracks(videos[0])
            return
        }
        if videos.count > 1 { batchExport("audio", setting: format, videos: videos); return }
        let source = videos[0]
        if format == "english" || format == "silent" {
            let suffix = format == "english" ? " English Audio.mkv" : " Silent.mkv"
            exportVideo(["audio", format, source.path], source: source,
                        name: source.deletingPathExtension().lastPathComponent + suffix, fileExtension: "mkv")
            return
        }
        let ext = format
        let name = source.deletingPathExtension().lastPathComponent + " Audio." + ext
        guard let output = save(name, near: source, fileExtension: ext) else { return }
        export(["audio", format, source.path, output])
    }

    func chooseAudioTracks(_ source: URL) {
        struct Track: Decodable {
            let codec_name: String?
            let channels: Int?
            let tags: [String: String]?
        }
        struct Probe: Decodable { let streams: [Track]? }
        beginProcessing("Reading audio tracks…")
        execute(resources.appendingPathComponent("engine.sh"), ["audio-tracks", source.path]) { success, output in
            guard success, let probe = try? JSONDecoder().decode(Probe.self, from: Data(output.utf8)) else {
                self.endProcessing("Could not read audio tracks.", success: false)
                self.alert("Could not read audio tracks", success ? "The audio track list was unreadable." : output)
                return
            }
            self.endProcessing("Audio tracks read.", success: true)
            guard let tracks = probe.streams, !tracks.isEmpty else {
                self.alert("No audio tracks", "This video has no audio tracks to select.")
                return
            }
            let checks = tracks.enumerated().map { index, track -> NSButton in
                let tags = track.tags ?? [:]
                let code = tags.first { $0.key.lowercased() == "language" }?.value.lowercased() ?? "und"
                let language = code == "und" ? "Unknown language" : Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
                let title = tags.first { $0.key.lowercased() == "title" }?.value
                let channels = track.channels.map { "\($0) ch" }
                let detail = [language, title, track.codec_name, channels].compactMap { $0 }.filter { !$0.isEmpty }
                let check = NSButton(checkboxWithTitle: (["Track \(index + 1)"] + detail).joined(separator: " · "),
                                     target: nil, action: nil)
                check.state = ["eng", "en"].contains(code) ? .on : .off
                return check
            }
            let list = NSStackView(views: checks)
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 6
            list.setFrameSize(list.fittingSize)
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 430, height: min(230, list.fittingSize.height + 4)))
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.documentView = list
            scroll.contentView.scroll(to: NSPoint(x: 0, y: list.isFlipped ? 0 : max(0, list.frame.height - scroll.contentView.bounds.height)))
            let dialog = NSAlert()
            dialog.messageText = "Choose audio tracks to keep"
            dialog.informativeText = "English-tagged tracks are checked. Review your selection before saving a new MKV."
            dialog.accessoryView = scroll
            dialog.addButton(withTitle: "Continue")
            dialog.addButton(withTitle: "Cancel")
            while dialog.runModal() == .alertFirstButtonReturn {
                let selected = checks.indices.filter { checks[$0].state == .on }
                guard !selected.isEmpty else {
                    self.alert("Choose at least one track", "Check the audio tracks you want to keep.")
                    continue
                }
                let name = source.deletingPathExtension().lastPathComponent + " Selected Audio.mkv"
                self.exportVideo(["audio", "keep:" + selected.map { String($0) }.joined(separator: ","), source.path],
                                 source: source, name: name, fileExtension: "mkv")
                return
            }
        }
    }

    @objc func addSubtitles() {
        let layouts = [("2D", "flat")] + stereoLayouts
        guard let source = sourceFiles("Choose the video that needs subtitles.", multiple: false)?.first,
              let layout = chooseOption("Choose the video layout", layouts.map { $0.0 }),
              let method = chooseOption("Choose a subtitle source", ["Local subtitle file", "Search OpenSubtitles", "Search Subtitle Cat", "Download from SubDL"],
                                        detail: "OpenSubtitles and SubDL each use their own API key. Subtitle Cat opens in your browser.") else { return }
        if method == 2 {
            guard let title = textInput("Search Subtitle Cat by movie or episode title",
                                        source.deletingPathExtension().lastPathComponent) else { return }
            var search = URLComponents()
            search.scheme = "https"
            search.host = "www.subtitlecat.com"
            search.path = "/index.php"
            search.queryItems = [URLQueryItem(name: "d", value: "1"), URLQueryItem(name: "search", value: title)]
            search.percentEncodedQuery = search.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            guard let url = search.url, NSWorkspace.shared.open(url) else {
                alert("Could not open Subtitle Cat", "Check that a default web browser is set.")
                return
            }
            guard alert("Download a subtitle from Subtitle Cat",
                        "Choose a result and download an SRT in your language. Return to TVT when the file is ready.",
                        ["Choose Downloaded SRT", "Cancel"]) == 0 else { return }
        }
        var depth = "0"
        if layout > 0 {
            let levels = [("At the screen", "0"), ("Slightly forward", "0.8"),
                          ("More forward", "1.5"), ("Most forward", "2.5")]
            guard let level = chooseOption("3D subtitle depth", levels.map { $0.0 }, selected: 1) else { return }
            depth = levels[level].1
        }
        var input: [String]
        if method == 0 || method == 2 {
            guard let captions = files("Choose a text subtitle file, such as SRT, ASS, or WebVTT.", multiple: false)?.first else { return }
            input = ["local", captions.path]
        } else {
            let prompt = method == 3 ? "Movie title and year, IMDb ID, or show title and S01E01"
                                     : "Movie title and year, or show title and S01E01"
            guard let title = textInput(prompt, source.deletingPathExtension().lastPathComponent),
                  let language = textInput("Subtitle language code", "en") else { return }
            input = [method == 3 ? "subdl" : "online", title, language]
        }
        var sidecar = false
        if layout > 0 {
            guard let format = chooseOption("Save 3D subtitles", ["Embed in a new MKV", "Save a separate ASS file"],
                                            detail: "If an embedded track is blank in VLC, try saving a separate ASS file beside the movie.") else { return }
            sidecar = format == 1
        }
        let name = source.deletingPathExtension().lastPathComponent + (sidecar ? ".ass" : " English subtitles.mkv")
        if sidecar {
            guard let output = save(name, near: source, fileExtension: "ass") else { return }
            export(["subtitles", source.path, output, layouts[layout].1, depth] + input)
        } else {
            exportVideo(["subtitles", source.path, layouts[layout].1, depth] + input,
                        source: source, name: name, fileExtension: "mkv", outputIndex: 2)
        }
    }

    @objc func changeLayout() {
        guard let source = sourceFiles("Choose a 2D or packed 3D video.", multiple: false)?.first,
              let choice = chooseOption("Change Aspect or Stereo Layout", ["2D aspect ratio", "3D stereo layout"]) else { return }
        var input = "flat"
        var output: String
        if choice == 0 {
            let ratios = ["16:9", "4:3", "1:1", "9:16"]
            guard let ratio = chooseOption("Choose an aspect ratio", ratios,
                                           detail: "TVT adds padding to fit the entire picture.") else { return }
            output = ratios[ratio]
        } else {
            let names = stereoLayouts.map { $0.0 }
            guard let from = chooseOption("Current stereo layout (left eye first)", names),
                  let to = chooseOption("Output stereo layout", names) else { return }
            input = stereoLayouts[from].1
            output = stereoLayouts[to].1
            if input == output { return }
        }
        let name = source.deletingPathExtension().lastPathComponent + " Reframed.mkv"
        exportVideo(["layout", input, output, source.path], source: source, name: name, fileExtension: "mkv")
    }

    func conversionProfiles() -> [[String]] {
        let url = resources.appendingPathComponent("ConversionProfiles.tsv")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            alert("Conversion profiles unavailable", "Reinstall TVT to restore the profiles.")
            return []
        }
        return contents.split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }.filter { $0.count == 3 }
    }

    @objc func convertVideo() {
        guard let videos = batchSources() else { return }
        if let iso = videos.first(where: { $0.pathExtension.lowercased() == "iso" }) {
            guard videos.count == 1 else {
                alert("Convert one ISO at a time", "Select just the disc image, then click Convert Video again.")
                return
            }
            openDiscBackup(iso, preferDirectISO: true)
            return
        }
        let profiles = conversionProfiles()
        guard !profiles.isEmpty else { return }
        let dialog = NSAlert()
        dialog.messageText = "Convert Video"
        dialog.informativeText = "Choose an output format. MKV keeps subtitle streams. The other presets export video and audio."
        let popup = ClipOrderMenu(frame: NSRect(x: 0, y: 0, width: 280, height: 30), pullsDown: false)
        popup.addItems(withTitles: profiles.map { $0[1] })
        dialog.accessoryView = popup
        dialog.addButton(withTitle: "Continue")
        dialog.addButton(withTitle: "Cancel")
        guard dialog.runModal() == .alertFirstButtonReturn else { return }
        let format = profiles[popup.indexOfSelectedItem][0]
        if videos.count > 1 { batchExport("convert", setting: format, videos: videos); return }
        let source = videos[0]
        let name = source.deletingPathExtension().lastPathComponent + " Converted." + format
        exportVideo(["convert", format, source.path], source: source, name: name, fileExtension: format)
    }

    @objc func inspectMedia() {
        guard let source = sourceFiles("Choose a file to inspect with MediaInfo.", multiple: false)?.first else { return }
        let choice = alert("MediaInfo", "Choose a report view.", ["Summary", "Full Details", "JSON", "Cancel"])
        let views = ["summary", "full", "json"]
        guard views.indices.contains(choice) else { return }
        guard !processing, !queued else { return }
        beginProcessing("Reading media information… Please wait.")
        execute(resources.appendingPathComponent("engine.sh"), ["info", views[choice], source.path]) { success, output in
            let finished = success && !output.isEmpty
            self.endProcessing(finished ? "Finished. MediaInfo report is ready." : "MediaInfo report unavailable.", success: finished)
            guard finished else {
                self.alert("MediaInfo report unavailable", output.isEmpty ? "MediaInfo did not recognize the selected file." : output)
                return
            }
            self.showReport(output, name: source.lastPathComponent)
        }
    }

    func showReport(_ report: String, name: String) {
        reportWindow?.close()
        let frame = NSRect(x: 0, y: 0, width: 800, height: 580)
        let panel = NSWindow(contentRect: frame, styleMask: [.titled, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false)
        panel.title = "MediaInfo — " + name
        panel.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: frame)
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: frame)
        text.isEditable = false
        text.isSelectable = true
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = report
        scroll.documentView = text
        panel.contentView = scroll
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(text)
        reportWindow = panel
    }

    @objc func showGuide() {
        NSWorkspace.shared.open(resources.appendingPathComponent("UserGuide.txt"))
    }

    @objc func checkManually() { checkUpdate(manual: true) }

    func checkUpdate(manual: Bool) {
        if queued {
            if manual { alert("Installing update", "TVT will reopen automatically.") }
            return
        }
        if checking {
            if manual { alert("Checking for updates", "An update check is already running.") }
            return
        }
        checking = true
        let script = resources.appendingPathComponent("update.sh")
        execute(script, ["check", version]) { success, output in
            self.checking = false
            guard success else {
                if manual { self.alert("Could not check for updates", String(output.suffix(2000))) }
                return
            }
            if output.isEmpty {
                if manual { self.alert("TVT is up to date", "You have version \(self.version).") }
                return
            }
            let fields = output.split(separator: " ").map(String.init)
            guard fields.count == 2 else { return }
            if self.trimEditor != nil || self.restoreComparison != nil || self.processing { return }
            if self.alert("TVT \(fields[0]) is available", "TVT will prepare the update, close to install it, and reopen automatically.", ["Quit and Install Update", "Later"]) != 0 { return }
            self.checking = true
            self.beginProcessing("Preparing update… TVT will reopen automatically.")
            self.execute(script, ["prepare", fields[0], fields[1], String(ProcessInfo.processInfo.processIdentifier),
                                  "restart", Bundle.main.bundleURL.path]) { prepared, detail in
                self.checking = false
                self.queued = prepared
                self.endProcessing(prepared ? "Installing update…" : "Could not prepare update.", success: prepared)
                if prepared {
                    NSApp.terminate(nil)
                } else {
                    self.alert("Could not prepare update", String(detail.suffix(2500)))
                }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = TVT()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
