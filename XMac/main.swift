import Cocoa
import WebKit

private let homeURL = URL(string: "https://x.com")!
private let safariUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15"

// Domains that must stay inside the app even when "open external links in
// browser" is enabled, because they are part of the sign-in flow.
private let authHosts: Set<String> = [
    "accounts.google.com", "accounts.youtube.com", "google.com",
    "appleid.apple.com", "idmsa.apple.com", "apple.com",
    "facebook.com", "login.microsoftonline.com", "github.com",
]

// X's timeline lays out tall media with an inline `aspect-ratio` on a stretched
// flex item. WebKit here computes the item's height as "used but not definite",
// so the width collapses to ~1px (the media becomes a thin vertical sliver).
//
// This only inspects elements that X newly inserts, batches all layout reads and
// writes into a single animation frame (read-all then write-all) to avoid layout
// thrashing, and marks fixed nodes so they are never measured twice. It does not
// override any globals, poll, or observe attribute changes.
private let fixupJS = """
    (function () {
        if (window.__xmacFixup) { return; }
        window.__xmacFixup = true;

        function ratioOf(el) {
            var s = el.style && el.style.aspectRatio;
            if (!s) { return 0; }
            var p = s.split('/');
            var w = parseFloat(p[0]);
            var h = p[1] ? parseFloat(p[1]) : 1;
            return (w && h) ? w / h : 0;
        }

        var pending = new Set();
        var scheduled = false;

        function flush() {
            scheduled = false;
            if (pending.size === 0) { return; }
            var items = Array.from(pending);
            pending.clear();

            // Phase 1: read layout for everything at once.
            var work = [];
            for (var i = 0; i < items.length; i++) {
                var el = items[i];
                if (el.__xmacFixed || !el.style || !el.style.aspectRatio) { continue; }
                var r = el.getBoundingClientRect();
                if (r.width < 8 && r.height >= 40) { work.push([el, r.height]); }
            }
            // Phase 2: apply all writes.
            for (var k = 0; k < work.length; k++) {
                var node = work[k][0];
                var ratio = ratioOf(node);
                if (ratio <= 0) { continue; }
                var target = Math.round(work[k][1] * ratio);
                if (target > 8) {
                    node.style.minWidth = target + 'px';
                    node.__xmacFixed = true;
                }
            }
        }

        function schedule() {
            if (scheduled) { return; }
            scheduled = true;
            requestAnimationFrame(flush);
        }

        function scan(root) {
            if (!root) { return; }
            if (root.nodeType === 1) {
                if (root.matches && root.matches('[style*="aspect-ratio"]')) { pending.add(root); }
                if (root.querySelectorAll) {
                    var els = root.querySelectorAll('[style*="aspect-ratio"]');
                    for (var i = 0; i < els.length; i++) { pending.add(els[i]); }
                }
            } else if (root.nodeType === 11) {
                var nodes = root.childNodes;
                for (var j = 0; j < nodes.length; j++) { scan(nodes[j]); }
            }
            schedule();
        }

        function start() {
            scan(document.body);
            try {
                new MutationObserver(function (mutations) {
                    for (var i = 0; i < mutations.length; i++) {
                        var added = mutations[i].addedNodes;
                        for (var j = 0; j < added.length; j++) { scan(added[j]); }
                    }
                }).observe(document.body, { childList: true, subtree: true });
            } catch (_) {}
        }

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', start);
        } else {
            start();
        }
    })();
    """

