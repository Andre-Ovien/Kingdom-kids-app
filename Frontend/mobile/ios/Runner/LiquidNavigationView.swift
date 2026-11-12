import Flutter
import UIKit

/// The persistent Flutter navigation host owns one native view. UIKit renders
/// the glass; Flutter remains authoritative for routes, profile, and audio.
final class LiquidNavigationViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    LiquidNavigationPlatformView(
      frame: frame,
      identifier: viewId,
      arguments: args,
      messenger: messenger
    )
  }
}

private final class LiquidNavigationPlatformView: NSObject, FlutterPlatformView {
  private let navigationView: LiquidNavigationView
  private let channel: FlutterMethodChannel

  init(
    frame: CGRect,
    identifier: Int64,
    arguments: Any?,
    messenger: FlutterBinaryMessenger
  ) {
    navigationView = LiquidNavigationView(frame: frame)
    channel = FlutterMethodChannel(
      name: "kingdom_kids/liquid_navigation/\(identifier)",
      binaryMessenger: messenger
    )
    super.init()
    if let values = arguments as? [String: Any] {
      navigationView.update(values, animated: false)
    }
    navigationView.onSelect = { [weak self] route in
      self?.channel.invokeMethod("select", arguments: ["route": route])
    }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      guard call.method == "update" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let values = call.arguments as? [String: Any],
            let route = values["selectedRoute"] as? String,
            LiquidNavigationView.routes.contains(route) else {
        result(FlutterError(
          code: "invalid_navigation_update",
          message: "A supported selected route is required.",
          details: nil
        ))
        return
      }
      self.navigationView.update(values, animated: true)
      result(nil)
    }
  }

  func view() -> UIView { navigationView }

  deinit {
    channel.setMethodCallHandler(nil)
  }
}

/// A real system tab bar owns its Liquid Glass, selection, and continuous
/// selection gesture. Profile is a separate native glass button beside it.
private final class LiquidNavigationView: UIView, UITabBarDelegate {
  static let routes = ["/", "/stories", "/games", "/profile"]
  private static let selectedInk = UIColor(red: 20 / 255, green: 87 / 255, blue: 1, alpha: 1)

  var onSelect: ((String) -> Void)?

  private let tabBar = UITabBar()
  private let tabItems: [UITabBarItem] = zip(
    ["Home", "Stories", "Games"],
    ["house.fill", "book.closed.fill", "puzzlepiece.extension.fill"]
  ).enumerated().map { index, value in
    let item = UITabBarItem(
      title: value.0,
      image: UIImage(systemName: value.1),
      selectedImage: nil
    )
    item.tag = index
    item.accessibilityIdentifier = "liquid-navigation-\(value.0.lowercased())"
    return item
  }
  private let profileGlass = LiquidNavigationView.makeProfileGlass()
  private let profileButton = UIButton(type: .custom)
  private let profileImageView = UIImageView()
  private var selectedRoute = "/"
  private var reduceMotion = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    overrideUserInterfaceStyle = .light
    isAccessibilityElement = false

    // Keep these item objects and this UITabBar alive across every page change.
    // Do not assign appearances, backgrounds, custom selectors, or recognizers:
    // UIKit supplies the current OS's native floating control and its gestures.
    tabBar.items = tabItems
    tabBar.selectedItem = tabItems.first
    tabBar.delegate = self
    tabBar.tintColor = Self.selectedInk
    tabBar.accessibilityIdentifier = "liquid-navigation-system-tab-bar"
    addSubview(tabBar)

