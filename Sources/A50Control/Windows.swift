import AppKit
import ServiceManagement
import SwiftUI

/// Ventanas normales de la app. Vive en la barra de menús (sin icono en el Dock) salvo mientras
/// haya una ventana abierta: entonces es una app corriente (Dock, ⌘-Tab) y al cerrarla vuelve a la barra.
enum AppWindows {
    static let panelTitle = "A50 Control"
    static let eqTitle = "Ecualizador A50"

    /// La rellena MenuLabel con el `openWindow` de SwiftUI, que solo existe dentro de una vista.
    static var opener: ((String) -> Void)?

    static func isOurs(_ w: NSWindow) -> Bool {
        w.styleMask.contains(.titled) && (w.title == panelTitle || w.title == eqTitle)
    }

    /// Ventanas nuestras abiertas (las minimizadas cuentan: siguen en el Dock).
    static func open(excluding closing: NSWindow? = nil) -> [NSWindow] {
        NSApp.windows.filter { isOurs($0) && $0 !== closing && ($0.isVisible || $0.isMiniaturized) }
    }

    static func show(_ id: String) {
        NSApp.setActivationPolicy(.regular)
        opener?(id)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let title = id == "eq" ? eqTitle : panelTitle
            guard let w = NSApp.windows.first(where: { isOurs($0) && $0.title == title }) else { return }
            moveToMouseScreen(w)
            w.makeKeyAndOrderFront(nil)
        }
    }

    /// Clic en el icono del Dock o abrir la app otra vez desde Finder/Spotlight.
    static func handleReopen() {
        if let w = open().first(where: { $0.title == panelTitle }) {
            NSApp.activate(ignoringOtherApps: true)
            w.deminiaturize(nil)
            w.makeKeyAndOrderFront(nil)
        } else {
            show("panel")
        }
    }

    static func updatePolicy(closing: NSWindow? = nil) {
        let want: NSApplication.ActivationPolicy = open(excluding: closing).isEmpty ? .accessory : .regular
        if NSApp.activationPolicy() != want { NSApp.setActivationPolicy(want) }
    }

    /// Con dos monitores, la ventana se abría donde la dejó la última vez, a veces en el que no miras.
    static func mouseScreen() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }

    static func moveToMouseScreen(_ w: NSWindow) {
        guard let screen = mouseScreen(), w.screen !== screen else { return }
        let v = screen.visibleFrame
        w.setFrameOrigin(NSPoint(x: v.midX - w.frame.width / 2, y: v.midY - w.frame.height / 2))
    }
}

final class A50AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { n in
            AppWindows.updatePolicy(closing: n.object as? NSWindow)
        }
        nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            AppWindows.updatePolicy()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppWindows.handleReopen()
        return true
    }
}

extension A50Model {
    /// Al abrir la app a mano se enseña el panel. Quedan fuera las pruebas, `--oculto` y el arranque
    /// al iniciar sesión (con ese ajuste activo y el Mac recién encendido): ahí solo el icono.
    static var shouldOpenPanelOnLaunch: Bool {
        let args = CommandLine.arguments
        if args.contains("--ventana-panel") { return true }
        if args.contains("--oculto") || selfTestPath != nil || audioTestPath != nil
            || AppWindows.testPath != nil || Capture.directory != nil
            || Diagnostics.argument("--autotest-diag") != nil || Diagnostics.argument("--autotest-micro") != nil { return false }
        if SMAppService.mainApp.status == .enabled && ProcessInfo.processInfo.systemUptime < 600 { return false }
        return true
    }
}

// MARK: Autotest (`A50Control --oculto --autotest-ventana <informe.txt>`)

extension AppWindows {
    static var testPath: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--autotest-ventana"), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    /// Abre, cierra y reabre las ventanas y mira qué hace el icono del Dock. No toca la base. Escribe el informe y sale.
    static func runSelfTest(report path: String) {
        var log: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            log.append("\(ok ? "OK   " : "FALLA") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
        func wait(_ s: Double, _ next: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: next)
        }
        func panel() -> NSWindow? { open().first { $0.title == panelTitle } }
        func policy() -> String { NSApp.activationPolicy() == .regular ? "Dock" : "solo barra" }
        func finish() {
            log.append(log.contains { $0.hasPrefix("FALLA") } ? "RESULTADO: FALLA" : "RESULTADO: OK")
            try? log.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }

        check("arranca sin ventanas y sin Dock", open().isEmpty && NSApp.activationPolicy() == .accessory, policy())
        show("panel")
        wait(1) {
            check("abre el panel", panel() != nil)
            check("con ventana, la app sale en el Dock", NSApp.activationPolicy() == .regular, policy())
            if let w = panel() {
                check("el panel está en la pantalla del ratón", w.screen === mouseScreen(),
                      "ventana en \(w.screen?.frame.debugDescription ?? "?")")
            }
            panel()?.close()
            wait(0.6) {
                check("al cerrar, vuelve a la barra de menús", open().isEmpty && NSApp.activationPolicy() == .accessory, policy())
                handleReopen()
                wait(1) {
                    check("reabrir la app devuelve el panel", panel() != nil && NSApp.activationPolicy() == .regular, policy())
                    show("eq")
                    wait(1) {
                        check("el ecualizador se abre junto al panel", open().count == 2, "\(open().count) ventanas")
                        open().forEach { $0.close() }
                        wait(0.6) {
                            check("sin ventanas, otra vez solo la barra", open().isEmpty && NSApp.activationPolicy() == .accessory, policy())
                            finish()
                        }
                    }
                }
            }
        }
    }
}
