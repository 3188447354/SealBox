//
//  ShareExtensionHandler.swift
//  ShareExtension
//
//  SealBox 0.0.3 rebuild — hosting shell (implementation #2).
//
//  Unchanged in shape from the old handler: a UIHostingController for
//  the SwiftUI root view, with the payload load kicked off from
//  beginRequest (the share-extension entry point). The ViewModel
//  guards against a double load — viewDidLoad and beginRequest both
//  call it.

import SwiftUI
import UIKit

final class ShareExtensionHandler: UIViewController {
    private let viewModel = ShareExtensionViewModel()
    private var host: UIHostingController<ShareExtensionRootView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        let root = ShareExtensionRootView(viewModel: viewModel, extensionContext: extensionContext)
        let host = UIHostingController(rootView: root)
        self.host = host
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        viewModel.loadPayload(from: extensionContext)
    }

    override func beginRequest(with context: NSExtensionContext) {
        viewModel.loadPayload(from: context)
    }
}
