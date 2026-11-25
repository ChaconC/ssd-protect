# Working in SSD Protect

Read [CONTRIBUTING.md](CONTRIBUTING.md) for branch, verification and PR
conventions. Keep implementation plans, handoffs and scratch work in `.local/`.
Keep personal paths, hardware identifiers and signing material out of commits.

Use English for coding tasks unless the contributor requests another language.
For other discussions, follow the contributor's language. Be concise, surface
trade-offs and question assumptions when evidence points elsewhere. Clarify
ambiguous requirements before giving a detailed proposal. Avoid em dashes.

- Use Swift and SwiftUI for the macOS 14+ menu bar app. Keep Disk Arbitration
  policy independent of popover state. Approval callbacks must return promptly
  from in-memory state.
- Treat names, mount paths and BSD disk numbers as transient. Verify the current
  physical attachment before an eject. Disable whole-drive operations for the
  startup disk and for ambiguous mappings.
- Preserve the saved protection rule during an intentional eject. A busy normal
  unmount and a separate user confirmation are prerequisites for forced unmount.
  Report success only after the system confirms eject.
- Exercise policy changes with simulated drives first. Reserve physical eject
  tests for explicitly designated expendable media.
