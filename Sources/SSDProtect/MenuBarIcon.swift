import AppKit
import SwiftUI

struct MenuBarIcon: View {
    let protectedCount: Int
    var bundle: Bundle = .main

    var body: some View {
        let isProtecting = protectedCount > 0
        if let icon = bundle.image(forResource: isProtecting ? "MenuBarIconProtected" : "MenuBarIcon") {
            Image(nsImage: icon)
        } else {
            // A standalone SwiftPM executable has no app asset catalog.
            Image(systemName: isProtecting ? "externaldrive.badge.checkmark" : "externaldrive")
        }
    }
}
