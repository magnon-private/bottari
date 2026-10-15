import Foundation
import CArchive

private let cp949 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
    CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
private let cp437 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
    CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))

/// UTF-8 플래그가 없는 zip 의 파일명은 libarchive 가 CP437 로 해석해 돌려준다.
/// 원래 바이트로 되돌린 뒤 UTF-8 → CP949(한글) 순으로 다시 해석한다.
private func repairLegacy(_ s: String) -> String {
    // CP437 오해석은 박스 문자/그리스 문자 등 Latin-1 밖의 문자를 만든다. 그 외에는 정상 이름으로 본다.
    guard s.unicodeScalars.contains(where: { $0.value > 0xFF }),
          let data = s.data(using: cp437, allowLossyConversion: false) else { return s }
    if let u = String(data: data, encoding: .utf8) { return u }
    if let k = String(data: data, encoding: cp949),
       k.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) { return k }
    return s
}

/// 파일명 바이트열 → String. UTF-8 이 아니면 (윈도우에서 만든 zip 등) CP949 → Shift-JIS → Latin-1 순으로 시도.
func decodeName(_ p: UnsafePointer<CChar>?) -> String? {
    guard let p = p else { return nil }
    let data = Data(bytes: p, count: strlen(p))
    if let s = String(data: data, encoding: .utf8) { return repairLegacy(s) }
    for enc in [cp949, .shiftJIS, .isoLatin1] {
        if let s = String(data: data, encoding: enc) { return s }
    }
    return String(decoding: data, as: UTF8.self)
}

/// 빈 요소와 "." 를 제거한다. ".." 는 보존하며, 포함된 항목은 hasUnsafePath 로 걸러낸다.
func normalizePath(_ raw: String) -> String {
    raw.split(separator: "/", omittingEmptySubsequences: true)
        .filter { $0 != "." }
        .joined(separator: "/")
}

func classify(error message: String) -> ArchiveError {
    if message.lowercased().contains("passphrase") || message.lowercased().contains("password") {
        return .passphraseRequired(message)
    }
    return .failed(message)
}

func errorString(_ a: OpaquePointer?) -> String {
    if let c = archive_error_string(a) { return String(cString: c) }
    return "알 수 없는 오류"
}

/// 단일 압축 스트림(foo.txt.gz 등)으로 폴백해 볼 확장자
private let rawExtensions: Set<String> = ["gz", "bz2", "xz", "zst", "lz", "lzma", "z"]

private func openReader(_ url: URL, passphrase: String?, raw: Bool) throws -> OpaquePointer {
    guard let a = archive_read_new() else { throw ArchiveError.failed("메모리 부족") }
    archive_read_support_filter_all(a)
    if raw { archive_read_support_format_raw(a) } else { archive_read_support_format_all(a) }
    if let p = passphrase, !p.isEmpty { archive_read_add_passphrase(a, p) }
    if archive_read_open_filename(a, url.path, 1 << 20) != ARCHIVE_OK {
        let msg = errorString(a)
        archive_read_free(a)
        throw ArchiveError.openFailed(msg)
    }
    return a
}

/// foo.tar.gz 처럼 tar 를 압축한 이름이면 true. 이런 파일은 raw 로 폴백하지 않는다(손상을 숨기지 않기 위해).
private func looksLikeCompressedTar(_ url: URL) -> Bool {
    url.deletingPathExtension().pathExtension.lowercased() == "tar"
}

/// 먼저 일반 형식으로 한 번만 열고, 형식을 인식하지 못했을 때만 단일 압축 스트림(raw)으로 폴백한다.
/// rawName 이 있으면 단일 압축 스트림이며, 그 내용물의 이름이다. (foo.txt.gz → foo.txt)
func makeReader(_ url: URL, passphrase: String?) throws -> (reader: OpaquePointer, rawName: String?) {
    do {
        return (try openReader(url, passphrase: passphrase, raw: false), nil)
    } catch ArchiveError.openFailed(let msg) where msg.contains("Unrecognized")
                                                 && rawExtensions.contains(url.pathExtension.lowercased())
                                                 && !looksLikeCompressedTar(url) {
        return (try openReader(url, passphrase: passphrase, raw: true), url.deletingPathExtension().lastPathComponent)
    }
}

