import Foundation

extension Int64 {
    /// 오버플로 시 Int64.max 로 포화되는 덧셈 (조작된 헤더의 거대한 크기 대비). 음수는 0 으로 본다.
    public func saturatingAdding(_ other: Int64) -> Int64 {
        let (r, overflow) = Swift.max(0, self).addingReportingOverflow(Swift.max(0, other))
        return overflow ? Int64.max : r
    }
}

public struct ArchiveEntry {
    public var path: String            // 정규화된 경로 ("./" 및 끝의 "/" 제거)
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var isSpecial: Bool         // 장치/FIFO/소켓 등 풀지 않는 종류
    public var symlinkTarget: String?
    public var size: Int64
    public var modified: Date?
    public var mode: UInt16
    public var isEncrypted: Bool

    /// 목록/추출에서 제외하는 경로: ".." 포함 또는 지나치게 깊음
    public static let maxDepth = 256
    public var hasUnsafePath: Bool {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true)
        return comps.count > ArchiveEntry.maxDepth || comps.contains("..")
    }
}

public struct ArchiveListing {
    public var entries: [ArchiveEntry]
    public var formatName: String
    public var fileSize: Int64
    /// 안전하지 않은 경로(.., 과도한 깊이)라 목록에서 뺀 항목 수
    public var skippedEntries: Int = 0

    public var hasEncrypted: Bool { entries.contains { $0.isEncrypted } }
    public var fileCount: Int { entries.filter { !$0.isDirectory }.count }
    public var totalSize: Int64 {
        entries.reduce(Int64(0)) { $0.saturatingAdding($1.isDirectory ? 0 : $1.size) }
    }
}

public enum ArchiveError: LocalizedError {
    case openFailed(String)
    case passphraseRequired(String)
    case failed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .openFailed(let m): return m
        case .passphraseRequired(let m): return m
        case .failed(let m): return m
        case .cancelled: return "취소되었습니다."
        }
    }
}

public final class CancelFlag {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public var isCancelled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// 압축파일 내부 트리의 노드. 목록에 없는 중간 디렉토리도 합성한다.
public final class ArchiveNode {
    public let name: String
    public let path: String
    public var isDirectory: Bool
    public var entry: ArchiveEntry?
    public private(set) var children: [ArchiveNode] = []
    public weak var parent: ArchiveNode?
    /// 파일은 자신의 크기, 디렉토리는 하위 파일 크기의 합
    public private(set) var size: Int64 = 0
    public private(set) var fileCount: Int = 0

    init(name: String, path: String, isDirectory: Bool) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }

    public static func build(from entries: [ArchiveEntry]) -> ArchiveNode {
        let root = ArchiveNode(name: "", path: "", isDirectory: true)
        var index: [String: ArchiveNode] = ["": root]

        // 깊이는 maxDepth 로 제한되므로 재귀해도 안전하다.
        func ensureDir(_ path: String) -> ArchiveNode {
            if let n = index[path] {
                if !n.isDirectory { n.isDirectory = true }   // 같은 이름의 파일 뒤에 하위 항목이 오면 폴더로 취급
                return n
            }
            let (parentPath, name) = split(path)
            let parent = ensureDir(parentPath)
            let node = ArchiveNode(name: name, path: path, isDirectory: true)
            node.parent = parent
            parent.children.append(node)
            index[path] = node
            return node
        }

        for e in entries where !e.path.isEmpty && !e.hasUnsafePath {
            if e.isDirectory {
                let node = ensureDir(e.path)
                node.entry = e
            } else {
                if let existing = index[e.path] {
                    // 중복 항목: 파일이면 마지막 것을 사용, 같은 이름의 폴더가 이미 있으면 폴더를 유지
                    if !existing.isDirectory { existing.entry = e }
                    continue
                }
                let (parentPath, name) = split(e.path)
                let parent = ensureDir(parentPath)
                let node = ArchiveNode(name: name, path: e.path, isDirectory: false)
                node.entry = e
                node.parent = parent
                parent.children.append(node)
                index[e.path] = node
            }
        }
        root.accumulate()
        return root
    }

    private func accumulate() {
        if isDirectory {
            size = 0
            fileCount = 0
            for c in children {
                c.accumulate()
                size = size.saturatingAdding(c.size)
                fileCount += c.isDirectory ? c.fileCount : 1
            }
        } else {
            size = max(0, entry?.size ?? 0)
        }
    }

    private static func split(_ path: String) -> (String, String) {
        if let i = path.lastIndex(of: "/") {
            return (String(path[..<i]), String(path[path.index(after: i)...]))
        }
        return ("", path)
    }
}
