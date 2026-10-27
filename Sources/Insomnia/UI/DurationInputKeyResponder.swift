import AppKit
import SwiftUI

/// A cursor-free keyboard receiver for the same custom pills used in the
/// status bar. Its hosting panel supplies the key window; no text editor is needed.
struct DurationInputKeyResponder: NSViewRepresentable {
    let active: Bool
    let focusRequest: Int
    let onPresentationChange: (Bool) -> Void
    let onKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> Receiver { Receiver() }

    func updateNSView(_ view: Receiver, context: Context) {
        view.onKey = onKey
        view.onPresentationChange = onPresentationChange
        view.update(active: active, focusRequest: focusRequest)
    }

    static func dismantleNSView(_ view: Receiver, coordinator: ()) {
        view.update(active: false, focusRequest: 0)
        view.onPresentationChange?(false)
        view.onPresentationChange = nil
        view.onKey = nil
    }

    final class Receiver: NSView {
        var onKey: ((NSEvent) -> Bool)?
        var onPresentationChange: ((Bool) -> Void)?
        private var active = false
        private var focusRequest = 0
        private var focusGeneration = 0

        override var acceptsFirstResponder: Bool { active }
        override var canBecomeKeyView: Bool { active }
        override var needsPanelToBecomeKey: Bool { active }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focusGeneration += 1
            NotificationCenter.default.removeObserver(self)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey),
                    name: NSWindow.didBecomeKeyNotification, object: window)
                NotificationCenter.default.addObserver(self, selector: #selector(windowDismissed),
                    name: NSWindow.didResignKeyNotification, object: window)
                NotificationCenter.default.addObserver(self, selector: #selector(windowDismissed),
                    name: NSWindow.willCloseNotification, object: window)
            }
            // Defer state updates until SwiftUI has finished attaching its view.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, self.window === window else { return }
                self.onPresentationChange?(window?.isVisible == true && window?.isKeyWindow == true)
            }
            requestFocus()
        }

        func update(active: Bool, focusRequest: Int) {
            let needsFocus = active && (!self.active || self.focusRequest != focusRequest)
            self.active = active
            self.focusRequest = focusRequest
            if !active {
                focusGeneration += 1
                if window?.firstResponder === self { window?.makeFirstResponder(nil) }
            } else if needsFocus {
                requestFocus()
            }
        }

        @objc private func windowBecameKey(_ notification: Notification) {
            onPresentationChange?(true)
            requestFocus()
        }

        @objc private func windowDismissed(_ notification: Notification) {
            focusGeneration += 1
            onPresentationChange?(false)
        }

        private func requestFocus() {
            focusGeneration += 1
            let generation = focusGeneration
            guard active, let expectedWindow = window else { return }
            DispatchQueue.main.async { [weak self, weak expectedWindow] in
                guard let self, let expectedWindow, self.active,
                      self.focusGeneration == generation, self.window === expectedWindow,
                      expectedWindow.isVisible, expectedWindow.isKeyWindow else { return }
                expectedWindow.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            if active, onKey?(event) == true { return }
            super.keyDown(with: event)
        }
    }
}
