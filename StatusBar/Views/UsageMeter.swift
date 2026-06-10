import SwiftUI

/// Thin rounded progress bar used for every usage meter.
struct UsageMeter: View {
    var fraction: Double
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(tint)
                    .frame(width: max(3, geo.size.width * clamped))
            }
        }
        .frame(height: 5)
        .accessibilityValue("\(Int((clamped * 100).rounded())) percent")
    }

    private var clamped: Double { min(max(fraction, 0), 1) }
}

/// One labelled section: title, optional bar, leading/trailing captions, note.
struct SectionView: View {
    let section: UsageSection
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title)
                .font(.headline)

            if let fraction = section.fraction {
                UsageMeter(fraction: fraction, tint: tint)
            }

            HStack(alignment: .firstTextBaseline) {
                Text(section.leading)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let trailing = section.trailing {
                    Text(trailing)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)

            if let note = section.note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
