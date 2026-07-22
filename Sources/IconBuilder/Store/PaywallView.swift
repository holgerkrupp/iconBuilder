import SwiftUI
import StoreKit

/// Why the paywall came up. Only the headline changes — the feature list and
/// the purchase controls are identical, so the price is never a surprise
/// depending on which door the user came through.
enum PaywallReason: Int, Identifiable {
    /// A paid `.icon` write action was chosen. Raised *before* any save panel.
    case gatedAction
    /// Shown up front, right after importing an external document, so nobody
    /// invests an afternoon of edits before learning what writing out costs.
    case importDisclosure
    /// Opened deliberately from the app menu.
    case informational

    var id: Int { rawValue }

    var headline: String {
        switch self {
        case .gatedAction: return "Unlock IconBuilder Pro"
        case .importDisclosure: return "Editing is free — saving .icon files is Pro"
        case .informational: return "IconBuilder Pro"
        }
    }

    var subhead: String? {
        switch self {
        case .gatedAction:
            return nil
        case .importDisclosure:
            return "IconBuilder edits a private copy in your library. Your original is never changed. Saving back to it, or exporting an editable .icon, needs Pro — you can buy it any time, including after you finish designing."
        case .informational:
            return nil
        }
    }

    var dismissTitle: String {
        switch self {
        case .importDisclosure: return "Continue Editing"
        case .gatedAction, .informational: return "Not Now"
        }
    }
}

/// The single paywall surface. Presented from the gated actions, from the
/// post-import disclosure, and from “IconBuilder Pro…” in the app menu.
struct PaywallView: View {
    var reason: PaywallReason = .gatedAction
    /// Called after a successful purchase or restore so the caller can continue
    /// whatever action hit the paywall (e.g. run the export it interrupted).
    var onUnlocked: () -> Void = {}

    @State private var store = StoreManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .padding(.top, 28)

            Text(reason.headline)
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            if let subhead = reason.subhead {
                Text(subhead)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }

            VStack(alignment: .leading, spacing: 10) {
                feature("arrow.uturn.backward.square", "Save Back to Icon Composer",
                        "Write your edits into the original .icon bundle.")
                feature("square.and.arrow.up", "Export Editable .icon",
                        "Save the project as a fresh bundle anywhere you like.")
                feature("infinity", "One-time purchase",
                        "No subscription. Yours forever, on all your Macs.")
            }
            .frame(maxWidth: 340)

            VStack(alignment: .leading, spacing: 4) {
                Label("Always free", systemImage: "checkmark.circle")
                    .font(.caption.weight(.medium))
                Text("Importing, editing, previewing, PDF/PNG/print exports, autosave and recovery never require Pro. Nothing you make can be locked away from you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 340, alignment: .leading)

            if let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }

            VStack(spacing: 8) {
                Button {
                    Task {
                        if await store.purchase() {
                            // Arm before dismissing: the caller replays the
                            // interrupted action from the sheet's onDismiss.
                            onUnlocked()
                            dismiss()
                        }
                    }
                } label: {
                    Group {
                        if store.purchaseInFlight {
                            ProgressView().controlSize(.small)
                        } else if let product = store.proProduct {
                            Text("Unlock for \(product.displayPrice)")
                        } else {
                            Text("Unlock Pro")
                        }
                    }
                    .frame(maxWidth: 260)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.purchaseInFlight)

                Button("Restore Purchases") {
                    Task {
                        await store.restorePurchases()
                        if store.isPro {
                            onUnlocked()
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.link)
                .disabled(store.purchaseInFlight)

                Button(reason.dismissTitle) { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .padding(.bottom, 24)
        }
        .frame(width: 420)
        .task {
            if store.proProduct == nil { await store.refresh() }
        }
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Small "PRO" chip marking a gated menu or toolbar item. Hidden once the
/// purchase is made, so a paid-up app carries no leftover upsell furniture.
struct ProBadge: View {
    @State private var store = StoreManager.shared

    @ViewBuilder
    var body: some View {
        if !store.isUnlocked {
            Text("PRO")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.tint)
                .accessibilityLabel("Requires IconBuilder Pro")
        }
    }
}
