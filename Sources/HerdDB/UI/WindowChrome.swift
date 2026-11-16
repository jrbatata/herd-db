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
    var onFullScreenChange: ((Bool) -> Void)? = nil
    var onCloseRequest: (() -> Bool)? = nil
    /// Quanto os semáforos descem, pra ficarem centrados na barra de 36pt.
    private let trafficLightOffset: CGFloat = 3

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.tabbingMode = .disallowed
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = .clear
            context.coordinator.attach(to: window, offset: trafficLightOffset)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onFullScreenChange = onFullScreenChange
        context.coordinator.onCloseRequest = onCloseRequest
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.onFullScreenChange = onFullScreenChange
        coordinator.onCloseRequest = onCloseRequest
        return coordinator
    }

    @MainActor
    final class Coordinator: NSObject {
        private var observers: [NSObjectProtocol] = []
        private var baseOrigins: [NSWindow.ButtonType: CGFloat] = [:]
        var onFullScreenChange: ((Bool) -> Void)?
        var onCloseRequest: (() -> Bool)?

        func attach(to window: NSWindow, offset: CGFloat) {
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didEnterFullScreenNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window else { return }
                        self.reposition(window, offset: offset)
                        self.onFullScreenChange?(window.styleMask.contains(.fullScreen))
                    }
                })
            }
            reposition(window, offset: offset)
            if let button = window.standardWindowButton(.closeButton) {
                button.target = self
                button.action = #selector(closeRequested(_:))
            }
            onFullScreenChange?(window.styleMask.contains(.fullScreen))
        }

        @objc private func closeRequested(_ sender: Any?) {
            guard onCloseRequest?() != false else { return }
            // `performClose` clicks the standard close button. Since that button's
            // action points back here, using it would recurse until a stack overflow.
            (sender as? NSView)?.window?.close()
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