    addSubview(profileGlass)
    profileGlass.contentView.addSubview(profileButton)
    profileButton.accessibilityLabel = "Profile"
    profileButton.accessibilityIdentifier = "liquid-navigation-profile"
    profileButton.addTarget(self, action: #selector(profileTapped), for: .touchUpInside)
    profileImageView.contentMode = .scaleAspectFill
    profileImageView.clipsToBounds = true
    profileImageView.isUserInteractionEnabled = false
    profileButton.addSubview(profileImageView)
    clearProfileImage()
    accessibilityElements = [tabBar, profileButton]
    updateProfileSelection()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func update(_ values: [String: Any], animated: Bool) {
    guard let route = values["selectedRoute"] as? String,
          Self.routes.contains(route) else { return }
    let selectionChanged = route != selectedRoute
    selectedRoute = route
    reduceMotion = values["reduceMotion"] as? Bool ?? false
    if let bytes = values["profileImage"] as? FlutterStandardTypedData,
       let image = UIImage(data: bytes.data) {
      profileImageView.image = image
      profileImageView.tintColor = nil
    } else {
      clearProfileImage()
    }

    // A native gesture has already selected its item before Dart acknowledges
    // the route. Reassigning it on every acknowledgement/avatar load can reset
    // the system's interaction. Only reconcile genuinely different selections.
    if selectionChanged || !animated {
      reconcileSelection(animated: animated)
    }
    updateProfileSelection()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let profileSize = min(69, bounds.width)
    let gap: CGFloat = 10
    let dockWidth = max(0, bounds.width - profileSize - gap)
    let fittingSize = tabBar.sizeThatFits(
      CGSize(width: dockWidth, height: bounds.height)
    )
    // The modern system bar requests 83pt here. Give it its public intrinsic
    // sizing rather than clipping/rebuilding its private 62pt floating platter.
    tabBar.frame = CGRect(
      x: 0, y: 0,
      width: dockWidth,
      height: max(0, fittingSize.height)
    )
    profileGlass.frame = CGRect(
      x: dockWidth + gap, y: 0, width: profileSize, height: profileSize
    )
    makeProfileCapsule()
    profileButton.frame = profileGlass.bounds
    let avatarSize = min(52, max(0, profileSize - 12))
    profileImageView.frame = CGRect(
      x: (profileSize - avatarSize) / 2,
      y: (profileSize - avatarSize) / 2,
      width: avatarSize,
      height: avatarSize
    )
    profileImageView.layer.cornerRadius = avatarSize / 2
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    tabBar.frame.contains(point) || profileGlass.frame.contains(point)
  }

  private func reconcileSelection(animated: Bool) {
    let item = Self.routes.firstIndex(of: selectedRoute).flatMap {
      $0 < tabItems.count ? tabItems[$0] : nil
    }
    // UITabBar explicitly supports a nil selectedItem. Profile is not a fourth
    // item in the main group, so it clears that group's selection.
    guard tabBar.selectedItem !== item else { return }
    let changes = { self.tabBar.selectedItem = item }
    if !animated || reduceMotion || UIAccessibility.isReduceMotionEnabled {
      UIView.performWithoutAnimation(changes)
    } else {
      changes()
    }
  }

  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    guard let index = tabItems.firstIndex(where: { $0 === item }) else { return }
    let route = Self.routes[index]
    guard route != selectedRoute else { return }
    selectedRoute = route
    updateProfileSelection()
    onSelect?(route)
  }

  @objc private func profileTapped() {
    guard selectedRoute != "/profile" else { return }
    selectedRoute = "/profile"
    reconcileSelection(animated: true)
    updateProfileSelection()
    onSelect?(selectedRoute)
  }

  private func updateProfileSelection() {
    let selected = selectedRoute == "/profile"
    profileButton.accessibilityTraits = selected ? [.button, .selected] : [.button]
    profileGlass.contentView.layer.borderWidth = selected ? 1.5 : 0
    profileGlass.contentView.layer.borderColor = Self.selectedInk.withAlphaComponent(0.5).cgColor
    profileGlass.contentView.layer.cornerRadius = min(profileGlass.bounds.width, profileGlass.bounds.height) / 2
  }

  private func clearProfileImage() {
    profileImageView.image = UIImage(systemName: "person.crop.circle.fill")
    profileImageView.tintColor = .label
  }

  private static func makeProfileGlass() -> UIVisualEffectView {
    let effect: UIVisualEffect
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect(style: .clear)
      glass.isInteractive = true
      effect = glass
    } else {
      effect = UIBlurEffect(style: .systemUltraThinMaterialLight)
    }
    let view = UIVisualEffectView(effect: effect)
    view.backgroundColor = .clear
    view.isOpaque = false
    view.clipsToBounds = true
    return view
  }

  private func makeProfileCapsule() {
    if #available(iOS 26.0, *) {
      profileGlass.cornerConfiguration = .capsule()
    } else {
      profileGlass.layer.cornerRadius = min(profileGlass.bounds.width, profileGlass.bounds.height) / 2
      profileGlass.layer.cornerCurve = .continuous
    }
  }
}
