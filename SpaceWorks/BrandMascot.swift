import SwiftUI

/// Patch, the Design-Kit mascot (`design/mascot/README.md`). The asset catalog swaps in the die-cut
/// `dark/` artwork in dark mode. Patch is the layout's one bold moment: no Unbounded phrase beside it.
/// A short entrance uses the kit's enter motion; Reduce Motion shows the static pose from the first frame.
struct PatchMascot: View {
    var size: CGFloat = 160
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entered = false
    var body: some View {
        Image("Patch").resizable().interpolation(.high).scaledToFit()
            .frame(width: size, height: size)
            .opacity(reduceMotion || entered ? 1 : 0)
            .offset(y: reduceMotion || entered ? 0 : MobileMotion.enterY)
            .accessibilityElement()
            .accessibilityLabel(Text("Patch, the Space Works mascot"))
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier("patch-mascot")
            .onAppear {
                guard !reduceMotion else { entered = true; return }
                withAnimation(MobileMotion.enterAnimation) { entered = true }
            }
    }
}

/// A whole-screen empty list: Patch above the unchanged empty copy.
struct SWEmptyState: View {
    var message: LocalizedStringKey = "Nothing here yet."
    var body: some View {
        VStack(spacing: 12) {
            PatchMascot(size: 96)
            Text(message).foregroundStyle(Color.swMuted).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 8)
    }
}

/// Design-Kit Aurora ID/badge look (`cards.aurora`) for the membership card and event ticket:
/// brand palette in both appearances; the card's content and layout are unchanged.
struct AuroraCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Color.swCardAuroraHeader).frame(height: 12).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(Color.swCardAuroraText)
                .tint(Color.swCardAuroraLabel)
            HStack(spacing: 0) {
                Rectangle().fill(Color.swCardAuroraRibbon)
                Rectangle().fill(Color.swCardAuroraTail).frame(width: 56)
            }.frame(height: 8).accessibilityHidden(true)
        }
        .background(Color.swCardAuroraBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.swLine))
    }
}
