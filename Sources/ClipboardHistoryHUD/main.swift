@preconcurrency import AppKit
import Carbon
import Carbon.HIToolbox
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers
@preconcurrency import Vision

private let hotKeySignature = OSType(
    UInt32(UInt8(ascii: "C")) << 24
        | UInt32(UInt8(ascii: "H")) << 16
        | UInt32(UInt8(ascii: "H")) << 8
        | UInt32(UInt8(ascii: "V"))
)

private let handledSearchCommands: Set<Selector> = [
    #selector(NSResponder.moveDown(_:)),
    #selector(NSResponder.moveUp(_:)),
    #selector(NSResponder.insertNewline(_:)),
    #selector(NSResponder.cancelOperation(_:))
]

private struct AppConfig: Decodable {
    let historyLimit: Int
    let maxPersistedImageBytes: Int
    let maxPersistedImages: Int
    let maxPersistedImageTotalBytes: Int
    let hotKey: HotKeyConfig

    static let `default` = AppConfig(
        historyLimit: 200,
        maxPersistedImageBytes: 3 * 1024 * 1024,
        maxPersistedImages: 30,
        maxPersistedImageTotalBytes: 32 * 1024 * 1024,
        hotKey: HotKeyConfig(key: "v", modifiers: ["command", "shift"])
    )

    private enum CodingKeys: String, CodingKey {
        case historyLimit
        case maxPersistedImageBytes
        case maxPersistedImages
        case maxPersistedImageTotalBytes
        case hotKey
    }

    init(
        historyLimit: Int,
        maxPersistedImageBytes: Int,
        maxPersistedImages: Int,
        maxPersistedImageTotalBytes: Int,
        hotKey: HotKeyConfig
    ) {
        self.historyLimit = historyLimit
        self.maxPersistedImageBytes = maxPersistedImageBytes
        self.maxPersistedImages = maxPersistedImages
        self.maxPersistedImageTotalBytes = maxPersistedImageTotalBytes
        self.hotKey = hotKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.default
        historyLimit = try container.decodeIfPresent(Int.self, forKey: .historyLimit) ?? defaults.historyLimit
        maxPersistedImageBytes = try container.decodeIfPresent(Int.self, forKey: .maxPersistedImageBytes) ?? defaults.maxPersistedImageBytes
        maxPersistedImages = try container.decodeIfPresent(Int.self, forKey: .maxPersistedImages) ?? defaults.maxPersistedImages
        maxPersistedImageTotalBytes = try container.decodeIfPresent(Int.self, forKey: .maxPersistedImageTotalBytes) ?? defaults.maxPersistedImageTotalBytes
        hotKey = try container.decodeIfPresent(HotKeyConfig.self, forKey: .hotKey) ?? defaults.hotKey
    }

    static func load() -> AppConfig {
        let url = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClipboardHistoryHUD/config.json")

        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data)
        else {
            return .default
        }

        return AppConfig(
            historyLimit: max(20, min(config.historyLimit, 1000)),
            maxPersistedImageBytes: max(0, min(config.maxPersistedImageBytes, 50 * 1024 * 1024)),
            maxPersistedImages: max(0, min(config.maxPersistedImages, 500)),
            maxPersistedImageTotalBytes: max(0, min(config.maxPersistedImageTotalBytes, 512 * 1024 * 1024)),
            hotKey: config.hotKey
        )
    }
}

private struct HotKeyConfig: Decodable {
    let key: String
    let modifiers: [String]

    var keyCode: UInt32 {
        switch key.lowercased() {
        case "a": return UInt32(kVK_ANSI_A)
        case "b": return UInt32(kVK_ANSI_B)
        case "c": return UInt32(kVK_ANSI_C)
        case "d": return UInt32(kVK_ANSI_D)
        case "e": return UInt32(kVK_ANSI_E)
        case "f": return UInt32(kVK_ANSI_F)
        case "g": return UInt32(kVK_ANSI_G)
        case "h": return UInt32(kVK_ANSI_H)
        case "i": return UInt32(kVK_ANSI_I)
        case "j": return UInt32(kVK_ANSI_J)
        case "k": return UInt32(kVK_ANSI_K)
        case "l": return UInt32(kVK_ANSI_L)
        case "m": return UInt32(kVK_ANSI_M)
        case "n": return UInt32(kVK_ANSI_N)
        case "o": return UInt32(kVK_ANSI_O)
        case "p": return UInt32(kVK_ANSI_P)
        case "q": return UInt32(kVK_ANSI_Q)
        case "r": return UInt32(kVK_ANSI_R)
        case "s": return UInt32(kVK_ANSI_S)
        case "t": return UInt32(kVK_ANSI_T)
        case "u": return UInt32(kVK_ANSI_U)
        case "w": return UInt32(kVK_ANSI_W)
        case "x": return UInt32(kVK_ANSI_X)
        case "y": return UInt32(kVK_ANSI_Y)
        case "z": return UInt32(kVK_ANSI_Z)
        case "space": return UInt32(kVK_Space)
        default: return UInt32(kVK_ANSI_V)
        }
    }

    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        for modifier in modifiers.map({ $0.lowercased() }) {
            switch modifier {
            case "command", "cmd":
                value |= UInt32(cmdKey)
            case "shift":
                value |= UInt32(shiftKey)
            case "option", "alt":
                value |= UInt32(optionKey)
            case "control", "ctrl":
                value |= UInt32(controlKey)
            default:
                continue
            }
        }
        return value == 0 ? UInt32(cmdKey | shiftKey) : value
    }

    var displayName: String {
        let modifierText = modifiers.map { modifier -> String in
            switch modifier.lowercased() {
            case "command", "cmd": return "Cmd"
            case "shift": return "Shift"
            case "option", "alt": return "Option"
            case "control", "ctrl": return "Control"
            default: return modifier.capitalized
            }
        }.joined(separator: "+")
        return "\(modifierText)+\(key.uppercased())"
    }
}

@main
@MainActor
private enum Main {
    static func main() {
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        ClipboardHistoryApp().run()
    }
}

@MainActor
private final class ClipboardHistoryApp: @unchecked Sendable {
    private let config: AppConfig
    private let store: ClipboardHistoryStore
    private let ocrProcessor = ClipboardOCRProcessor()
    private let hud = ClipboardHistoryHUD()
    private let statusMenu = ClipboardStatusMenu()
    private var hotKeyRef: EventHotKeyRef?
    private var timer: Timer?
    private var knownChangeCount = -1
    private var isPaused = false

    init() {
        config = AppConfig.load()
        store = ClipboardHistoryStore(
            limit: config.historyLimit,
            maxPersistedImageBytes: config.maxPersistedImageBytes,
            maxPersistedImages: config.maxPersistedImages,
            maxPersistedImageTotalBytes: config.maxPersistedImageTotalBytes
        )
    }

    func run() {
        NSApplication.shared.setActivationPolicy(.accessory)
        hud.onPick = { [weak self] item in
            self?.write(item)
        }
        hud.onTogglePin = { [weak self] item in
            self?.togglePin(item)
        }
        hud.onDelete = { [weak self] item in
            self?.delete(item)
        }
        hud.onClear = { [weak self] in
            self?.clearHistory()
        }
        hud.onOpen = { [weak self] item in
            self?.open(item)
        }
        hud.onSaveImage = { [weak self] item in
            self?.saveImage(item)
        }
        hud.onCopyMarkdownLink = { [weak self] item in
            self?.copyMarkdownLink(item)
        }
        statusMenu.configure(
            open: { [weak self] in self?.showHUD() },
            clear: { [weak self] in self?.clearHistory() },
            pauseChanged: { [weak self] paused in self?.setPaused(paused) },
            quit: { NSApplication.shared.terminate(nil) }
        )

        registerHotKey()
        startClipboardWatcher()
        schedulePendingOCR()

        log("ClipboardHistoryHUD is running.")
        log("Copy text, URLs, files, or images, then press \(config.hotKey.displayName).")

        NSApplication.shared.run()
    }

