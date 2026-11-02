import Cocoa
import FlutterMacOS

// Sits over the Flutter view only to receive dragged files; mouse events pass through it.
private class FileDropView: NSView {
  private let channel: FlutterMethodChannel

  init(frame: NSRect, channel: FlutterMethodChannel) {
    self.channel = channel
    super.init(frame: frame)
    registerForDraggedTypes([.fileURL])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    return nil
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    channel.invokeMethod("dragEntered", arguments: nil)
    return .copy
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    channel.invokeMethod("dragExited", arguments: nil)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let urls = sender.draggingPasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    channel.invokeMethod("dropped", arguments: urls.map { $0.path })
    return true
  }
}

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
    // For lib/core/native_bridge.dart.
    let channel = FlutterMethodChannel(name: "devkit/native", binaryMessenger: flutterViewController.engine.binaryMessenger)
    let dropView = FileDropView(frame: flutterViewController.view.bounds, channel: channel)
    dropView.autoresizingMask = [.width, .height]
    flutterViewController.view.addSubview(dropView)

    super.awakeFromNib()
  }
}
