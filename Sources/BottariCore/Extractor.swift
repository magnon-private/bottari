import Foundation
import CArchive

public struct ExtractProgress {
    public var currentPath: String
    public var fraction: Double      // 0...1
    public var filesDone: Int
}

public struct ExtractResult {
    public var extracted = 0
    public var skipped = 0           // 이미 존재하여 건너뜀
    public var warnings: [String] = []
}

public enum ArchiveExtractor {
    /// - selection: nil 이면 전체. 아니면 선택한 경로(파일/디렉토리)들. 선택 항목의 상위 경로는 제거하고 풀린다.
    /// - totalBytes: 풀릴 데이터의 총량(진행률 계산용). nil 이면 읽은 압축파일 바이트 기준.
    public static func extract(archive url: URL,
                               to destination: URL,
                               selection: [String]? = nil,
                               overwrite: Bool,
                               passphrase: String? = nil,
                               totalBytes: Int64? = nil,
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

        let a = try makeReader(url, passphrase: passphrase)
        defer { archive_read_free(a) }
        guard let disk = archive_write_disk_new() else { throw ArchiveError.failed("메모리 부족") }
        defer { archive_write_free(disk) }
        archive_write_disk_set_options(disk,
            ARCHIVE_EXTRACT_PERM | ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_UNLINK |
            ARCHIVE_EXTRACT_SECURE_SYMLINKS | ARCHIVE_EXTRACT_SECURE_NODOTDOT)
        archive_write_disk_set_standard_lookup(disk)

        let fileSize = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let rawIndex = max(0, archive_filter_count(a) - 1)
        var result = ExtractResult()
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
        while true {
            if cancel.isCancelled { throw ArchiveError.cancelled }
            let rc = archive_read_next_header(a, &entry)
            if rc == ARCHIVE_EOF { break }
            if rc < ARCHIVE_WARN { throw classify(error: errorString(a)) }
            guard let e = entry, let item = makeEntry(e), !item.path.isEmpty else { continue }

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
            if item.isEncrypted && (passphrase ?? "").isEmpty && !item.isDirectory {
                throw ArchiveError.passphraseRequired("암호가 필요합니다.")
            }

            var st = stat()
            let exists = lstat(target, &st) == 0
            if exists && !overwrite && (st.st_mode & S_IFMT) != S_IFDIR && !item.isDirectory {
                result.skipped += 1
                continue
            }

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

            report(item.path, force: true)
            let wr = archive_write_header(disk, e)
            if wr < ARCHIVE_WARN {
                let msg = errorString(disk)
                if wr == ARCHIVE_FATAL { throw ArchiveError.failed(msg) }
                result.warnings.append("\(item.path): \(msg)")
                continue
            }

            if !item.isDirectory && item.size > 0 || item.isEncrypted {
                var buff: UnsafeRawPointer?
                var size = 0
                var offset: Int64 = 0
                while true {
                    if cancel.isCancelled { throw ArchiveError.cancelled }
                    let r = archive_read_data_block(a, &buff, &size, &offset)
                    if r == Int(ARCHIVE_EOF) { break }
                    if r < Int(ARCHIVE_WARN) { throw classify(error: errorString(a)) }
                    if archive_write_data_block(disk, buff, size, offset) < Int(ARCHIVE_WARN) {
                        throw ArchiveError.failed("\(item.path): \(errorString(disk))")
                    }
                    written += Int64(size)
                    report(item.path)
                }
            }
            archive_write_finish_entry(disk)
            result.extracted += 1
        }
        archive_write_close(disk)
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