func makeEntry(_ e: OpaquePointer, rawName: String? = nil) -> ArchiveEntry? {
    let rawPath = rawName ?? decodeName(archive_entry_pathname(e))
    guard let raw = rawPath else { return nil }
    let type = archive_entry_filetype(e) & UInt16(ARCHIVE_AE_IFMT)
    let isDir = rawName == nil && (type == UInt16(ARCHIVE_AE_IFDIR) || raw.hasSuffix("/"))
    let isLink = type == UInt16(ARCHIVE_AE_IFLNK)
    let known = [UInt16(ARCHIVE_AE_IFREG), UInt16(ARCHIVE_AE_IFDIR), UInt16(ARCHIVE_AE_IFLNK), 0]
    return ArchiveEntry(
        path: normalizePath(raw),
        isDirectory: isDir,
        isSymlink: isLink,
        isSpecial: !known.contains(type),
        symlinkTarget: isLink ? decodeName(archive_entry_symlink(e)) : nil,
        size: archive_entry_size_is_set(e) != 0 ? max(0, archive_entry_size(e)) : 0,
        modified: archive_entry_mtime_is_set(e) != 0 ? Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(e))) : nil,
        mode: archive_entry_mode(e) & 0o7777,
        isEncrypted: archive_entry_is_data_encrypted(e) != 0
    )
}

public enum ArchiveReader {
    public static func list(url: URL, passphrase: String? = nil) throws -> ArchiveListing {
        let (a, rawName) = try makeReader(url, passphrase: passphrase)
        defer { archive_read_free(a) }

        var entries: [ArchiveEntry] = []
        var skipped = 0
        var entry: OpaquePointer?
        while true {
            let rc = archive_read_next_header(a, &entry)
            if rc == ARCHIVE_EOF { break }
            if rc < ARCHIVE_WARN { throw classify(error: errorString(a)) }
            guard let e = entry, let item = makeEntry(e, rawName: rawName) else { continue }
            if item.hasUnsafePath { skipped += 1; continue }
            entries.append(item)
        }
        let format = rawName != nil ? "단일 압축 파일" : (archive_format_name(a).map { String(cString: $0) } ?? "")
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return ArchiveListing(entries: entries, formatName: format, fileSize: size, skippedEntries: skipped)
    }

    public struct TestResult {
        public var checkedFiles: Int
        public var failures: [String]
    }

    /// 모든 데이터를 읽어 손상 여부를 검사한다.
    public static func test(url: URL, passphrase: String? = nil, cancel: CancelFlag,
                            progress: @escaping (String) -> Void) throws -> TestResult {
        let (a, rawName) = try makeReader(url, passphrase: passphrase)
        defer { archive_read_free(a) }

        var result = TestResult(checkedFiles: 0, failures: [])
        var entry: OpaquePointer?
        while true {
            if cancel.isCancelled { throw ArchiveError.cancelled }
            let rc = archive_read_next_header(a, &entry)
            if rc == ARCHIVE_EOF { break }
            if rc < ARCHIVE_WARN {
                result.failures.append(errorString(a))
                break
            }
            guard let e = entry, let item = makeEntry(e, rawName: rawName) else { continue }
            if item.isDirectory { continue }
            progress(item.path)
            var buff: UnsafeRawPointer?
            var size = 0
            var offset: Int64 = 0
            while true {
                if cancel.isCancelled { throw ArchiveError.cancelled }
                let r = archive_read_data_block(a, &buff, &size, &offset)
                if r == ARCHIVE_EOF { break }
                if r < ARCHIVE_WARN {
                    let msg = errorString(a)
                    if case .passphraseRequired = classify(error: msg) { throw classify(error: msg) }
                    result.failures.append("\(item.path): \(msg)")
                    break
                }
            }
            result.checkedFiles += 1
        }
        return result
    }
}
