import Foundation

@MainActor
func snapshotCopySmokeTest() {
    for source in ["", "я👩‍💻e\u{301}\0\r\n" + String(repeating:"x",count:1024*1024)] {
        let document=RustDocument(source)
        precondition(document.text==source)
        precondition(document.replace(NSRange(location:0,length:0),with:"🦀"))
        precondition(document.text=="🦀"+source)
        precondition(document.history(redo:false)==0 && document.text==source && !document.isDirty)
    }
    print("Direct snapshot copy native smoke passed: empty, 1 MiB, NUL, Unicode, CRLF and Undo")
}

// Explicit developer-only measurement: no UI, recovery, clipboard or credentials.
@MainActor
func profileSnapshotCopies() {
    var results: [[String: Any]] = []
    for mib in [1, 10] {
        let source = "я👩‍💻e\u{301}\0\r\n" + String(repeating: "x", count: mib * 1024 * 1024)
        let document = RustDocument(source)
        var samples: [Double] = []
        for _ in 0..<30 {
            autoreleasepool {
                let start = ContinuousClock.now
                let snapshot = document.text
                let elapsed = start.duration(to: .now)
                samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
                precondition(snapshot == source)
            }
        }
        samples.sort()
        let snapshot = document.text
        let rss: Int? = withExtendedLifetime(snapshot) {
            let process = Process(); let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-o", "rss=", "-p", String(ProcessInfo.processInfo.processIdentifier)]
            process.standardOutput = pipe
            try! process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Int(String(decoding:data,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines))
        }
        results.append(["bytes": source.utf8.count, "samples": samples.count,
                        "copy_p50_ms": samples[15], "copy_p95_ms": samples[28],
                        "rss_kib": rss.map { $0 as Any } ?? NSNull()])
    }
    let data = try! JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys])
    print(String(decoding:data,as:UTF8.self))
}
