import AppKit
import UniformTypeIdentifiers
import BottariCore

enum Fmt {
    static func size(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
    static func date(_ d: Date?) -> String { d.map { dateFormatter.string(from: $0) } ?? "" }

    /// "drwxr-xr-x" 형식
    static func attributes(mode: UInt16, isDirectory: Bool, isSymlink: Bool) -> String {
        guard mode != 0 else { return isDirectory ? "d" : "" }
        let bits = Array("rwxrwxrwx")
        var s = String(isDirectory ? "d" : (isSymlink ? "l" : "-"))
        for i in 0..<9 { s.append(mode & (1 << UInt16(8 - i)) != 0 ? bits[i] : "-") }
        return s
    }
}

enum ArchiveTypes {
    static let extensions: Set<String> = ["zip", "jar", "7z", "rar", "tar", "tgz", "gz", "tbz", "tbz2", "bz2",
                                          "txz", "xz", "tzst", "zst", "lz", "lzma", "cab", "iso", "cpio",
                                          "xar", "lha", "lzh"]
    static func isArchive(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }
}

enum Icons {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 256
        return c
    }()

    static func icon(ext: String, isDirectory: Bool, isLink: Bool) -> NSImage {
        let key = isDirectory ? "/dir" : (isLink ? "/link" : ext.lowercased())
        if let c = cache.object(forKey: key as NSString) { return c }
        let type: UTType
        if isDirectory { type = .folder }
        else if isLink { type = .aliasFile }
        else { type = UTType(filenameExtension: key) ?? .data }
        let img = (NSWorkspace.shared.icon(for: type).copy() as? NSImage) ?? NSImage()
        img.size = NSSize(width: 16, height: 16)
        cache.setObject(img, forKey: key as NSString)
        return img
    }

    static func kind(ext: String, isDirectory: Bool, isLink: Bool) -> String {
        if isDirectory { return "폴더" }
        if isLink { return "심볼릭 링크" }
        if let d = UTType(filenameExtension: ext)?.localizedDescription { return d }
        return ext.isEmpty ? "파일" : "\(ext.uppercased()) 파일"
    }
}

func showError(_ error: Error, window: NSWindow?) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "작업을 완료하지 못했습니다"
    alert.informativeText = error.localizedDescription
    alert.addButton(withTitle: "확인")
    if let w = window, w.isVisible { alert.beginSheetModal(for: w) } else { NSApp.activate(ignoringOtherApps: true); alert.runModal() }
}

enum PassphrasePrompt {
    static func ask(archive: URL, retry: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = "암호 입력"
        alert.informativeText = (retry ? "암호가 올바르지 않습니다. " : "") + "‘\(archive.lastPathComponent)’ 의 암호를 입력하세요."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}

/// 진행률 패널
final class ProgressPanel: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private let percent = NSTextField(labelWithString: "0%")
    private let bar = NSProgressIndicator()
    var onCancel: (() -> Void)?

    init(title: String) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 128),
                   styleMask: [.titled], backing: .buffered, defer: false)
        self.title = title
        level = .floating
        isReleasedWhenClosed = false

        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = .secondaryLabelColor
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        percent.alignment = .right
        percent.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let cancel = NSButton(title: "취소", target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"

        for v in [label, percent, bar, cancel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            contentView!.addSubview(v)
        }
        let c = contentView!
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: c.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: percent.leadingAnchor, constant: -8),
            percent.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            percent.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -20),
            percent.widthAnchor.constraint(equalToConstant: 44),
            bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -20),
            cancel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 14),
            cancel.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -20),
            cancel.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -14),
        ])
    }

    func setIndeterminate() {
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        percent.stringValue = ""
    }

    func update(text: String, fraction: Double?) {
        label.stringValue = text
        if let f = fraction {
            bar.isIndeterminate = false
            bar.doubleValue = f
            percent.stringValue = "\(Int(f * 100))%"
        }
    }

    @objc private func cancelTapped() { onCancel?() }
}
