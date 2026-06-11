import Foundation

enum LocalActivity {
    static func countJSONLogEvents(
        roots: [URL],
        since start: Date,
        typeField: String = "type",
        userType: String = "user",
        timestampField: String = "timestamp",
        messageField: String? = nil,
        messageContainsAny needles: [String] = []
    ) -> Double {
        let fileManager = FileManager.default
        var count = 0

        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let file as URL in enumerator where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
                else { continue }

                for event in array {
                    if let type = event[typeField] as? String, type != userType { continue }
                    if let messageField, !needles.isEmpty {
                        let message = (event[messageField] as? String)?.lowercased() ?? ""
                        guard needles.contains(where: { message.contains($0.lowercased()) }) else {
                            continue
                        }
                    }
                    if let timestamp = DateParsing.iso8601(event[timestampField] as? String),
                       timestamp >= start {
                        count += 1
                    }
                }
            }
        }
        return Double(count)
    }

    static func countJSONLEvents(file: URL, since start: Date, timestampField: String = "ts") -> Double {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return 0 }
        var count = 0

        for line in text.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let seconds = (json[timestampField] as? NSNumber)?.doubleValue,
               Date(timeIntervalSince1970: seconds) >= start {
                count += 1
            }
        }
        return Double(count)
    }

    static func countModifiedFiles(roots: [URL], since start: Date, extensions: Set<String>) -> Double {
        let fileManager = FileManager.default
        var count = 0

        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let file as URL in enumerator {
                guard extensions.contains(file.pathExtension) else { continue }
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modified = values.contentModificationDate,
                      modified >= start
                else { continue }
                count += 1
            }
        }
        return Double(count)
    }

    static func startOfToday(calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: Date())
    }

    static func startOfMonth(calendar: Calendar = .current) -> Date {
        let now = Date()
        let comps = calendar.dateComponents([.year, .month], from: now)
        return calendar.date(from: comps) ?? calendar.startOfDay(for: now)
    }
}