// Only injected when XMAC_DEBUG is set; records JS errors and network activity.
private let debugJS = """
    window.__xmacErrors = window.__xmacErrors || [];
    window.addEventListener('error', function (e) {
        try { window.__xmacErrors.push('error: ' + (e.message || e.type)); } catch (_) {}
    }, true);
    window.addEventListener('unhandledrejection', function (e) {
        try { window.__xmacErrors.push('rejection: ' + String(e.reason)); } catch (_) {}
    });
    (function () {
        var o = console.error;
        console.error = function () {
            try { window.__xmacErrors.push('console.error: ' + Array.prototype.join.call(arguments, ' ')); } catch (_) {}
            return o.apply(console, arguments);
        };
    })();
    window.__xmacNet = [];
    try {
        var _fetch = window.fetch;
        window.fetch = function () {
            var a = arguments[0];
            var u = (a && a.url) ? a.url : String(a);
            var p = _fetch.apply(this, arguments);
            p.then(function (r) { window.__xmacNet.push('fetch ' + r.status + ' ' + u); },
                   function (e) { window.__xmacNet.push('fetch-ERR ' + e + ' ' + u); });
            return p;
        };
        var _open = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function (m, u) { this.__u = u; return _open.apply(this, arguments); };
        var _send = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.send = function () {
            var x = this;
            x.addEventListener('loadend', function () { window.__xmacNet.push('xhr ' + x.status + ' ' + x.__u); });
            return _send.apply(this, arguments);
        };
    } catch (_) {}
    """

// MARK: - Safari cookie import
//
// Login happens in the real browser (embedded webviews are blocked by Google
// and X's new onboarding flow hangs in WKWebView). Afterwards we read the
// session cookies straight out of Safari's cookie store and inject them.

struct BrowserCookie {
    let domain: String
    let name: String
    let value: String
    let path: String
    let secure: Bool
}

private func parseBinaryCookies(_ path: String) -> [BrowserCookie] {
    guard let data = FileManager.default.contents(atPath: path) else { return [] }
    let b = [UInt8](data)
    func u32be(_ o: Int) -> Int {
        guard o >= 0, o + 3 < b.count else { return 0 }
        return Int(UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3]))
    }
    func u32le(_ o: Int) -> Int {
        guard o >= 0, o + 3 < b.count else { return 0 }
        return Int(UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24)
    }
    func cstr(_ o: Int) -> String {
        guard o >= 0, o < b.count else { return "" }
        var bytes: [UInt8] = []
        var i = o
        while i < b.count && b[i] != 0 { bytes.append(b[i]); i += 1 }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
    guard b.count >= 8, b[0] == 0x63, b[1] == 0x6f, b[2] == 0x6f, b[3] == 0x6b else { return [] }
    let pages = u32be(4)
    var pageSizes: [Int] = []
    for i in 0..<pages { pageSizes.append(u32be(8 + i * 4)) }
    var pageStart = 8 + pages * 4
    var result: [BrowserCookie] = []
    for size in pageSizes {
        let page = pageStart
        let numCookies = u32le(page + 4)
        var offsets: [Int] = []
        for i in 0..<numCookies { offsets.append(u32le(page + 8 + i * 4)) }
        for off in offsets {
            let cs = page + off
            let flags = u32le(cs + 8)
            let domain = cstr(cs + u32le(cs + 16))
            let name = cstr(cs + u32le(cs + 20))
            let cookiePath = cstr(cs + u32le(cs + 24))
            let value = cstr(cs + u32le(cs + 28))
            if !name.isEmpty && !domain.isEmpty {
                result.append(
                    BrowserCookie(
                        domain: domain, name: name, value: value,
                        path: cookiePath.isEmpty ? "/" : cookiePath, secure: (flags & 1) != 0))
            }
        }
        pageStart += size
    }
    return result
}

private func readSafariCookies() -> [BrowserCookie] {
    let home = NSHomeDirectory()
    let candidates = [
        "\(home)/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies",
        "\(home)/Library/Cookies/Cookies.binarycookies",
    ]
    for path in candidates where FileManager.default.fileExists(atPath: path) {
        let cookies = parseBinaryCookies(path)
        if !cookies.isEmpty { return cookies }
    }
    return []
}


private func isInternalHost(_ host: String?) -> Bool {
    guard let host = host?.lowercased() else { return false }
    return host == "x.com" || host.hasSuffix(".x.com")
        || host == "twitter.com" || host.hasSuffix(".twitter.com")
}

final class FindSearchField: NSSearchField {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

final class PopupWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    convenience init(webView: WKWebView) {
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 720)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "X"

        // WKWebView must live inside a container view, not be used directly as
        // the window's contentView, otherwise it can render as a black frame.
        let container = NSView(frame: frame)
        container.autoresizingMask = [.width, .height]
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        window.contentView = container

