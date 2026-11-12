import AppKit
import CVibechar

struct SyntaxSpan: Decodable { let start: Int; let length: Int; let role: Int }
struct SyntaxFrame: Decodable {
    let serial: UInt64; let document: UInt64; let revision: UInt64
    let language: String; let syntax: String; let reason: String
    let automatic: Bool; let complete: Bool; let limited: Bool
    let spans: [SyntaxSpan]
}
struct LanguageChoice: Decodable { let id: String; let name: String; let extensions: [String] }

func languageChoices(_ query: String) -> [LanguageChoice] {
    let query = Array(query.utf8.prefix(128))
    return query.withUnsafeBufferPointer { input in
        let length = vc_syntax_choices(input.baseAddress, input.count, nil, 0)
        var bytes = [UInt8](repeating: 0, count: length)
        let copied = bytes.withUnsafeMutableBufferPointer { vc_syntax_choices(input.baseAddress, input.count, $0.baseAddress, $0.count) }
        guard copied == length else { return [] }
        return (try? JSONDecoder().decode([LanguageChoice].self, from: Data(bytes))) ?? []
    }
}

enum SyntaxColors {
    private static let light: [UInt32] = [0x282B29,0x9C4263,0x427445,0x956529,0x81867C,0x7761A1,0x356B9A,0x257D82,0xBD4C2B,0x356B9A,0x777D73]
    private static let dark: [UInt32] = [0xE3E5DF,0xDDA4BB,0xB2CF9B,0xE2BA83,0x7F8B7B,0xC0B0DE,0x9DBFDA,0x8FC7C5,0xF49A6B,0x9DBFDA,0x969F91]
    private static let colors: [NSColor] = light.indices.map { index in
        NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua,.darkAqua]) == .darkAqua ? dark[index] : light[index]
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255)/255, green: CGFloat((rgb >> 8) & 255)/255, blue: CGFloat(rgb & 255)/255, alpha: 1)
        }
    }
    static func color(_ role: Int) -> NSColor { colors[max(0, min(role, colors.count - 1))] }
}

