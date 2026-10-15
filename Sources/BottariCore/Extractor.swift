import Foundation
import CArchive

public struct ExtractProgress {
    public var currentPath: String
    public var fraction: Double      // 0...1
    public var filesDone: Int
}

/// 압축 해제 결과. 클래스인 이유: 도중에 실패(예: 암호 필요)해도 그때까지의 집계를 호출자가 읽을 수 있게 하기 위함.
public final class ExtractResult {
    public var extracted = 0         // 푼 파일(디렉토리 제외) 수
    public var skipped = 0           // 이미 존재하여 건너뜀
    public var warnings: [String] = []
    public init() {}
}

/// 원본 압축파일의 격리(quarantine) 속성. 풀린 항목에 그대로 물려줘 Gatekeeper 검사를 유지한다.
private let quarantineKey = "com.apple.quarantine"

private func readQuarantine(_ url: URL) -> [UInt8]? {
    let n = getxattr(url.path, quarantineKey, nil, 0, 0, 0)
    guard n > 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: n)
    let m = getxattr(url.path, quarantineKey, &buf, n, 0, 0)
    return m > 0 ? Array(buf.prefix(m)) : nil
}

/// 격리 속성을 붙인다. 읽기 전용(0444/0555 등) 항목은 xattr 쓰기가 EACCES 로 실패하므로
/// 잠시 소유자 쓰기 권한을 주고 붙인 뒤 원래 모드로 되돌린다.
private func applyQuarantine(_ path: String, _ value: [UInt8]) {
    if setxattr(path, quarantineKey, value, value.count, 0, XATTR_NOFOLLOW) == 0 { return }
    guard errno == EACCES else { return }
    var st = stat()
    guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK else { return }
    let mode = st.st_mode & 0o7777
    chmod(path, mode | 0o200)
    _ = setxattr(path, quarantineKey, value, value.count, 0, XATTR_NOFOLLOW)
    chmod(path, mode)
}

/// root 아래에서 target 의 상위 폴더들 (가까운 것부터)
private func ancestors(of target: String, root: String) -> [String] {
    var result: [String] = []
    var p = (target as NSString).deletingLastPathComponent
    while p.count > root.count && p.hasPrefix(root + "/") {
        result.append(p)
        p = (p as NSString).deletingLastPathComponent
    }
    return result
}

