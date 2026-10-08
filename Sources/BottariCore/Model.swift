import Foundation

public struct ArchiveEntry {
    public var path: String            // 정규화된 경로 ("./" 및 끝의 "/" 제거)
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var symlinkTarget: String?
    public var size: Int64
    public var modified: Date?
    public var mode: UInt16
    public var isEncrypted: Bool
}

public struct ArchiveListing {
    public var entries: [ArchiveEntry]
    public var formatName: String
    public var fileSize: Int64

    public var hasEncrypted: Bool { entries.contains { $0.isEncrypted } }
    public var fileCount: Int { entries.filter { !$0.isDirectory }.count }
    public var totalSize: Int64 { entries.reduce(0) { $0 + ($1.isDirectory ? 0 : $1.size) } }
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

        func ensureDir(_ path: String) -> ArchiveNode {
            if let n = index[path] { return n }
            let (parentPath, name) = split(path)
            let parent = ensureDir(parentPath)
            let node = ArchiveNode(name: name, path: path, isDirectory: true)
            node.parent = parent
            parent.children.append(node)
            index[path] = node
            return node
        }

        for e in entries where !e.path.isEmpty {
            if e.isDirectory {
                let node = ensureDir(e.path)
                node.entry = e
            } else {
                let (parentPath, name) = split(e.path)
                let parent = ensureDir(parentPath)
                if let existing = index[e.path], !existing.isDirectory {
                    existing.entry = e   // 중복 항목은 마지막 것을 사용
                    continue
                }
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
                size += c.size
                fileCount += c.isDirectory ? c.fileCount : 1
            }
        } else {
            size = entry?.size ?? 0
        }
    }

    private static func split(_ path: String) -> (String, String) {
        if let i = path.lastIndex(of: "/") {
            return (String(path[..<i]), String(path[path.index(after: i)...]))
        }
        return ("", path)
    }
}