    private func startClipboardWatcher() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.capturePasteboardIfChanged()
            }
        }
    }

    private func capturePasteboardIfChanged() {
        guard !isPaused else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != knownChangeCount else { return }
        knownChangeCount = pasteboard.changeCount

        guard let item = ClipboardReader.read(
            from: pasteboard,
            source: SourceApplication.current()
        ) else { return }
        store.add(item)
        scheduleOCR(for: item)

        if hud.isVisible {
            hud.show(items: store.items)
        }
    }

    private func write(_ item: ClipboardItem) {
        ClipboardWriter.write(item)
        knownChangeCount = NSPasteboard.general.changeCount
        store.promote(item)
        hud.hide()
        NSSound(named: "Pop")?.play()
        log("Restored clipboard item: \(item.kind.rawValue) \(item.title)")
    }

    private func togglePin(_ item: ClipboardItem) {
        store.togglePin(item)
        hud.show(items: store.items)
    }

    private func delete(_ item: ClipboardItem) {
        store.delete(item)
        hud.show(items: store.items)
    }

    private func clearHistory() {
        store.clear()
        if hud.isVisible {
            hud.show(items: store.items)
        }
    }

    private func open(_ item: ClipboardItem) {
        guard let url = item.url else { return }
        hud.hide()
        NSWorkspace.shared.open(url)
    }

    private func saveImage(_ item: ClipboardItem) {
        guard item.kind == .image,
              let imageData = item.imageData,
              let extensionName = fileExtension(for: item.imageType)
        else {
            return
        }

        hud.hide()
        NSApplication.shared.activate(ignoringOtherApps: true)

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "clipboard-\(Int(item.createdAt.timeIntervalSince1970)).\(extensionName)"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = allowedContentTypes(for: extensionName)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try imageData.write(to: url)
        } catch {
            log("Failed to save image: \(error.localizedDescription)")
        }
    }

    private func copyMarkdownLink(_ item: ClipboardItem) {
        guard let url = item.url, !url.isFileURL else { return }
        let title = item.title.replacingOccurrences(of: "]", with: "\\]")
        let markdown = "[\(title)](\(url.absoluteString))"
        ClipboardWriter.writeText(markdown)
        knownChangeCount = NSPasteboard.general.changeCount
        NSSound(named: "Pop")?.play()
    }

    private func setPaused(_ paused: Bool) {
        isPaused = paused
        statusMenu.setPaused(paused)
        log(paused ? "Clipboard watching paused." : "Clipboard watching resumed.")
    }

    private func registerHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let eventRef, let userData else {
                    return OSStatus(eventNotHandledErr)
                }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard status == noErr,
                      hotKeyID.signature == hotKeySignature,
                      hotKeyID.id == 1
                else {
                    return OSStatus(eventNotHandledErr)
                }

                let app = Unmanaged<ClipboardHistoryApp>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                Task { @MainActor in
                    app.toggleHUD()
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            nil
        )

        guard handlerStatus == noErr else {
            fputs("Failed to install hotkey handler: \(handlerStatus)\n", stderr)
            exit(1)
        }

        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: 1)
        let hotKeyStatus = RegisterEventHotKey(
            config.hotKey.keyCode,
            config.hotKey.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard hotKeyStatus == noErr else {
            fputs("Failed to register \(config.hotKey.displayName): \(hotKeyStatus)\n", stderr)
            exit(1)
        }
    }

    private func toggleHUD() {
        capturePasteboardIfChanged()

        if hud.isVisible {
            log("Hotkey pressed. Hiding HUD.")
            hud.hide()
        } else {
            log("Hotkey pressed. Showing HUD with \(store.items.count) items.")
            showHUD()
        }
    }

    private func showHUD() {
        capturePasteboardIfChanged()
        hud.show(items: store.items)
    }

    private func schedulePendingOCR() {
        for item in store.items where item.kind == .image && item.ocrText == nil {
            scheduleOCR(for: item)
        }
    }

    private func scheduleOCR(for item: ClipboardItem) {
        ocrProcessor.recognize(item: item) { [weak self] id, signature, text in
            guard let self else { return }
            guard self.store.updateOCRText(forID: id, signature: signature, text: text) else {
                return
            }

            if self.hud.isVisible {
                self.hud.show(items: self.store.items)
            }

            if !text.isEmpty {
                log("OCR indexed image clipboard item: \(singleLine(text, limit: 90))")
            }
        }
    }
}

private enum ClipboardKind: String, Codable {
    case text = "Text"
    case url = "URL"
    case fileURL = "File"
    case image = "Image"
}

private struct SourceApplication {
    let name: String
    let bundleIdentifier: String?

    static func current() -> SourceApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier
        else {
            return nil
        }

        return SourceApplication(
            name: app.localizedName ?? app.bundleIdentifier ?? "Unknown App",
            bundleIdentifier: app.bundleIdentifier
        )
    }
}

@MainActor
private final class ClipboardStatusMenu {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var pauseMenuItem: NSMenuItem?

    func configure(
        open: @escaping () -> Void,
        clear: @escaping () -> Void,
        pauseChanged: @escaping (Bool) -> Void,
        quit: @escaping () -> Void
    ) {
        statusItem.button?.image = NSImage(
            systemSymbolName: "list.clipboard",
            accessibilityDescription: "Clipboard History HUD"
        )

        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Open Clipboard History", action: open))
        menu.addItem(ClosureMenuItem(title: "Clear History", action: clear))
        menu.addItem(.separator())
        let pauseMenuItem = ClosureMenuItem(title: "Pause Watching") { [weak self] in
            guard let self else { return }
            let paused = self.pauseMenuItem?.state != .on
            pauseChanged(paused)
        }
        menu.addItem(pauseMenuItem)
        self.pauseMenuItem = pauseMenuItem
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Quit", action: quit))
        statusItem.menu = menu
    }

    func setPaused(_ paused: Bool) {
        pauseMenuItem?.state = paused ? .on : .off
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(runHandler), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func runHandler() {
        handler()
    }
}

private struct ClipboardItem: Identifiable, Equatable, @unchecked Sendable {
    let id: UUID
    let kind: ClipboardKind
    let title: String
    let detail: String
    let createdAt: Date
    let signature: String
    let isPinned: Bool
    let sourceAppName: String?
    let sourceBundleIdentifier: String?
    let ocrText: String?
    let text: String?
    let url: URL?
    let imageData: Data?
    let imageType: NSPasteboard.PasteboardType?
    let image: NSImage?

    init(
        id: UUID = UUID(),
        kind: ClipboardKind,
        title: String,
        detail: String,
        createdAt: Date,
        signature: String,
        isPinned: Bool = false,
        sourceAppName: String? = nil,
        sourceBundleIdentifier: String? = nil,
        ocrText: String? = nil,
        text: String?,
        url: URL?,
        imageData: Data?,
        imageType: NSPasteboard.PasteboardType?,
        image: NSImage?
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.createdAt = createdAt
        self.signature = signature
        self.isPinned = isPinned
        self.sourceAppName = sourceAppName
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.ocrText = ocrText
        self.text = text
        self.url = url
        self.imageData = imageData
        self.imageType = imageType
        self.image = image
    }

    static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
        lhs.id == rhs.id
    }
}

private extension ClipboardItem {
    var pinnedToggled: ClipboardItem {
        ClipboardItem(
            id: id,
            kind: kind,
            title: title,
            detail: detail,
            createdAt: createdAt,
            signature: signature,
            isPinned: !isPinned,
            sourceAppName: sourceAppName,
            sourceBundleIdentifier: sourceBundleIdentifier,
            ocrText: ocrText,
            text: text,
            url: url,
            imageData: imageData,
            imageType: imageType,
            image: image
        )
    }

    func withOCRText(_ ocrText: String) -> ClipboardItem {
        ClipboardItem(
            id: id,
            kind: kind,
            title: title,
            detail: detail,
            createdAt: createdAt,
            signature: signature,
            isPinned: isPinned,
            sourceAppName: sourceAppName,
            sourceBundleIdentifier: sourceBundleIdentifier,
            ocrText: ocrText,
            text: text,
            url: url,
            imageData: imageData,
            imageType: imageType,
            image: image
        )
    }

    func matchesSearch(_ query: String) -> Bool {
        let tokens = query
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return true }

        let searchableText = [
            kind.rawValue,
            title,
            detail,
            sourceAppName,
            sourceBundleIdentifier,
            ocrText,
            text,
            url?.absoluteString
        ]
            .compactMap(\.self)
            .joined(separator: " ")

