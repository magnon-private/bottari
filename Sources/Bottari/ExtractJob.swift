import AppKit
import BottariCore

/// 백그라운드 압축 해제 + 진행 패널. 암호가 필요하면 물어보고 다시 시도한다.
final class ExtractJob {
    private static var retained: [ObjectIdentifier: ExtractJob] = [:]

    let archive: URL
    let destination: URL
    let selection: [String]?
    let overwrite: Bool
    let totalBytes: Int64?
    var passphrase: String?
    private let showDelay: TimeInterval
    private let cancel = CancelFlag()
    private var panel: ProgressPanel?
    private var finished = false
    private var stats = ExtractResult()
    private var carried = 0     // 암호 재시도 전에 이미 푼 파일 수
    private var completion: ((Result<ExtractResult, Error>) -> Void)?

    init(archive: URL, destination: URL, selection: [String]? = nil, overwrite: Bool,
         passphrase: String?, totalBytes: Int64? = nil, showDelay: TimeInterval = 0) {
        self.archive = archive
        self.destination = destination
        self.selection = selection
        self.overwrite = overwrite
        self.passphrase = passphrase
        self.totalBytes = totalBytes
        self.showDelay = showDelay
    }

    func start(completion: @escaping (Result<ExtractResult, Error>) -> Void) {
        self.completion = completion
        ExtractJob.retained[ObjectIdentifier(self)] = self
        DispatchQueue.main.asyncAfter(deadline: .now() + showDelay) { [weak self] in
            guard let self = self, !self.finished else { return }
            let p = ProgressPanel(title: "압축 푸는 중 — \(self.archive.lastPathComponent)")
            p.onCancel = { [weak self] in self?.cancel.isCancelled = true }
            p.update(text: "준비 중…", fraction: self.totalBytes == nil ? nil : 0)
            p.center()
            p.makeKeyAndOrderFront(nil)
            self.panel = p
        }
        run()
    }

    private func run() {
        let archive = archive, destination = destination, selection = selection
        let overwrite = overwrite, passphrase = passphrase, total = totalBytes, cancel = cancel
        stats = ExtractResult()
        let stats = self.stats
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try ArchiveExtractor.extract(
                    archive: archive, to: destination, selection: selection, overwrite: overwrite,
                    passphrase: passphrase, totalBytes: total, result: stats, cancel: cancel) { p in
                    DispatchQueue.main.async { self?.panel?.update(text: p.currentPath, fraction: p.fraction) }
                }
                DispatchQueue.main.async { self?.finishSuccess(result) }
            } catch ArchiveError.passphraseRequired {
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.panel?.orderOut(nil)
                    self.carried += self.stats.extracted
                    let retry = !(self.passphrase ?? "").isEmpty
                    if let pw = PassphrasePrompt.ask(archive: self.archive, retry: retry) {
                        self.passphrase = pw
                        self.panel?.makeKeyAndOrderFront(nil)
                        self.run()
                    } else {
                        self.finish(.failure(ArchiveError.cancelled))
                    }
                }
            } catch {
                DispatchQueue.main.async { self?.finish(.failure(error)) }
            }
        }
    }

    private func finishSuccess(_ r: ExtractResult) {
        // 암호 재시도 때 앞선 시도에서 이미 푼 파일은 "존재하여 건너뜀"으로 다시 집계되므로 보정한다.
        if !overwrite && carried > 0 {
            r.extracted += carried
            r.skipped = max(0, r.skipped - carried)
        }
        finish(.success(r))
    }

    private func finish(_ result: Result<ExtractResult, Error>) {
        guard !finished else { return }
        finished = true
        panel?.onCancel = nil
        panel?.close()
        panel = nil
        ExtractJob.retained[ObjectIdentifier(self)] = nil
        completion?(result)
        completion = nil
    }

    /// 결과 요약 알림이 필요하면 표시한다.
    static func reportIfNeeded(_ r: ExtractResult, window: NSWindow?) {
        guard r.skipped > 0 || !r.warnings.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "압축을 풀었지만 확인할 내용이 있습니다"
        var lines = ["\(r.extracted)개 파일을 풀었습니다."]
        if r.skipped > 0 { lines.append("\(r.skipped)개 파일은 이미 존재하여 건너뛰었습니다. (덮어쓰기 옵션으로 변경 가능)") }
        lines.append(contentsOf: r.warnings.prefix(8))
        if r.warnings.count > 8 { lines.append("… 외 \(r.warnings.count - 8)건") }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "확인")
        if let w = window, w.isVisible { alert.beginSheetModal(for: w) } else { NSApp.activate(ignoringOtherApps: true); alert.runModal() }
    }
}
