import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController

    // The scaffold's 800x600 opens just under kRailBreakpoint (840dp), which
    // would show the phone layout in a desktop window. Open wide enough for
    // the navigation rail and the diary to breathe; the minimum keeps the
    // window from being squeezed below anything the phone layouts handle.
    var frame = windowFrame
    frame.size = NSSize(width: 1100, height: 800)
    self.setFrame(frame, display: true)
    self.contentMinSize = NSSize(width: 400, height: 600)
    self.setFrameAutosaveName("MojoMainWindow")

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
