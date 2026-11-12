//
//  ViewExtensions.swift
//  LiveContainer
//
//  Created by s s on 2026/3/20.
//

import SwiftUI
import UniformTypeIdentifiers
import LocalAuthentication
import SafariServices
import Security
import Combine

struct SafariView: UIViewControllerRepresentable {
    let url: Binding<URL>
    func makeUIViewController(context: UIViewControllerRepresentableContext<Self>) -> SFSafariViewController {
        return SFSafariViewController(url: url.wrappedValue)
    }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: UIViewControllerRepresentableContext<SafariView>) {
        
    }
}

// https://stackoverflow.com/questions/56726663/how-to-add-a-textfield-to-alert-in-swiftui
extension View {

    public func textFieldAlert(
        isPresented: Binding<Bool>,
        title: String,
        text: Binding<String>,
        placeholder: String = "",
        action: @escaping (String?) -> Void,
        actionCancel: @escaping (String?) -> Void
    ) -> some View {
        self.modifier(TextFieldAlertModifier(isPresented: isPresented, title: title, text: text, placeholder: placeholder, action: action, actionCancel: actionCancel))
    }
    
    public func betterFileImporter(
        isPresented: Binding<Bool>,
        types : [UTType],
        multiple : Bool = false,
        callback: @escaping ([URL]) -> (),
        onDismiss: @escaping () -> Void
    ) -> some View {
        self.modifier(DocModifier(isPresented: isPresented, types: types, multiple: multiple, callback: callback, onDismiss: onDismiss))
    }
    
}


/// Walk the presented-view-controller chain to the topmost controller.
fileprivate func topmostViewController(from root: UIViewController?) -> UIViewController? {
    var top = root
    while let presented = top?.presentedViewController {
        top = presented
    }
    return top
}

/// Present `vc` from the topmost view controller in `window`, retrying
/// briefly while a presentation/dismissal transition is in flight.
/// UIKit silently drops a `present` issued mid-transition. That is what
/// broke certificate import: the file picker was presented right after
/// the confirmation alert was confirmed, while the alert's dismissal
/// animation was still running, so the picker never appeared and the
/// import hung forever waiting for a picker callback. The same race hit
/// the password prompt after the picker was dismissed. Presenting from
/// the topmost controller also matters because Settings is a
/// fullScreenCover over the desktop. `isStillWanted` is re-checked
/// before every attempt so a presentation that is no longer wanted is
/// never shown late.
fileprivate func presentFromTopmost(
    _ vc: UIViewController,
    in window: UIWindow?,
    isStillWanted: @escaping () -> Bool,
    attempts: Int = 0
) {
    guard isStillWanted() else { return }
    guard let top = topmostViewController(from: window?.rootViewController) else { return }
    // A transition in flight, or a transient system UI (alert / picker)
    // on top: presenting now would be silently dropped by UIKit.
    // Wait it out and retry.
    if top.isBeingPresented || top.isBeingDismissed
        || top is UIAlertController || top is UIDocumentPickerViewController {
        guard attempts < 30 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            presentFromTopmost(vc, in: window, isStillWanted: isStillWanted, attempts: attempts + 1)
        }
        return
    }
    top.present(vc, animated: true)
}

public struct DocModifier: ViewModifier {
    @EnvironmentObject var sceneDelegate: SceneDelegate
    @State private var docController: UIDocumentPickerViewController?
    @State private var delegate : UIDocumentPickerDelegate
    
    @Binding var isPresented: Bool

    var callback: ([URL]) -> ()
    private let onDismiss: () -> Void
    private let types : [UTType]
    private let multiple : Bool
    
    init(isPresented : Binding<Bool>, types : [UTType], multiple : Bool, callback: @escaping ([URL]) -> (), onDismiss: @escaping () -> Void) {
        self.callback = callback
        self.onDismiss = onDismiss
        self.types = types
        self.multiple = multiple
        self.delegate = Coordinator(callback: callback, onDismiss: onDismiss)
        self._isPresented = isPresented
    }

