import SwiftUI

/// Atalho em formato de tecla, com fundo translúcido sobre o botão.
struct KeyHint: View {
    let text: String
    let onProminent: Bool

    init(_ text: String, onProminent: Bool) {
        self.text = text
        self.onProminent = onProminent
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(onProminent ? Color.white.opacity(0.22) : Color.primary.opacity(0.08))
            }
            .opacity(0.9)
    }
}

