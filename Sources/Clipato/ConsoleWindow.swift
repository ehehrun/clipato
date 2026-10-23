import AppKit

final class ConsoleWindow: EscapeClosingWindow {
    weak var sidebarResizeHandle: SidebarResizeHandleView?
    private weak var resizingSidebar: SidebarResizeHandleView?

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            resizingSidebar = nil
            if attachedSheet == nil, let handle = sidebarResizeHandle, handle.isEnabled,
               handle.bounds.contains(handle.convert(event.locationInWindow, from: nil)),
               let content = contentView, let container = content.superview,
               content.hitTest(container.convert(event.locationInWindow, from: nil)) === handle {
                resizingSidebar = handle
                handle.mouseDown(with: event)
                return
            }
        case .leftMouseDragged:
            if let handle = resizingSidebar {
                handle.mouseDragged(with: event)
                return
            }
        case .leftMouseUp:
            if let handle = resizingSidebar {
                resizingSidebar = nil
                handle.mouseUp(with: event)
                return
            }
        default:
            break
        }
        super.sendEvent(event)
    }
}
