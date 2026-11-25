import Foundation

/// Both the hardware and media have to match. Either component can expose a
/// collision even when the other disk is ineligible or only partly identified.
struct IdentityEvidence: Codable, Hashable {
    let device: String?
    let media: String?

    func isUnique(in inventory: [UInt64: Self]) -> Bool {
        guard let device, let media else { return false }
        return inventory.values.filter { $0.device == device }.count == 1
            && inventory.values.filter { $0.media == media }.count == 1
    }
}

struct RestoreRules {
    private struct Preferences: Codable {
        var enabled = false
        var saved: Set<IdentityEvidence> = []
    }

    private let defaults: UserDefaults?
    private static let key = "protectionRestoration.v1"
    private var preferences: Preferences
    // Only these bindings refer to live attachments. They never leave this process.
    private(set) var bindings: [UInt64: IdentityEvidence] = [:]
    var enabled: Bool { preferences.enabled }
    var hasChoices: Bool { !preferences.saved.isEmpty }

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        preferences = defaults?.data(forKey: Self.key).flatMap {
            try? PropertyListDecoder().decode(Preferences.self, from: $0)
        } ?? Preferences()
    }

    mutating func setEnabled(_ enabled: Bool) {
        preferences.enabled = enabled
        if !enabled {
            preferences.saved.removeAll()
            bindings.removeAll()
        }
        persist()
    }

    func matches(_ id: UInt64, evidence: [UInt64: IdentityEvidence]) -> Bool {
        guard enabled, let key = evidence[id], preferences.saved.contains(key) else { return false }
        return key.isUnique(in: evidence)
    }

    mutating func record(_ id: UInt64, evidence: [UInt64: IdentityEvidence]) {
        guard enabled, let key = evidence[id], key.isUnique(in: evidence) else { return }
        bindings[id] = key
        if preferences.saved.insert(key).inserted { persist() }
    }

    mutating func disconnected(_ id: UInt64) { bindings.removeValue(forKey: id) }

    mutating func forget(_ id: UInt64) {
        if let key = bindings.removeValue(forKey: id), preferences.saved.remove(key) != nil { persist() }
    }

    mutating func discardCollisions(in evidence: [UInt64: IdentityEvidence]) {
        let collisions = preferences.saved.filter { key in
            let hardware = evidence.values.filter { $0.device == key.device }
            let media = evidence.values.filter { $0.media == key.media }
            return hardware.count > 1 || media.count > 1
                || hardware.contains { $0.media != nil && $0.media != key.media }
                || media.contains { $0.device != nil && $0.device != key.device }
        }
        guard !collisions.isEmpty else { return }
        preferences.saved.subtract(collisions)
        bindings = bindings.filter { !collisions.contains($0.value) }
        persist()
    }

    private func persist() {
        if let data = try? PropertyListEncoder().encode(preferences) { defaults?.set(data, forKey: Self.key) }
    }
}
