import SwiftUI

enum AppTypography {
    static let hero = Font.system(size: 34, weight: .bold, design: .rounded)
    static let screenTitle = Font.largeTitle.bold()
    static let sectionTitle = Font.system(size: 20, weight: .bold, design: .rounded)
    static let cardTitle = Font.system(size: 17, weight: .semibold, design: .rounded)
    static let body = Font.body
    static let bodyEmphasis = Font.body.weight(.semibold)
    static let caption = Font.system(size: 12, weight: .medium, design: .rounded)
    static let label = Font.system(size: 11, weight: .bold, design: .rounded)
}
