import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct AccessibilityNodeSnapshot: Codable, Equatable, Sendable {
    var path: String
    var role: String?
    var title: String?
    var value: String?
    var frame: CGRect?
    var children: [AccessibilityNodeSnapshot] = []
}

final class NeoYAccessibilityController: NeoYAccessibilityService, @unchecked Sendable {
    static let shared = NeoYAccessibilityController()

    private let cacheLock = NSLock()
    private var elementsByPath: [String: AXUIElement] = [:]
    private var lastSnapshot: AccessibilityNodeSnapshot?

    func inspect(maxDepth: Int = 8, maxNodes: Int = 400) async throws -> String {
        guard AXIsProcessTrusted() else {
            return Self.json([
                "trusted": false,
                "roots": [],
                "error": "NeoY needs macOS Accessibility permission for semantic UI inspection/actions",
            ])
        }
        let gate = AccessibilityCompletionGate()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let result = inspectSynchronously(maxDepth: maxDepth, maxNodes: maxNodes)
                if gate.claim() { continuation.resume(returning: result) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
                if gate.claim() {
                    continuation.resume(returning: Self.json([
                        "trusted": true,
                        "roots": [],
                        "error": "Accessibility inspection timed out after 1 second",
                    ]))
                }
            }
        }
    }

    private func inspectSynchronously(maxDepth: Int, maxNodes: Int) -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return Self.json(["trusted": true, "roots": [], "error": "No frontmost macOS application is available"])
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        cacheLock.lock()
        elementsByPath.removeAll()
        cacheLock.unlock()
        let result = visit(root, path: "0", depth: max(0, maxDepth), remaining: max(1, maxNodes))
        let snapshot = AccessibilityNodeSnapshot(path: "", role: "application", title: app.localizedName, children: result.nodes)
        cacheLock.lock()
        lastSnapshot = snapshot
        cacheLock.unlock()
        return Self.json([
            "trusted": true,
            "application": app.localizedName ?? "",
            "pid": Int(app.processIdentifier),
            "roots": snapshot.children,
        ])
    }

    func resolve(_ target: DemoTarget) throws -> (frame: CGRect, element: AXUIElement?) {
        if let rect = target.rect { return (rect, nil) }
        cacheLock.lock()
        let snapshot = lastSnapshot
        let cachedElements = elementsByPath
        cacheLock.unlock()
        if let path = target.path, let element = cachedElements[path] {
            guard let frame = frame(for: element) else { throw DemoRecorderError.message("Accessibility element has no usable frame") }
            return (frame, element)
        }
        guard let snapshot else { throw DemoRecorderError.message("Run accessibility.inspect before resolving a labeled element") }
        let flattened = flatten(snapshot.children)
        let matches = flattened.filter { node in
            let roleMatches = target.role == nil || node.role?.caseInsensitiveCompare(target.role!) == .orderedSame
            let labelMatches = target.label.map { label in
                [node.title, node.value].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(label) }
            } ?? true
            return roleMatches && labelMatches && node.frame != nil
        }
        guard let node = matches.first, let frame = node.frame, let element = cachedElements[node.path] else {
            throw DemoRecorderError.message("No accessibility element matched the requested target")
        }
        return (frame, element)
    }

    func click(_ target: DemoTarget) async throws -> String {
        let resolved = try resolve(target)
        if let element = resolved.element, canPerformPress(element) {
            let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
            guard error == .success else { throw accessibilityError(error) }
        } else {
            let point = CGPoint(x: resolved.frame.midX, y: resolved.frame.midY)
            postMouseEvent(.leftMouseDown, at: point)
            postMouseEvent(.leftMouseUp, at: point)
        }
        return Self.json(["action": "click", "frame": resolved.frame])
    }

    func type(_ text: String, target: DemoTarget?) async throws -> String {
        if let target {
            let resolved = try resolve(target)
            if let element = resolved.element {
                _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
        }
        text.forEach { character in
            if character == "\n" {
                postKeyEvent(36, flags: [])
            } else {
                postUnicode(character)
            }
        }
        return Self.json(["action": "type", "characters": text.count])
    }

    func setValue(_ value: String, target: DemoTarget) async throws -> String {
        let resolved = try resolve(target)
        guard let element = resolved.element else {
            throw DemoRecorderError.message("set_value requires a resolvable accessibility element")
        }
        let error = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        guard error == .success else { throw accessibilityError(error) }
        return Self.json(["action": "set_value", "frame": resolved.frame])
    }

    func key(_ name: String, at target: DemoTarget?) async throws -> String {
        let normalized = name.lowercased()
        var flags: CGEventFlags = []
        var keyName = normalized
        if normalized.hasPrefix("cmd+") {
            flags = [.maskCommand]
            keyName = String(normalized.dropFirst(4))
        } else if normalized.hasPrefix("option+") {
            flags = [.maskAlternate]
            keyName = String(normalized.dropFirst(7))
        }
        let keyCode = Self.keyCodes[keyName] ?? { UInt16(0) }()
        guard Self.keyCodes[keyName] != nil else {
            throw DemoRecorderError.message("Unsupported key '\(name)'")
        }
        if let target {
            let frame = try resolve(target).frame
            postMouseEvent(.mouseMoved, at: CGPoint(x: frame.midX, y: frame.midY))
        }
        postKeyEvent(keyCode, flags: flags)
        return Self.json(["action": "key", "key": name])
    }

    func scroll(_ target: DemoTarget, deltaX: Double, deltaY: Double) async throws -> String {
        let frame = try resolve(target).frame
        let point = CGPoint(x: frame.midX, y: frame.midY)
        postMouseEvent(.scrollWheel, at: point)
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: Int32(deltaY), wheel2: Int32(deltaX), wheel3: 0)
        event?.post(tap: .cghidEventTap)
        return Self.json(["action": "scroll", "frame": frame])
    }

    func drag(from: DemoTarget, to: DemoTarget) async throws -> String {
        let start = try resolve(from).frame
        let end = try resolve(to).frame
        let startPoint = CGPoint(x: start.midX, y: start.midY)
        let endPoint = CGPoint(x: end.midX, y: end.midY)
        postMouseEvent(.leftMouseDown, at: startPoint)
        for step in 1...10 {
            let fraction = Double(step) / 10
            let point = CGPoint(
                x: startPoint.x + (endPoint.x - startPoint.x) * fraction,
                y: startPoint.y + (endPoint.y - startPoint.y) * fraction
            )
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        postMouseEvent(.leftMouseUp, at: endPoint)
        return Self.json(["action": "drag", "from": start, "to": end])
    }

    private func visit(_ element: AXUIElement, path: String, depth: Int, remaining: Int) -> (nodes: [AccessibilityNodeSnapshot], consumed: Int) {
        guard depth >= 0, remaining > 0 else { return ([], remaining) }
        cacheLock.lock()
        elementsByPath[path] = element
        cacheLock.unlock()
        let role = Self.string(element, kAXRoleAttribute)
        let title = Self.string(element, kAXTitleAttribute)
        let value = Self.string(element, kAXValueAttribute)
        let frame = frame(for: element)
        let node = AccessibilityNodeSnapshot(path: path, role: role, title: title, value: value, frame: frame)
        var children: [AccessibilityNodeSnapshot] = []
        var left = remaining - 1
        if let childElements = Self.array(element, kAXChildrenAttribute) {
            for (index, child) in childElements.enumerated() where left > 0 {
                let result = visit(child, path: "\(path).\(index)", depth: depth - 1, remaining: left)
                children.append(contentsOf: result.nodes)
                left = result.consumed
            }
        }
        return ([AccessibilityNodeSnapshot(path: path, role: role, title: title, value: value, frame: frame, children: children)], left)
    }

    private func flatten(_ nodes: [AccessibilityNodeSnapshot]) -> [AccessibilityNodeSnapshot] {
        nodes.flatMap { [$0] + flatten($0.children) }
    }

    private func frame(for element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let positionValue = position, let sizeValue = size,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        var cgSize = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &cgSize)
        return CGRect(origin: point, size: cgSize)
    }

    private func requestTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func canPerformPress(_ element: AXUIElement) -> Bool {
        var actions: CFArray?
        guard AXUIElementCopyActionNames(element, &actions) == .success, let actions else { return false }
        return (actions as? [String])?.contains(kAXPressAction) ?? false
    }

    private func postMouseEvent(_ type: CGEventType, at point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func postKeyEvent(_ keyCode: UInt16, flags: CGEventFlags) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }

    private func postUnicode(_ character: Character) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        let characters = Array(String(character).utf16)
        characters.withUnsafeBufferPointer { buffer in
            if let baseAddress = buffer.baseAddress {
                down?.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: baseAddress)
                up?.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: baseAddress)
            }
        }
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func accessibilityError(_ code: AXError) -> Error {
        DemoRecorderError.message("Accessibility action failed with AXError \(code.rawValue)")
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        return value as? String
    }

    private static func array(_ element: AXUIElement, _ name: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let array = value as? [AXUIElement] else { return nil }
        return array
    }

    private static let keyCodes: [String: UInt16] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126, "a": 0, "c": 8, "v": 9, "x": 7,
    ]

    static func json(_ value: [String: Any]) -> String {
        let normalized = value.mapValues(jsonSafe)
        guard let data = try? JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func jsonSafe(_ value: Any) -> Any {
        if let rect = value as? CGRect {
            return ["x": rect.origin.x, "y": rect.origin.y, "width": rect.size.width, "height": rect.size.height]
        }
        if let snapshots = value as? [AccessibilityNodeSnapshot],
           let data = try? JSONEncoder().encode(snapshots),
           let object = try? JSONSerialization.jsonObject(with: data) {
            return object
        }
        if let dict = value as? [String: Any] { return dict.mapValues(jsonSafe) }
        if let array = value as? [Any] { return array.map(jsonSafe) }
        if value is String || value is NSNumber || value is NSNull { return value }
        return String(describing: value)
    }
}

