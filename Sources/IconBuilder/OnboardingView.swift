import SwiftUI

/// Bump this value when a release adds onboarding pages that existing users
/// should see. Pages introduced in that release are shown by themselves to
/// returning users; first-time users receive the complete walkthrough.
enum IconBuilderOnboarding {
    static let currentRelease = 1
    static let releaseDefaultsKey = "IconBuilderLastSeenOnboardingRelease"
}

@MainActor
final class IconBuilderOnboardingPresentation {
    static let shared = IconBuilderOnboardingPresentation()

    private var claimedThisLaunch = false

    private init() {}

    func claimAutomaticPresentation(lastSeenRelease: Int) -> Bool {
        guard !claimedThisLaunch,
              lastSeenRelease < IconBuilderOnboarding.currentRelease else { return false }
        claimedThisLaunch = true
        return true
    }
}

struct IconBuilderOnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @AppStorage(IconBuilderOnboarding.releaseDefaultsKey)
    private var lastSeenRelease = 0
    @State private var selectedPage = 0

    private static let allPages: [IconBuilderOnboardingPage] = [
        IconBuilderOnboardingPage(
            id: "open",
            introducedIn: 1,
            title: "Open an Icon Composer Project",
            summary: "IconBuilder works directly with Apple .icon bundles and keeps their manifest and assets together.",
            systemImage: "app.dashed",
            tint: .blue,
            bullets: [
                "Choose Open, drop an .icon bundle into the window, or open one from Finder.",
                "Use the appearance switcher to inspect Light, Dark, Tinted, and Clear variants.",
                "Save writes manifest changes and edited SVG assets back into the open bundle."
            ]
        ),
        IconBuilderOnboardingPage(
            id: "edit",
            introducedIn: 1,
            title: "Arrange and Edit Layers",
            summary: "The workspace keeps layer organization, the final preview or vector editor, and contextual properties visible together.",
            systemImage: "pencil.and.outline",
            tint: .orange,
            bullets: [
                "Select layers and groups on the left; edit document, group, or layer properties in the Inspector.",
                "Add vector shapes or import SVG artwork, then move, resize, align, and combine selected shapes.",
                "Selecting a vector layer immediately shows its on-canvas editing controls."
            ]
        ),
        IconBuilderOnboardingPage(
            id: "appearances",
            introducedIn: 1,
            title: "Tune Every Appearance",
            summary: "Recipes provide a starting point for platform masks and Liquid Glass while appearance overrides preserve deliberate variants.",
            systemImage: "circle.lefthalf.filled",
            tint: .purple,
            bullets: [
                "Pick a lighting recipe and a mask shape independently, then adjust background, glass, edge light, and shadow.",
                "Appearance-specific Inspector controls affect the appearance selected below the canvas.",
                "Use the CMYK preview and an optional print profile to check printable color before export."
            ]
        ),
        IconBuilderOnboardingPage(
            id: "export",
            introducedIn: 1,
            title: "Export for Screen or Print",
            summary: "Choose a focused export for app artwork, vector delivery, or a production-ready die-cut PDF.",
            systemImage: "square.and.arrow.up",
            tint: .green,
            bullets: [
                "PNG exports raster artwork at the requested pixel size; PDF keeps supported artwork vector.",
                "Print-Ready PDF adds physical size, bleed, TrimBox and BleedBox metadata, plus an optional CutContour spot-color layer.",
                "Confirm RGB or CMYK, flattening, profile, bleed, and contour requirements with the receiving print service."
            ]
        )
    ]

    private var pages: [IconBuilderOnboardingPage] {
        let unseen = Self.allPages.filter { $0.introducedIn > lastSeenRelease }
        return unseen.isEmpty ? Self.allPages : unseen
    }

    private var isUpdate: Bool {
        lastSeenRelease > 0 && lastSeenRelease < IconBuilderOnboarding.currentRelease
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isUpdate ? "What’s New" : "Getting Started")
                        .font(.title2.bold())
                    Text("IconBuilder")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Documentation") {
                    openWindow(id: "documentation")
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider()

            IconBuilderOnboardingPageView(page: pages[selectedPage])

            Divider()

            HStack(spacing: 8) {
                ForEach(pages.indices, id: \.self) { index in
                    Circle()
                        .fill(index == selectedPage ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }

                Spacer()

                if selectedPage > 0 {
                    Button("Back") {
                        withAnimation { selectedPage -= 1 }
                    }
                }

                Button(selectedPage == pages.count - 1 ? "Done" : "Continue") {
                    if selectedPage < pages.count - 1 {
                        withAnimation { selectedPage += 1 }
                    } else {
                        completeAndClose()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(18)
        }
        .frame(width: 660, height: 560)
        .onDisappear(perform: markCurrentReleaseSeen)
    }

    private func completeAndClose() {
        markCurrentReleaseSeen()
        dismiss()
    }

    private func markCurrentReleaseSeen() {
        lastSeenRelease = max(lastSeenRelease, IconBuilderOnboarding.currentRelease)
    }
}

private struct IconBuilderOnboardingPage: Identifiable {
    let id: String
    let introducedIn: Int
    let title: String
    let summary: String
    let systemImage: String
    let tint: Color
    let bullets: [String]
}

private struct IconBuilderOnboardingPageView: View {
    let page: IconBuilderOnboardingPage

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: page.systemImage)
                .font(.system(size: 54, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(page.tint)
                .frame(width: 92, height: 92)
                .background(page.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 22))
                .accessibilityHidden(true)

            VStack(spacing: 7) {
                Text(page.title)
                    .font(.largeTitle.bold())
                Text(page.summary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(page.bullets, id: \.self) { bullet in
                    Label {
                        Text(bullet)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(page.tint)
                    }
                }
            }
            .frame(maxWidth: 540, alignment: .leading)
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

#Preview {
    IconBuilderOnboardingView()
}
