enum Phase { case unmount, eject }

struct Protection {
    var enrolled: Set<UInt64> = []
    var operation: (drive: UInt64, phase: Phase)?

    func veto(_ drive: UInt64, _ phase: Phase) -> Bool {
        enrolled.contains(drive) && !(operation?.drive == drive && operation?.phase == phase)
    }
}

struct Attachments {
    private var ids: [String: UInt64] = [:]

    subscript(name: String) -> UInt64? {
        get { ids[name] }
        set { ids[name] = newValue }
    }

    mutating func retire(_ name: String, departing: UInt64?, live: UInt64?) -> UInt64? {
        guard let tracked = ids[name], live != tracked,
              departing == nil || departing == tracked else { return nil }
        return ids.removeValue(forKey: name)
    }
}
