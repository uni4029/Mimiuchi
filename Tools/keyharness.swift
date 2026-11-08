// Test harness: shows a window with selected text, becomes frontmost and presses ⌘C twice
// through the window server (real key events), exactly like a user would.
import AppKit
import Carbon.HIToolbox

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        let menu = NSMenu()
        let editItem = NSMenuItem()
        menu.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        NSApp.mainMenu = menu

        window = NSWindow(contentRect: NSRect(x: 260, y: 420, width: 640, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Harness"
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 160))
        tv.font = .systemFont(ofSize: 18)
        tv.string = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Hello world"
        window.contentView = tv
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))

        let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "double"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            // Safety: only press keys when this harness is the frontmost app, so keystrokes can
            // never go to another application.
            for _ in 0 ..< 10 where NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                NSApp.activate(ignoringOtherApps: true)
                self.window.makeKeyAndOrderFront(nil)
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            }
            let front = NSWorkspace.shared.frontmostApplication
            print("frontmost:", front?.bundleIdentifier ?? "?", "pid", front?.processIdentifier ?? -1)
            guard front?.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
                print("ABORT: harness is not frontmost; no keys pressed")
                exit(3)
            }
            Self.press()
            if mode == "double" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { Self.press(); print("pressed cmd+c twice") }
            } else {
                print("pressed cmd+c once")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) { NSApp.terminate(nil) }
        }
    }

    static func press() {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