        return tokens.allSatisfy {
            let token = $0.lowercased()
            if token == "pinned" {
                return isPinned
            }
            if token == "today" {
                return Calendar.current.isDateInToday(createdAt)
            }
            if token.hasPrefix("type:") {
                return kind.rawValue.localizedCaseInsensitiveContains(String($0.dropFirst(5)))
            }
            if token.hasPrefix("app:") {
                let app = String($0.dropFirst(4))
                return (sourceAppName ?? "").localizedCaseInsensitiveContains(app)
                    || (sourceBundleIdentifier ?? "").localizedCaseInsensitiveContains(app)
            }
            if token.hasPrefix("from:") {
                let app = String($0.dropFirst(5))
                return (sourceAppName ?? "").localizedCaseInsensitiveContains(app)
                    || (sourceBundleIdentifier ?? "").localizedCaseInsensitiveContains(app)
            }
            if token.hasPrefix("ocr:") {
                let text = String($0.dropFirst(4))
                return (ocrText ?? "").localizedCaseInsensitiveContains(text)
            }
            return searchableText.localizedCaseInsensitiveContains($0)
        }
    }
}

private final class ClipboardOCRProcessor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ClipboardHistoryHUD.OCR", qos: .utility)
    private let lock = NSLock()
    private var inFlightSignatures = Set<String>()

    func recognize(
        item: ClipboardItem,
        completion: @escaping @MainActor (_ id: UUID, _ signature: String, _ text: String) -> Void
    ) {
        guard item.kind == .image,
              item.ocrText == nil,
              let imageData = item.imageData
        else {
            return
        }

        let id = item.id
        let signature = item.signature

        lock.lock()
        let inserted = inFlightSignatures.insert(signature).inserted
        lock.unlock()
        guard inserted else { return }

        queue.async { [weak self] in
            let text = Self.recognizeText(in: imageData)
            self?.markFinished(signature)
            Task { @MainActor in
                completion(id, signature, text)
            }
        }
    }

    private func markFinished(_ signature: String) {
        lock.lock()
        inFlightSignatures.remove(signature)
        lock.unlock()
    }

    private static func recognizeText(in imageData: Data) -> String {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return ""
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = recognitionLanguages(for: request)

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            log("OCR failed: \(error.localizedDescription)")
            return ""
        }

        let lines = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return normalizedOCRText(lines.joined(separator: "\n"))
    }

    private static func recognitionLanguages(for request: VNRecognizeTextRequest) -> [String] {
        let preferred = ["ko-KR", "en-US"]
        guard let supported = try? request.supportedRecognitionLanguages() else {
            return preferred
        }

        let selected = preferred.filter { supported.contains($0) }
        return selected.isEmpty ? Array(supported.prefix(2)) : selected
    }

    private static func normalizedOCRText(_ text: String) -> String {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let joined = lines.joined(separator: "\n")
        guard joined.count > 4_000 else { return joined }
        let end = joined.index(joined.startIndex, offsetBy: 4_000)
        return String(joined[..<end])
    }
}

@MainActor
private final class ClipboardHistoryStore {
    private let limit: Int
    private let persistence: ClipboardHistoryPersistence
    private(set) var items: [ClipboardItem]

    init(
        limit: Int,
        maxPersistedImageBytes: Int,
        maxPersistedImages: Int,
        maxPersistedImageTotalBytes: Int
    ) {
        self.limit = limit
        persistence = ClipboardHistoryPersistence(
            maxPersistedImageBytes: maxPersistedImageBytes,
            maxPersistedImages: maxPersistedImages,
            maxPersistedImageTotalBytes: maxPersistedImageTotalBytes
        )
        items = persistence.load(limit: limit)
        persistence.compact(items)
    }

    func add(_ item: ClipboardItem) {
        let existingPinned = items.first { $0.signature == item.signature }?.isPinned ?? false
        let item = existingPinned ? ClipboardItem(
            id: item.id,
            kind: item.kind,
            title: item.title,
            detail: item.detail,
            createdAt: item.createdAt,
            signature: item.signature,
            isPinned: true,
            sourceAppName: item.sourceAppName,
            sourceBundleIdentifier: item.sourceBundleIdentifier,
            ocrText: item.ocrText,
            text: item.text,
            url: item.url,
            imageData: item.imageData,
            imageType: item.imageType,
            image: item.image
        ) : item

        items.removeAll { $0.signature == item.signature }
        items.insert(item, at: item.isPinned ? 0 : firstUnpinnedIndex())

        if items.count > limit {
            items.removeLast(items.count - limit)
        }

        persistence.persistListChange(items, changedItem: item)
    }

    func promote(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let item = items.remove(at: index)
        items.insert(item, at: item.isPinned ? 0 : firstUnpinnedIndex())
        persistence.updateListMetadata(items)
    }

    func togglePin(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let toggled = items.remove(at: index).pinnedToggled
        items.insert(toggled, at: toggled.isPinned ? 0 : firstUnpinnedIndex())
        persistence.updateListMetadata(items)
    }

    func updateOCRText(forID id: UUID, signature: String, text: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id && $0.signature == signature }) else {
            return false
        }

        items[index] = items[index].withOCRText(text)
        persistence.updateOCRText(forID: id, signature: signature, text: text)
        return true
    }

    func delete(_ item: ClipboardItem) {
        guard let deletedIndex = items.firstIndex(where: { $0.id == item.id }) else { return }
        items.remove(at: deletedIndex)
        persistence.delete(item, remainingItems: items, fromPosition: deletedIndex)
    }

    func clear() {
        items.removeAll()
        persistence.clear()
    }

    private func firstUnpinnedIndex() -> Int {
        items.firstIndex { !$0.isPinned } ?? items.count
    }
}

private final class ClipboardHistoryPersistence {
    private let maxPersistedImageBytes: Int
    private let maxPersistedImages: Int
    private let maxPersistedImageTotalBytes: Int
    private var db: OpaquePointer?

    init(maxPersistedImageBytes: Int, maxPersistedImages: Int, maxPersistedImageTotalBytes: Int) {
        self.maxPersistedImageBytes = maxPersistedImageBytes
        self.maxPersistedImages = maxPersistedImages
        self.maxPersistedImageTotalBytes = maxPersistedImageTotalBytes
        openDatabase()
        ensureSchema()
        migrateJSONIfNeeded()
    }

    deinit {
        sqlite3_close(db)
    }

