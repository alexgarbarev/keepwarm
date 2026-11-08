// keepwarm-menu.swift
// Иконка в меню-баре с режимами Вкл / Выкл / Авто.
// Авто: если загрузка GPU выше порога несколько секунд подряд, утилита
// выключается; когда загрузка спадает, включается снова.
//
// Сборка: swiftc -O keepwarm-menu.swift -o keepwarm
// Параметры (необязательно):
//   --fps N         частота обновлений (по умолчанию 45)
//   --threshold N   порог загрузки GPU в % для режима Авто (по умолчанию 60)
//   --alpha A       прозрачность окна (по умолчанию 0.02)

import Cocoa
import IOKit
import QuartzCore

// ---------- Настройки ----------
struct Config {
    var fps: Int = 45
    var threshold: Int = 60
    var alpha: CGFloat = 0.02
}

func parseArgs() -> Config {
    var c = Config()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--fps":       if let v = it.next(), let n = Int(v) { c.fps = n }
        case "--threshold": if let v = it.next(), let n = Int(v) { c.threshold = n }
        case "--alpha":     if let v = it.next(), let d = Double(v) { c.alpha = CGFloat(d) }
        default: break
        }
    }
    return c
}

// ---------- Загрузка GPU ----------
// Читает PerformanceStatistics у IOAccelerator. Название ключа может
// отличаться между версиями macOS, поэтому проверяем несколько вариантов.
// Если ничего не нашли, возвращаем nil (Авто тогда работает как Вкл).
func gpuUtilization() -> Int? {
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                       IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS
    else { return nil }
    defer { IOObjectRelease(it) }

    var best: Int? = nil
    var svc = IOIteratorNext(it)
    while svc != 0 {
        if let ref = IORegistryEntryCreateCFProperty(
            svc, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0),
           let dict = ref.takeRetainedValue() as? [String: Any] {
            for key in ["Device Utilization %", "GPU Activity(%)", "Renderer Utilization %"] {
                if let n = dict[key] as? NSNumber {
                    best = max(best ?? 0, n.intValue)
                    break
                }
            }
        }
        IOObjectRelease(svc)
        svc = IOIteratorNext(it)
    }
    return best
}

// ---------- Приложение ----------
enum Mode: String { case on, off, auto }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let cfg = parseArgs()

    var mode: Mode = .auto
    var autoPaused = false
    var overCount = 0
    var underCount = 0
    var lastUtil: Int? = nil

    var statusItem: NSStatusItem!
    var statusLine: NSMenuItem!
    var modeItems: [Mode: NSMenuItem] = [:]

    var window: NSWindow?
    var layer: CALayer?
    var link: CADisplayLink?
    var toggle = false
    var primaryIsBuiltin = false

    func applicationDidFinishLaunching(_ n: Notification) {
        if let s = UserDefaults.standard.string(forKey: "mode"), let m = Mode(rawValue: s) {
            mode = m
        }
        setupMenu()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
        sample()
    }

    // ----- Меню -----
    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self

        statusLine = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        for (m, title) in [(Mode.on, "Вкл"), (Mode.off, "Выкл"), (Mode.auto, "Авто")] {
            let item = NSMenuItem(title: title, action: #selector(pickMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = m.rawValue
            menu.addItem(item)
            modeItems[m] = item
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выход", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        refreshUI()
    }

    @objc func pickMode(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String, let m = Mode(rawValue: s) else { return }
        mode = m
        UserDefaults.standard.set(m.rawValue, forKey: "mode")
        autoPaused = false
        overCount = 0
        underCount = 0
        apply()
    }

    @objc func quit() { NSApp.terminate(nil) }

    func menuWillOpen(_ menu: NSMenu) { refreshUI() }

    // ----- Логика режима Авто -----
    func sample() {
        lastUtil = gpuUtilization()

        if mode == .auto {
            if let u = lastUtil {
                if u > cfg.threshold {
                    overCount += 1; underCount = 0
                    if overCount >= 3 { autoPaused = true }      // >порога 3 сек подряд
                } else {
                    underCount += 1; overCount = 0
                    if underCount >= 2 { autoPaused = false }    // ниже порога 2 сек подряд
                }
            } else {
                autoPaused = false   // ключ не найден, работаем как Вкл
            }
        }
        apply()
    }

    var shouldRun: Bool {
        switch mode {
        case .on:   return true
        case .off:  return false
        case .auto: return !autoPaused
        }
    }

    func apply() {
        if shouldRun {
            if window == nil { buildWindow() }
        } else {
            teardownWindow()
        }
        refreshUI()
    }

    // ----- Окно -----
    @objc func screensChanged() {
        teardownWindow()
        apply()
    }

    func teardownWindow() {
        link?.invalidate(); link = nil
        window?.orderOut(nil); window = nil; layer = nil
    }

    func buildWindow() {
        guard let screen = NSScreen.screens.first else { return }   // primary
        if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           CGDisplayIsBuiltin(CGDirectDisplayID(num.uint32Value)) != 0 {
            primaryIsBuiltin = true
            return
        }
        primaryIsBuiltin = false

        let rect = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: 4, height: 4)
        let w = NSWindow(contentRect: rect, styleMask: .borderless,
                         backing: .buffered, defer: false, screen: screen)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let v = NSView(frame: NSRect(origin: .zero, size: rect.size))
        v.wantsLayer = true
        let l = CALayer()
        l.frame = v.bounds
        l.backgroundColor = NSColor.black.withAlphaComponent(cfg.alpha).cgColor
        v.layer?.addSublayer(l)
        w.contentView = v
        w.orderFrontRegardless()

        let f = Float(cfg.fps)
        let dl = v.displayLink(target: self, selector: #selector(tick(_:)))
        dl.preferredFrameRateRange = CAFrameRateRange(minimum: f, maximum: f, preferred: f)
        dl.add(to: .main, forMode: .common)

        window = w; layer = l; link = dl
    }

    @objc func tick(_ sender: CADisplayLink) {
        toggle.toggle()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = NSColor.black
            .withAlphaComponent(toggle ? cfg.alpha * 2 : cfg.alpha).cgColor
        CATransaction.commit()
    }

    // ----- Отображение -----
    func refreshUI() {
        for (m, item) in modeItems { item.state = (m == mode) ? .on : .off }

        let gpuText = lastUtil.map { "GPU \($0)%" } ?? "GPU: нет данных"
        let stateText: String
        if primaryIsBuiltin && mode != .off {
            stateText = "primary встроенный, не нужен"
        } else if window != nil {
            stateText = "работает"
        } else if mode == .auto && autoPaused {
            stateText = "пауза (высокая нагрузка)"
        } else {
            stateText = "выключен"
        }
        statusLine?.title = "\(stateText) · \(gpuText)"

        let symbol: String
        if window != nil { symbol = "circle.fill" }
        else if mode == .auto && autoPaused { symbol = "pause.circle.fill" }
        else { symbol = "circle" }
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "keepwarm")
            button.toolTip = "keepwarm: \(stateText)"
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
