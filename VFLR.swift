import AppKit

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

final class VFLR: NSObject, NSApplicationDelegate {
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        if FileManager.default.fileExists(atPath: development.appendingPathComponent(".install-lock").path) {
            NSApp.terminate(nil)
            return
        }
        let menu = NSMenu()
        let app = NSMenuItem()
        menu.addItem(app)
        app.submenu = NSMenu(title: "VFLR")
        app.submenu?.addItem(withTitle: "About VFLR", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.submenu?.addItem(.separator())
        app.submenu?.addItem(withTitle: "Quit VFLR", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let windowMenu = NSMenuItem()
        menu.addItem(windowMenu)
        windowMenu.submenu = NSMenu(title: "Window")
        windowMenu.submenu?.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let help = NSMenuItem()
        menu.addItem(help)
        help.submenu = NSMenu(title: "Help")
        for (title, action) in [("VFLR User Guide", #selector(showGuide)), ("Check for Updates…", #selector(checkManually))] {
            let item = help.submenu!.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        NSApp.mainMenu = menu
        NSApp.helpMenu = help.submenu

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "VFLR — Video Fix Link Restore"
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

        let title = NSTextField(labelWithString: "Video Fix Link Restore")
        title.font = .boldSystemFont(ofSize: 22)
        stack.addArrangedSubview(title)
        sourcesLabel = NSTextField(labelWithString: "Drop videos here, or browse for files.")
        sourcesLabel.lineBreakMode = .byTruncatingMiddle
        sourcesLabel.widthAnchor.constraint(equalToConstant: 395).isActive = true
        browseButton = NSButton(title: "Browse…", target: self, action: #selector(browseSources))
        clearButton = NSButton(title: "Clear", target: self, action: #selector(clearSources))
        clearButton.isEnabled = false
        let sourcesRow = NSStackView(views: [sourcesLabel, browseButton, clearButton])
        stack.addArrangedSubview(sourcesRow)

        let editing = toolGroup("Edit and Assemble", [
            ("Split Movie", #selector(split)), ("Join Parts", #selector(join)), ("Link Videos", #selector(link))
        ])
        let picture = toolGroup("Picture and Format", [
            ("Upscale Video", #selector(upscale)), ("Convert Video", #selector(convertVideo)),
            ("Change Aspect or Stereo Layout", #selector(changeLayout))
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
        guard !processing, !queued else { return false }
        var seen: Set<URL> = []
        let valid = urls.map { $0.standardizedFileURL }.filter {
            guard $0.isFileURL, seen.insert($0).inserted else { return false }
            return (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
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

    func files(_ prompt: String, multiple: Bool, directory: URL? = nil) -> [URL]? {
        let panel = NSOpenPanel()
        panel.message = prompt
        panel.directoryURL = directory
        panel.allowsMultipleSelection = multiple
        return panel.runModal() == .OK ? panel.urls : nil
    }

    func save(_ name: String, near source: URL, fileExtension: String = "mp4") -> String? {
        let panel = NSSavePanel()
        panel.directoryURL = source.deletingLastPathComponent()
        panel.nameFieldStringValue = name
        panel.allowedFileTypes = [fileExtension]
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    func execute(_ script: URL, _ arguments: [String], done: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [script.path] + arguments
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

    func export(_ arguments: [String]) {
        guard !processing, !queued else { return }
        let messages = ["split": "Splitting movie", "join": "Joining parts", "link": "Linking videos",
                        "upscale": "Upscaling video", "convert": "Converting video", "download": "Downloading media",
                        "audio": "Processing audio", "subtitles": "Preparing subtitles", "layout": "Changing video layout"]
        beginProcessing((messages[arguments[0]] ?? "Processing") + "… Please wait.")
        execute(resources.appendingPathComponent("engine.sh"), arguments) { success, output in
            let finished = success && !output.isEmpty
            self.endProcessing(finished ? "Finished. Your result is ready." : "Processing failed.", success: finished)
            if finished {
                self.result = URL(fileURLWithPath: output)
                self.revealButton.isHidden = false
            } else {
                self.alert("Processing failed", output.isEmpty ? "No result was created." : String(output.suffix(4000)))
            }
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
        let ordered = sorted(selected)
        guard alert("Join these parts in this order?", ordered.map { $0.lastPathComponent }.joined(separator: "\n"), ["Join", "Cancel"]) == 0 else { return }
        export(["join"] + ordered.map { $0.path })
    }

    @objc func link() {
        guard let selected = sourceFiles("Select the videos to link.", multiple: true) else { return }
        guard selected.count >= 2 else { alert("Choose at least two videos", "Select all clips you want to link."); return }
        var remaining = sorted(selected)
        var ordered: [URL] = []
        while remaining.count > 1 {
            let dialog = NSAlert()
            dialog.messageText = "Choose video \(ordered.count + 1) of \(selected.count)"
            dialog.informativeText = "The first clip sets the output size and frame rate. The export uses one stereo audio track."
            let popup = ClipOrderMenu(frame: NSRect(x: 0, y: 0, width: 360, height: 30), pullsDown: false)
            popup.addItems(withTitles: remaining.enumerated().map { "\($0.offset + 1). \($0.element.lastPathComponent) — \($0.element.deletingLastPathComponent().path)" })
            dialog.accessoryView = popup
            dialog.addButton(withTitle: "Continue")
            dialog.addButton(withTitle: "Cancel")
            guard dialog.runModal() == .alertFirstButtonReturn else { return }
            ordered.append(remaining.remove(at: popup.indexOfSelectedItem))
        }
        ordered += remaining
        guard alert("Link these videos in this order?", ordered.map { $0.lastPathComponent }.joined(separator: "\n"), ["Save", "Cancel"]) == 0,
              let output = save("Linked Video.mp4", near: ordered[0]) else { return }
        export(["link", output] + ordered.map { $0.path })
    }

    @objc func upscale() {
        guard let source = sourceFiles("Choose the source video.", multiple: false)?.first else { return }
        let choice = alert("Upscale Video", "Fit the picture within the selected size while keeping its proportions.", ["1080p", "4K", "Cancel"])
        guard choice == 0 || choice == 1 else { return }
        let name = source.deletingPathExtension().lastPathComponent + (choice == 0 ? " 1080p.mp4" : " 4K.mp4")
        guard let output = save(name, near: source) else { return }
        export(["upscale", choice == 0 ? "1080" : "2160", source.path, output])
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
        guard let url = textInput("Paste an online video page URL"),
              let choice = chooseOption("Download Online", ["Video (MKV)", "Audio Only (MP3)"]) else { return }
        let ext = choice == 0 ? "mkv" : "mp3"
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Online Video")
        guard let output = save("Online Video." + ext, near: home, fileExtension: ext) else { return }
        export(["download", choice == 0 ? "video" : "audio", url, output])
    }

    @objc func audioTools() {
        let options = [("MP3 audio", "mp3"), ("M4A audio", "m4a"), ("FLAC audio", "flac"),
                       ("WAV audio", "wav"), ("Remove audio (MKV)", "silent")]
        guard let source = sourceFiles("Choose the source video.", multiple: false)?.first,
              let choice = chooseOption("Extract or Remove Audio", options.map { $0.0 },
                                        detail: "Audio extraction uses the first audio track.") else { return }
        let format = options[choice].1
        let ext = format == "silent" ? "mkv" : format
        let name = source.deletingPathExtension().lastPathComponent + (format == "silent" ? " Silent." : " Audio.") + ext
        guard let output = save(name, near: source, fileExtension: ext) else { return }
        export(["audio", format, source.path, output])
    }

    @objc func addSubtitles() {
        let layouts = [("2D", "flat")] + stereoLayouts
        guard let source = sourceFiles("Choose the video that needs subtitles.", multiple: false)?.first,
              let layout = chooseOption("Choose the video layout", layouts.map { $0.0 }),
              let method = chooseOption("Choose a subtitle source", ["Local subtitle file", "Search OpenSubtitles"],
                                        detail: "Online search requires OpenSubtitles credentials. See the User Guide.") else { return }
        var depth = "0"
        if layout > 0 {
            let levels = [("At the screen", "0"), ("Slightly forward", "0.8"),
                          ("More forward", "1.5"), ("Most forward", "2.5")]
            guard let level = chooseOption("3D subtitle depth", levels.map { $0.0 }, selected: 1) else { return }
            depth = levels[level].1
        }
        var input: [String]
        if method == 0 {
            guard let captions = files("Choose a text subtitle file, such as SRT, ASS, or WebVTT.", multiple: false)?.first else { return }
            input = ["local", captions.path]
        } else {
            guard let title = textInput("Movie title and year, or show title and S01E01", source.deletingPathExtension().lastPathComponent),
                  let language = textInput("Subtitle language code", "en") else { return }
            input = ["online", title, language]
        }
        let name = source.deletingPathExtension().lastPathComponent + " Subtitled.mkv"
        guard let output = save(name, near: source, fileExtension: "mkv") else { return }
        export(["subtitles", source.path, output, layouts[layout].1, depth] + input)
    }

    @objc func changeLayout() {
        guard let source = sourceFiles("Choose a 2D or packed 3D video.", multiple: false)?.first,
              let choice = chooseOption("Change Aspect or Stereo Layout", ["2D aspect ratio", "3D stereo layout"]) else { return }
        var input = "flat"
        var output: String
        if choice == 0 {
            let ratios = ["16:9", "4:3", "1:1", "9:16"]
            guard let ratio = chooseOption("Choose an aspect ratio", ratios,
                                           detail: "VFLR adds padding to fit the entire picture.") else { return }
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
        guard let path = save(name, near: source, fileExtension: "mkv") else { return }
        export(["layout", input, output, source.path, path])
    }

    @objc func convertVideo() {
        guard let source = sourceFiles("Choose any video supported by FFmpeg.", multiple: false)?.first else { return }
        let url = resources.appendingPathComponent("ConversionProfiles.tsv")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            alert("Conversion profiles unavailable", "Reinstall VFLR to restore the profiles.")
            return
        }
        let profiles = contents.split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }.filter { $0.count == 3 }
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
        let name = source.deletingPathExtension().lastPathComponent + " Converted." + format
        guard let output = save(name, near: source, fileExtension: format) else { return }
        export(["convert", format, source.path, output])
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
            if manual { alert("Update ready", "Quit VFLR to install the downloaded update.") }
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
                if manual { self.alert("VFLR is up to date", "You have version \(self.version).") }
                return
            }
            let fields = output.split(separator: " ").map(String.init)
            guard fields.count == 2 else { return }
            if !manual && self.processing { return }
            if self.alert("VFLR \(fields[0]) is available", "VFLR will download the update and install it after you quit.", ["Download Update", "Later"]) != 0 { return }
            self.checking = true
            self.execute(script, ["prepare", fields[0], fields[1], String(ProcessInfo.processInfo.processIdentifier)]) { prepared, detail in
                self.checking = false
                if prepared {
                    self.queued = true
                    self.operations.forEach { $0.isEnabled = false }
                    self.browseButton.isEnabled = false
                    self.clearButton.isEnabled = false
                    if !self.processing { self.status.stringValue = "Update ready. Quit VFLR to install." }
                    self.alert("Update ready", "Quit VFLR to install it, then reopen VFLR from Applications.")
                } else {
                    self.alert("Could not prepare update", String(detail.suffix(2500)))
                }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = VFLR()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