enum AccessibilityTools {
    static func tools() -> [ToolDefinition] {
        [
            ToolDefinition(name: "accessibility.inspect", description: "Inspect the focused macOS accessibility tree and cache resolvable element paths.", parameters: schema([
                "max_depth": integer("Maximum traversal depth", default: 8),
                "max_nodes": integer("Maximum returned nodes", default: 400),
            ])) { args in
                let maxDepth = int(args, "max_depth", 8)
                let maxNodes = int(args, "max_nodes", 400)
                return try await NeoYAccessibilityController.shared.inspect(maxDepth: maxDepth, maxNodes: maxNodes)
            },
            ToolDefinition(name: "accessibility.resolve", description: "Resolve an explicit rectangle or cached accessibility element to a screen frame.", parameters: targetSchema()) { args in
                let target = try target(from: args)
                let resolved = try NeoYAccessibilityController.shared.resolve(target)
                return NeoYAccessibilityController.json(["frame": resolved.frame])
            },
            ToolDefinition(name: "computer.click", description: "Press or click a resolved macOS UI target.", parameters: targetSchema()) { args in
                try await NeoYAccessibilityController.shared.click(try target(from: args))
            },
            ToolDefinition(name: "computer.type", description: "Type text into the focused or specified element.", parameters: schema([
                "text": string("Text to type"),
                "target": .object(["type": .string("object")]),
            ], required: ["text"])) { args in
                let text = try requiredString(args, "text")
                let parsedTarget = optionalTarget(from: args)
                return try await NeoYAccessibilityController.shared.type(text, target: parsedTarget)
            },
            ToolDefinition(name: "computer.set_value", description: "Set the accessibility value of an element.", parameters: schema([
                "value": string("New value"),
                "target": .object(["type": .string("object")]),
            ], required: ["value", "target"])) { args in
                try await NeoYAccessibilityController.shared.setValue(try requiredString(args, "value"), target: try target(from: args))
            },
            ToolDefinition(name: "computer.key", description: "Press a supported key or cmd/option key combination.", parameters: schema([
                "key": string("return, tab, space, delete, escape, arrow names, or cmd+c"),
                "target": .object(["type": .string("object")]),
            ], required: ["key"])) { args in
                try await NeoYAccessibilityController.shared.key(try requiredString(args, "key"), at: optionalTarget(from: args))
            },
            ToolDefinition(name: "computer.scroll", description: "Scroll at a resolved target.", parameters: schema([
                "target": .object(["type": .string("object")]),
                "delta_x": .object(["type": .string("number")]),
                "delta_y": .object(["type": .string("number")]),
            ], required: ["target"])) { args in
                try await NeoYAccessibilityController.shared.scroll(
                    try target(from: args),
                    deltaX: double(args, "delta_x"),
                    deltaY: double(args, "delta_y")
                )
            },
            ToolDefinition(name: "computer.drag", description: "Drag from one resolved target to another.", parameters: schema([
                "from": .object(["type": .string("object")]),
                "to": .object(["type": .string("object")]),
            ], required: ["from", "to"])) { args in
                try await NeoYAccessibilityController.shared.drag(from: try target(from: args), to: try target(from: args, key: "to"))
            },
        ]
    }

