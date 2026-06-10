import SwiftUI

/// Horizontal strip of provider chips at the top of the menu. The selected chip
/// is filled with its accent colour.
struct ProviderTabBar: View {
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Provider.allCases) { provider in
                tab(provider)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func tab(_ provider: Provider) -> some View {
        let isSelected = provider == store.selected
        return Button {
            store.selected = provider
        } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: provider.systemImage)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 34, height: 26)
                    if showsWarningDot(for: provider) {
                        Circle()
                            .fill(.red)
                            .frame(width: 6, height: 6)
                            .offset(x: 2, y: -1)
                    }
                }
                Text(provider.displayName)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? provider.accentColor : Color.clear)
            }
            .opacity(store.state(for: provider).isConfigured ? 1 : 0.45)
        }
        .buttonStyle(.plain)
    }

    /// Red dot for a configured provider whose token needs attention.
    private func showsWarningDot(for provider: Provider) -> Bool {
        switch store.state(for: provider) {
        case .needsReauth, .failed: return true
        default: return false
        }
    }
}
