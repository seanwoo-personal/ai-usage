import CryptoKit
import Foundation

/// A short, one-way label for "which account is this usage from", so a tool reading several Macs
/// can tell that two of them use the same Claude or Codex account and show it once.
/// Built from the provider's own account/organization ID with SHA-256; the ID itself is never
/// stored or shown, and the label can't be turned back into it. Same account → same label on every
/// Mac and connection type (web or CLI).
enum AccountKey {
    static func make(_ provider: Provider, id: String?) -> String? {
        guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty, id.count <= 200 else { return nil }
        let digest = SHA256.hash(data: Data("ai-usage:account:v1:\(provider.rawValue):\(id.lowercased())".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Claude Code keeps the logged-in organization in its settings file (`~/.claude.json`, or
    /// `$CLAUDE_CONFIG_DIR/.claude.json`). Only `oauthAccount.organizationUuid` is read.
    static func claudeCodeOrganization(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any] else { return nil }
        return account["organizationUuid"] as? String
    }

    static var claudeCodeConfig: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent(".claude.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    /// Reads the file only if it's a sane size (it also holds Claude Code's project history).
    static func claudeCodeKey(config url: URL = claudeCodeConfig) -> String? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size < 50_000_000,
              let data = try? Data(contentsOf: url) else { return nil }
        return make(.claude, id: claudeCodeOrganization(data))
    }

    /// Codex CLI's `auth.json` has the ChatGPT account ID it sends with every request.
    static func codexAccount(_ authJSON: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: authJSON) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any] else { return nil }
        return tokens["account_id"] as? String
    }
}
