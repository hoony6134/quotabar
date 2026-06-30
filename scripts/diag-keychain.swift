#!/usr/bin/env swift
// QuotaBar 키체인 읽기 진단 — 앱과 '동일한' SecItemCopyMatching + 파싱 로직을 재현.
// 토큰 '값'은 출력하지 않음 (길이/만료시각/키이름만). 결과를 scripts/diag-swift-output.txt 에 저장.
// 실행:  swift scripts/diag-keychain.swift
import Foundation
import Security

var lines: [String] = []
func log(_ s: String) { print(s); lines.append(s) }

func statusMessage(_ st: OSStatus) -> String {
    if let m = SecCopyErrorMessageString(st, nil) as String? { return "\(st) (\(m))" }
    return "\(st)"
}

func keychainRaw(_ service: String) -> String? {
    let q: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let st = SecItemCopyMatching(q as CFDictionary, &item)
    log("  [\(service)] SecItemCopyMatching status = \(statusMessage(st))")
    guard st == errSecSuccess, let d = item as? Data,
          let s = String(data: d, encoding: .utf8) else { return nil }
    return s
}

log("QuotaBar keychain Swift diagnostic")
log("date: \(Date())")
log("")

let services = ["Claude Code-credentials", "Claude Code", "claude-code"]
for svc in services {
    guard let raw = keychainRaw(svc) else { log("  [\(svc)] -> 읽기 실패/없음\n"); continue }
    log("  [\(svc)] -> \(raw.utf8.count) bytes")
    guard let data = raw.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        log("   JSON 파싱 실패\n"); continue
    }
    log("   top-level keys: \(json.keys.sorted())")
    let oauth = (json["claudeAiOauth"] as? [String: Any]) ?? json
    if json["claudeAiOauth"] != nil { log("   claudeAiOauth keys: \(oauth.keys.sorted())") }
    let acc = (oauth["accessToken"] as? String) ?? (oauth["access_token"] as? String)
    let ref = (oauth["refreshToken"] as? String) ?? (oauth["refresh_token"] as? String)
    log("   accessToken: \(acc.map { "present(len \($0.count))" } ?? "MISSING")")
    log("   refreshToken: \(ref.map { "present(len \($0.count))" } ?? "MISSING")")
    if let ms = (oauth["expiresAt"] as? NSNumber)?.doubleValue, ms > 0 {
        let date = Date(timeIntervalSince1970: ms / 1000)
        log("   expiresAt(ms): \(date)  -> \(date > Date() ? "VALID(유효)" : "EXPIRED(만료)")")
    } else if let s = (oauth["expires_at"] as? NSNumber)?.doubleValue, s > 0 {
        let date = Date(timeIntervalSince1970: s)
        log("   expires_at(s): \(date)  -> \(date > Date() ? "VALID(유효)" : "EXPIRED(만료)")")
    } else {
        log("   expiresAt: 없음/파싱불가")
    }
    log("")
}

// 결과 파일 저장
let outURL = URL(fileURLWithPath: (#filePath as NSString).deletingLastPathComponent)
    .appendingPathComponent("diag-swift-output.txt")
try? lines.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
log(">>> 저장됨: \(outURL.path)")