public enum ArchiveExtractor {
    /// - selection: nil 이면 전체. 아니면 선택한 경로(파일/디렉토리)들. 선택 항목의 상위 경로는 제거하고 풀린다.
    /// - totalBytes: 풀릴 데이터의 총량(진행률 계산용). nil 이면 읽은 압축파일 바이트 기준.
    /// - result: 집계를 받을 객체. 생략하면 새로 만든다.
    /// - ownerAccess: true 면 소유자가 항상 읽고 쓸 수 있게 한다(파일 rw, 폴더 rwx). 미리보기/드래그용 임시 추출에서
    ///   0000, 0555 같은 권한 때문에 열거나 지우지 못하는 문제를 막는다. 어느 경우든 setuid/setgid/sticky 는 복원하지 않는다.
    @discardableResult
    public static func extract(archive url: URL,
                               to destination: URL,
                               selection: [String]? = nil,
                               overwrite: Bool,
                               passphrase: String? = nil,
                               totalBytes: Int64? = nil,
                               result: ExtractResult = ExtractResult(),
                               ownerAccess: Bool = false,
                               cancel: CancelFlag,
                               progress: @escaping (ExtractProgress) -> Void) throws -> ExtractResult {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let real = realpath(destination.path, nil) else {
            throw ArchiveError.failed("대상 폴더를 열 수 없습니다: \(destination.path)")
        }
        let root = String(cString: real)
        free(real)

        let picks: [(path: String, strip: Int)]? = selection?.map { p in
            let n = normalizePath(p)
            if let i = n.lastIndex(of: "/") { return (n, n.distance(from: n.startIndex, to: i) + 1) }
            return (n, 0)
        }

        let (a, rawName) = try makeReader(url, passphrase: passphrase)
        defer { archive_read_free(a) }
        guard let disk = archive_write_disk_new() else { throw ArchiveError.failed("메모리 부족") }
        defer { archive_write_free(disk) }
        // 덮어쓰기를 끈 경우 libarchive 가 기존 항목을 지우지 못하게 한다(UNLINK 대신 NO_OVERWRITE).
        archive_write_disk_set_options(disk,
            ARCHIVE_EXTRACT_PERM | ARCHIVE_EXTRACT_TIME |
            (overwrite ? ARCHIVE_EXTRACT_UNLINK : ARCHIVE_EXTRACT_NO_OVERWRITE) |
            ARCHIVE_EXTRACT_SECURE_SYMLINKS | ARCHIVE_EXTRACT_SECURE_NODOTDOT)
        archive_write_disk_set_standard_lookup(disk)

        let quarantine = readQuarantine(url)
        // 상위 폴더(예: 디렉토리 엔트리 없이 풀리는 Foo.app)에도 격리 속성이 필요하다.
        // 이번 추출에서 새로 만든 폴더만 대상으로 한다. (사용자가 원래 갖고 있던 폴더에는 붙이지 않음)
        var createdDirs: [String: Bool] = [:]
        var taggedDirs = Set<String>()
        let fileSize = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let rawIndex = max(0, archive_filter_count(a) - 1)
        var written: Int64 = 0
        var lastReport = Date.distantPast

        func report(_ path: String, force: Bool = false) {
            let now = Date()
            guard force || now.timeIntervalSince(lastReport) > 0.05 else { return }
            lastReport = now
            var f = 0.0
            if let t = totalBytes, t > 0 { f = Double(written) / Double(t) }
            else if fileSize > 0 { f = Double(archive_filter_bytes(a, rawIndex)) / Double(fileSize) }
            progress(ExtractProgress(currentPath: path, fraction: min(1, max(0, f)), filesDone: result.extracted))
        }

        var entry: OpaquePointer?
        var sawHeader = false
        while true {
            if cancel.isCancelled { throw ArchiveError.cancelled }
            let rc = archive_read_next_header(a, &entry)
            if rc == ARCHIVE_EOF { break }
            if rc < ARCHIVE_WARN { throw classify(error: errorString(a)) }
            sawHeader = true
            guard let e = entry, let item = makeEntry(e, rawName: rawName), !item.path.isEmpty else { continue }

            if item.hasUnsafePath {
                result.warnings.append("안전하지 않은 경로를 건너뜀: \(item.path)")
                continue
            }
            if item.isSpecial {
                result.warnings.append("특수 파일(장치/FIFO/소켓)을 건너뜀: \(item.path)")
                continue
            }

            // 선택 항목 필터 + 상위 경로 제거
            var rel = item.path
            if let picks = picks {
                guard let hit = picks.first(where: { item.path == $0.path || item.path.hasPrefix($0.path + "/") }) else { continue }
                rel = String(item.path.dropFirst(hit.strip))
            }
            guard let target = safeTarget(root: root, relative: rel) else {
                result.warnings.append("안전하지 않은 경로를 건너뜀: \(item.path)")
                continue
            }
            var st = stat()
            let exists = lstat(target, &st) == 0
            if exists && !overwrite {
                let existingIsDir = (st.st_mode & S_IFMT) == S_IFDIR
                // 기존 폴더에 같은 이름의 폴더를 합치는 경우만 허용. 파일↔폴더 충돌을 포함해 나머지는 건드리지 않는다.
                if !(existingIsDir && item.isDirectory) {
                    result.skipped += 1
                    continue
                }
            }

            if item.isEncrypted && (passphrase ?? "").isEmpty && !item.isDirectory {
                throw ArchiveError.passphraseRequired("암호가 필요합니다.")
            }

            for dir in ancestors(of: target, root: root) where createdDirs[dir] == nil {
                createdDirs[dir] = lstat(dir, &st) != 0     // 아직 없으면 이번에 libarchive 가 만든다
            }
            if item.isDirectory && createdDirs[target] == nil { createdDirs[target] = !exists }

            archive_entry_set_pathname(e, target)
            if let hl = archive_entry_hardlink(e), let h = decodeName(hl) {
                var hrel = normalizePath(h)
                if let picks = picks, let hit = picks.first(where: { hrel == $0.path || hrel.hasPrefix($0.path + "/") }) {
                    hrel = String(hrel.dropFirst(hit.strip))
                }
                if let htarget = safeTarget(root: root, relative: hrel) {
                    archive_entry_set_hardlink(e, htarget)
                } else {
                    result.warnings.append("안전하지 않은 링크를 건너뜀: \(item.path)")
                    continue
                }
            }

            if !item.isSymlink {
                var perm = item.mode & 0o777          // setuid/setgid/sticky 제거
                if item.mode == 0 { perm = item.isDirectory ? 0o755 : 0o644 }   // 권한 정보가 없는 항목
                if ownerAccess { perm |= item.isDirectory ? 0o700 : 0o600 }
                archive_entry_set_perm(e, mode_t(perm))
            }

            // 일반 파일은 첫 데이터 블록을 먼저 읽어 본다. 암호가 틀렸거나 데이터를 읽을 수 없으면
            // 헤더를 쓰기 전에 실패하므로 기존 파일을 지우거나 빈 파일을 만들지 않는다.
            let isRegular = !item.isDirectory && !item.isSymlink
            var buff: UnsafeRawPointer?
            var size = 0
            var offset: Int64 = 0
            var hasBlock = false
            if isRegular {
                let r = archive_read_data_block(a, &buff, &size, &offset)
                if r == ARCHIVE_EOF { hasBlock = false }
                else if r < ARCHIVE_WARN { throw classify(error: errorString(a)) }
                else { hasBlock = true }
            }

            report(item.path, force: true)
            let wr = archive_write_header(disk, e)
            if wr < ARCHIVE_WARN {
                let msg = errorString(disk)
                if wr == ARCHIVE_FATAL { throw ArchiveError.failed(msg) }
                result.warnings.append("\(item.path): \(msg)")
                continue
            }

            // 헤더에 크기가 없는 항목(스트리밍 zip 등)도 있으므로 크기와 무관하게 읽는다.
            // 진짜 빈 파일은 첫 호출에서 EOF 가 돌아온다.
            if isRegular {
                do {
                    while hasBlock {
                        if cancel.isCancelled { throw ArchiveError.cancelled }
                        if archive_write_data_block(disk, buff, size, offset) < Int(ARCHIVE_WARN) {
                            throw ArchiveError.failed("\(item.path): \(errorString(disk))")
                        }
                        written += Int64(size)
                        report(item.path)
                        let r = archive_read_data_block(a, &buff, &size, &offset)
                        if r == ARCHIVE_EOF { break }
                        if r < ARCHIVE_WARN { throw classify(error: errorString(a)) }
                    }
                } catch {
                    archive_write_finish_entry(disk)   // 열려 있던 항목을 먼저 마감한 뒤
                    unlink(target)                      // 쓰다 만 불완전한 파일을 지운다
                    throw error
                }
            }
            let fr = archive_write_finish_entry(disk)
            if fr < ARCHIVE_WARN {                       // 디스크 풀(ENOSPC) 등 마감 시점의 오류
                if isRegular { unlink(target) }
                throw ArchiveError.failed("\(item.path): \(errorString(disk))")
            }
            if let q = quarantine {
                if !item.isDirectory || createdDirs[target] == true { applyQuarantine(target, q) }
                for dir in ancestors(of: target, root: root) where createdDirs[dir] == true && !taggedDirs.contains(dir) {
                    applyQuarantine(dir, q)
                    taggedDirs.insert(dir)
                }
            }
            if !item.isDirectory { result.extracted += 1 }
        }
        // 내용이 0바이트인 단일 압축 파일(빈 foo.txt.gz): 항목이 없으므로 빈 파일을 직접 만든다.
        if let name = rawName, !sawHeader,
           picks == nil || picks!.contains(where: { $0.path == normalizePath(name) }),
           let target = safeTarget(root: root, relative: name) {
            var st = stat()
            if lstat(target, &st) == 0 && !overwrite {
                result.skipped += 1
            } else if FileManager.default.createFile(atPath: target, contents: Data()) {
                if let q = quarantine { applyQuarantine(target, q) }
                result.extracted += 1
            } else {
                throw ArchiveError.failed("\(name): 파일을 만들 수 없습니다")
            }
        }
        if archive_write_close(disk) < ARCHIVE_WARN {      // 지연된 폴더 메타데이터 반영 단계의 오류
            throw ArchiveError.failed(errorString(disk))
        }
        progress(ExtractProgress(currentPath: "", fraction: 1, filesDone: result.extracted))
        return result
    }

    /// 상대 경로를 root 아래의 절대 경로로. ".." 가 있으면 nil.
    static func safeTarget(root: String, relative: String) -> String? {
        var comps: [String] = []
        for c in relative.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { return nil }
            comps.append(String(c))
        }
        guard !comps.isEmpty else { return nil }
        return root + "/" + comps.joined(separator: "/")
    }
}

/// "foo.tar.gz" → "foo", "bar.zip" → "bar"
public func archiveStem(_ url: URL) -> String {
    var name = url.deletingPathExtension().lastPathComponent
    if name.lowercased().hasSuffix(".tar") { name = String(name.dropLast(4)) }
    return name.isEmpty ? url.lastPathComponent : name
}