    public func body(content: Content) -> some View {
        content.onChange(of: isPresented) { isPresented in
            if isPresented, docController == nil {
                let controller = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
                controller.allowsMultipleSelection = multiple
                controller.delegate = delegate
                self.docController = controller
                presentFromTopmost(controller, in: sceneDelegate.window) { self.isPresented }
            } else if !isPresented, let docController = docController {
                docController.dismiss(animated: true)
                self.docController = nil
            }
        }
    }

    private func shutdown() {
        isPresented = false
        docController = nil
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        var callback: ([URL]) -> ()
        private let onDismiss: () -> Void
        
        init(callback: @escaping ([URL]) -> Void, onDismiss: @escaping () -> Void) {
            self.callback = callback
            self.onDismiss = onDismiss
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            callback(urls)
            onDismiss()
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onDismiss()
        }
    }

}

public struct TextFieldAlertModifier: ViewModifier {
    @EnvironmentObject var sceneDelegate: SceneDelegate
    @State private var alertController: UIAlertController?

    @Binding var isPresented: Bool

    let title: String
    let text: Binding<String>
    let placeholder: String
    let action: (String?) -> Void
    let actionCancel: (String?) -> Void

    public func body(content: Content) -> some View {
        content.onChange(of: isPresented) { isPresented in
            if isPresented, alertController == nil {
                let alertController = makeAlertController()
                self.alertController = alertController
                presentFromTopmost(alertController, in: sceneDelegate.window) { self.isPresented }
            } else if !isPresented, let alertController = alertController {
                alertController.dismiss(animated: true)
                self.alertController = nil
            }
        }
    }

    private func makeAlertController() -> UIAlertController {
        let controller = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        controller.addTextField {
            $0.placeholder = self.placeholder
            $0.text = self.text.wrappedValue
            $0.clearButtonMode = .always
        }
        controller.addAction(UIAlertAction(title: "lc.common.cancel".loc, style: .cancel) { _ in
            self.actionCancel(nil)
            shutdown()
        })
        controller.addAction(UIAlertAction(title: "lc.common.ok".loc, style: .default) { _ in
            self.action(controller.textFields?.first?.text)
            shutdown()
        })
        return controller
    }

    private func shutdown() {
        isPresented = false
        alertController = nil
    }

}

struct BasicButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

struct ActivityViewController: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: UIViewControllerRepresentableContext<ActivityViewController>) -> UIActivityViewController {
        return UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: UIViewControllerRepresentableContext<ActivityViewController>) {}
}

struct IconImageView: View {
    var icon: UIImage
    
    var body: some View {
        GeometryReader { g in
            Image(uiImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: g.size.width*0.2667))
        }
    }
}


extension UIViewController {
    func presentConfirmation(
        title: String,
        message: String,
        confirmTitle: String,
        cancelTitle: String
    ) async -> Bool? {
        guard viewIfLoaded?.window != nil, presentedViewController == nil else {
            return nil
        }

        return await withUnsafeContinuation { continuation in
            let finishConfirmation =  { (result: Bool?, alert: UIAlertController?) in
                alert?.dismiss(animated: true) {
                    continuation.resume(returning: result)
                }
            }
            
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: confirmTitle, style: .destructive) { [weak alert] _ in
                finishConfirmation(true, alert)
            })
            alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel) { [weak alert] _ in
                finishConfirmation(false, alert)
            })
            present(alert, animated: true)
        }
    }

    func showError(_ message: String) {
        guard viewIfLoaded?.window != nil else {
            return
        }

        let presentError = { [weak self] in
            guard let self else {
                return
            }
            let alert = UIAlertController(title: "lc.common.error".loc, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "lc.common.ok".loc, style: .default))
            alert.addAction(UIAlertAction(title: "lc.common.copy".loc, style: .default) { _ in
                UIPasteboard.general.string = message
            })
            self.present(alert, animated: true)
        }

        if let presentedViewController {
            presentedViewController.dismiss(animated: true, completion: presentError)
        } else {
            presentError()
        }
    }
}
