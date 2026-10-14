import SwiftUI

struct AloBackSwipeExclusionKey: PreferenceKey {
    static var defaultValue: [CGRect] { [] }
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Scrubbers, text input and other horizontal controls own their touches.
    func aloBackSwipeExclusion(enabled: Bool = true) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: AloBackSwipeExclusionKey.self,
                                       value: enabled ? [geometry.frame(in: .global)] : [])
            }
        }
    }
}