    private var historyDirectory: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClipboardHistoryHUD", isDirectory: true)
    }

    private var databaseURL: URL {
        historyDirectory.appendingPathComponent("history.sqlite3")
    }

    private var imageDirectory: URL {
        historyDirectory.appendingPathComponent("images", isDirectory: true)
    }

    private var legacyJSONURL: URL {
        historyDirectory.appendingPathComponent("history.json")
    }

    func load(limit: Int) -> [ClipboardItem] {
        guard let db else { return loadLegacyJSON(limit: limit) }

        let sql = """
        SELECT id, kind, title, detail, created_at, signature, text, url_string,
               image_data, image_type, pinned, source_app_name, source_bundle_id, ocr_text, image_file
        FROM clipboard_items
        ORDER BY position ASC
        LIMIT ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError("Failed to prepare history load")
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var items: [ClipboardItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let item = item(from: statement) else { continue }
            items.append(item)
        }

        return items
    }

    func persistListChange(_ items: [ClipboardItem], changedItem: ClipboardItem) {
        guard db != nil else { return }
        let allowedImageIDs = allowedPersistedImageIDs(in: items)
        let position = items.firstIndex { $0.id == changedItem.id } ?? 0

        exec("BEGIN IMMEDIATE TRANSACTION;")
        deleteRowsNotIn(items)
        deleteDuplicateSignature(changedItem.signature, excludingID: changedItem.id)
        upsert(changedItem, position: position, persistImage: allowedImageIDs.contains(changedItem.id))
        updatePositions(items)
        clearImagesNotAllowed(allowedImageIDs)
        exec("COMMIT;")
    }

    func updateListMetadata(_ items: [ClipboardItem]) {
        guard db != nil else { return }
        let allowedImageIDs = allowedPersistedImageIDs(in: items)
        exec("BEGIN IMMEDIATE TRANSACTION;")
        deleteRowsNotIn(items)
        updatePositions(items)
        clearImagesNotAllowed(allowedImageIDs)
        exec("COMMIT;")
    }

    func updateOCRText(forID id: UUID, signature: String, text: String) {
        guard let db else { return }
        let sql = "UPDATE clipboard_items SET ocr_text = ? WHERE id = ? AND signature = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError("Failed to prepare OCR update")
            return
        }
        defer { sqlite3_finalize(statement) }

        bindText(text, to: 1, in: statement)
        bindText(id.uuidString, to: 2, in: statement)
        bindText(signature, to: 3, in: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSQLiteError("Failed to update OCR text")
            return
        }
    }

    func delete(_ item: ClipboardItem, remainingItems: [ClipboardItem], fromPosition deletedPosition: Int) {
        guard let db else { return }
        deleteImageFile(for: item.id)
        let sql = "DELETE FROM clipboard_items WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError("Failed to prepare history delete")
            return
        }
        defer { sqlite3_finalize(statement) }

        exec("BEGIN IMMEDIATE TRANSACTION;")
        bindText(item.id.uuidString, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSQLiteError("Failed to delete history item")
            exec("ROLLBACK;")
            return
        }
        updatePositions(remainingItems, startingAt: deletedPosition)
        exec("COMMIT;")
    }

    func clear() {
        exec("DELETE FROM clipboard_items;")
        deleteAllImageFiles()
        checkpoint()
    }

    func compact(_ items: [ClipboardItem]) {
        guard db != nil else { return }
        let allowedImageIDs = allowedPersistedImageIDs(in: items)
        exec("BEGIN IMMEDIATE TRANSACTION;")
        deleteRowsNotIn(items)
        for (position, item) in items.enumerated() {
            upsert(item, position: position, persistImage: allowedImageIDs.contains(item.id))
        }
        updatePositions(items)
        clearImagesNotAllowed(allowedImageIDs)
        exec("COMMIT;")
        passiveCheckpoint()
        exec("VACUUM;")
        checkpoint()
    }

    func save(_ items: [ClipboardItem]) {
        guard let db else { return }
        let allowedImageIDs = allowedPersistedImageIDs(in: items)

        exec("BEGIN IMMEDIATE TRANSACTION;")
        exec("DELETE FROM clipboard_items;")

        let sql = """
        INSERT INTO clipboard_items (
            id, kind, title, detail, created_at, signature, text, url_string,
            image_data, image_type, image_file, pinned, source_app_name, source_bundle_id, ocr_text, position
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError("Failed to prepare history save")
            exec("ROLLBACK;")
            return
        }
        defer { sqlite3_finalize(statement) }

        for (position, item) in items.enumerated() {
            guard let record = PersistedClipboardItem(
                item: item,
                maxImageBytes: maxPersistedImageBytes,
                imageFile: persistImageFile(for: item, persistImage: allowedImageIDs.contains(item.id))
            ) else {
                continue
            }

            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)

            bind(record, position: position, to: statement)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                logSQLiteError("Failed to insert history item")
                exec("ROLLBACK;")
                return
            }
        }

        exec("COMMIT;")
        passiveCheckpoint()
    }

    private func allowedPersistedImageIDs(in items: [ClipboardItem]) -> Set<UUID> {
        guard maxPersistedImages > 0, maxPersistedImageTotalBytes > 0, maxPersistedImageBytes > 0 else {
            return []
        }

        var allowed: Set<UUID> = []
        var imageCount = 0
        var byteCount = 0

        for item in items where item.kind == .image {
            guard let size = item.imageData?.count,
                  size > 0,
                  size <= maxPersistedImageBytes,
                  imageCount < maxPersistedImages,
                  byteCount + size <= maxPersistedImageTotalBytes
            else {
                continue
            }
            allowed.insert(item.id)
            imageCount += 1
            byteCount += size
        }

        return allowed
    }

    private func deleteRowsNotIn(_ items: [ClipboardItem]) {
        if items.isEmpty {
            exec("DELETE FROM clipboard_items;")
            return
        }

        let ids = items.map { "'\($0.id.uuidString)'" }.joined(separator: ",")
        exec("DELETE FROM clipboard_items WHERE id NOT IN (\(ids));")
    }

    private func deleteDuplicateSignature(_ signature: String, excludingID id: UUID) {
        guard let db else { return }
        let sql = "DELETE FROM clipboard_items WHERE signature = ? AND id <> ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError("Failed to prepare duplicate delete")
            return
        }
        defer { sqlite3_finalize(statement) }

        bindText(signature, to: 1, in: statement)
        bindText(id.uuidString, to: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSQLiteError("Failed to delete duplicate history item")
            return
        }
    }

    private func upsert(_ item: ClipboardItem, position: Int, persistImage: Bool) {
        guard let db,
              let record = PersistedClipboardItem(
                  item: item,
                  maxImageBytes: maxPersistedImageBytes,
                  imageFile: persistImageFile(for: item, persistImage: persistImage)
              )
        else {
            return
        }

        let sql = """
        INSERT INTO clipboard_items (
            id, kind, title, detail, created_at, signature, text, url_string,
            image_data, image_type, image_file, pinned, source_app_name, source_bundle_id, ocr_text, position
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            kind = excluded.kind,
            title = excluded.title,
            detail = excluded.detail,
            created_at = excluded.created_at,
            signature = excluded.signature,
            text = excluded.text,
            url_string = excluded.url_string,
            image_data = excluded.image_data,
            image_type = excluded.image_type,
            image_file = excluded.image_file,
            pinned = excluded.pinned,
            source_app_name = excluded.source_app_name,
            source_bundle_id = excluded.source_bundle_id,
            ocr_text = excluded.ocr_text,
            position = excluded.position;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError("Failed to prepare history upsert")
            return
        }
        defer { sqlite3_finalize(statement) }

        bind(record, position: position, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSQLiteError("Failed to upsert history item")
            return
        }
    }

    private func updatePositions(_ items: [ClipboardItem]) {
        updatePositions(items, startingAt: 0)
    }

    private func updatePositions(_ items: [ClipboardItem], startingAt startIndex: Int) {
        guard let db else { return }
        guard items.indices.contains(startIndex) else { return }
        let sql = "UPDATE clipboard_items SET pinned = ?, position = ? WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError("Failed to prepare position update")
            return
        }
        defer { sqlite3_finalize(statement) }

        for position in startIndex..<items.count {
            let item = items[position]
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_int(statement, 1, item.isPinned ? 1 : 0)
            sqlite3_bind_int(statement, 2, Int32(position))
            bindText(item.id.uuidString, to: 3, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                logSQLiteError("Failed to update history position")
                return
            }
        }
    }

    private func clearImagesNotAllowed(_ allowedImageIDs: Set<UUID>) {
        if allowedImageIDs.isEmpty {
            exec("UPDATE clipboard_items SET image_data = NULL, image_type = NULL, image_file = NULL WHERE image_data IS NOT NULL OR image_file IS NOT NULL;")
            deleteAllImageFiles()
            return
        }

        let ids = allowedImageIDs.map { "'\($0.uuidString)'" }.joined(separator: ",")
        exec("UPDATE clipboard_items SET image_data = NULL, image_type = NULL, image_file = NULL WHERE id NOT IN (\(ids));")
        deleteImageFilesNotIn(allowedImageIDs)
    }

    private func persistImageFile(for item: ClipboardItem, persistImage: Bool) -> String? {
        guard persistImage,
              let data = item.imageData,
              data.count <= maxPersistedImageBytes,
              let extensionName = fileExtension(for: item.imageType)
        else {
            return nil
        }

        do {
            try FileManager.default.createDirectory(
                at: imageDirectory,
                withIntermediateDirectories: true
            )
            let fileName = "\(item.id.uuidString).\(extensionName)"
            let url = imageDirectory.appendingPathComponent(fileName)
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
            }
            return fileName
        } catch {
            log("Failed to persist clipboard image file: \(error.localizedDescription)")
            return nil
        }
    }

    private func readImageFile(_ fileName: String?) -> Data? {
        guard let fileName, !fileName.isEmpty else { return nil }
        return try? Data(contentsOf: imageDirectory.appendingPathComponent(fileName))
    }

    private func deleteImageFile(for id: UUID) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: imageDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for file in files where file.deletingPathExtension().lastPathComponent == id.uuidString {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func deleteImageFilesNotIn(_ allowedImageIDs: Set<UUID>) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: imageDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        let allowed = Set(allowedImageIDs.map(\.uuidString))
        for file in files where !allowed.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func deleteAllImageFiles() {
        try? FileManager.default.removeItem(at: imageDirectory)
    }

    private func checkpoint() {
        exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    private func passiveCheckpoint() {
        exec("PRAGMA wal_checkpoint(PASSIVE);")
    }

    private func openDatabase() {
        do {
            try FileManager.default.createDirectory(
                at: historyDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            log("Failed to create history directory: \(error.localizedDescription)")
            return
        }

        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
            logSQLiteError("Failed to open SQLite history")
            sqlite3_close(db)
            db = nil
            return
        }

        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("PRAGMA wal_autocheckpoint=8192;")
        exec("PRAGMA journal_size_limit=33554432;")
    }

    private func ensureSchema() {
        exec("""
        CREATE TABLE IF NOT EXISTS clipboard_items (
            id TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            detail TEXT NOT NULL,
            created_at REAL NOT NULL,
            signature TEXT NOT NULL,
            text TEXT,
            url_string TEXT,
            image_data BLOB,
            image_type TEXT,
            image_file TEXT,
            pinned INTEGER NOT NULL DEFAULT 0,
            source_app_name TEXT,
            source_bundle_id TEXT,
            ocr_text TEXT,
            position INTEGER NOT NULL
        );
        """)
        addColumnIfMissing("pinned", definition: "INTEGER NOT NULL DEFAULT 0")
        addColumnIfMissing("source_app_name", definition: "TEXT")
        addColumnIfMissing("source_bundle_id", definition: "TEXT")
        addColumnIfMissing("ocr_text", definition: "TEXT")
        addColumnIfMissing("image_file", definition: "TEXT")
        exec("CREATE INDEX IF NOT EXISTS idx_clipboard_items_signature ON clipboard_items(signature);")
        exec("CREATE INDEX IF NOT EXISTS idx_clipboard_items_position ON clipboard_items(position);")
    }

    private func addColumnIfMissing(_ name: String, definition: String) {
        guard !columnExists(name) else { return }
        exec("ALTER TABLE clipboard_items ADD COLUMN \(name) \(definition);")
    }

    private func columnExists(_ name: String) -> Bool {
        guard let db else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(clipboard_items);", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            if columnText(statement, 1) == name {
                return true
            }
        }

        return false
    }

    private func migrateJSONIfNeeded() {
        guard let db, FileManager.default.fileExists(atPath: legacyJSONURL.path) else { return }

        let countSQL = "SELECT COUNT(*) FROM clipboard_items;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, countSQL, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_int(statement, 0) == 0
        else {
            return
        }

        let migrated = loadLegacyJSON(limit: 40)
        guard !migrated.isEmpty else { return }
        save(migrated)
        log("Migrated \(migrated.count) clipboard history items from JSON to SQLite.")
    }

    private func loadLegacyJSON(limit: Int) -> [ClipboardItem] {
        let url = legacyJSONURL
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([PersistedClipboardItem].self, from: data)
        else {
            return []
        }

        return records.prefix(limit).compactMap { $0.clipboardItem }
    }

    private func item(from statement: OpaquePointer?) -> ClipboardItem? {
        guard let idText = columnText(statement, 0),
              let id = UUID(uuidString: idText),
              let kindText = columnText(statement, 1),
              let kind = ClipboardKind(rawValue: kindText),
              let title = columnText(statement, 2),
              let detail = columnText(statement, 3),
              let signature = columnText(statement, 5)
        else {
            return nil
        }

        let imageData = columnBlob(statement, 8) ?? readImageFile(columnText(statement, 14))
        return ClipboardItem(
            id: id,
            kind: kind,
            title: title,
            detail: detail,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            signature: signature,
            isPinned: sqlite3_column_int(statement, 10) == 1,
            sourceAppName: columnText(statement, 11),
            sourceBundleIdentifier: columnText(statement, 12),
            ocrText: columnText(statement, 13),
            text: columnText(statement, 6),
            url: columnText(statement, 7).flatMap(URL.init(string:)),
            imageData: imageData,
            imageType: columnText(statement, 9).map { NSPasteboard.PasteboardType($0) },
            image: imageData.flatMap(NSImage.init(data:))
        )
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            logSQLiteError("SQLite exec failed")
        }
    }

    private func bind(_ record: PersistedClipboardItem, position: Int, to statement: OpaquePointer?) {
        bindText(record.id.uuidString, to: 1, in: statement)
        bindText(record.kind.rawValue, to: 2, in: statement)
        bindText(record.title, to: 3, in: statement)
        bindText(record.detail, to: 4, in: statement)
        sqlite3_bind_double(statement, 5, record.createdAt.timeIntervalSince1970)
        bindText(record.signature, to: 6, in: statement)
        bindOptionalText(record.text, to: 7, in: statement)
        bindOptionalText(record.urlString, to: 8, in: statement)
        sqlite3_bind_null(statement, 9)
        bindOptionalText(record.imageTypeRawValue, to: 10, in: statement)
        bindOptionalText(record.imageFile, to: 11, in: statement)
        sqlite3_bind_int(statement, 12, record.isPinned == true ? 1 : 0)
        bindOptionalText(record.sourceAppName, to: 13, in: statement)
        bindOptionalText(record.sourceBundleIdentifier, to: 14, in: statement)
        bindOptionalText(record.ocrText, to: 15, in: statement)
        sqlite3_bind_int(statement, 16, Int32(position))
    }

    private func bindText(_ value: String, to index: Int32, in statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func bindOptionalText(_ value: String?, to index: Int32, in statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        bindText(value, to: index, in: statement)
    }

    private func bindOptionalBlob(_ value: Data?, to index: Int32, in statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }

        _ = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(value.count), sqliteTransient)
        }
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index)
        else {
            return nil
        }

        return String(cString: UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self))
    }

    private func columnBlob(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_blob(statement, index)
        else {
            return nil
        }

        let count = Int(sqlite3_column_bytes(statement, index))
        return Data(bytes: pointer, count: count)
    }

    private func logSQLiteError(_ message: String) {
        let detail = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown error"
        log("\(message): \(detail)")
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private struct PersistedClipboardItem: Codable {
    let id: UUID
    let kind: ClipboardKind
    let title: String
    let detail: String
    let createdAt: Date
    let signature: String
    let isPinned: Bool?
    let sourceAppName: String?
    let sourceBundleIdentifier: String?
    let ocrText: String?
    let text: String?
    let urlString: String?
    let imageData: Data?
    let imageTypeRawValue: String?
    let imageFile: String?

    init?(item: ClipboardItem, maxImageBytes: Int, imageFile: String? = nil) {
        id = item.id
        kind = item.kind
        title = item.title
        detail = item.detail
        createdAt = item.createdAt
        signature = item.signature
        isPinned = item.isPinned
        sourceAppName = item.sourceAppName
        sourceBundleIdentifier = item.sourceBundleIdentifier
        ocrText = item.ocrText
        text = item.text
        urlString = item.url?.absoluteString
        imageData = nil
        imageTypeRawValue = imageFile == nil ? nil : item.imageType?.rawValue
        self.imageFile = imageFile
    }

    var clipboardItem: ClipboardItem? {
        let url = urlString.flatMap(URL.init(string:))
        let image = imageData.flatMap(NSImage.init(data:))
        let imageType = imageTypeRawValue.map { NSPasteboard.PasteboardType($0) }

        return ClipboardItem(
            id: id,
            kind: kind,
            title: title,
            detail: detail,
            createdAt: createdAt,
            signature: signature,
            isPinned: isPinned ?? false,
            sourceAppName: sourceAppName,
            sourceBundleIdentifier: sourceBundleIdentifier,
            ocrText: ocrText,
            text: text,
            url: url,
            imageData: imageData,
            imageType: imageType,
            image: image
        )
    }
}

private enum ClipboardReader {
    static func read(from pasteboard: NSPasteboard, source: SourceApplication?) -> ClipboardItem? {
        if let fileURL = readURLObject(from: pasteboard), fileURL.isFileURL {
            return item(for: fileURL, source: source)
        }

        if let image = readImage(from: pasteboard, source: source) {
            return image
        }

        if let url = readURLObject(from: pasteboard) {
            return item(for: url, source: source)
        }

        guard let text = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            return nil
        }

        if let url = URL(string: text), url.scheme != nil, url.host != nil {
            return item(for: url, source: source)
        }

        return ClipboardItem(
            kind: .text,
            title: singleLine(text, limit: 90),
            detail: "\(text.count) characters",
            createdAt: Date(),
            signature: "text:\(text)",
            sourceAppName: source?.name,
            sourceBundleIdentifier: source?.bundleIdentifier,
            text: text,
            url: nil,
            imageData: nil,
            imageType: nil,
            image: nil
        )
    }

    private static func readImage(from pasteboard: NSPasteboard, source: SourceApplication?) -> ClipboardItem? {
        for type in preferredImagePasteboardTypes() {
            guard let data = pasteboard.data(forType: type),
                  let image = NSImage(data: data)
            else {
                continue
            }

            let pixelSize = imagePixelSize(image)
            return ClipboardItem(
                kind: .image,
                title: "Image \(pixelSize.width)x\(pixelSize.height)",
                detail: "\(formatBytes(data.count)) \(type.rawValue)",
                createdAt: Date(),
                signature: "image:\(fnv1a64(data))",
                sourceAppName: source?.name,
                sourceBundleIdentifier: source?.bundleIdentifier,
                text: nil,
                url: nil,
                imageData: data,
                imageType: type,
                image: image
            )
        }

        return nil
    }

    private static func preferredImagePasteboardTypes() -> [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = [.png, .tiff]
        for imageType in NSImage.imageTypes {
            let type = NSPasteboard.PasteboardType(imageType)
            guard !types.contains(type) else { continue }
            types.append(type)
        }
        return types
    }

    private static func readURLObject(from pasteboard: NSPasteboard) -> URL? {
        if let urlString = pasteboard.string(forType: .URL),
           let url = URL(string: urlString) {
            return url
        }

        let allURLObjects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [:]
        ) as? [URL]

        return allURLObjects?.first
    }

    private static func item(for url: URL, source: SourceApplication?) -> ClipboardItem {
        let isFile = url.isFileURL
        let title = isFile ? url.lastPathComponent : (url.host ?? url.absoluteString)
        let detail = isFile ? url.path : url.absoluteString

        return ClipboardItem(
            kind: isFile ? .fileURL : .url,
            title: singleLine(title, limit: 90),
            detail: singleLine(detail, limit: 120),
            createdAt: Date(),
            signature: "\(isFile ? "file" : "url"):\(url.absoluteString)",
            sourceAppName: source?.name,
            sourceBundleIdentifier: source?.bundleIdentifier,
            text: url.absoluteString,
            url: url,
            imageData: nil,
            imageType: nil,
            image: nil
        )
    }
}

private enum ClipboardWriter {
    static func writeText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func write(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.kind {
        case .text:
            pasteboard.setString(item.text ?? "", forType: .string)
        case .url:
            if let url = item.url {
                pasteboard.writeObjects([url as NSURL])
                pasteboard.setString(url.absoluteString, forType: .string)
                pasteboard.setString(url.absoluteString, forType: .URL)
            } else {
                pasteboard.setString(item.text ?? "", forType: .string)
            }
        case .fileURL:
            if let url = item.url {
                pasteboard.writeObjects([url as NSURL])
            } else {
                pasteboard.setString(item.text ?? "", forType: .string)
            }
        case .image:
            guard let imageData = item.imageData,
                  let imageType = item.imageType
            else {
                return
            }
            pasteboard.declareTypes([imageType], owner: nil)
            pasteboard.setData(imageData, forType: imageType)
        }
    }
}

@MainActor
private final class ClipboardHistoryHUD: NSObject, NSSearchFieldDelegate, NSControlTextEditingDelegate {
    var onPick: ((ClipboardItem) -> Void)?
    var onTogglePin: ((ClipboardItem) -> Void)?
    var onDelete: ((ClipboardItem) -> Void)?
    var onClear: (() -> Void)?
    var onOpen: ((ClipboardItem) -> Void)?
    var onSaveImage: ((ClipboardItem) -> Void)?
    var onCopyMarkdownLink: ((ClipboardItem) -> Void)?
    var isVisible: Bool {
        panel?.isVisible == true
    }

    private var allItems: [ClipboardItem] = []
    private var items: [ClipboardItem] = []
    private var selectedIndex = 0
    private var panel: HistoryPanel?
    private let rowsContainer = FlippedView()
    private let searchField = NSSearchField()
    private let emptyLabel = NSTextField(labelWithString: "No clipboard history yet")
    private let counterLabel = NSTextField(labelWithString: "")
    private weak var scrollView: NSScrollView?
    private var rowViews: [ClipRowView] = []

    func show(items: [ClipboardItem]) {
        allItems = items
        ensurePanel()
        panel?.contentView?.layoutSubtreeIfNeeded()
        applySearch(keepSelection: false)
        positionPanel()
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        panel?.makeFirstResponder(searchField)
    }

    func hide() {
        ClipRowView.closeActiveOCRPreview()
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let contentView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 460, height: 400))
        contentView.material = .hudWindow
        contentView.blendingMode = .behindWindow
        contentView.state = .active
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 8
        contentView.layer?.masksToBounds = true

        let titleLabel = NSTextField(labelWithString: "Clipboard History")
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        counterLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        counterLabel.textColor = .secondaryLabelColor
        counterLabel.alignment = .right
        counterLabel.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search history"
        searchField.font = .systemFont(ofSize: 13)
        searchField.controlSize = .regular
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        rowsContainer.frame = NSRect(x: 0, y: 0, width: 460, height: 1)

        let scrollView = NSScrollView()
        scrollView.documentView = rowsContainer
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView = scrollView

        emptyLabel.font = .systemFont(ofSize: 13, weight: .medium)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(titleLabel)
        contentView.addSubview(counterLabel)
        contentView.addSubview(searchField)
        contentView.addSubview(separator)
        contentView.addSubview(scrollView)
        contentView.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),

            counterLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            counterLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            counterLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),

            searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            searchField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            searchField.heightAnchor.constraint(equalToConstant: 28),

            separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separator.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),

            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            emptyLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])

        let panel = HistoryPanel(
            contentRect: contentView.frame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = contentView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.onKeyDown = { [weak self] event in
            self?.handleKey(event) ?? false
        }
        panel.onOrderOut = {
            ClipRowView.closeActiveOCRPreview()
        }
        self.panel = panel
    }

    private func applySearch(keepSelection: Bool) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            items = allItems
        } else {
            items = allItems.filter { $0.matchesSearch(query) }
        }

        if items.isEmpty {
            selectedIndex = -1
        } else if keepSelection {
            selectedIndex = min(max(selectedIndex, 0), items.count - 1)
        } else {
            selectedIndex = 0
        }

        reloadRows()
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        applySearch(keepSelection: false)
    }

    func controlTextDidChange(_ obj: Notification) {
        applySearch(keepSelection: false)
    }

    private func reloadRows() {
        ClipRowView.closeActiveOCRPreview()
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = []

        emptyLabel.isHidden = !items.isEmpty
        emptyLabel.stringValue = allItems.isEmpty ? "No clipboard history yet" : "No matching items"

        if searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            counterLabel.stringValue = "\(allItems.count)"
        } else {
            counterLabel.stringValue = "\(items.count)/\(allItems.count)"
        }

        let scrollBounds = scrollView?.contentView.bounds ?? NSRect(x: 0, y: 0, width: 460, height: 318)
        let rowHeight: CGFloat = 72
        let rowGap: CGFloat = 6
        let inset: CGFloat = 8
        let contentWidth = max(scrollBounds.width, 320)
        let contentHeight = max(
            scrollBounds.height,
            inset * 2 + CGFloat(items.count) * rowHeight + CGFloat(max(items.count - 1, 0)) * rowGap
        )
        rowsContainer.setFrameSize(NSSize(width: contentWidth, height: contentHeight))

        for (index, item) in items.enumerated() {
            let row = ClipRowView(item: item, index: index)
            row.onTogglePin = { [weak self] item in self?.onTogglePin?(item) }
            row.onDelete = { [weak self] item in self?.onDelete?(item) }
            row.onOpen = { [weak self] item in self?.onOpen?(item) }
            row.onSaveImage = { [weak self] item in self?.onSaveImage?(item) }
            row.target = self
            row.action = #selector(rowPicked(_:))
            row.frame = NSRect(
                x: inset,
                y: inset + CGFloat(index) * (rowHeight + rowGap),
                width: contentWidth - inset * 2,
                height: rowHeight
            )
            rowsContainer.addSubview(row)
            rowViews.append(row)
        }

        updateSelection()
    }

    private func updateSelection() {
        for (index, row) in rowViews.enumerated() {
            row.isSelected = index == selectedIndex
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let isCommand = event.modifierFlags.contains(.command)
        switch Int(event.keyCode) {
        case 53:
            hide()
            return true
        case 51:
            if isCommand {
                onClear?()
            } else if let item = selectedItem {
                onDelete?(item)
            }
            return true
        case 125:
            moveSelection(by: 1)
            return true
        case 126:
            moveSelection(by: -1)
            return true
        case 36, 76:
            pickSelected()
            return true
        case 31:
            if isCommand, let item = selectedItem {
                onOpen?(item)
                return true
            }
            return false
        case 35:
            if isCommand, let item = selectedItem {
                onTogglePin?(item)
                return true
            }
            return false
        case 1:
            if isCommand, let item = selectedItem {
                onSaveImage?(item)
                return true
            }
            return false
        case 46:
            if isCommand, let item = selectedItem {
                onCopyMarkdownLink?(item)
                return true
            }
            return false
        case 3:
            if isCommand {
                panel?.makeFirstResponder(searchField)
                return true
            }
            return false
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), items.count - 1)
        updateSelection()
        rowsContainer.scrollToVisible(rowViews[selectedIndex].frame)
    }

    private func pickSelected() {
        guard let selectedItem else { return }
        onPick?(selectedItem)
    }

    private var selectedItem: ClipboardItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    nonisolated func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        Task { @MainActor [weak self] in
            self?.handleSearchCommand(commandSelector)
        }
        return handledSearchCommands.contains(commandSelector)
    }

    private func handleSearchCommand(_ commandSelector: Selector) {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            pickSelected()
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
        default:
            break
        }
    }

    @objc private func rowPicked(_ sender: ClipRowView) {
        selectedIndex = sender.index
        updateSelection()
        pickSelected()
    }

    private func positionPanel() {
        guard let panel else { return }

        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.maxY - size.height - 70
        )
        panel.setFrameOrigin(origin)
    }
}

private final class HistoryPanel: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?
    var onOrderOut: (() -> Void)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyDown?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func orderOut(_ sender: Any?) {
        onOrderOut?()
        super.orderOut(sender)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}

private final class ClipRowView: NSControl {
    private static weak var activeOCRPreviewRow: ClipRowView?

    static func closeActiveOCRPreview() {
        activeOCRPreviewRow?.closeOCRPreview()
    }

    let index: Int
    private let item: ClipboardItem
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let iconBadgeView = NSView()
    private let iconImageView = NSImageView()
    private let imageView = NSImageView()
    private let pinButton = NSButton()
    private let quickActionButton = NSButton()
    private let deleteButton = NSButton()
    private var trackingArea: NSTrackingArea?
    private var hoverWorkItem: DispatchWorkItem?
    private var closeWorkItem: DispatchWorkItem?
    private var ocrPreviewPopover: NSPopover?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    var onTogglePin: ((ClipboardItem) -> Void)?
    var onDelete: ((ClipboardItem) -> Void)?
    var onOpen: ((ClipboardItem) -> Void)?
    var onSaveImage: ((ClipboardItem) -> Void)?

    var isSelected = false {
        didSet {
            needsDisplay = true
        }
    }

    init(item: ClipboardItem, index: Int) {
        self.item = item
        self.index = index
        super.init(frame: .zero)
        wantsLayer = true
        setup()
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        hoverWorkItem?.cancel()
        closeWorkItem?.cancel()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            closeOCRPreview()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0, dy: 0)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)

        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.24).setFill()
        } else {
            NSColor.controlBackgroundColor.withAlphaComponent(0.34).setFill()
        }
        path.fill()
    }

    override func mouseDown(with event: NSEvent) {
        closeOCRPreview()
        sendAction(action, to: target)
    }

    override func mouseEntered(with event: NSEvent) {
        closeWorkItem?.cancel()
        scheduleOCRPreview(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        if isPointerOverActionButton(event) {
            closeOCRPreview()
        } else {
            scheduleOCRPreview(for: event)
        }
    }

    override func mouseExited(with event: NSEvent) {
        scheduleOCRPreviewClose()
    }

    private func setup() {
        iconBadgeView.wantsLayer = true
        iconBadgeView.layer?.cornerRadius = 8
        iconBadgeView.layer?.backgroundColor = iconBackgroundColor(for: item.kind).cgColor
        iconBadgeView.translatesAutoresizingMaskIntoConstraints = false

        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        iconImageView.image = NSImage(
            systemSymbolName: symbolName(for: item.kind),
            accessibilityDescription: item.kind.rawValue
        )?.withSymbolConfiguration(symbolConfiguration)
        iconImageView.contentTintColor = iconTintColor(for: item.kind)
        iconImageView.imageScaling = .scaleProportionallyDown
        iconImageView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = item.title
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.stringValue = rowDetail(for: item)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        imageView.image = item.image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 4
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        imageView.isHidden = item.kind != .image
        imageView.translatesAutoresizingMaskIntoConstraints = false

        configureIconButton(
            pinButton,
            symbolName: item.isPinned ? "pin.fill" : "pin",
            accessibilityDescription: item.isPinned ? "Unpin" : "Pin"
        )
        pinButton.target = self
        pinButton.action = #selector(togglePin)

        configureIconButton(
            quickActionButton,
            symbolName: quickActionSymbolName(for: item),
            accessibilityDescription: quickActionDescription(for: item)
        )
        quickActionButton.target = self
        quickActionButton.action = #selector(runQuickAction)

        configureIconButton(
            deleteButton,
            symbolName: "trash",
            accessibilityDescription: "Delete"
        )
        deleteButton.target = self
        deleteButton.action = #selector(deleteItem)

        addSubview(iconBadgeView)
        iconBadgeView.addSubview(iconImageView)
        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(imageView)
        addSubview(pinButton)
        addSubview(quickActionButton)
        addSubview(deleteButton)

        NSLayoutConstraint.activate([
            iconBadgeView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            iconBadgeView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconBadgeView.widthAnchor.constraint(equalToConstant: 32),
            iconBadgeView.heightAnchor.constraint(equalToConstant: 32),

            iconImageView.centerXAnchor.constraint(equalTo: iconBadgeView.centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: iconBadgeView.centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 18),
            iconImageView.heightAnchor.constraint(equalToConstant: 18),

            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 26),
            deleteButton.heightAnchor.constraint(equalToConstant: 26),

            quickActionButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -4),
            quickActionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            quickActionButton.widthAnchor.constraint(equalToConstant: 26),
            quickActionButton.heightAnchor.constraint(equalToConstant: 26),

            pinButton.trailingAnchor.constraint(equalTo: quickActionButton.leadingAnchor, constant: -4),
            pinButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: 26),
            pinButton.heightAnchor.constraint(equalToConstant: 26),

            imageView.trailingAnchor.constraint(equalTo: pinButton.leadingAnchor, constant: -8),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 52),
            imageView.heightAnchor.constraint(equalToConstant: 52),

            titleLabel.leadingAnchor.constraint(equalTo: iconBadgeView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: item.kind == .image ? imageView.leadingAnchor : pinButton.leadingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 13),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3)
        ])
    }

    private func configureIconButton(
        _ button: NSButton,
        symbolName: String,
        accessibilityDescription: String
    ) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        button.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityDescription
        )?.withSymbolConfiguration(configuration)
        button.imagePosition = .imageOnly
        button.bezelStyle = .rounded
        button.isBordered = false
        button.toolTip = accessibilityDescription
        button.contentTintColor = .secondaryLabelColor
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func scheduleOCRPreview(for event: NSEvent) {
        guard ocrPreviewText(for: item) != nil,
              !isPointerOverActionButton(event)
        else {
            return
        }

        if Self.activeOCRPreviewRow !== self {
            Self.activeOCRPreviewRow?.closeOCRPreview()
        }

        closeWorkItem?.cancel()
        if ocrPreviewPopover?.isShown == true {
            return
        }

        hoverWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.showOCRPreview()
        }
        hoverWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func showOCRPreview() {
        guard window != nil,
              ocrPreviewPopover?.isShown != true,
              let ocrText = ocrPreviewText(for: item)
        else {
            return
        }

        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = OCRPreviewViewController(text: ocrText)
        ocrPreviewPopover = popover
        Self.activeOCRPreviewRow = self
        popover.show(
            relativeTo: NSRect(x: 0, y: bounds.midY, width: 1, height: 1),
            of: self,
            preferredEdge: .minX
        )
        installMouseMonitors()
    }

    private func scheduleOCRPreviewClose() {
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
        closeWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.isMouseInsideRowOrPreview() {
                return
            }
            self.closeOCRPreview()
        }
        closeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func closeOCRPreview() {
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
        closeWorkItem?.cancel()
        closeWorkItem = nil
        ocrPreviewPopover?.close()
        ocrPreviewPopover = nil
        removeMouseMonitors()
        if Self.activeOCRPreviewRow === self {
            Self.activeOCRPreviewRow = nil
        }
    }

    private func installMouseMonitors() {
        removeMouseMonitors()
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.closeOCRPreviewIfPointerLeft()
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.closeOCRPreviewIfPointerLeft()
            }
        }
    }

    private func removeMouseMonitors() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private func closeOCRPreviewIfPointerLeft() {
        guard ocrPreviewPopover?.isShown == true else { return }
        if !isMouseInsideRowOrPreview() {
            closeOCRPreview()
        }
    }

    private func isMouseInsideRowOrPreview() -> Bool {
        let mouseLocation = NSEvent.mouseLocation
        guard let rowWindow = window else { return false }

        let rowFrameInWindow = convert(bounds, to: nil)
        let rowFrameOnScreen = rowWindow.convertToScreen(rowFrameInWindow)

        guard let previewWindow = ocrPreviewPopover?.contentViewController?.view.window else {
            return rowFrameOnScreen.insetBy(dx: -8, dy: -8).contains(mouseLocation)
        }

        let previewFrame = previewWindow.frame
        let hoverRegion = rowFrameOnScreen
            .union(previewFrame)
            .insetBy(dx: -14, dy: -14)
        return hoverRegion.contains(mouseLocation)
    }

    private func isPointerOverActionButton(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        return pinButton.frame.insetBy(dx: -4, dy: -8).contains(point)
            || quickActionButton.frame.insetBy(dx: -4, dy: -8).contains(point)
            || deleteButton.frame.insetBy(dx: -4, dy: -8).contains(point)
    }

    @objc private func togglePin() {
        onTogglePin?(item)
    }

    @objc private func deleteItem() {
        onDelete?(item)
    }

    @objc private func runQuickAction() {
        if item.kind == .image {
            onSaveImage?(item)
        } else if item.url != nil {
            onOpen?(item)
        } else {
            sendAction(action, to: target)
        }
    }
}

private final class OCRPreviewViewController: NSViewController {
    private let text: String

    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 420, height: 260)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let size = preferredContentSize
        let contentView = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        contentView.material = .popover
        contentView.blendingMode = .behindWindow
        contentView.state = .active

        let titleLabel = NSTextField(labelWithString: "OCR Text")
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let copyButton = NSButton(title: "Copy All", target: self, action: #selector(copyAll))
        copyButton.image = NSImage(
            systemSymbolName: "doc.on.doc",
            accessibilityDescription: "Copy All OCR Text"
        )
        copyButton.imagePosition = .imageLeading
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.font = .systemFont(ofSize: 11, weight: .medium)
        copyButton.toolTip = "Copy all OCR text"
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        let textView = NSTextView()
        textView.string = text
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.frame = NSRect(x: 0, y: 0, width: size.width - 12, height: size.height - 44)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(
            width: size.width - 28,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textStorage?.setAttributes(
            [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor
            ],
            range: NSRange(location: 0, length: (textView.string as NSString).length)
        )

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(titleLabel)
        contentView.addSubview(copyButton)
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),

            copyButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            copyButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6)
        ])

        view = contentView
    }

    @objc private func copyAll() {
        ClipboardWriter.writeText(text)
        NSSound(named: "Pop")?.play()
    }
}

private func rowDetail(for item: ClipboardItem) -> String {
    var parts = [item.detail]
    if let ocrText = item.ocrText, !ocrText.isEmpty {
        parts.append("OCR \(singleLine(ocrText, limit: 56))")
    }
    if let sourceAppName = item.sourceAppName {
        parts.append(sourceAppName)
    }
    if item.isPinned {
        parts.append("Pinned")
    }
    return parts.joined(separator: "  •  ")
}

private func ocrPreviewText(for item: ClipboardItem) -> String? {
    guard item.kind == .image,
          let ocrText = item.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines),
          !ocrText.isEmpty
    else {
        return nil
    }

    return readableOCRPreviewText(ocrText, maxLength: 2_000)
}

private func readableOCRPreviewText(_ text: String, maxLength: Int) -> String {
    let lines = text
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    let shortLineCount = lines.filter { $0.count <= 24 }.count
    let shouldCollapseLines = lines.count >= 6 && Double(shortLineCount) / Double(lines.count) > 0.45
    let normalized = shouldCollapseLines
        ? lines.joined(separator: " ")
        : lines.joined(separator: "\n")

    guard normalized.count > maxLength else { return normalized }
    let end = normalized.index(normalized.startIndex, offsetBy: maxLength)
    return String(normalized[..<end]) + "\n..."
}

private func quickActionSymbolName(for item: ClipboardItem) -> String {
    switch item.kind {
    case .image:
        return "tray.and.arrow.down"
    case .url, .fileURL:
        return "arrow.up.forward.app"
    case .text:
        return "doc.on.doc"
    }
}

private func quickActionDescription(for item: ClipboardItem) -> String {
    switch item.kind {
    case .image:
        return "Save Image"
    case .url, .fileURL:
        return "Open"
    case .text:
        return "Copy"
    }
}

private func symbolName(for kind: ClipboardKind) -> String {
    switch kind {
    case .text:
        return "doc.text"
    case .url:
        return "link"
    case .fileURL:
        return "folder"
    case .image:
        return "photo"
    }
}

private func iconBackgroundColor(for kind: ClipboardKind) -> NSColor {
    switch kind {
    case .text:
        return NSColor.systemBlue.withAlphaComponent(0.22)
    case .url:
        return NSColor.systemGreen.withAlphaComponent(0.20)
    case .fileURL:
        return NSColor.systemOrange.withAlphaComponent(0.22)
    case .image:
        return NSColor.systemPurple.withAlphaComponent(0.22)
    }
}

private func iconTintColor(for kind: ClipboardKind) -> NSColor {
    switch kind {
    case .text:
        return NSColor.systemBlue.blended(withFraction: 0.25, of: .white) ?? .systemBlue
    case .url:
        return NSColor.systemGreen.blended(withFraction: 0.20, of: .white) ?? .systemGreen
    case .fileURL:
        return NSColor.systemOrange.blended(withFraction: 0.20, of: .white) ?? .systemOrange
    case .image:
        return NSColor.systemPurple.blended(withFraction: 0.25, of: .white) ?? .systemPurple
    }
}

private func imagePixelSize(_ image: NSImage) -> (width: Int, height: Int) {
    if let representation = image.representations.first {
        return (representation.pixelsWide, representation.pixelsHigh)
    }

    return (Int(image.size.width), Int(image.size.height))
}

private func singleLine(_ text: String, limit: Int) -> String {
    let collapsed = text
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard collapsed.count > limit else { return collapsed }
    let end = collapsed.index(collapsed.startIndex, offsetBy: limit)
    return String(collapsed[..<end]) + "..."
}

private func formatBytes(_ count: Int) -> String {
    if count < 1024 {
        return "\(count) B"
    }

    if count < 1024 * 1024 {
        return String(format: "%.1f KB", Double(count) / 1024)
    }

    return String(format: "%.1f MB", Double(count) / 1024 / 1024)
}

private func fileExtension(for pasteboardType: NSPasteboard.PasteboardType?) -> String? {
    switch pasteboardType {
    case .png:
        return "png"
    case .tiff:
        return "tiff"
    default:
        guard let rawValue = pasteboardType?.rawValue.lowercased() else { return nil }
        if rawValue.contains("png") { return "png" }
        if rawValue.contains("jpeg") || rawValue.contains("jpg") { return "jpg" }
        if rawValue.contains("gif") { return "gif" }
        if rawValue.contains("tiff") { return "tiff" }
        return "png"
    }
}

private func allowedContentTypes(for extensionName: String) -> [UTType] {
    switch extensionName.lowercased() {
    case "png":
        return [.png]
    case "jpg", "jpeg":
        return [.jpeg]
    case "gif":
        return [.gif]
    case "tiff", "tif":
        return [.tiff]
    default:
        return [.image]
    }
}

private func fnv1a64(_ data: Data) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in data {
        hash ^= UInt64(byte)
        hash &*= 0x100000001b3
    }
    return String(hash, radix: 16)
}

private func log(_ message: String) {
    print("[clipboard-history-hud] \(message)")
}