        window.minSize = NSSize(width: 420, height: 420)
        window.center()
        self.init(window: window)
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate,
    WKDownloadDelegate, NSToolbarDelegate, NSSearchFieldDelegate
{
    private let defaults = UserDefaults.standard
    private let debugEnabled = ProcessInfo.processInfo.environment["XMAC_DEBUG"] != nil

    private var window: NSWindow!
    private var webView: WKWebView!
    private var container: NSView!
    private var findBar: NSVisualEffectView!
    private var findField: FindSearchField!
    private var findBarHeight: NSLayoutConstraint!
    private var findResultLabel: NSTextField!
    private var statusItem: NSStatusItem!
    private var externalToggleItem: NSMenuItem!

    private var popups: [ObjectIdentifier: PopupWindowController] = [:]
    private var observations: [NSKeyValueObservation] = []
    private var lastFindQuery = ""
    private var lastBadgeCount = 0
    private var pendingURL: URL?

    private func dbg(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        let line = "[\(Date())] \(message())\n"
        let url = URL(fileURLWithPath: "/tmp/xmac_debug.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.data(using: .utf8)!.write(to: url)
        }
    }

    private var openExternalInBrowser: Bool {
        get {
            if defaults.object(forKey: "openExternalInBrowser") == nil { return true }
            return defaults.bool(forKey: "openExternalInBrowser")
        }
        set { defaults.set(newValue, forKey: "openExternalInBrowser") }
    }

    private var savedZoom: Double {
        get {
            let value = defaults.double(forKey: "pageZoom")
            return value == 0 ? 1.0 : value
        }
        set { defaults.set(newValue, forKey: "pageZoom") }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildStatusItem()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = "Version/16.0 Safari/605.1.15"
        configuration.mediaTypesRequiringUserActionForPlayback = []
        if #available(macOS 12.3, *) {
            configuration.preferences.isElementFullscreenEnabled = true
        }
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.addUserScript(
            WKUserScript(source: fixupJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        if debugEnabled {
            configuration.userContentController.addUserScript(
                WKUserScript(source: debugJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        let uaOverride = ProcessInfo.processInfo.environment["XMAC_UA"] ?? defaults.string(forKey: "uaOverride")
        if let override = uaOverride {
            if override != "default" && !override.isEmpty {
                webView.customUserAgent = override
            }
        } else {
            webView.customUserAgent = safariUserAgent
        }
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        self.webView = webView

        container = NSView()
        container.addSubview(webView)

        let findBar = NSVisualEffectView()
        findBar.material = .headerView
        findBar.blendingMode = .withinWindow
        findBar.state = .active
        findBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(findBar)
        self.findBar = findBar
        buildFindBar()

        NSLayoutConstraint.activate([
            findBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            findBar.topAnchor.constraint(equalTo: container.topAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        findBarHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
        findBarHeight.isActive = true
        findBar.isHidden = true

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "X"
        window.contentView = container
        window.minSize = NSSize(width: 560, height: 560)
        window.center()
        window.setFrameAutosaveName("XMacMainWindow")
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        observations.append(
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                guard let self = self else { return }
                if self.window.title != "X" { self.window.title = "X" }
                self.updateDockBadge(from: webView.title)
            })
        observations.append(
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                self?.window.representedURL = self?.webView.url
            })

        window.toolbar = makeToolbar()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        webView.load(URLRequest(url: pendingURL ?? homeURL))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        dbg("application(open:) urls=\(urls.map { $0.absoluteString })")
        guard let url = urls.first else { return }
        // macOS may deliver this before applicationDidFinishLaunching (e.g. when
        // the app is opened with a URL), at which point the UI is not built yet.
        guard window != nil, webView != nil, let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            pendingURL = url
            return
        }
        window.makeKeyAndOrderFront(nil)
        webView.load(URLRequest(url: url))
    }

    func windowWillClose(_ notification: Notification) {
        if findBarHeight.constant > 0 { setFindBarVisible(false) }
    }

    // MARK: - Dock badge

    private func updateDockBadge(from title: String?) {
        var count = 0
        if let title = title,
            let range = title.range(of: #"^\((\d+)\)"#, options: .regularExpression)
        {
            count = Int(title[range].filter { $0.isNumber }) ?? 0
        }
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
        if count > lastBadgeCount && lastBadgeCount >= 0 && window != nil && !window.isKeyWindow {
            NSApp.requestUserAttention(.informationalRequest)
        }
        lastBadgeCount = count
    }

    // MARK: - Status bar item

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if #available(macOS 11.0, *),
            let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "X")
        {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "X"
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "显示 / 隐藏 X", action: #selector(toggleWindow(_:)), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "刷新", action: #selector(reload(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "主页", action: #selector(goHome(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 X", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            .target = NSApp
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleWindow(_ sender: Any?) {
        if window.isVisible && window.isKeyWindow {
            window.orderOut(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Toolbar

    private func toolbarIdentifier(_ name: String) -> NSToolbarItem.Identifier {
        return NSToolbarItem.Identifier("xmac." + name)
    }

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "XMacToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [
            toolbarIdentifier("back"),
            toolbarIdentifier("forward"),
            toolbarIdentifier("reload"),
            toolbarIdentifier("find"),
            .flexibleSpace,
            toolbarIdentifier("home"),
            toolbarIdentifier("login"),
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier.rawValue {
        case "xmac.back":
            configure(item, symbol: "chevron.backward", label: "后退", action: #selector(goBack(_:)))
        case "xmac.forward":
            configure(item, symbol: "chevron.forward", label: "前进", action: #selector(goForward(_:)))
        case "xmac.reload":
            configure(item, symbol: "arrow.clockwise", label: "刷新", action: #selector(reload(_:)))
        case "xmac.find":
            configure(item, symbol: "magnifyingglass", label: "查找", action: #selector(showFindBar(_:)))
        case "xmac.home":
            configure(item, symbol: "house", label: "主页", action: #selector(goHome(_:)))
        case "xmac.login":
            configure(item, symbol: "person.crop.circle", label: "登录", action: #selector(loginInBrowser(_:)))
        default:
            return nil
        }
        return item
    }

    private func configure(_ item: NSToolbarItem, symbol: String, label: String, action: Selector) {
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.target = self
        item.action = action
        if #available(macOS 11.0, *) {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        }
    }

    // MARK: - Find bar

    private func buildFindBar() {
        let field = FindSearchField()
        field.placeholderString = "在页面中查找"
        field.delegate = self
        field.target = self
        field.action = #selector(findFieldChanged(_:))
        field.onCancel = { [weak self] in self?.setFindBarVisible(false) }
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        findField = field

        let previous = toolbarButton(symbol: "chevron.up", label: "上一个", action: #selector(findPrevious(_:)))
        let next = toolbarButton(symbol: "chevron.down", label: "下一个", action: #selector(findNext(_:)))

        let result = NSTextField(labelWithString: "")
        result.textColor = .secondaryLabelColor
        result.font = .systemFont(ofSize: 12)
        result.translatesAutoresizingMaskIntoConstraints = false
        findResultLabel = result

        let done = NSButton(title: "完成", target: self, action: #selector(hideFindBar(_:)))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\u{1b}"

        let stack = NSStackView(views: [field, previous, next, result, done])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        findBar.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: findBar.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: findBar.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),
        ])
    }

    private func toolbarButton(symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.toolTip = label
        if #available(macOS 11.0, *) {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        }
        return button
    }

    @objc private func showFindBar(_ sender: Any?) {
        setFindBarVisible(true)
    }

    @objc private func hideFindBar(_ sender: Any?) {
        setFindBarVisible(false)
    }

    private func setFindBarVisible(_ visible: Bool) {
        findBar.isHidden = !visible
        findBarHeight.constant = visible ? 38 : 0
        if visible {
            window.makeFirstResponder(findField)
        } else {
            lastFindQuery = ""
            findResultLabel.stringValue = ""
        }
    }

    @objc private func findFieldChanged(_ sender: NSSearchField) {
        lastFindQuery = sender.stringValue
        runFind(backwards: false)
    }

    @objc private func findNext(_ sender: Any?) {
        runFind(backwards: false)
    }

    @objc private func findPrevious(_ sender: Any?) {
        runFind(backwards: true)
    }

    private func runFind(backwards: Bool) {
        guard !lastFindQuery.isEmpty else {
            findResultLabel.stringValue = ""
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        configuration.caseSensitive = false
        webView.find(lastFindQuery, configuration: configuration) { [weak self] result in
            self?.findResultLabel.stringValue = result.matchFound ? "" : "无结果"
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField, field === findField else { return }
        findFieldChanged(field)
    }

    // MARK: - Menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "关于 X", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "在浏览器中登录…", action: #selector(loginInBrowser(_:)), keyEquivalent: ""
        ).target = self
        appMenu.addItem(
            withTitle: "从浏览器导入登录会话", action: #selector(importBrowserSession(_:)), keyEquivalent: ""
        ).target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 X", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 X", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "查找…", action: #selector(showFindBar(_:)), keyEquivalent: "f").target = self
        let findNextItem = editMenu.addItem(
            withTitle: "查找下一个", action: #selector(findNext(_:)), keyEquivalent: "g")
        findNextItem.target = self
        let findPrevItem = editMenu.addItem(
            withTitle: "查找上一个", action: #selector(findPrevious(_:)), keyEquivalent: "g")
        findPrevItem.target = self
        findPrevItem.keyEquivalentModifierMask = [.command, .shift]

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "显示")
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "刷新", action: #selector(reload(_:)), keyEquivalent: "r").target = self
        let hardReload = viewMenu.addItem(
            withTitle: "强制刷新（忽略缓存）", action: #selector(hardReload(_:)), keyEquivalent: "r")
        hardReload.target = self
        hardReload.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(withTitle: "打开位置…", action: #selector(openLocation(_:)), keyEquivalent: "l").target =
            self
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "放大", action: #selector(zoomIn(_:)), keyEquivalent: "+").target = self
        viewMenu.addItem(withTitle: "缩小", action: #selector(zoomOut(_:)), keyEquivalent: "-").target = self
        viewMenu.addItem(withTitle: "实际大小", action: #selector(zoomReset(_:)), keyEquivalent: "0").target = self
        viewMenu.addItem(.separator())
        let external = viewMenu.addItem(
            withTitle: "站外链接用默认浏览器打开", action: #selector(toggleExternal(_:)), keyEquivalent: "")
        external.target = self
        external.state = openExternalInBrowser ? .on : .off
        externalToggleItem = external
        viewMenu.addItem(.separator())
        viewMenu.addItem(
            withTitle: "进入全屏幕", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f"
        ).keyEquivalentModifierMask = [.command, .control]

        let historyMenuItem = NSMenuItem()
        mainMenu.addItem(historyMenuItem)
        let historyMenu = NSMenu(title: "历史记录")
        historyMenuItem.submenu = historyMenu
        historyMenu.addItem(withTitle: "后退", action: #selector(goBack(_:)), keyEquivalent: "[").target = self
        historyMenu.addItem(withTitle: "前进", action: #selector(goForward(_:)), keyEquivalent: "]").target = self
        historyMenu.addItem(withTitle: "主页", action: #selector(goHome(_:)), keyEquivalent: "H").target = self

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(
            withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Actions

    @objc private func reload(_ sender: Any?) {
        if webView.url == nil {
            webView.load(URLRequest(url: homeURL))
        } else {
            webView.reload()
        }
    }

    @objc private func hardReload(_ sender: Any?) {
        if webView.url == nil {
            webView.load(URLRequest(url: homeURL))
        } else {
            webView.reloadFromOrigin()
        }
    }

    @objc private func goBack(_ sender: Any?) {
        if webView.canGoBack { webView.goBack() }
    }

    @objc private func goForward(_ sender: Any?) {
        if webView.canGoForward { webView.goForward() }
    }

    @objc private func goHome(_ sender: Any?) {
        webView.load(URLRequest(url: homeURL))
    }

    @objc private func zoomIn(_ sender: Any?) {
        applyZoom(webView.pageZoom + 0.1)
    }

    @objc private func zoomOut(_ sender: Any?) {
        applyZoom(webView.pageZoom - 0.1)
    }

    @objc private func zoomReset(_ sender: Any?) {
        applyZoom(1.0)
    }

    private func applyZoom(_ value: Double) {
        let clamped = min(3.0, max(0.5, value))
        webView.pageZoom = clamped
        savedZoom = clamped
    }

    @objc private func toggleExternal(_ sender: NSMenuItem) {
        openExternalInBrowser.toggle()
        sender.state = openExternalInBrowser ? .on : .off
    }

    @objc private func openLocation(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "打开位置"
        alert.informativeText = "输入要打开的网址："
        alert.addButton(withTitle: "打开")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://x.com"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            var text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if !text.contains("://") { text = "https://" + text }
            if let url = URL(string: text) { webView.load(URLRequest(url: url)) }
        }
    }

    // MARK: - Browser login

    @objc private func loginInBrowser(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://x.com/login")!)
        let alert = NSAlert()
        alert.messageText = "在浏览器中登录 X"
        alert.informativeText =
            "已用默认浏览器打开 X 登录页。\n\n"
            + "请先完成登录（Google / Apple / 手机号 / 密码均可），"
            + "然后回到本应用点击「导入会话」。"
        alert.addButton(withTitle: "导入会话")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            importBrowserSession(nil)
        }
    }

    @objc private func importBrowserSession(_ sender: Any?) {
        let cookies = readSafariCookies()
        let needed = cookies.filter { ["auth_token", "ct0", "twid", "kdt"].contains($0.name) }
        guard needed.contains(where: { $0.name == "auth_token" }) else {
            promptManualImport()
            return
        }
        apply(cookies: needed) { [weak self] in
            guard let self = self else { return }
            self.webView.load(URLRequest(url: homeURL))
        }
    }

    private func apply(cookies: [BrowserCookie], completion: @escaping () -> Void) {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let group = DispatchGroup()
        let expires = Date().addingTimeInterval(60 * 60 * 24 * 365)
        for cookie in cookies {
            group.enter()
            var properties: [HTTPCookiePropertyKey: Any] = [
                .domain: cookie.domain,
                .path: cookie.path,
                .name: cookie.name,
                .value: cookie.value,
                .secure: "TRUE",
                .expires: expires,
            ]
            if cookie.name == "auth_token" || cookie.name == "ct0" {
                properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
            }
            if let httpCookie = HTTPCookie(properties: properties) {
                store.setCookie(httpCookie) { group.leave() }
            } else {
                group.leave()
            }
        }
        group.notify(queue: .main) { completion() }
    }

    private func promptManualImport() {
        let alert = NSAlert()
        alert.messageText = "未能自动读取登录会话"
        alert.informativeText =
            "请先在默认浏览器中登录 x.com，然后重新点击「导入会话」。\n\n"
            + "如果你使用的是 Safari 以外的浏览器，可以在下方手动粘贴 Cookie（可选）。"
        alert.addButton(withTitle: "导入")
        alert.addButton(withTitle: "取消")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 60))
        let tokenField = NSTextField(frame: NSRect(x: 0, y: 32, width: 420, height: 24))
        tokenField.placeholderString = "auth_token"
        let ct0Field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        ct0Field.placeholderString = "ct0"
        container.addSubview(tokenField)
        container.addSubview(ct0Field)
        alert.accessoryView = container
        alert.window.initialFirstResponder = tokenField
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let token = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let ct0 = ct0Field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        var cookies = [
            BrowserCookie(domain: ".x.com", name: "auth_token", value: token, path: "/", secure: true)
        ]
        if !ct0.isEmpty {
            cookies.append(BrowserCookie(domain: ".x.com", name: "ct0", value: ct0, path: "/", secure: true))
        }
        apply(cookies: cookies) { [weak self] in
            self?.webView.load(URLRequest(url: homeURL))
        }
    }

    // MARK: - WKUIDelegate

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }

        let url = navigationAction.request.url
        let host = url?.host?.lowercased()
        dbg("createWebViewWith url=\(url?.absoluteString ?? "nil") host=\(host ?? "nil")")
        if openExternalInBrowser, let url = url, let host = host,
            !isInternalHost(host), !authHosts.contains(host)
        {
            NSWorkspace.shared.open(url)
            return nil
        }

        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.customUserAgent = safariUserAgent
        popup.allowsBackForwardNavigationGestures = true
        popup.navigationDelegate = self
        popup.uiDelegate = self

        let controller = PopupWindowController(webView: popup)
        controller.onClose = { [weak self] in
            self?.popups.removeValue(forKey: ObjectIdentifier(popup))
        }
        popups[ObjectIdentifier(popup)] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        popups.removeValue(forKey: ObjectIdentifier(webView))?.close()
    }

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = webView.url?.host ?? "X"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
        completionHandler()
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = webView.url?.host ?? "X"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(
        _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.begin { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        dbg("didFinish url=\(webView.url?.absoluteString ?? "nil")")
        if abs(webView.pageZoom - savedZoom) > 0.001 {
            webView.pageZoom = savedZoom
        }
        scheduleDebugProbe(webView)
    }

    private func scheduleDebugProbe(_ webView: WKWebView) {
        guard debugEnabled else { return }
        let body = """
            (function(){
              var c = document.createElement('div');
              c.style.cssText = 'display:flex;';
              var item = document.createElement('div');
              item.style.cssText = 'flex:0 0 auto;aspect-ratio:0.6357406431207169 / 1;height:400px;';
              c.appendChild(item);
              document.body.appendChild(c);
              var flexItemWidth = Math.round(item.getBoundingClientRect().width);
              c.remove();

              var c2 = document.createElement('div');
              c2.style.cssText = 'display:flex;';
              var item2 = document.createElement('div');
              item2.style.cssText = 'flex:0 0 auto;aspect-ratio:0.6357406431207169 / 1;height:100%;max-height:400px;';
              c2.style.height = '400px';
              c2.appendChild(item2);
              document.body.appendChild(c2);
              var flexItem2Width = Math.round(item2.getBoundingClientRect().width);
              c2.remove();

              return JSON.stringify({innerWidth:window.innerWidth, ua:navigator.userAgent.slice(0,60),
                aspectSupported:CSS.supports('aspect-ratio','1'),
                flexItemWidth:flexItemWidth, flexItem2Width:flexItem2Width});
            })()
            """
        for delay in [6.0, 14.0, 22.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                webView?.evaluateJavaScript(body) { result, error in
                    self?.dbg("DOM \(String(describing: result)) err=\(String(describing: error))")
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        dbg("didStartProvisional url=\(webView.url?.absoluteString ?? "nil")")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        dbg("didCommit url=\(webView.url?.absoluteString ?? "nil")")
        scheduleDebugProbe(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        dbg("didFail url=\(webView.url?.absoluteString ?? "nil") error=\(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) {
        dbg("didFailProvisional url=\(webView.url?.absoluteString ?? "nil") error=\(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        dbg("webContentProcessDidTerminate url=\(webView.url?.absoluteString ?? "nil")")
        // WebKit renders a black frame when its content process dies; recover.
        webView.reload()
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        dbg(
            "navigationAction url=\(url.absoluteString) targetFrameNil=\(navigationAction.targetFrame == nil) "
                + "type=\(navigationAction.navigationType.rawValue)")
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme != "http" && scheme != "https" && scheme != "about" && scheme != "blob"
            && scheme != "data" && scheme != "javascript"
        {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        let response = navigationResponse.response
        dbg(
            "navigationResponse url=\(response.url?.absoluteString ?? "nil") "
                + "status=\((response as? HTTPURLResponse)?.statusCode ?? -1) "
                + "mime=\(response.mimeType ?? "nil") canShow=\(navigationResponse.canShowMIMEType)")
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload
    ) {
        download.delegate = self
    }

    func webView(
        _ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload
    ) {
        download.delegate = self
    }

    // MARK: - WKDownloadDelegate

    func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse,
        suggestedFilename: String, completionHandler: @escaping (URL?) -> Void
    ) {
        let directory =
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        var destination = directory.appendingPathComponent(suggestedFilename)
        if FileManager.default.fileExists(atPath: destination.path) {
            let base = destination.deletingPathExtension().lastPathComponent
            let ext = destination.pathExtension
            destination = directory.appendingPathComponent(
                "\(base)-\(Int(Date().timeIntervalSince1970)).\(ext)")
        }
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let url = download.progress.fileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let alert = NSAlert()
        alert.messageText = "下载失败"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
