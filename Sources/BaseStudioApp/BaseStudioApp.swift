import SwiftUI

@main
struct BaseStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Base Studio") {
            ContentView()
                .frame(minWidth: 1080, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandMenu("Recording") {
                Button("Stop Recording") {
                    AppDelegate.shared.stopHandler?.stopRecording()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { AppDelegate.shared.editorActions?.undo() }
                    .keyboardShortcut("z", modifiers: [.command])
                Button("Redo") { AppDelegate.shared.editorActions?.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("Editor") {
                Button("Play / Pause") {
                    AppDelegate.shared.editorActions?.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Delete Selected Region") {
                    AppDelegate.shared.editorActions?.deleteSelectedRegion()
                }
                .keyboardShortcut(.delete, modifiers: [])

                Divider()

                Button("Step Backward (1 frame)") {
                    AppDelegate.shared.editorActions?.stepBackward(seconds: 1.0/60.0)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])

                Button("Step Forward (1 frame)") {
                    AppDelegate.shared.editorActions?.stepForward(seconds: 1.0/60.0)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])

                Button("Step Backward (1 second)") {
                    AppDelegate.shared.editorActions?.stepBackward(seconds: 1.0)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.shift])

                Button("Step Forward (1 second)") {
                    AppDelegate.shared.editorActions?.stepForward(seconds: 1.0)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.shift])

                Button("Go to Start") { AppDelegate.shared.editorActions?.gotoStart() }
                    .keyboardShortcut(.home, modifiers: [])
                Button("Go to End") { AppDelegate.shared.editorActions?.gotoEnd() }
                    .keyboardShortcut(.end, modifiers: [])

                Divider()

                Button("Export…") {
                    AppDelegate.shared.editorActions?.export()
                }
                .keyboardShortcut("e", modifiers: [.command])
            }
        }
    }
}
