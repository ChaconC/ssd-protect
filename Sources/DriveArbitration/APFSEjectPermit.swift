struct APFSEjectPermit {
    let root: UInt64
    let member: UInt64
    let phase: Phase

    func allows(root: UInt64, observed: UInt64?, phase: Phase) -> Bool {
        self.root == root && member == observed && self.phase == phase
    }
}
