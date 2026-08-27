import AppKit

let application = NSApplication.shared
let appDelegate = AppDelegate()

application.setActivationPolicy(.regular)
application.delegate = appDelegate
application.run()
