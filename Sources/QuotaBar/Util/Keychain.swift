import Foundation

/// 계정별 인증 토큰을 macOS 키체인에 저장하는 간단한 래퍼.
///
/// Security 프레임워크 대신 `security` CLI를 쓰는 이유: ad-hoc 서명 빌드는 빌드마다 서명이 바뀌어
/// 앱이 직접 만든 항목도 다음 빌드에서 "다른 앱"으로 취급돼 접근 창이 뜬다. CLI가 만든 항목은
/// CLI가 다시 읽을 수 있어 개발 중에도 창이 뜨지 않는다.
///
/// 비밀값은 인자(argv)가 아니라 `security -i`(대화식 모드)의 표준입력으로 넘긴다 — argv는
/// 같은 머신의 다른 프로세스가 `ps`로 읽을 수 있기 때문이다.
enum Keychain {
    private static let service = "com.wevoid.quotabar"

    static func save(_ value: String, for key: String) {
        writeGenericPassword(service: service, account: key, value: value)
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

    /// generic password 항목을 만들거나(-U) 갱신한다. 값은 표준입력으로 전달된다.
    /// 다른 서비스 이름(예: Claude Code의 자격증명 항목)을 갱신할 때도 쓴다.
    static func writeGenericPassword(service: String, account: String, value: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["-i"]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        let command = "add-generic-password -a \(quote(account)) -s \(quote(service)) -w \(quote(value)) -U\n"
        do {
            try process.run()
        } catch {
            return
        }
        stdin.fileHandleForWriting.write(Data(command.utf8))
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
    }

    /// `security -i`의 토크나이저용 큰따옴표 인용 (`\`와 `"`만 이스케이프).
    private static func quote(_ raw: String) -> String {
        let escaped = raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
