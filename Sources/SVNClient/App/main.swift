import AppKit

let application = NSApplication.shared
let appDelegate = AppDelegate()

application.setActivationPolicy(AppRuntimeEnvironment.isRunningTests() ? .prohibited : .regular)
application.delegate = appDelegate
application.run()
