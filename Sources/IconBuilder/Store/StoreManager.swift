import Foundation
import StoreKit
import Observation

/// StoreKit 2 wrapper for the single "Pro" non-consumable that unlocks writing
/// finished work out of the app — save-back, editable `.icon` export, and the
/// PDF/PNG/print exports. Importing, editing, previewing and autosaving into
/// the internal library are always free.
///
/// Change `proProductID` to the product configured in App Store Connect (and in
/// IconBuilder.storekit for local testing).
@MainActor
@Observable
final class StoreManager {
    static let shared = StoreManager()

    static let proProductID = "de.holgerkrupp.IconBuilder.pro"

    /// True when the paywall should be bypassed.
    ///
    /// Two ways in, both for testing only — never for a shipping build:
    ///  - build with the `NO_PAYWALL` flag (`./make-app.sh --no-paywall`), which
    ///    bakes the bypass in so it also applies when launched from Finder;
    ///  - set `ICONBUILDER_NO_PAYWALL=1` in the environment, for a run scheme.
    static let paywallDisabled: Bool = {
        #if NO_PAYWALL
        return true
        #else
        return ProcessInfo.processInfo.environment["ICONBUILDER_NO_PAYWALL"] == "1"
        #endif
    }()

    private(set) var proProduct: Product?
    private(set) var isPro = false
    private(set) var purchaseInFlight = false
    private(set) var lastError: String?

    var isUnlocked: Bool { isPro || Self.paywallDisabled }

    private var updatesTask: Task<Void, Never>?

    init() {
        guard !Self.paywallDisabled else { return }
        updatesTask = Task { await listenForTransactions() }
        Task { await refresh() }
    }

    /// Fetch the product and current entitlement state.
    func refresh() async {
        do {
            proProduct = try await Product.products(for: [Self.proProductID]).first
        } catch {
            lastError = error.localizedDescription
        }
        await updateEntitlement()
    }

    func updateEntitlement() async {
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.proProductID,
               transaction.revocationDate == nil {
                owned = true
            }
        }
        isPro = owned
    }

    /// Runs the purchase flow. Returns true if Pro is unlocked afterwards.
    @discardableResult
    func purchase() async -> Bool {
        lastError = nil
        // The product may not have loaded yet (slow network, sandbox delay);
        // try once more before giving up so the button always does something.
        if proProduct == nil {
            purchaseInFlight = true
            await refresh()
            purchaseInFlight = false
        }
        guard let product = proProduct else {
            lastError = "Couldn't reach the App Store to load the purchase. Check your connection and try again."
            return false
        }
        purchaseInFlight = true
        defer { purchaseInFlight = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(.verified(let transaction)):
                await transaction.finish()
                isPro = true
            case .success(.unverified(_, let error)):
                lastError = "The App Store purchase could not be verified: \(error.localizedDescription)"
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            lastError = error.localizedDescription
        }
        return isPro
    }

    func restorePurchases() async {
        lastError = nil
        purchaseInFlight = true
        defer { purchaseInFlight = false }
        do {
            try await AppStore.sync()
            await updateEntitlement()
            if !isPro { lastError = "No previous purchase was found for this Apple Account." }
        } catch {
            lastError = "Purchases could not be restored: \(error.localizedDescription)"
        }
    }

    private func listenForTransactions() async {
        for await result in Transaction.updates {
            if case .verified(let transaction) = result {
                await transaction.finish()
                await updateEntitlement()
            }
        }
    }
}
