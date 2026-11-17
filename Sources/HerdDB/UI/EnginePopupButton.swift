import AppKit
import HerdCore
import SwiftUI

/// Seletor de engine com o ícone de marca de cada banco.
/// O `Picker` do SwiftUI com `Label` trunca o texto quando o item tem imagem
/// (vira "Post…"), então usamos o `NSPopUpButton` nativo, que mede ícone e
/// título juntos e mantém o menu com as imagens.
struct EnginePopupButton: NSViewRepresentable {
    @Binding var engine: DatabaseEngine

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))

        button.menu?.removeAllItems()
        for engine in DatabaseEngine.allCases {
            let item = NSMenuItem(title: engine.displayName, action: nil, keyEquivalent: "")
            item.image = engine.brandImage
            item.representedObject = engine.rawValue
            button.menu?.addItem(item)
        }
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self

        let index = DatabaseEngine.allCases.firstIndex(of: engine) ?? 0
        if button.indexOfSelectedItem != index {
            button.selectItem(at: index)
        }

        // O ícone de marca pode não existir quando o app roda fora do bundle.
        for (index, engine) in DatabaseEngine.allCases.enumerated() {
            button.item(at: index)?.image = engine.brandImage
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: EnginePopupButton

        init(_ parent: EnginePopupButton) {
            self.parent = parent
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard let rawValue = sender.selectedItem?.representedObject as? String,
                  let engine = DatabaseEngine(rawValue: rawValue)
            else { return }
            parent.engine = engine
        }
    }
}
