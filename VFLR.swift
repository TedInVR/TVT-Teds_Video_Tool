import AppKit

final class ClipOrderMenu: NSPopUpButton {
    override func scrollWheel(with event: NSEvent) {}
}

final class VFLR: NSObject, NSApplicationDelegate {
    let resources = Bundle.main.resourceURL!
    let development = URL(fileURLWithPath: "/Applications/VFLR Development", isDirectory: true)
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    var window: NSWindow!
    var status: NSTextField!
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

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 395),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "VFLR — Video Fix Link Restore"
        window.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        let title = NSTextField(labelWithString: "Video Fix Link Restore")
        title.font = .boldSystemFont(ofSize: 22)
        stack.addArrangedSubview(title)
        for (name, action) in [("Split Movie", #selector(split)), ("Join Parts", #selector(join)),
                               ("Link Videos", #selector(link)), ("Upscale Video", #selector(upscale)),
                               ("MediaInfo", #selector(inspectMedia)), ("Convert Video", #selector(convertVideo))] {
            let button = NSButton(title: name, target: self, action: action)
            button.bezelStyle = .rounded
            button.widthAnchor.constraint(equalToConstant: 150).isActive = true
            operations.append(button)
            stack.addArrangedSubview(button)
        }
        status = NSTextField(wrappingLabelWithString: "Choose a video operation.")
        status.preferredMaxLayoutWidth = 420
        stack.addArrangedSubview(status)
        window.contentView = stack
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
        let files = filenames.map { URL(fileURLWithPath: $0) }
        DispatchQueue.main.async {
            if files.count == 1 { self.splitFile(files[0]) }
            else if let selected = self.files("Select every numbered movie part, including the first.", multiple: true, directory: files[0].deletingLastPathComponent()) {
                self.joinFiles(selected)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if processing {
            alert("Export in progress", "Wait for the current export to finish before quitting.")
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

    func export(_ arguments: [String]) {
        guard !processing, !queued else { return }
        processing = true
        operations.forEach { $0.isEnabled = false }
        status.stringValue = "Exporting video…"
        execute(resources.appendingPathComponent("engine.sh"), arguments) { success, output in
            self.processing = false
            self.operations.forEach { $0.isEnabled = !self.queued }
            self.status.stringValue = success ? "Export finished." : "Export failed."
            if success { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: output)]) }
            else { self.alert("Export failed", String(output.suffix(4000))) }
        }
    }

    @objc func split() {
        if let source = files("Choose the movie to split.", multiple: false)?.first { splitFile(source) }
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
        if let selected = files("Select all numbered movie parts.", multiple: true) { joinFiles(selected) }
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
        guard let selected = files("Select the videos to link.", multiple: true) else { return }
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
        guard let source = files("Choose the source video.", multiple: false)?.first else { return }
        let choice = alert("Upscale Video", "Fit the picture within the selected size while keeping its proportions.", ["1080p", "4K", "Cancel"])
        guard choice == 0 || choice == 1 else { return }
        let name = source.deletingPathExtension().lastPathComponent + (choice == 0 ? " 1080p.mp4" : " 4K.mp4")
        guard let output = save(name, near: source) else { return }
        export(["upscale", choice == 0 ? "1080" : "2160", source.path, output])
    }

    @objc func convertVideo() {
        guard let source = files("Choose any video supported by FFmpeg.", multiple: false)?.first else { return }
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
        guard let source = files("Choose a file to inspect with MediaInfo.", multiple: false)?.first else { return }
        let choice = alert("MediaInfo", "Choose a report view.", ["Summary", "Full Details", "JSON", "Cancel"])
        let views = ["summary", "full", "json"]
        guard views.indices.contains(choice) else { return }
        execute(resources.appendingPathComponent("engine.sh"), ["info", views[choice], source.path]) { success, output in
            guard success, !output.isEmpty else {
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
