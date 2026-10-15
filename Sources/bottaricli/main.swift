import Foundation
import BottariCore

// 개발/테스트용 CLI:  bottaricli l <archive> [pass] | x <archive> <dest> [pass] | t <archive> [pass]
let args = CommandLine.arguments
func usage() -> Never {
    print("usage: bottaricli l <archive> [passphrase] | x <archive> <dest> [passphrase] | t <archive> [passphrase]")
    exit(2)
}
guard args.count >= 3 else { usage() }
let url = URL(fileURLWithPath: args[2])
do {
    switch args[1] {
    case "l":
        let l = try ArchiveReader.list(url: url, passphrase: args.count > 3 ? args[3] : nil)
        print("format=\(l.formatName) files=\(l.fileCount) total=\(l.totalSize) skipped=\(l.skippedEntries)")
        let root = ArchiveNode.build(from: l.entries)
        func dump(_ n: ArchiveNode, _ d: Int) {
            for c in n.children {
                print(String(repeating: "  ", count: d) + c.name + (c.isDirectory ? "/" : "") + "  \(c.size)")
                dump(c, d + 1)
            }
        }
        dump(root, 0)
    case "x":
        guard args.count >= 4 else { usage() }
        let r = try ArchiveExtractor.extract(archive: url, to: URL(fileURLWithPath: args[3]), overwrite: true,
                                             passphrase: args.count > 4 ? args[4] : nil, cancel: CancelFlag()) { _ in }
        print("extracted=\(r.extracted) skipped=\(r.skipped) warnings=\(r.warnings)")
    case "t":
        let r = try ArchiveReader.test(url: url, passphrase: args.count > 3 ? args[3] : nil, cancel: CancelFlag()) { _ in }
        print("checked=\(r.checkedFiles) failures=\(r.failures)")
    default: usage()
    }
} catch { print("ERROR: \(error.localizedDescription)"); exit(1) }
