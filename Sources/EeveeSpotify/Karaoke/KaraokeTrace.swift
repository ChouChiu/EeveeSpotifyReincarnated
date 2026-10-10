import Foundation
import ObjectiveC.runtime

// TEMPORARY: timing trace for chasing lyrics jitter on device. Remove before opening the PR.
// Writes <app tmp>/karaoke_trace.log, which a development-signed install exposes over USB.
enum KaraokeTrace {
    private static let queue = DispatchQueue(label: "com.eevee.karaoke.trace", qos: .utility)
    private static let path = NSTemporaryDirectory() + "karaoke_trace.log"
    private static let maxRecords = 20_000
    private static var buffer: [String] = []
    private static var records = 0
    private static var started = false

    static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    static func log(_ line: String) {
        let stamp = now()
        queue.async {
            if !started {
                started = true
                try? FileManager.default.removeItem(atPath: path)
                buffer.append("# launch uptime=\(stamp)")
            }
            guard records < maxRecords else { return }
            records += 1
            buffer.append(String(format: "%.6f ", stamp) + line)
            if buffer.count >= 240 { flush() }
        }
    }

    static func flushSoon() {
        queue.async { flush() }
    }

    /// Every property and zero-argument getter on the object's class chain, once per class.
    static func dumpShape(_ label: String, of object: AnyObject) {
        var names: [String] = []
        var cls: AnyClass? = object_getClass(object)
        while let current = cls, current != NSObject.self {
            var count: UInt32 = 0
            if let props = class_copyPropertyList(current, &count) {
                for i in 0..<Int(count) {
                    names.append("\(NSStringFromClass(current)).\(String(cString: property_getName(props[i])))")
                }
                free(props)
            }
            cls = class_getSuperclass(current)
        }
        log("SHAPE \(label) class=\(NSStringFromClass(object_getClass(object) ?? NSObject.self)) props=\(names.joined(separator: ","))")
        flushSoon()
    }

    private static func flush() {
        guard !buffer.isEmpty else { return }
        let text = buffer.joined(separator: "\n") + "\n"
        buffer.removeAll(keepingCapacity: true)
        guard let data = text.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
    }
}
