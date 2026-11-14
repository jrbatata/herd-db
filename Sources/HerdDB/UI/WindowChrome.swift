import AppKit
import SwiftUI

/// Fundo translúcido (vibrancy) que deixa o papel de parede/janelas atrás aparecerem desfocados.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Deixa a barra de título transparente e o conteúdo ocupando a janela toda,
/// com os semáforos (fechar/minimizar/zoom) flutuando sobre a sidebar.
struct WindowConfigurator: NSViewRepresentable {
    /// Quanto os semáforos descem, pra ficarem centrados na barra de 36pt.
    private let trafficLightOffset: CGFloat = 3

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = .clear
            context.coordinator.attach(to: window, offset: trafficLightOffset)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var observers: [NSObjectProtocol] = []
        private var baseOrigins: [NSWindow.ButtonType: CGFloat] = [:]

        func attach(to window: NSWindow, offset: CGFloat) {
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didExitFullScreenNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window else { return }
                        self.reposition(window, offset: offset)
                    }
                })
            }
            reposition(window, offset: offset)
        }

        private func reposition(_ window: NSWindow, offset: CGFloat) {
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(type) else { continue }
                let base = baseOrigins[type] ?? button.frame.origin.y
                baseOrigins[type] = base
                button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: base - offset))
            }
        }
    }
}
