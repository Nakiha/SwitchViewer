import Cocoa
import AVFoundation
import CoreImage
import CoreMedia
import IOKit.pwr_mgt
import Metal
import VideoToolbox
import simd
import SwitchViewerInterpolation

extension AppDelegate {
    func markSourceSelected() {
        hasSelectedSource = true
        window.makeKeyAndOrderFront(nil)
    }

    func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "SwitchViewer"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 400)
        window.delegate = self
        window.collectionBehavior = [.fullScreenPrimary]
        window.acceptsMouseMovedEvents = true
        window.center()

        rootView = NSView(frame: window.contentView!.bounds)
        rootView.autoresizingMask = [.width, .height]
        window.contentView = rootView

        previewView = PreviewView()
        previewView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(previewView)

        // Capture coordinators retain selection state; configuration edits it in-app.
        devicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        devicePopup.target = self
        devicePopup.action = #selector(deviceChanged(_:))

        formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged(_:))
        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: rootView.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])

    }

    /// Standard application commands plus compatibility state used by coordinators.
    /// All configuration controls are embedded in the floating control bar.
    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let application = NSMenu()
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        application.addItem(settings)
        application.addItem(.separator())
        let quit = NSMenuItem(title: "退出 SwitchViewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        application.addItem(quit)
        appItem.submenu = application
        main.addItem(appItem)
        NSApp.mainMenu = main

        deviceMenu = NSMenu()
        formatMenu = NSMenu()
        sourceMenu = NSMenu()
        statusTextItem = NSMenuItem(title: "未运行", action: nil, keyEquivalent: "")
        statusDetailsItem = NSMenuItem()
        muteMenuItem = NSMenuItem()
        floatMenuItem = NSMenuItem()
        clickThroughMenuItem = NSMenuItem()
        gameOperationMenuItem = NSMenuItem()
        frameInterpolationMenuItem = NSMenuItem(title: "Apple 插帧", action: nil, keyEquivalent: "")
        uniformProxyMenuItem = NSMenuItem()
        volumeSlider = NSSlider(value: Double(audioVolume), minValue: 0, maxValue: 1,
                                target: self, action: #selector(volumeChanged(_:)))
        colorMenuItems = ColorMode.allCases.map { mode in
            let item = NSMenuItem(title: mode.label, action: nil, keyEquivalent: "")
            item.tag = mode.rawValue
            return item
        }
        frameInterpolationModeMenuItems = FrameInterpolationMode.allCases.map { mode in
            let item = NSMenuItem(title: mode.label, action: nil, keyEquivalent: "")
            item.tag = mode.rawValue
            return item
        }
        presentationPacingMenuItems = PresentationPacingMode.allCases.map { mode in
            let item = NSMenuItem(title: mode.label, action: nil, keyEquivalent: "")
            item.tag = mode.rawValue
            return item
        }
        refreshSourceMenu()
        updateAppleLowLatencyMenuAvailability()
    }

    @objc func showSettingsFromMenu() { showConfiguration() }
}
