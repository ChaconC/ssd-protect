import SwiftUI

/// Measure the complete menu before deciding whether the rows need to scroll.
struct DriveMenuLayout<Header: View, Rows: View, Footer: View>: View {
    let availableHeight: CGFloat
    @ViewBuilder var header: () -> Header
    @ViewBuilder var rows: () -> Rows
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        ViewThatFits(in: .vertical) {
            column { rows() }.fixedSize(horizontal: false, vertical: true)
            column { ScrollView { rows() } }.frame(height: availableHeight)
        }
        .frame(width: 340)
        .frame(maxHeight: availableHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func column<List: View>(@ViewBuilder list: () -> List) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header()
            Divider()
            list()
            footer()
        }
        .padding()
    }
}