    private static func target(from args: JSONValue, key: String = "target") throws -> DemoTarget {
        guard case .object(let object) = args, let raw = object[key] else {
            throw DemoRecorderError.message("\(key) is required")
        }
        return try JSONDecoder().decode(DemoTarget.self, from: JSONEncoder().encode(raw))
    }

    private static func optionalTarget(from args: JSONValue) -> DemoTarget? {
        guard case .object(let object) = args, let raw = object["target"] else { return nil }
        return try? JSONDecoder().decode(DemoTarget.self, from: JSONEncoder().encode(raw))
    }

    private static func requiredString(_ args: JSONValue, _ key: String) throws -> String {
        guard case .object(let object) = args, case .string(let value)? = object[key] else {
            throw DemoRecorderError.message("\(key) is required")
        }
        return value
    }

    private static func int(_ args: JSONValue, _ key: String, _ fallback: Int) -> Int {
        guard case .object(let object) = args, case .int(let value)? = object[key] else { return fallback }
        return value
    }

    private static func double(_ args: JSONValue, _ key: String) -> Double {
        guard case .object(let object) = args else { return 0 }
        switch object[key] {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return 0
        }
    }

    private static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func integer(_ description: String, default defaultValue: Int) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description), "default": .int(defaultValue)])
    }

    private static func targetSchema() -> JSONValue {
        schema(["target": .object(["type": .string("object")])], required: ["target"])
    }

    private static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var value: [String: JSONValue] = ["type": .string("object"), "properties": .object(properties)]
        if !required.isEmpty { value["required"] = .array(required.map(JSONValue.string)) }
        return .object(value)
    }
}

private final class AccessibilityCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }
}
