import AppKit
import BottariCore

enum DestinationMode: Int {
    case here = 0       // 현재 디렉토리
    case named = 1      // 확장자를 제외한 파일명 디렉토리
    case custom = 2     // 직접 입력
}

struct ExtractRequest {
    var destination: URL
    var mode: DestinationMode
    var overwrite: Bool
    var onlySelected: Bool

    /// 여러 압축파일에 같은 선택을 적용할 때 파일별 대상 폴더
    func destination(for archive: URL) -> URL {
        switch mode {
        case .here: return ExtractDestinations.here(archive)
        case .named: return ExtractDestinations.named(archive)
        case .custom: return destination
        }
    }
}

enum ExtractDestinations {
    static func here(_ archive: URL) -> URL { archive.deletingLastPathComponent() }
    static func named(_ archive: URL) -> URL {
        archive.deletingLastPathComponent().appendingPathComponent(archiveStem(archive), isDirectory: true)
    }
}

/// "압축 풀기" 대화상자: 현재 디렉토리 / 파일명 디렉토리 / 직접 입력 중 선택
final class ExtractDialog: NSObject {
    private let archive: URL
    private var radios: [NSButton] = []
    private let pathField = NSTextField()
    private let scope = NSPopUpButton()
    private let overwrite = NSButton(checkboxWithTitle: "기존 파일 덮어쓰기", target: nil, action: nil)
    private var mode: DestinationMode

    private init(archive: URL) {
        self.archive = archive
        self.mode = DestinationMode(rawValue: UserDefaults.standard.integer(forKey: "extractMode")) ?? .named
        super.init()
    }

    static func ask(archive: URL, hasSelection: Bool) -> ExtractRequest? {
        ExtractDialog(archive: archive).run(hasSelection: hasSelection)
    }

    private func secondary(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.lineBreakMode = .byTruncatingMiddle
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        return l
    }

    private func indented(_ view: NSView) -> NSView {
        let box = NSStackView(views: [view])
        box.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 0)
        return box
    }

    private func run(hasSelection: Bool) -> ExtractRequest? {
        let defaults = UserDefaults.standard
        let hereURL = ExtractDestinations.here(archive)
        let namedURL = ExtractDestinations.named(archive)

        let titles = ["현재 디렉토리", "‘\(archiveStem(archive))’ 디렉토리 (파일명)", "직접 지정"]
        radios = titles.enumerated().map { i, t in
            let b = NSButton(radioButtonWithTitle: t, target: self, action: #selector(radioChanged(_:)))
            b.tag = i
            b.state = i == mode.rawValue ? .on : .off
            return b
        }

        pathField.placeholderString = "압축 풀 폴더 경로"
        pathField.stringValue = defaults.string(forKey: "customDir") ?? NSHomeDirectory()
        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let browse = NSButton(title: "선택…", target: self, action: #selector(browse))
        let customRow = NSStackView(views: [pathField, browse])
        customRow.spacing = 8

        let customBox = indented(customRow)
        var views: [NSView] = [
            radios[0], indented(secondary(hereURL.path)),
            radios[1], indented(secondary(namedURL.path + "/")),
            radios[2], customBox,
        ]
        if hasSelection {
            scope.addItems(withTitles: ["모든 항목", "선택한 항목만"])
            scope.selectItem(at: 1)
            let label = NSTextField(labelWithString: "대상:")
            let row = NSStackView(views: [label, scope])
            row.spacing = 8
            views.append(row)
        }
        overwrite.state = defaults.bool(forKey: "overwrite") ? .on : .off
        views.append(overwrite)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(14, after: customBox)
        stack.layoutSubtreeIfNeeded()
        stack.frame = NSRect(origin: .zero, size: NSSize(width: 450, height: stack.fittingSize.height))
        updateEnabled()

        let alert = NSAlert()
        alert.messageText = "압축 풀기"
        alert.informativeText = archive.lastPathComponent
        alert.accessoryView = stack
        alert.addButton(withTitle: "압축 풀기")
        alert.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        defaults.set(mode.rawValue, forKey: "extractMode")
        defaults.set(overwrite.state == .on, forKey: "overwrite")

        let dest: URL
        switch mode {
        case .here: dest = hereURL
        case .named: dest = namedURL
        case .custom:
            var p = (pathField.stringValue.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            if p.isEmpty {
                guard let chosen = chooseFolder() else { return nil }
                p = chosen.path
            }
            defaults.set(p, forKey: "customDir")
            dest = URL(fileURLWithPath: p, isDirectory: true)
        }
        return ExtractRequest(destination: dest, mode: mode, overwrite: overwrite.state == .on,
                              onlySelected: hasSelection && scope.indexOfSelectedItem == 1)
    }

    private func updateEnabled() {
        pathField.isEnabled = mode == .custom
    }

    @objc private func radioChanged(_ sender: NSButton) {
        mode = DestinationMode(rawValue: sender.tag) ?? .named
        for r in radios { r.state = r === sender ? .on : .off }
        updateEnabled()
        if mode == .custom { pathField.window?.makeFirstResponder(pathField) }
    }

    @objc private func browse() {
        if let url = chooseFolder() {
            pathField.stringValue = url.path
            radioChanged(radios[2])
        }
    }

    private func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "선택"
        panel.message = "압축을 풀 폴더를 선택하세요"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
