import Cocoa
import FlutterMacOS

private func renderPdfPage(path: String, page: Int, width: Int) -> Any {
  guard let document = CGPDFDocument(URL(fileURLWithPath: path) as CFURL) else {
    return FlutterError(code: "pdf", message: "This PDF couldn't be opened.", details: nil)
  }
  if document.isEncrypted && !document.isUnlocked {
    return FlutterError(code: "pdf", message: "This PDF is protected by a password.", details: nil)
  }
  guard document.numberOfPages > 0, let pdfPage = document.page(at: max(0, min(page, document.numberOfPages - 1)) + 1) else {
    return FlutterError(code: "pdf", message: "This PDF has no pages.", details: nil)
  }
  let box = pdfPage.getBoxRect(.cropBox)
  let sideways = abs(pdfPage.rotationAngle) % 180 == 90
  let natural = sideways ? CGSize(width: box.height, height: box.width) : box.size
  guard natural.width > 0, natural.height > 0 else {
    return FlutterError(code: "pdf", message: "This PDF page is empty.", details: nil)
  }
  let scale = CGFloat(width) / natural.width
  let pixelWidth = width
  let pixelHeight = Int((natural.height * scale).rounded())
  guard let context = CGContext(
    data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else {
    return FlutterError(code: "pdf", message: "This PDF page is too large to draw.", details: nil)
  }
  context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
  context.scaleBy(x: scale, y: scale)
  // At the page's own size this only handles its offset and rotation: the transform never scales up.
  context.concatenate(pdfPage.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: natural), rotate: 0, preserveAspectRatio: true))
  context.drawPDFPage(pdfPage)
  guard let image = context.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
    return FlutterError(code: "pdf", message: "This PDF page couldn't be drawn.", details: nil)
  }
  return ["pages": document.numberOfPages, "png": FlutterStandardTypedData(bytes: png)] as [String: Any]
}

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
    channel.setMethodCallHandler { call, result in
      guard call.method == "renderPdf" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any], let path = args["path"] as? String,
        let page = args["page"] as? Int, let width = args["width"] as? Int
      else {
        result(FlutterError(code: "pdf", message: "Bad arguments", details: nil))
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        let output = renderPdfPage(path: path, page: page, width: width)
        DispatchQueue.main.async { result(output) }
      }
    }

    super.awakeFromNib()
  }
}
