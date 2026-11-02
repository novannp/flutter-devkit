import Cocoa
import FlutterMacOS
import UserNotifications

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

// System notifications and file drops, for lib/core/native_bridge.dart.
private class NativeBridge: NSObject, UNUserNotificationCenterDelegate {
  private let channel: FlutterMethodChannel

  init(controller: FlutterViewController) {
    channel = FlutterMethodChannel(name: "devkit/native", binaryMessenger: controller.engine.binaryMessenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "notify", let arguments = call.arguments as? [String: Any] else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.notify(arguments, result: result)
    }
    UNUserNotificationCenter.current().delegate = self

    let dropView = FileDropView(frame: controller.view.bounds, channel: channel)
    dropView.autoresizingMask = [.width, .height]
    controller.view.addSubview(dropView)
  }

  private func notify(_ arguments: [String: Any], result: @escaping FlutterResult) {
    let content = UNMutableNotificationContent()
    content.title = arguments["title"] as? String ?? ""
    content.body = arguments["body"] as? String ?? ""
    let id = String(arguments["id"] as? Int ?? 0)
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
      guard granted else {
        DispatchQueue.main.async {
          result(FlutterError(code: "notifications_denied", message: nil, details: nil))
        }
        return
      }
      center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
        DispatchQueue.main.async {
          result(error == nil ? nil : FlutterError(code: "notify_failed", message: error?.localizedDescription, details: nil))
        }
      }
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let id = Int(response.notification.request.identifier) ?? -1
    DispatchQueue.main.async {
      self.channel.invokeMethod("notificationClicked", arguments: id)
      NSApp.activate(ignoringOtherApps: true)
    }
    completionHandler()
  }
}

class MainFlutterWindow: NSWindow {
  private var nativeBridge: NativeBridge?

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
    nativeBridge = NativeBridge(controller: flutterViewController)

    super.awakeFromNib()
  }
}
