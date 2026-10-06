import AppKit
import SwiftUI

/// The plan, this month's usage, and the license key: Settings' License tab, and the
/// window that opens when a limit is reached, headed by what was reached.
struct LicenseView: View {
    let license: LicenseManager
    let usage: UsageMeter
    var limit: Limit?

    @State private var key = ""

    var body: some View {
        Form {
            if let limit {
                Section {
                    Label(limit.message, systemImage: "hourglass")
                        .font(.headline)
                        .foregroundStyle(Color.accent)
                }
            }

            Section("Plan") {
                LabeledContent("Lector \(license.tier.name)") {
                    if let email = license.stored?.email {
                        Text(email).foregroundStyle(Color.inkMuted)
                    }
                }
                usageRow("Grabs this month", used: usage.used(.grab), cap: license.tier.grabsPerMonth)
                usageRow("Translations this month", used: usage.used(.translation),
                         cap: license.tier.translationsPerMonth)
                LabeledContent("Live translation") {
                    Text(license.tier.allowsLive ? "Included" : "With Translate")
                        .foregroundStyle(Color.inkMuted)
                }
            }

            Section("License key") {
                if license.stored == nil || license.tier == .text {
                    HStack {
                        TextField("License key", text: $key,
                                  prompt: Text(license.stored == nil ? "Paste your key from Gumroad"
                                                                     : "Paste your upgrade key"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .onSubmit(activate)
                        Button("Activate", action: activate)
                            .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || license.isChecking)
                    }
                }
                if let stored = license.stored {
                    LabeledContent("Key") {
                        Text(Self.masked(stored.key)).monospaced().foregroundStyle(Color.inkMuted)
                    }
                    if let upgrade = stored.upgradeKey {
                        LabeledContent("Upgrade key") {
                            Text(Self.masked(upgrade)).monospaced().foregroundStyle(Color.inkMuted)
                        }
                    }
                    Button("Remove License from This Mac", role: .destructive) { license.remove() }
                }
                if license.isChecking {
                    ProgressView().controlSize(.small)
                }
                if let error = license.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            if license.tier != .translate {
                Section("Buy") {
                    if license.tier == .free {
                        buyRow("Text", detail: "Unlimited grabs, 30 translations a month", price: "$9",
                               url: AppConstants.storeURL)
                        buyRow("Translate", detail: "Unlimited grabs and translations, live translation",
                               price: "$15", url: AppConstants.storeURL)
                    } else {
                        buyRow("Upgrade to Translate", detail: "Unlimited translations, live translation",
                               price: "$6", url: AppConstants.upgradeURL)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func activate() {
        let entered = key
        Task {
            await license.activate(entered)
            if license.error == nil { key = "" }
        }
    }

    private func usageRow(_ title: String, used: Int, cap: Int?) -> some View {
        LabeledContent(title) {
            if let cap {
                Text("\(min(used, cap)) of \(cap)")
                    .monospacedDigit()
                    .foregroundStyle(used >= cap ? Color.accent : Color.inkMuted)
            } else {
                Text("Unlimited").foregroundStyle(Color.inkMuted)
            }
        }
    }

    private func buyRow(_ title: String, detail: String, price: String, url: URL) -> some View {
        LabeledContent {
            Button("Buy \(price)") { NSWorkspace.shared.open(url) }
        } label: {
            Text(title)
            Text(detail)
        }
    }

    /// Enough of a key to tell which one it is, without showing it to anyone looking on.
    static func masked(_ key: String) -> String {
        guard key.count > 8 else { return key }
        return "••••••••" + key.suffix(8)
    }
}
