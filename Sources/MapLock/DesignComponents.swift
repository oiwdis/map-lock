import SwiftUI

/// A consistent landmark at the top of each destination.
struct PageHeading: View {
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow.uppercased())
                .font(Theme.font(Theme.Size.xs, .semibold))
                .tracking(1.4)
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(Theme.font(Theme.Size.xl, .bold))
                .tracking(-0.7)
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(Theme.font(Theme.Size.body))
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SetupSection<Content: View>: View {
    let number: String
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            HStack(spacing: 10) {
                Text(number)
                    .font(Theme.font(Theme.Size.xs, .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.accent.opacity(0.10)))
                    .accessibilityHidden(true)
                Text(title)
                    .font(Theme.font(Theme.Size.md, .semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(Theme.Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(radius: Theme.Radius.lg, shadow: false)
    }
}

struct LearningEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: Theme.Space.s3) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 58, height: 58)
                .background(Circle().fill(Theme.accent.opacity(0.10)))
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.font(Theme.Size.md, .semibold))
                .foregroundStyle(Theme.text)
            Text(message)
                .font(Theme.font(Theme.Size.sm))
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, Theme.Space.s5)
        .frame(maxWidth: .infinity)
    }
}
