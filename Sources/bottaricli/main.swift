import Foundation
import BottariCore

// 개발/테스트용 CLI:  bottaricli l <archive> | x <archive> <dest> [pass] | t <archive>
let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: bottaricli l|x|t <archive> [dest] [passphrase]"); exit(2) }
let url = URL(fileURLWithPath: args[2])
do {
    switch args[1] {
    case "l":
        let l = try ArchiveReader.list(url: url, passphrase: args.count > 3 ? args[3] : nil)
        print("format=\(l.formatName) files=\(l.fileCount) total=\(l.totalSize)")
        let root = ArchiveNode.build(from: l.entries)
        func dump(_ n: ArchiveNode, _ d: Int) {
            for c in n.children {
                print(String(repeating: "  ", count: d) + c.name + (c.isDirectory ? "/" : "") + "  \(c.size)")
                dump(c, d + 1)
            }
        }
        dump(root, 0)
    case "x":
        let r = try ArchiveExtractor.extract(archive: url, to: URL(fileURLWithPath: args[3]), overwrite: true,
                                             passphrase: args.count > 4 ? args[4] : nil, cancel: CancelFlag()) { _ in }
        print(r)
    case "t":
        print(try ArchiveReader.test(url: url, cancel: CancelFlag()) { _ in })
    default: exit(2)
    }
} catch { print("ERROR: \(error.localizedDescription)"); exit(1) }
