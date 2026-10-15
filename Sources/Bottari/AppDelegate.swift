import AppKit
import UniformTypeIdentifiers
import BottariCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [ArchiveWindowController] = []
    var tempDirs: [URL] = []
    private var handledExternalRequest = false   // Finder 열기/서비스로 시작됨
    private var backgroundJobs = 0

    // MARK: - 수명주기

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        sweepStaleTempDirs()
        // 파일/서비스 요청 없이 직접 실행했다면 빈 창을 보여준다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, !self.handledExternalRequest, self.controllers.isEmpty else { return }
            self.newController().showWindow(nil)
        }
    }

    /// 강제 종료/크래시로 남은 이전 실행의 임시 폴더(Bottari-*)를 하루 이상 지난 것만 정리한다.
    private func sweepStaleTempDirs() {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory
            let names = (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? []
            let cutoff = Date().addingTimeInterval(-24 * 3600)
            for name in names where name.hasPrefix("Bottari-") {
                let url = tmp.appendingPathComponent(name)
                // 미리보기 앱이 폴더 안에 잠금 파일을 만들면 수정 시각이 갱신되므로 생성 시각을 기준으로 한다.
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                if let c = created, c < cutoff { try? fm.removeItem(at: url) }
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newController().showWindow(nil) }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handledExternalRequest = true
        urls.forEach { openArchive($0) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tempDirs.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    // MARK: - 창 관리

    private func newController() -> ArchiveWindowController {
        let c = ArchiveWindowController()
        controllers.append(c)
        return c
    }

    func controllerClosed(_ c: ArchiveWindowController) {
        controllers.removeAll { $0 === c }
        quitIfIdleBackgroundLaunch()
    }

    func openArchive(_ url: URL) {
        if let existing = controllers.first(where: { $0.openedOrPendingURL == url.standardizedFileURL }) {
            existing.showWindow(nil)
            return
        }
        let c = controllers.first(where: { $0.isPristine }) ?? newController()
        c.showWindow(nil)
        c.load(url)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var activeController: ArchiveWindowController? {
        controllers.first { $0.window?.isKeyWindow == true } ?? controllers.last
    }

    // MARK: - 메뉴 동작

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "열 압축파일을 선택하세요"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { openArchive($0) }
    }

    /// Finder 에서 압축파일을 더블클릭하면 Bottari 가 열리도록 기본 앱으로 지정한다.
    @objc func setAsDefaultApp(_ sender: Any?) {
        let ids = ["public.zip-archive", "org.7-zip.7-zip-archive", "com.rarlab.rar-archive", "public.tar-archive",
                   "org.gnu.gnu-zip-archive", "public.bzip2-archive", "public.cpio-archive", "public.iso-image"]
        let types = ids.compactMap { UTType($0) }
            + ["xz", "txz", "zst", "tzst", "cab", "lzma", "jar"].compactMap { UTType(filenameExtension: $0) }
        let confirm = NSAlert()
        confirm.messageText = "Bottari 를 기본 압축 프로그램으로 설정할까요?"
        confirm.informativeText = "zip, 7z, rar, tar, gz, bz2, xz 등 \(types.count)개 형식을 Finder 에서 더블클릭하면 Bottari 로 열립니다. 형식마다 macOS 확인 창이 나올 수 있습니다."
        confirm.addButton(withTitle: "설정")
        confirm.addButton(withTitle: "취소")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let group = DispatchGroup()
        var failed: [String] = []
        for t in types {
            group.enter()
            NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: t) { error in
                if error != nil { DispatchQueue.main.async { failed.append(t.preferredFilenameExtension ?? t.identifier) } }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let done = NSAlert()
            if failed.isEmpty {
                done.messageText = "설정했습니다"
                done.informativeText = "이제 압축파일을 더블클릭하면 Bottari 로 열립니다."
            } else {
                done.alertStyle = .warning
                done.messageText = "일부 형식은 설정하지 못했습니다"
                done.informativeText = failed.joined(separator: ", ") + "\n\nFinder 에서 파일 ▸ 정보 가져오기 ▸ 구분: 응용 프로그램 ▸ ‘모두 변경…’ 으로 직접 지정할 수 있습니다."
            }
            done.addButton(withTitle: "확인")
            done.runModal()
        }
    }

    @objc func newWindow(_ sender: Any?) { newController().showWindow(nil) }

    // MARK: - Finder 서비스 (우클릭 ▸ 서비스 / 빠른 동작)

    private func fileURLs(_ pboard: NSPasteboard) -> [URL] {
        (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    @objc func openArchiveService(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        handledExternalRequest = true
        let urls = fileURLs(pboard)
        DispatchQueue.main.async { urls.forEach { self.openArchive($0) } }
    }

    @objc func extractHereService(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        handledExternalRequest = true
        let urls = fileURLs(pboard)
        DispatchQueue.main.async {
            self.extractBatch(urls, destination: { ExtractDestinations.here($0) }, overwrite: UserDefaults.standard.bool(forKey: "overwrite"), reveal: false)
        }
    }

    @objc func extractToFolderService(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        handledExternalRequest = true
        let urls = fileURLs(pboard)
        DispatchQueue.main.async {
            self.extractBatch(urls, destination: { ExtractDestinations.named($0) }, overwrite: UserDefaults.standard.bool(forKey: "overwrite"), reveal: true)
        }
    }

    @objc func extractDialogService(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        handledExternalRequest = true
        let urls = fileURLs(pboard)
        DispatchQueue.main.async {
            guard let first = urls.first, let req = ExtractDialog.ask(archive: first, hasSelection: false) else {
                self.quitIfIdleBackgroundLaunch(); return
            }
            self.extractBatch(urls, destination: { req.destination(for: $0) }, overwrite: req.overwrite, reveal: true)
        }
    }

    /// 여러 압축파일을 차례로 푼다.
    func extractBatch(_ urls: [URL], destination: @escaping (URL) -> URL, overwrite: Bool, reveal: Bool) {
        backgroundJobs += 1
        var queue = urls
        var revealed: [URL] = []
        func next() {
            guard !queue.isEmpty else {
                if reveal && !revealed.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(revealed) }
                backgroundJobs -= 1
                quitIfIdleBackgroundLaunch()
                return
            }
            let archive = queue.removeFirst()
            let dest = destination(archive)
            let job = ExtractJob(archive: archive, destination: dest, overwrite: overwrite, passphrase: nil)
            job.start { result in
                switch result {
                case .success(let r):
                    revealed.append(dest)
                    ExtractJob.reportIfNeeded(r, window: nil)
                case .failure(let e):
                    if case ArchiveError.cancelled = e { queue.removeAll() } else { showError(e, window: nil) }
                }
                next()
            }
        }
        next()
    }

    /// 서비스만을 위해 실행된 경우 작업이 끝나면 종료한다.
    private func quitIfIdleBackgroundLaunch() {
        guard handledExternalRequest, backgroundJobs == 0, controllers.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if self.backgroundJobs == 0 && self.controllers.isEmpty { NSApp.terminate(nil) }
        }
    }

    // MARK: - 메뉴

    private func buildMenu() {
        let main = NSMenu()
        func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                 _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = target
            menu.addItem(item)
        }
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(); main.addItem(item)
            let m = NSMenu(title: title); item.submenu = m
            return m
        }

        let appMenu = submenu("Bottari")
        add(appMenu, "Bottari 정보", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        add(appMenu, "기본 압축 프로그램으로 설정…", #selector(setAsDefaultApp(_:)), target: self)
        appMenu.addItem(.separator())
        let services = NSMenuItem(title: "서비스", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "서비스")
        services.submenu = servicesMenu
        appMenu.addItem(services)
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())
        add(appMenu, "Bottari 가리기", #selector(NSApplication.hide(_:)), "h")
        add(appMenu, "다른 앱 가리기", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(appMenu, "모두 보기", #selector(NSApplication.unhideAllApplications(_:)))
        appMenu.addItem(.separator())
        add(appMenu, "Bottari 종료", #selector(NSApplication.terminate(_:)), "q")

        let file = submenu("파일")
        add(file, "새 창", #selector(newWindow(_:)), "n", target: self)
        add(file, "압축파일 열기…", #selector(openDocument(_:)), "o", target: self)
        file.addItem(.separator())
        add(file, "압축 풀기…", #selector(ArchiveWindowController.extract(_:)), "e")
        add(file, "현재 디렉토리에 풀기", #selector(ArchiveWindowController.extractHere(_:)), "e", [.command, .shift])
        add(file, "파일명 디렉토리에 풀기", #selector(ArchiveWindowController.extractToNamedFolder(_:)), "e", [.command, .option])
        add(file, "테스트", #selector(ArchiveWindowController.testArchive(_:)), "t")
        add(file, "정보", #selector(ArchiveWindowController.showInfo(_:)), "i")
        file.addItem(.separator())
        add(file, "닫기", #selector(NSWindow.performClose(_:)), "w")

        let edit = submenu("편집")
        add(edit, "모두 선택", #selector(ArchiveWindowController.selectAllRows(_:)), "a")

        let view = submenu("보기")
        add(view, "상위 폴더", #selector(ArchiveWindowController.goUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!))
        add(view, "새로 고침", #selector(ArchiveWindowController.refresh(_:)), "r")
        add(view, "숨김 파일 보기", #selector(ArchiveWindowController.toggleHidden(_:)), ".", [.command, .shift])

        let win = submenu("윈도우")
        add(win, "최소화", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(win, "확대/축소", #selector(NSWindow.performZoom(_:)))
        win.addItem(.separator())
        add(win, "모두 앞으로 가져오기", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }
}
