import SwiftUI

public struct RiskBadgeView: View {
    public let risk: RiskLevel

    public init(risk: RiskLevel) {
        self.risk = risk
    }

    private var badgeColor: Color {
        switch risk {
        case .safe: return .green
        case .review: return .orange
        case .caution: return .red
        case .neverDelete: return .secondary
        }
    }

    public var body: some View {
        Text(risk.rawValue)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(badgeColor.opacity(0.16))
            .foregroundColor(badgeColor)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(badgeColor.opacity(0.45), lineWidth: 1)
            )
            .cornerRadius(5)
    }
}
