import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let project = FlutterDartProject()
    project.dartEntrypointArguments = arguments
    let flutterViewController = FlutterViewController(project: project)
    self.contentViewController = flutterViewController

    // A device workspace opens with --title=<device name> and --cascade=<n>.
    var cascade = 0
    for argument in arguments {
      if argument.hasPrefix("--title=") {
        self.title = String(argument.dropFirst("--title=".count))
      } else if argument.hasPrefix("--cascade=") {
        cascade = (Int(argument.dropFirst("--cascade=".count)) ?? 0) % 8
      }
    }

    let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
    let width = min(1440, screen.width)
    let height = min(900, screen.height)
    let step = CGFloat(cascade * 40)
    self.setFrame(
      NSRect(x: screen.minX + step, y: screen.maxY - height - step, width: width, height: height),
      display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
