import Flutter
import CoreMotion
import UIKit
import UserNotifications
import StoreKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var sailingMotionChannel: FlutterEventChannel?
  private var sailingMotionHandler: SailingMotionStreamHandler?
  private var storefrontChannel: FlutterMethodChannel?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    CheckoutReturnLinkBridge.shared.register(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
    storefrontChannel?.setMethodCallHandler(nil)
    let storefront = FlutterMethodChannel(
      name: "kingdom_kids/storefront",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    storefront.setMethodCallHandler { call, result in
      guard call.method == "currentCountryCode" else {
        result(FlutterMethodNotImplemented)
        return
      }
      Task { @MainActor in
        let current = await Storefront.current
        result(current?.countryCode)
      }
    }
    storefrontChannel = storefront
    engineBridge.applicationRegistrar.register(
      LiquidNavigationViewFactory(
        messenger: engineBridge.applicationRegistrar.messenger()
      ),
      withId: "kingdom_kids/liquid_navigation"
    )
    sailingMotionHandler?.dispose()
    sailingMotionChannel?.setStreamHandler(nil)
    let handler = SailingMotionStreamHandler()
    let channel = FlutterEventChannel(
      name: "kingdom_kids/sailing_motion",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setStreamHandler(handler)
    sailingMotionHandler = handler
    sailingMotionChannel = channel
  }
}

/// Only transports non-auth checkout correlation. Dart validates every field
/// and then uses the signed-in parent's API session to verify the purchase.
final class CheckoutReturnLinkBridge: NSObject, FlutterStreamHandler {
  static let shared = CheckoutReturnLinkBridge()
  private var pending: String?
  private var sink: FlutterEventSink?
  private var methods: FlutterMethodChannel?
  private var events: FlutterEventChannel?

  func register(messenger: FlutterBinaryMessenger) {
    methods?.setMethodCallHandler(nil)
    events?.setStreamHandler(nil)
    let methods = FlutterMethodChannel(name: "kingdom_kids/checkout_returns", binaryMessenger: messenger)
    methods.setMethodCallHandler { [weak self] call, result in
      guard call.method == "initialLink" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let value = self?.pending
      self?.pending = nil
      result(value)
    }
    self.methods = methods
    let events = FlutterEventChannel(name: "kingdom_kids/checkout_return_events", binaryMessenger: messenger)
    events.setStreamHandler(self)
    self.events = events
  }

  func receive(_ url: URL) {
    guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
    let https = parts.scheme == "https" && parts.host == "kingdom-kids.app" && parts.percentEncodedPath == "/payments/return/"
    let fallback = parts.scheme == "kingdomkids" && parts.host == "payments" && parts.percentEncodedPath == "/return/"
    guard https || fallback, url.absoluteString.count <= 1024 else { return }
    if let sink = sink { sink(url.absoluteString) }
    else { pending = url.absoluteString }
  }

  func onListen(withArguments arguments: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
    sink = eventSink
    if let value = pending {
      pending = nil
      eventSink(value)
    }
    return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }
}

/// A single Core Motion session, stopped whenever the game unsubscribes or
/// the app leaves the foreground. No fitness-history APIs are used.
private final class SailingMotionStreamHandler: NSObject, FlutterStreamHandler {
  private let motion = CMMotionManager()
  private var events: FlutterEventSink?
  private var observers: [NSObjectProtocol] = []
  private var generation = 0
  private var foreground = UIApplication.shared.applicationState == .active

  override init() {
    super.init()
    let notifications = NotificationCenter.default
    observers.append(notifications.addObserver(
      forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.foreground = false
      self?.stop()
    })
    observers.append(notifications.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.foreground = true
      self?.start()
    })
  }

  func onListen(withArguments arguments: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
    stop()
    guard motion.isDeviceMotionAvailable else {
      return FlutterError(code: "motion_unavailable", message: "Device tilt is unavailable.", details: nil)
    }
    events = eventSink
    start()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    events = nil
    stop()
    return nil
  }

  private func start() {
    guard foreground, events != nil, !motion.isDeviceMotionActive else { return }
    generation += 1
    let request = generation
    motion.deviceMotionUpdateInterval = 1.0 / 30.0
    motion.startDeviceMotionUpdates(to: .main) { [weak self] sample, error in
      guard let self = self, self.foreground, self.generation == request,
            let sink = self.events else { return }
      if let error = error {
        sink(FlutterError(code: "motion_unavailable", message: error.localizedDescription, details: nil))
        sink(FlutterEndOfEventStream)
        self.events = nil
        self.stop()
        return
      }
      if let x = sample?.gravity.x, x.isFinite {
        // Core Motion gravity points downhill: a rightward portrait lean
        // produces a positive x, unlike Android's proper acceleration.
        sink(max(-1.0, min(1.0, x)))
      }
    }
  }

  private func stop() {
    generation += 1
    motion.stopDeviceMotionUpdates()
  }

  func dispose() {
    events = nil
    stop()
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
  }

  deinit { dispose() }
}
