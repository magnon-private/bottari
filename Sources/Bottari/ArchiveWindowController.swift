import AppKit
import BottariCore

/// 드래그 앤 드롭으로 압축파일을 여는 컨테이너 뷰
final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(sender).isEmpty ? [] : .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let u = urls(sender)
        guard !u.isEmpty else { return false }
        onDrop?(u)
        return true
    }
}

final class ArchiveTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onBackspace: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn?()          // return / enter
        case 51: onBackspace?()           // delete
        default: super.keyDown(with: event)
        }
    }
}

private extension NSToolbarItem.Identifier {
    static let open = NSToolbarItem.Identifier("open")
    static let extract = NSToolbarItem.Identifier("extract")
    static let test = NSToolbarItem.Identifier("test")
    static let info = NSToolbarItem.Identifier("info")
}

/// 표의 한 줄. 일반 디렉토리의 항목이거나 압축파일 내부의 항목.
struct Row {
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?
    let attr: String
    let kind: String
    let encrypted: Bool
    let node: ArchiveNode?     // 압축파일 내부 항목
    let url: URL?              // 파일 시스템 항목
    let icon: NSImage
    var isArchive: Bool { !isDirectory && (url.map(ArchiveTypes.isArchive) ?? false) }
    var key: String { node?.path ?? url?.path ?? name }
}

