import AppKit
import DriveArbitration
import SwiftUI

extension DriveIcon {
    var symbol: String {
        switch self {
        case .external: "externaldrive"
        case .thumbDrive: "mediastick"
        case .enclosure: "externaldrive.connected.to.line.below"
        case .diskImage: "opticaldisc"
        case .network: "network"
        case .internalDisk: "internaldrive"
        }
    }
}

struct DriveRow<Detail: View, Actions: View>: View {
    let icon: DriveIcon
    let name: String
    @ViewBuilder var detail: () -> Detail
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon.symbol)
                .font(.title3)
                .frame(width: 24)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.medium)
                detail().font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions()
        }
    }
}

private extension NSEvent.ModifierFlags {
    var isEjectAlternate: Bool {
        intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .option
    }
}

// Modifier monitoring is only for the image and help shown in the menu.
final class OptionKey: ObservableObject {
    @Published private(set) var isDown = false
    private var monitor: Any?

    func start() {
        isDown = NSEvent.modifierFlags.isEjectAlternate
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.isDown = event.modifierFlags.isEjectAlternate
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isDown = false
    }
}

struct DriveActions: View {
    let name: String
    @Binding var protected: Bool
    let optionDown: Bool
    let eject: () -> Void
    let forceEject: () -> Void

    var body: some View {
        Toggle("Protect \(name)", isOn: $protected)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        EjectControl(name: name, optionDown: optionDown, eject: eject, forceEject: forceEject)
            .frame(width: 24, height: 24)
    }
}

private struct EjectControl: NSViewRepresentable {
    let name: String
    let optionDown: Bool
    let eject: () -> Void
    let forceEject: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> EjectButton {
        let button = EjectButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = button
        button.action = #selector(EjectButton.ordinaryPress)
        return button
    }

    func updateNSView(_ button: EjectButton, context: Context) {
        button.eject = eject
        button.forceEject = forceEject
        button.isEnabled = isEnabled
        button.image = NSImage(systemSymbolName: optionDown ? "eject.fill" : "eject", accessibilityDescription: nil)
        button.setAccessibilityLabel("Eject \(name)")
        button.toolTip = optionDown ? "Force Eject \(name) without confirmation. Unsaved changes may be lost."
            : "Eject \(name)… Hold Option to Force Eject."
        button.setAccessibilityHelp(button.toolTip)
    }
}

final class EjectButton: NSButton {
    var eject: (() -> Void)?
    var forceEject: (() -> Void)?

    @objc func ordinaryPress() { eject?() }
    @objc private func forcePress() { forceEject?() }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        ordinaryPress()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        // Keep AppKit's click tracking, including cancellation on drag-out.
        // Select the alternate only for this primary-button interaction.
        let original = action
        if event.type == .leftMouseDown && event.modifierFlags.isEjectAlternate {
            action = #selector(forcePress)
        }
        defer { action = original }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        guard event.type == .keyDown, event.charactersIgnoringModifiers == " ",
              event.modifierFlags.contains(.option) else {
            super.keyDown(with: event)
            return
        }
        guard !event.isARepeat else { return }
        if event.modifierFlags.isEjectAlternate { forcePress() }
        else { ordinaryPress() }
    }
}

// A status-item popover can receive a click without becoming the key window.
// The footer button supplies its own window as the sheet's parent.
struct QuitButton: NSViewRepresentable {
    let request: (NSWindow) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(request: request) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Quit", target: context.coordinator, action: #selector(Coordinator.click(_:)))
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.request = request
    }

    final class Coordinator: NSObject {
        var request: (NSWindow) -> Void
        init(request: @escaping (NSWindow) -> Void) { self.request = request }

        @objc func click(_ sender: NSButton) {
            if let window = sender.window { request(window) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var confirmingQuit = false
    private var quitApproved = false

    func requestQuit(from window: NSWindow) {
        guard !confirmingQuit else { return }
        showQuitSheet(on: window) { approved in
            if approved { NSApp.terminate(nil) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitApproved { return .terminateNow }
        guard !confirmingQuit else { return .terminateCancel }
        if let window = sender.keyWindow {
            showQuitSheet(on: window) { sender.reply(toApplicationShouldTerminate: $0) }
            return .terminateLater
        }
        return quitAlert().runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    private func showQuitSheet(on window: NSWindow, completion: @escaping (Bool) -> Void) {
        confirmingQuit = true
        quitAlert().beginSheetModal(for: window) { response in
            self.confirmingQuit = false
            self.quitApproved = response == .alertSecondButtonReturn
            completion(self.quitApproved)
        }
    }

    private func quitAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Quit SSD Protect?"
        alert.informativeText = "Quitting stops protection. Your drives will no longer be protected from accidental ejects."
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        let quit = alert.addButton(withTitle: "Quit")
        quit.keyEquivalent = ""
        quit.hasDestructiveAction = true
        return alert
    }
}
