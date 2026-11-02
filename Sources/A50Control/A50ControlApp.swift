import SwiftUI

@main
struct A50ControlApp: App {
    @NSApplicationDelegateAdaptor(A50AppDelegate.self) private var delegate
    @StateObject private var model = A50Model()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: {
            MenuLabel().environmentObject(model)
        }
        .menuBarExtraStyle(.window)

        Window(AppWindows.eqTitle, id: "eq") {
            EQEditorView().environmentObject(model)
        }
        .windowResizability(.contentSize)

        // El mismo panel de la barra de menús, como ventana normal: se abre al lanzar la app a mano.
        Window(AppWindows.panelTitle, id: "panel") {
            MenuView(inWindow: true).environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}