final class ArchiveWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
                                      NSToolbarDelegate, NSToolbarItemValidation, NSMenuItemValidation, NSFilePromiseProviderDelegate,
                                      NSTextFieldDelegate {
    /// 현재 열린 압축파일 (nil 이면 디렉토리 탐색 모드)
    private(set) var archiveURL: URL?
    private var fsDir: URL
    private var listing: ArchiveListing?
    private var root: ArchiveNode?
    private var currentDir: ArchiveNode?
    private var rows: [Row] = []
    private var passphrase: String?
    private var loadToken = 0
    /// 아직 아무것도 열지/탐색하지 않은 처음 상태 (Finder 에서 열 때 재사용)
    private(set) var isPristine = true

    private let table = ArchiveTableView()
    private let upButton = NSButton()
    private let pathField = NSTextField()
    private let leftStatus = NSTextField(labelWithString: "")
    private let rightStatus = NSTextField(labelWithString: "")
    private let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = 1   // 드래그마다 압축파일 전체를 읽으므로 동시에 하나씩만
        return q
    }()
    private var testCancel: CancelFlag?
    private var testPanel: ProgressPanel?

    private static var cascade = NSPoint.zero
    private var inArchive: Bool { archiveURL != nil && root != nil }
    private var showHidden: Bool { UserDefaults.standard.bool(forKey: "showHidden") }

    init() {
        let last = UserDefaults.standard.string(forKey: "lastDir")
        var isDir: ObjCBool = false
        if let last = last, FileManager.default.fileExists(atPath: last, isDirectory: &isDir), isDir.boolValue {
            fsDir = URL(fileURLWithPath: last, isDirectory: true)
        } else {
            fsDir = FileManager.default.homeDirectoryForCurrentUser
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 560, height: 320)
        super.init(window: w)
        w.delegate = self
        setupUI()
        w.center()
        ArchiveWindowController.cascade = w.cascadeTopLeft(from: ArchiveWindowController.cascade)
        browse(fsDir)
        isPristine = true
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI

    private func setupUI() {
        guard let window = window else { return }
        let content = DropView()
        content.onDrop = { [weak self] urls in self?.handleDrop(urls) }
        window.contentView = content

        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .expanded

        upButton.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "상위 폴더")
        upButton.bezelStyle = .texturedRounded
        upButton.target = self
        upButton.action = #selector(goUp(_:))
        upButton.toolTip = "상위 폴더 (⌘↑)"

        pathField.isEditable = true
        pathField.isBezeled = true
        pathField.bezelStyle = .squareBezel
        pathField.lineBreakMode = .byTruncatingHead
        pathField.usesSingleLineMode = true
        pathField.placeholderString = "경로를 입력하고 Return"
        pathField.target = self
        pathField.action = #selector(pathEntered(_:))

        let pathBar = NSStackView(views: [upButton, pathField])
        pathBar.spacing = 6
        pathBar.translatesAutoresizingMaskIntoConstraints = false

        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.style = .plain
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.doubleAction = #selector(openSelected(_:))
        table.target = self
        table.onReturn = { [weak self] in self?.openSelected(nil) }
        table.onBackspace = { [weak self] in self?.goUp(nil) }
        table.setDraggingSourceOperationMask(.copy, forLocal: false)

        func addColumn(_ id: String, _ title: String, _ width: CGFloat, min: CGFloat = 50, right: Bool = false) {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            c.minWidth = min
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            if right { c.headerCell.alignment = .right }
            table.addTableColumn(c)
        }
        addColumn("name", "이름", 300, min: 120)
        addColumn("size", "크기", 90, right: true)
        addColumn("modified", "수정한 날짜", 130)
        addColumn("attr", "속성", 90)
        addColumn("kind", "종류", 130)
        addColumn("enc", "암호", 44, min: 36)
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        for l in [leftStatus, rightStatus] {
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            l.lineBreakMode = .byTruncatingTail
        }
        rightStatus.alignment = .right
        rightStatus.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let status = NSStackView(views: [leftStatus, rightStatus])
        status.distribution = .fill
        status.translatesAutoresizingMaskIntoConstraints = false
        leftStatus.setContentHuggingPriority(.defaultLow, for: .horizontal)

        content.addSubview(pathBar)
        content.addSubview(scroll)
        content.addSubview(status)
        NSLayoutConstraint.activate([
            pathBar.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            pathBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            pathBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: pathBar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 5),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
        ])
    }

    // MARK: - 디렉토리 탐색

    /// 일반 디렉토리를 표시한다. select 가 있으면 그 항목을 선택한다.
    func browse(_ dir: URL, select: URL? = nil) {
        cancelActiveTest()
        loadToken += 1
        isPristine = false
        fsDir = dir.standardizedFileURL
        archiveURL = nil
        listing = nil
        root = nil
        currentDir = nil
        passphrase = nil
        UserDefaults.standard.set(fsDir.path, forKey: "lastDir")
        window?.title = fsDir.path == "/" ? "/" : fsDir.lastPathComponent
        window?.representedURL = fsDir
        reloadRows(select: select?.path)
    }

    private func fileSystemRows() -> [Row] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: fsDir.path)) ?? []
        var result: [Row] = []
        for name in names {
            if !showHidden && name.hasPrefix(".") { continue }
            let url = fsDir.appendingPathComponent(name)
            var st = stat()
            guard lstat(url.path, &st) == 0 else { continue }
            let isLink = (st.st_mode & S_IFMT) == S_IFLNK
            if isLink { var target = stat(); if stat(url.path, &target) == 0 { st = target } }
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            let ext = (name as NSString).pathExtension
            let isApp = isDir && ext.lowercased() == "app"
            let icon: NSImage
            if isApp {
                icon = (NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage) ?? NSImage()
                icon.size = NSSize(width: 16, height: 16)
            } else {
                icon = Icons.icon(ext: ext, isDirectory: isDir, isLink: isLink)
            }
            result.append(Row(name: name, isDirectory: isDir, size: isDir ? 0 : Int64(st.st_size),
                              modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
                              attr: Fmt.attributes(mode: UInt16(st.st_mode & 0o7777), isDirectory: isDir, isSymlink: isLink),
                              kind: isApp ? "응용 프로그램" : Icons.kind(ext: ext, isDirectory: isDir, isLink: isLink),
                              encrypted: false, node: nil, url: url, icon: icon))
        }
        return result
    }

    private func archiveRows() -> [Row] {
        (currentDir?.children ?? []).map { n in
            let ext = (n.name as NSString).pathExtension
            let link = n.entry?.isSymlink == true
            return Row(name: n.name, isDirectory: n.isDirectory, size: n.size, modified: n.entry?.modified,
                       attr: Fmt.attributes(mode: n.entry?.mode ?? 0, isDirectory: n.isDirectory, isSymlink: link),
                       kind: Icons.kind(ext: ext, isDirectory: n.isDirectory, isLink: link),
                       encrypted: n.entry?.isEncrypted == true, node: n, url: nil,
                       icon: Icons.icon(ext: ext, isDirectory: n.isDirectory, isLink: link))
        }
    }

    // MARK: - 압축파일 열기

    private func handleDrop(_ urls: [URL]) {
        guard let first = urls.first else { return }
        open(first)
        for extra in urls.dropFirst() { (NSApp.delegate as? AppDelegate)?.openArchive(extra) }
    }

    /// 디렉토리면 탐색, 파일이면 압축파일로 연다.
    private func open(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { NSSound.beep(); return }
        if isDir.boolValue { browse(url) } else { load(url) }
    }

    func load(_ url: URL, passphrase: String? = nil) {
        cancelActiveTest()
        loadToken += 1
        let token = loadToken
        isPristine = false
        leftStatus.stringValue = "여는 중…"
        rightStatus.stringValue = ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try ArchiveReader.list(url: url, passphrase: passphrase) }
            DispatchQueue.main.async {
                guard let self = self, token == self.loadToken else { return }
                switch result {
                case .success(let l):
                    self.archiveURL = url
                    self.fsDir = url.deletingLastPathComponent()
                    self.listing = l
                    self.root = ArchiveNode.build(from: l.entries)
                    self.currentDir = self.root
                    self.passphrase = passphrase
                    self.window?.title = url.lastPathComponent
                    self.window?.representedURL = url
                    self.reloadRows()
                case .failure(let error):
                    if case ArchiveError.passphraseRequired = error,
                       let pw = PassphrasePrompt.ask(archive: url, retry: passphrase != nil) {
                        self.load(url, passphrase: pw)
                        return
                    }
                    if case ArchiveError.passphraseRequired = error {} else { showError(error, window: self.window) }
                    self.updateUI()   // 이전 화면 유지
                }
            }
        }
    }

    // MARK: - 목록 / 정렬 / 상태

    private func reloadRows(select: String? = nil) {
        rows = inArchive ? archiveRows() : fileSystemRows()
        sortRows()
        table.reloadData()
        table.deselectAll(nil)
        if let s = select, let i = rows.firstIndex(where: { $0.key == s }) {
            table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
            table.scrollRowToVisible(i)
        } else {
            table.scrollRowToVisible(0)
        }
        table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("enc"))?.isHidden = !(listing?.hasEncrypted ?? false)
        updateUI()
    }

    private func sortRows() {
        let desc = table.sortDescriptors.first
        let key = desc?.key ?? "name"
        let asc = desc?.ascending ?? true
        func cmp(_ a: Row, _ b: Row) -> ComparisonResult {
            switch key {
            case "size": return a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
            case "modified": return (a.modified ?? .distantPast).compare(b.modified ?? .distantPast)
            case "attr": return a.attr.compare(b.attr)
            case "kind": return a.kind.localizedStandardCompare(b.kind)
            case "enc": return a.encrypted == b.encrypted ? .orderedSame : (a.encrypted ? .orderedDescending : .orderedAscending)
            default: return a.name.localizedStandardCompare(b.name)
            }
        }
        rows.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }   // 폴더가 항상 위
            var r = cmp(a, b)
            if r == .orderedSame { r = a.name.localizedStandardCompare(b.name) }
            return asc ? r == .orderedAscending : r == .orderedDescending
        }
    }

    private func updateUI() {
        upButton.isEnabled = inArchive || fsDir.path != "/"
        if inArchive, let url = archiveURL, let dir = currentDir {
            pathField.stringValue = url.path + (dir.path.isEmpty ? "" : "/" + dir.path) + "/"
        } else {
            pathField.stringValue = fsDir.path
        }
        updateStatus()
        window?.toolbar?.validateVisibleItems()
    }

    private func updateStatus() {
        let sel = selectedRows
        if sel.isEmpty {
            leftStatus.stringValue = "\(rows.count)개 개체"
        } else {
            let total = sel.reduce(Int64(0)) { $0.saturatingAdding($1.size) }
            leftStatus.stringValue = "\(rows.count)개 개체 중 \(sel.count)개 선택" + (total > 0 ? "  ·  \(Fmt.size(total))" : "")
        }
        if inArchive, let l = listing {
            var text = "\(l.formatName)  ·  파일 \(l.fileCount)개  ·  \(Fmt.size(l.totalSize)) (압축파일 \(Fmt.size(l.fileSize)))"
            if l.skippedEntries > 0 { text += "  ·  안전하지 않은 경로 \(l.skippedEntries)개 숨김" }
            rightStatus.stringValue = text
        } else {
            rightStatus.stringValue = ""
        }
    }

    private var selectedRows: [Row] {
        table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0] : nil }
    }
    private var selectedNodes: [ArchiveNode] { selectedRows.compactMap { $0.node } }

    // MARK: - 테이블

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        let keep = Set(selectedRows.map { $0.key })
        sortRows()
        table.reloadData()
        let idx = IndexSet(rows.enumerated().filter { keep.contains($0.element.key) }.map { $0.offset })
        table.selectRowIndexes(idx, byExtendingSelection: false)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateStatus()
        window?.toolbar?.validateVisibleItems()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, row < rows.count else { return nil }
        let r = rows[row]
        let id = col.identifier
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id)
        let text: String
        switch id.rawValue {
        case "name":
            text = r.name
            cell.imageView?.image = r.icon
        case "size": text = r.isDirectory && r.size == 0 ? "" : Fmt.size(r.size)
        case "modified": text = Fmt.date(r.modified)
        case "attr": text = r.attr
        case "kind": text = r.kind
        case "enc": text = r.encrypted ? "*" : ""
        default: text = ""
        }
        cell.textField?.stringValue = text
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingMiddle
        cell.addSubview(tf)
        cell.textField = tf
        switch id.rawValue {
        case "name":
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(iv)
            cell.imageView = iv
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16),
                iv.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
            ])
        default:
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4).isActive = true
            if id.rawValue == "size" { tf.alignment = .right }
            if id.rawValue == "attr" { tf.font = .monospacedSystemFont(ofSize: 11, weight: .regular) }
            if ["size", "modified", "enc"].contains(id.rawValue) { tf.textColor = .secondaryLabelColor }
        }
        tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4).isActive = true
        tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor).isActive = true
        return cell
    }

    // MARK: - 탐색

    @objc func openSelected(_ sender: Any?) {
        let clicked = table.clickedRow
        let row: Row?
        if sender as AnyObject === table, clicked >= 0, clicked < rows.count { row = rows[clicked] }
        else { row = selectedRows.first }
        guard let r = row else { return }

        if inArchive, let n = r.node {
            if n.isDirectory { currentDir = n; reloadRows() } else { openTemporarily(n) }
        } else if let url = r.url {
            if r.isDirectory { browse(url) }
            else if r.isArchive { load(url) }
            else { NSWorkspace.shared.open(url) }
        }
    }

    @objc func goUp(_ sender: Any?) {
        if inArchive, let dir = currentDir {
            if let parent = dir.parent {
                currentDir = parent
                reloadRows(select: dir.path)
            } else if let archive = archiveURL {
                browse(archive.deletingLastPathComponent(), select: archive)   // 압축파일 밖으로
            }
        } else if fsDir.path != "/" {
            let child = fsDir
            browse(fsDir.deletingLastPathComponent(), select: child)
        }
    }

    @objc func refresh(_ sender: Any?) {
        if let u = archiveURL, inArchive { load(u, passphrase: passphrase) } else { reloadRows() }
    }

    @objc func toggleHidden(_ sender: Any?) {
        UserDefaults.standard.set(!showHidden, forKey: "showHidden")
        if !inArchive { reloadRows() }
    }

    @objc private func pathEntered(_ sender: NSTextField) {
        let p = (sender.stringValue.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard !p.isEmpty, FileManager.default.fileExists(atPath: p) else { NSSound.beep(); updateUI(); return }
        open(URL(fileURLWithPath: p))
        window?.makeFirstResponder(table)
    }

    /// 항목을 임시 폴더에 풀어서 기본 앱으로 연다.
    private func openTemporarily(_ node: ArchiveNode) {
        guard let url = archiveURL else { return }
        if node.entry?.isSymlink == true {
            // 링크가 압축 폴더 밖(예: /etc)을 가리킬 수 있어 따라가 열지 않는다.
            let alert = NSAlert()
            alert.messageText = "심볼릭 링크는 열지 않습니다"
            alert.informativeText = "‘\(node.name)’ → \(node.entry?.symlinkTarget ?? "?")"
            alert.addButton(withTitle: "확인")
            present(alert)
            return
        }
        var pw = passphrase
        if node.entry?.isEncrypted == true && (pw ?? "").isEmpty {
            guard let entered = PassphrasePrompt.ask(archive: url, retry: false) else { return }
            pw = entered     // 작업이 성공한 뒤에만 self.passphrase 에 저장한다
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Bottari-\(UUID().uuidString)", isDirectory: true)
        (NSApp.delegate as? AppDelegate)?.tempDirs.append(dir)
        let job = ExtractJob(archive: url, destination: dir, selection: [node.path], overwrite: true,
                             passphrase: pw, totalBytes: node.size, ownerAccess: true, showDelay: 0.6)
        job.start { [weak self] result in
            switch result {
            case .success:
                self?.passphrase = job.passphrase
                NSWorkspace.shared.open(dir.appendingPathComponent(node.name))
            case .failure(let e):
                if case ArchiveError.cancelled = e { return }
                showError(e, window: self?.window)
            }
        }
    }

    // MARK: - 압축 풀기 / 테스트 / 정보

    /// 탐색 모드에서 선택한 압축파일들
    private var selectedArchiveURLs: [URL] { selectedRows.filter { $0.isArchive }.compactMap { $0.url } }

    @objc func extract(_ sender: Any?) {
        if !inArchive {
            let urls = selectedArchiveURLs
            guard let first = urls.first, let req = ExtractDialog.ask(archive: first, hasSelection: false) else { return }
            (NSApp.delegate as? AppDelegate)?.extractBatch(urls, destination: { req.destination(for: $0) },
                                                           overwrite: req.overwrite, reveal: true)
            return
        }
        guard let url = archiveURL else { return }
        guard let req = ExtractDialog.ask(archive: url, hasSelection: !selectedNodes.isEmpty) else { return }
        runExtract(to: req.destination, overwrite: req.overwrite, onlySelected: req.onlySelected)
    }

    @objc func extractHere(_ sender: Any?) {
        quickExtract { ExtractDestinations.here($0) }
    }

    @objc func extractToNamedFolder(_ sender: Any?) {
        quickExtract { ExtractDestinations.named($0) }
    }

    private func quickExtract(_ dest: @escaping (URL) -> URL) {
        let overwrite = UserDefaults.standard.bool(forKey: "overwrite")
        if inArchive, let url = archiveURL {
            runExtract(to: dest(url), overwrite: overwrite, onlySelected: false)
        } else {
            (NSApp.delegate as? AppDelegate)?.extractBatch(selectedArchiveURLs, destination: dest, overwrite: overwrite, reveal: true)
        }
    }

    private func runExtract(to dest: URL, overwrite: Bool, onlySelected: Bool) {
        guard let url = archiveURL, let root = root else { return }
        let nodes = onlySelected ? selectedNodes : []
        // 풀 대상에 암호화된 파일이 있을 때만 미리 묻는다. (선택한 항목만 푸는 경우 그 항목들만 본다)
        var pw = passphrase
        let needsPassword = onlySelected ? nodes.contains { $0.hasEncrypted } : (listing?.hasEncrypted == true)
        if needsPassword && (pw ?? "").isEmpty {
            guard let entered = PassphrasePrompt.ask(archive: url, retry: false) else { return }
            pw = entered
        }
        let job = ExtractJob(archive: url, destination: dest,
                             selection: onlySelected ? nodes.map { $0.path } : nil,
                             overwrite: overwrite, passphrase: pw,
                             totalBytes: onlySelected ? nodes.reduce(Int64(0)) { $0.saturatingAdding($1.size) } : root.size)
        job.start { [weak self] result in
            switch result {
            case .success(let r):
                self?.passphrase = job.passphrase
                NSWorkspace.shared.activateFileViewerSelecting([dest])
                ExtractJob.reportIfNeeded(r, window: self?.window)
            case .failure(let e):
                if case ArchiveError.cancelled = e { return }
                showError(e, window: self?.window)
            }
        }
    }

    @objc func testArchive(_ sender: Any?) { startTest(passphrase: passphrase) }

    /// 창이 보이면 시트로, 아니면 모달로 알림을 표시한다. (window 강제 언래핑 방지)
    private func present(_ alert: NSAlert) {
        if let w = window, w.isVisible { alert.beginSheetModal(for: w) } else { alert.runModal() }
    }

    /// 진행 중인 테스트가 있으면 취소하고 진행 패널을 닫는다.
    private func cancelActiveTest() {
        testCancel?.isCancelled = true
        testPanel?.onCancel = nil
        testPanel?.close()
        testPanel = nil
        testCancel = nil
    }

    private func startTest(passphrase pw: String?) {
        guard let url = archiveURL, inArchive else { return }
        cancelActiveTest()
        let cancel = CancelFlag()
        let panel = ProgressPanel(title: "테스트 중 — \(url.lastPathComponent)")
        panel.onCancel = { cancel.isCancelled = true }
        panel.setIndeterminate()
        panel.update(text: "검사 중…", fraction: nil)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        testCancel = cancel
        testPanel = panel
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try ArchiveReader.test(url: url, passphrase: pw, cancel: cancel) { p in
                    DispatchQueue.main.async { panel.update(text: p, fraction: nil) }
                }
            }
            DispatchQueue.main.async {
                panel.onCancel = nil
                panel.close()
                guard let self = self else { return }
                self.testPanel = nil
                self.testCancel = nil
                if cancel.isCancelled { return }   // 사용자가 취소했거나 창이 닫힘

                if case .failure(let e) = result, case ArchiveError.passphraseRequired = e,
                   let entered = PassphrasePrompt.ask(archive: url, retry: !(pw ?? "").isEmpty) {
                    self.passphrase = entered
                    self.startTest(passphrase: entered)
                    return
                }
                let alert = NSAlert()
                switch result {
                case .success(let r):
                    if r.failures.isEmpty {
                        alert.messageText = "오류 없음"
                        alert.informativeText = "\(r.checkedFiles)개 파일을 검사했으며 문제가 없습니다."
                    } else {
                        alert.alertStyle = .warning
                        alert.messageText = "오류가 발견되었습니다"
                        alert.informativeText = r.failures.prefix(10).joined(separator: "\n")
                    }
                case .failure(let e):
                    alert.alertStyle = .warning
                    alert.messageText = "테스트하지 못했습니다"
                    alert.informativeText = e.localizedDescription
                }
                alert.addButton(withTitle: "확인")
                if let w = self.window, w.isVisible { alert.beginSheetModal(for: w) }
            }
        }
    }

    @objc func showInfo(_ sender: Any?) {
        guard let url = archiveURL, let l = listing, let root = root else { return }
        let dirs = l.entries.filter { $0.isDirectory }.count
        let ratio = l.totalSize > 0 ? String(format: "%.1f%%", Double(l.fileSize) / Double(l.totalSize) * 100) : "-"
        let alert = NSAlert()
        alert.messageText = url.lastPathComponent
        alert.informativeText = """
        경로: \(url.deletingLastPathComponent().path)
        형식: \(l.formatName)
        파일: \(l.fileCount)개   폴더: \(dirs)개
        원본 크기: \(Fmt.size(root.size))
        압축파일 크기: \(Fmt.size(l.fileSize))
        압축률: \(ratio)
        암호화: \(l.hasEncrypted ? "있음" : "없음")
        """
        alert.addButton(withTitle: "확인")
        present(alert)
    }

    @objc func openAnother(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "열 압축파일을 선택하세요"
        panel.directoryURL = fsDir
        guard panel.runModal() == .OK else { return }
        handleDrop(panel.urls)
    }

    @objc func selectAllRows(_ sender: Any?) { table.selectAll(nil) }

    // MARK: - 메뉴/툴바 유효성

    private func canExtract() -> Bool { inArchive || !selectedArchiveURLs.isEmpty }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .open: return true
        case .extract: return canExtract()
        default: return inArchive
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(extract(_:)), #selector(extractHere(_:)), #selector(extractToNamedFolder(_:)):
            return canExtract()
        case #selector(testArchive(_:)), #selector(showInfo(_:)): return inArchive
        case #selector(goUp(_:)): return inArchive || fsDir.path != "/"
        case #selector(toggleHidden(_:)):
            item.state = showHidden ? .on : .off
            return true
        default: return true
        }
    }

    // MARK: - 툴바

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.open, .extract, .test, .info]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.open, .extract, .test, .info, .flexibleSpace]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let spec: (String, String, String, Selector)
        switch id {
        case .open: spec = ("열기", "folder", "압축파일 열기 (⌘O)", #selector(openAnother(_:)))
        case .extract: spec = ("압축 풀기", "arrow.down.doc", "압축 풀기 (⌘E)", #selector(extract(_:)))
        case .test: spec = ("테스트", "checkmark.shield", "압축파일 무결성 검사 (⌘T)", #selector(testArchive(_:)))
        case .info: spec = ("정보", "info.circle", "압축파일 정보 (⌘I)", #selector(showInfo(_:)))
        default: return nil
        }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = spec.0
        item.paletteLabel = spec.0
        item.toolTip = spec.2
        item.image = NSImage(systemSymbolName: spec.1, accessibilityDescription: spec.0)
        item.target = self
        item.action = spec.3
        return item
    }

    // MARK: - 드래그 아웃 (Finder 로 끌어서 풀기)

    /// 드래그 시작 시점의 값 스냅샷. 백그라운드 큐에서 컨트롤러 상태를 읽지 않기 위함.
    private final class DragItem {
        let archive: URL
        let passphrase: String?
        let path: String
        let name: String
        init(archive: URL, passphrase: String?, path: String, name: String) {
            self.archive = archive; self.passphrase = passphrase; self.path = path; self.name = name
        }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < rows.count else { return nil }
        let r = rows[row]
        if let url = r.url { return url as NSURL }
        guard let node = r.node, let archive = archiveURL else { return nil }
        let provider = NSFilePromiseProvider(fileType: node.isDirectory ? "public.folder" : "public.data", delegate: self)
        provider.userInfo = DragItem(archive: archive, passphrase: passphrase, path: node.path, name: node.name)
        return provider
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (provider.userInfo as? DragItem)?.name ?? "item"
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { promiseQueue }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let item = provider.userInfo as? DragItem else { completionHandler(nil); return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Bottari-drag-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            _ = try ArchiveExtractor.extract(archive: item.archive, to: tmp, selection: [item.path], overwrite: true,
                                             passphrase: item.passphrase, ownerAccess: true, cancel: CancelFlag()) { _ in }
            let src = tmp.appendingPathComponent(item.name)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: src, to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    // MARK: - 창

    func windowWillClose(_ notification: Notification) {
        cancelActiveTest()
        (NSApp.delegate as? AppDelegate)?.controllerClosed(self)
    }
}
