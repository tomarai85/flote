import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// メインの Flutter engine へノートウィンドウの位置/サイズ更新を push する channel。
  /// J-1: desktop_multi_window の サブウィンドウ が NSWindow.didMove /
  /// didEndLiveResize を発火したとき、タイトルから noteId を抽出して Flutter に
  /// 通知する。Flutter 側は NoteManager.updatePosition / updateSize で永続化する。
  private var styleChannel: FlutterMethodChannel?

  /// NSWindow タイトルのプレフィックス。Flutter 側
  /// `titleForNoteWindow(noteId) = "Flote Note $noteId"` と同期。
  private static let noteWindowTitlePrefix = "Flote Note "

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "flote/window_style",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    self.styleChannel = channel

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }

      switch call.method {
      case "applyNonactivatingStyleToAllSubwindows":
        self.applyNonactivatingStyleToAllSubwindows()
        result(nil)
      case "setWindowLevelFloating":
        if let args = call.arguments as? [String: Any],
           let title = args["windowTitle"] as? String {
          self.setWindowLevelFloating(title: title)
          result(nil)
        } else {
          result(
            FlutterError(
              code: "bad_args",
              message: "windowTitle required",
              details: nil
            )
          )
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // J-1: サブウィンドウの move/resize を購読して Flutter メインに push する。
    // delegate を差し替えると desktop_multi_window が内部で使う
    // NSWindowDelegate を壊すため、代わりに NotificationCenter を使う。
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(onAnyWindowDidMove(_:)),
      name: NSWindow.didMoveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(onAnyWindowDidEndLiveResize(_:)),
      name: NSWindow.didEndLiveResizeNotification,
      object: nil
    )

    super.awakeFromNib()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  /// SwiftUI FloatingPanel.swift 準拠の視覚設定をノートウィンドウに適用する。
  /// styleMask = [.nonactivatingPanel, .fullSizeContentView] 相当
  /// + 赤/黄/緑トラフィックライト非表示 + タイトルバー透明 + 背景透明 + 影あり。
  private func applyFloteNoteWindowStyle(to window: NSWindow) {
    // Floating + 全スペース追従
    window.level = .floating
    window.collectionBehavior.insert(.canJoinAllSpaces)
    window.collectionBehavior.insert(.stationary)
    window.isMovableByWindowBackground = true

    // SwiftUI FloatingPanel と同じ枠なしスタイル。
    window.styleMask.insert(.fullSizeContentView)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true

    // 赤/黄/緑ボタン (close/miniaturize/zoom) を隠す。SwiftUI 版は
    // .titled を含まないのでそもそもボタンが存在しないが、
    // desktop_multi_window が .titled を付けてくるため隠して対応する。
    window.standardWindowButton(.closeButton)?.isHidden = true
    window.standardWindowButton(.miniaturizeButton)?.isHidden = true
    window.standardWindowButton(.zoomButton)?.isHidden = true

    // 背景を透明にして Flutter 側の角丸背景を見せる。
    window.backgroundColor = .clear
    window.isOpaque = false
    window.hasShadow = true
  }

  private func applyNonactivatingStyleToAllSubwindows() {
    for window in NSApp.windows {
      if window === self {
        continue
      }
      applyFloteNoteWindowStyle(to: window)
    }
  }

  private func setWindowLevelFloating(title: String) {
    for window in NSApp.windows {
      if window.title == title {
        applyFloteNoteWindowStyle(to: window)
        return
      }
    }
  }

  /// 任意の NSWindow が動いたとき、それが Note ウィンドウなら Flutter に通知する。
  @objc private func onAnyWindowDidMove(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    if window === self { return }
    guard let noteId = Self.noteIdFromTitle(window.title) else { return }

    // NSWindow の座標系は左下原点だが、Flutter 側の StickyNote.positionX/Y は
    // 「左上原点 (Cocoa の frame.origin に近い)」として保存しているため、
    // そのまま frame.origin を渡す。再表示時は NoteWindowManager.setFrame が
    // 同じ座標系で復元するので一貫する (両方向 Cocoa base で完結)。
    let frame = window.frame
    styleChannel?.invokeMethod(
      "noteWindow.didMove",
      arguments: [
        "noteId": noteId,
        "x": frame.origin.x,
        "y": frame.origin.y,
      ]
    )
  }

  /// 任意の NSWindow のライブリサイズが終わったら Flutter に通知する。
  @objc private func onAnyWindowDidEndLiveResize(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    if window === self { return }
    guard let noteId = Self.noteIdFromTitle(window.title) else { return }

    let size = window.frame.size
    let origin = window.frame.origin
    styleChannel?.invokeMethod(
      "noteWindow.didResize",
      arguments: [
        "noteId": noteId,
        "width": size.width,
        "height": size.height,
        "x": origin.x,
        "y": origin.y,
      ]
    )
  }

  /// "Flote Note <id>" → "<id>" を抽出する。パターン違いなら nil。
  private static func noteIdFromTitle(_ title: String) -> String? {
    guard title.hasPrefix(noteWindowTitlePrefix) else { return nil }
    let id = String(title.dropFirst(noteWindowTitlePrefix.count))
    return id.isEmpty ? nil : id
  }
}
