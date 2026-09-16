import AppKit
import ApplicationServices

/// Identity of the focused destination captured when recording stops.
struct PasteDestinationSnapshot: Equatable {
    struct ElementIdentity: Equatable {
        let role: String
        let identifier: String?
        let title: String?
        let valueDescription: String?
        let position: String?
        let size: String?
    }

    let processIdentifier: pid_t
    let bundleIdentifier: String
    let window: ElementIdentity
    let element: ElementIdentity
    let selectedTextRange: CFRange

    @MainActor
    static func capture() -> PasteDestinationSnapshot? {
        guard AXIsProcessTrusted(),
            let application = NSWorkspace.shared.frontmostApplication,
            let bundleIdentifier = application.bundleIdentifier
        else { return nil }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let windowElement = copyElement(kAXFocusedWindowAttribute, from: appElement),
            let focusedElement = copyElement(kAXFocusedUIElementAttribute, from: appElement),
            let windowIdentity = identity(of: windowElement),
            let elementIdentity = identity(of: focusedElement),
            let range = selectedTextRange(of: focusedElement)
        else { return nil }

        return PasteDestinationSnapshot(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: bundleIdentifier,
            window: windowIdentity,
            element: elementIdentity,
            selectedTextRange: range
        )
    }

    @MainActor
    func stillMatches() -> Bool {
        guard let current = Self.capture() else { return false }
        return current == self
    }

    private static func copyElement(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyString(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == CFStringGetTypeID()
        else { return nil }
        return value as? String
    }

    private static func copyPoint(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            AXValueGetType(value as! AXValue) == .cgPoint
        else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func copySize(_ attribute: String, from element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            AXValueGetType(value as! AXValue) == .cgSize
        else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    private static func identity(of element: AXUIElement) -> ElementIdentity? {
        guard let role = copyString(kAXRoleAttribute, from: element) else { return nil }
        let identifier = copyString(kAXIdentifierAttribute, from: element)
        let title = copyString(kAXTitleAttribute, from: element)
        let value = copyString(kAXValueAttribute, from: element)
        let position = copyPoint(kAXPositionAttribute, from: element).map { "\($0.x),\($0.y)" }
        let size = copySize(kAXSizeAttribute, from: element).map { "\($0.width),\($0.height)" }
        guard identifier != nil || title != nil || (position != nil && size != nil) else { return nil }
        return ElementIdentity(role: role, identifier: identifier, title: title,
                               valueDescription: value, position: position, size: size)
    }

    private static func selectedTextRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
            let value,
            AXValueGetType(value as! AXValue) == .cfRange
        else { return nil }
        var range = CFRange(location: 0, length: 0)
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }
}
