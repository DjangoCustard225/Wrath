import SwiftUI

// Card chrome adapted from Quby's AppTheme.darkCard.
// Copyright (c) 2026 Ammar Haseeb. MIT license: Resources/Licenses/Quby.txt.
struct MediaCardStyle: ViewModifier {
    var padding: CGFloat = 12
    var cornerRadius: CGFloat = 22
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        let fill = colorScheme == .dark ? Color(white: 0.08) : Color.white
        let border = colorScheme == .dark ? Color.white.opacity(0.22) : Color.black.opacity(0.14)
        content
            .padding(padding)
            .background(fill, in: shape)
            .overlay { shape.strokeBorder(border, lineWidth: 1) }
            .contentShape(shape)
    }
}
