import Foundation
import LocalAuthentication
import Security

/// 계정별 인증 토큰을 macOS 키체인에 저장하는 간단한 래퍼.
enum Keychain {
    private static let service = "com.wevoid.quotabar"

    static func save(_ value: String, for key: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["add-generic-password", "-a", key, "-s", service, "-w", value, "-U"]
        
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        
        try? process.run()
        process.waitUntilExit()
    }

    static func load(for key: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", key, "-s", service, "-w"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        } catch {
            // ignore
        }
        return nil
    }

    static func delete(for key: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["delete-generic-password", "-a", key, "-s", service]
        
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        
        try? process.run()
        process.waitUntilExit()
    }
}