private final class LanguageRow: NSButton {
    var chosen = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        if chosen || isHighlighted {
            PocketPalette.hover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

@MainActor
final class LanguagePicker: NSViewController, NSSearchFieldDelegate {
    private let search = NSSearchField()
    private let hint: String
    private let picked: (String) -> Void
    private let dismissed: () -> Void
    private let empty = NSTextField(labelWithString: "No language found. Try an extension like ts.")
    private var buttons: [LanguageRow] = []
    private var choices: [LanguageChoice] = []
    private var generation = 0
    private var selected = 0
    private var searching = false
    private var enterPending = false
    init(hint: String, dismissed: @escaping () -> Void, picked: @escaping (String) -> Void) { self.hint = hint; self.dismissed = dismissed; self.picked = picked; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        let surface = NSView(frame: NSRect(x: 0, y: 0, width: 308, height: 332))
        view = surface
        search.frame = NSRect(x: 16, y: 282, width: 276, height: 28)
        search.placeholderString = "Language or extension…"
        search.delegate = self
        search.sendsWholeSearchString = true
        search.target = self; search.action = #selector(chooseFirst)
        search.setAccessibilityLabel("Find a language")
        surface.addSubview(search)
        let caption = NSTextField(labelWithString: hint)
        caption.font = .systemFont(ofSize: 11); caption.textColor = .secondaryLabelColor
        caption.frame = NSRect(x: 18, y: 254, width: 272, height: 18); caption.lineBreakMode = .byTruncatingTail
        surface.addSubview(caption)
        empty.font = .systemFont(ofSize: 11); empty.textColor = .secondaryLabelColor
        empty.frame = NSRect(x: 18, y: 220, width: 272, height: 28); empty.isHidden = true
        surface.addSubview(empty)
        for index in 0..<7 {
            let button = LanguageRow(title: "", target: self, action: #selector(choose(_:)))
            button.tag = index; button.isBordered = false; button.alignment = .left
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.frame = NSRect(x: 16, y: 220 - index*32, width: 276, height: 28)
            button.cell?.lineBreakMode = .byTruncatingTail
            button.isHidden = true; buttons.append(button); surface.addSubview(button)
        }
        refresh()
    }
    override func viewDidAppear() { super.viewDidAppear(); view.window?.makeFirstResponder(search) }
    func controlTextDidChange(_ obj: Notification) { refresh() }
    private func refresh() {
        generation += 1; let version = generation; let query = search.stringValue
        searching = true; enterPending = false; selected = 0
        buttons.forEach { $0.isEnabled = false }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let choices = languageChoices(query)
            DispatchQueue.main.async {
                guard let self, self.generation == version else { return }
                self.choices = choices
                self.selected = min(self.selected, max(0, choices.count - 1))
                self.searching = false
                self.empty.isHidden = !choices.isEmpty
                for (index, button) in self.buttons.enumerated() {
                    button.isHidden = index >= choices.count
                    button.isEnabled = true; button.chosen = index == self.selected
                    if index < choices.count {
                        let choice = choices[index]
                        button.title = choice.id.isEmpty ? "Auto · detect for me" : choice.name
                        button.setAccessibilityLabel(button.title)
                        button.image = NSImage(systemSymbolName: choice.id.isEmpty ? "circle.dotted" : "chevron.right", accessibilityDescription: nil)
                        button.imagePosition = .imageLeading
                        button.contentTintColor = choice.id.isEmpty ? PocketPalette.accent : PocketPalette.ink
                    }
                }
                if self.enterPending { self.chooseFirst() }
            }
        }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { dismissed(); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { chooseFirst(); return true }
        if commandSelector == #selector(NSResponder.moveDown(_:)) || commandSelector == #selector(NSResponder.moveUp(_:)) {
            guard !choices.isEmpty else { return true }
            selected = (selected + (commandSelector == #selector(NSResponder.moveDown(_:)) ? 1 : choices.count - 1)) % choices.count
            for (index, button) in buttons.enumerated() { button.chosen = index == selected }
            return true
        }
        return false
    }
    @objc private func chooseFirst() {
        if searching { enterPending = true; return }
        enterPending = false
        if selected < choices.count { picked(choices[selected].id) }
    }
    @objc private func choose(_ sender: NSButton) { if sender.tag < choices.count { picked(choices[sender.tag].id) } }

    static func smokeTest(output: URL?) {
        var picked = "unselected"
        var dismissed = false
        let picker = LanguagePicker(hint: "JSON · JSON structure", dismissed: { dismissed = true }, picked: { picked = $0 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 308, height: 332), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = PocketSurface(frame: NSRect(x: 0, y: 0, width: 308, height: 332))
        window.contentView!.addSubview(picker.view)
        defer { window.close() }
        func waitForSearch() {
            let deadline = Date(timeIntervalSinceNow: 15)
            while picker.searching {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
                precondition(Date() < deadline, "Language search must finish")
            }
        }
        waitForSearch()
        precondition(picker.choices.count == 7 && picker.choices[0].id.isEmpty)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            for button in picker.buttons where !button.isHidden { precondition(picker.view.bounds.contains(button.frame)) }
            if let output {
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    let surface = window.contentView!
                    let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds)!
                    surface.cacheDisplay(in: surface.bounds, to: bitmap)
                    try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("language-picker-\(name).png"))
                }
            }
        }
        picker.search.stringValue = "py"; picker.refresh()
        picker.chooseFirst() // Enter may arrive before the background query returns.
        waitForSearch()
        precondition(picked == "Python")
        picker.search.stringValue = "unknown-language-xyz"; picker.refresh(); waitForSearch()
        precondition(picker.choices.isEmpty && !picker.empty.isHidden)
        precondition(picker.control(picker.search, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        precondition(dismissed)
        print("Language picker smoke passed: bounded search, extension alias, rapid Enter, no matches, Escape, light/dark layout")
    }
}
