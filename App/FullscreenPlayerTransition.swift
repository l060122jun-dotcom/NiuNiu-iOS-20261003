import SwiftUI
import UIKit

private struct FullscreenPlayerInsetsKey: EnvironmentKey {
    static let defaultValue = EdgeInsets()
}

extension EnvironmentValues {
    var fullscreenPlayerInsets: EdgeInsets {
        get { self[FullscreenPlayerInsetsKey.self] }
        set { self[FullscreenPlayerInsetsKey.self] = newValue }
    }
}

/// One hosting controller / one renderer for both placements. The representable's
/// inline view is a permanent placeholder, not a second playback surface.
@MainActor struct FullscreenPlayerTransition<Content: View>: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let landscape: Bool
    let orientationFailure: (String) -> Void
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> PlayerPlacementController {
        let inline = PlayerPlacementController()
        context.coordinator.inline = inline
        context.coordinator.host = UIHostingController(rootView: AnyView(content()))
        context.coordinator.attachInline()
        inline.onShown = { [weak coordinator = context.coordinator] in
            if coordinator?.desiredPresented == true { coordinator?.presentIfNeeded() }
        }
        return inline
    }

    func updateUIViewController(_ controller: PlayerPlacementController, context: Context) {
        let coordinator = context.coordinator
        coordinator.setPresented = { isPresented = $0 }
        coordinator.didDismiss = onDismiss
        coordinator.orientationFailure = orientationFailure
        coordinator.content = { insets in AnyView(content().environment(\.fullscreenPlayerInsets, insets)) }
        coordinator.host?.rootView = coordinator.content?(coordinator.insets) ?? AnyView(content())
        coordinator.desiredLandscape = landscape
        coordinator.desiredPresented = isPresented
        if isPresented { coordinator.presentIfNeeded() }
        else { coordinator.dismissIfNeeded() }
    }

    final class Coordinator: NSObject, UIViewControllerTransitioningDelegate {
        weak var inline: PlayerPlacementController?
        var host: UIHostingController<AnyView>?
        var fullscreen: PlayerFullscreenController?
        var setPresented: ((Bool) -> Void)?
        var didDismiss: (() -> Void)?
        var orientationFailure: ((String) -> Void)?
        var content: ((EdgeInsets) -> AnyView)?
        var insets = EdgeInsets()
        var desiredLandscape = true
        var desiredPresented = false
        var dismissing = false
        var presentationPending = false

        func attachInline() {
            guard let inline, let host else { return }
            move(host, to: inline)
            inline.layoutPlayer = { [weak self] in
                guard let self, self.host?.parent === self.inline else { return }
                self.host?.view.frame = self.inline?.view.bounds ?? .zero
            }
        }

        func presentIfNeeded() {
            if let fullscreen {
                if !dismissing && fullscreen.didShow { fullscreen.setLandscape(desiredLandscape) }
                return
            }
            guard !presentationPending else { return }
            // SwiftUI can update before the bridge has a window / presenting parent.
            presentationPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.presentationPending = false
                guard self.desiredPresented, let inline = self.inline, inline.view.window != nil,
                      let presenter = inline.parent, presenter.presentedViewController == nil,
                      let host = self.host else { return }
                let fullscreen = PlayerFullscreenController()
                fullscreen.modalPresentationStyle = .custom
                fullscreen.modalPresentationCapturesStatusBarAppearance = true
                fullscreen.transitioningDelegate = self
                fullscreen.host = host
                fullscreen.inline = inline
                fullscreen.onShown = { [weak self, weak fullscreen] in
                    guard let self else { return }
                    fullscreen?.setLandscape(self.desiredLandscape)
                }
                fullscreen.orientationFailure = { [weak self] message in self?.orientationFailure?(message) }
                fullscreen.layoutPlayer = { [weak self, weak fullscreen] in
                    guard let self, let fullscreen else { return }
                    host.view.frame = fullscreen.view.bounds
                    let safe = fullscreen.view.safeAreaInsets
                    let next = EdgeInsets(top: safe.top, leading: safe.left, bottom: safe.bottom, trailing: safe.right)
                    guard next != self.insets else { return }
                    self.insets = next
                    if let content = self.content { host.rootView = content(next) }
                }
                self.fullscreen = fullscreen
                presenter.present(fullscreen, animated: true)
            }
        }

        func dismissIfNeeded() {
            guard let fullscreen, !dismissing else { return }
            guard !fullscreen.isBeingPresented else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.dismissIfNeeded() }
                return
            }
            dismissing = true
            // Restore real portrait geometry before measuring the inline destination.
            fullscreen.restorePortrait { [weak self, weak fullscreen] in
                guard let self, let fullscreen else { return }
                fullscreen.dismiss(animated: true) {
                    self.insets = EdgeInsets()
                    if let content = self.content { self.host?.rootView = content(self.insets) }
                    self.fullscreen = nil
                    self.dismissing = false
                    self.setPresented?(false)
                    self.didDismiss?()
                }
            }
        }

        func presentationController(forPresented presented: UIViewController, presenting: UIViewController?, source: UIViewController) -> UIPresentationController? {
            PlayerFullscreenPresentation(presentedViewController: presented, presenting: presenting)
        }
        func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
            PlayerGeometryAnimator<Content>(coordinator: self, presenting: true)
        }
        func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
            PlayerGeometryAnimator<Content>(coordinator: self, presenting: false)
        }
    }
}

@MainActor class PlayerPlacementController: UIViewController {
    var layoutPlayer: (() -> Void)?
    var onShown: (() -> Void)?
    override func loadView() { view = UIView(); view.backgroundColor = .black }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); layoutPlayer?() }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); onShown?() }
}

@MainActor final class PlayerFullscreenController: PlayerPlacementController {
    weak var host: UIViewController?
    weak var inline: UIViewController?
    var orientationFailure: ((String) -> Void)?
    var didShow = false
    private var orientationMask: UIInterfaceOrientationMask = .allButUpsideDown
    private var portraitCompletion: (() -> Void)?
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { orientationMask }
    override var shouldAutorotate: Bool { true }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override func viewDidAppear(_ animated: Bool) {
        didShow = true
        super.viewDidAppear(animated)
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }
    func setLandscape(_ landscape: Bool) {
        let mask: UIInterfaceOrientationMask = landscape ? .landscapeRight : .portrait
        guard mask != orientationMask else { return }
        orientationMask = mask
        setNeedsUpdateOfSupportedInterfaceOrientations()
        view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] error in
            self?.orientationFailure?("系统未允许此屏幕方向：\(error.localizedDescription)")
        }
    }
    func restorePortrait(completion: @escaping () -> Void) {
        portraitCompletion = completion
        setLandscape(false)
        // No rotation callback occurs if already portrait or geometry is denied.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in self?.finishPortrait() }
        if view.window?.windowScene?.interfaceOrientation == .portrait { finishPortrait() }
    }
    private func finishPortrait() {
        let completion = portraitCompletion
        portraitCompletion = nil
        completion?()
    }
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { [weak self] _ in self?.view.setNeedsLayout(); self?.view.layoutIfNeeded() }) { [weak self] _ in
            if size.height >= size.width { self?.finishPortrait() }
        }
    }
}

@MainActor private final class PlayerFullscreenPresentation: UIPresentationController {
    override var shouldPresentInFullscreen: Bool { true }
    override var shouldRemovePresentersView: Bool { false }
    override var frameOfPresentedViewInContainerView: CGRect { containerView?.bounds ?? .zero }
    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        presentedView?.frame = frameOfPresentedViewInContainerView
    }
}

@MainActor private final class PlayerGeometryAnimator<Content: View>: NSObject, UIViewControllerAnimatedTransitioning {
    let coordinator: FullscreenPlayerTransition<Content>.Coordinator
    let presenting: Bool
    init(coordinator: FullscreenPlayerTransition<Content>.Coordinator, presenting: Bool) {
        self.coordinator = coordinator
        self.presenting = presenting
    }
    func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval { 0.38 }
    func animateTransition(using context: UIViewControllerContextTransitioning) {
        guard let inline = coordinator.inline, let host = coordinator.host,
              let fullscreen = coordinator.fullscreen else { context.completeTransition(false); return }
        let container = context.containerView
        let fullscreenView = fullscreen.view!
        let fullFrame = presenting ? context.finalFrame(for: fullscreen) : container.bounds
        let inlineFrame = inline.view.convert(inline.view.bounds, to: container)
        fullscreenView.frame = fullFrame
        if presenting { container.addSubview(fullscreenView) }
        // The live hosting view (including the existing sample-buffer renderer) is
        // moved, never recreated or snapshot-replaced. UIKit owns actual rotation
        // after didAppear; LandscapeRight is the system's counterclockwise turn.
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        fullscreen.addChild(host)
        fullscreenView.addSubview(host.view)
        host.didMove(toParent: fullscreen)
        host.view.frame = presenting ? fullscreenView.convert(inlineFrame, from: container) : fullscreenView.bounds
        host.view.clipsToBounds = true
        let target = presenting ? fullscreenView.bounds : fullscreenView.convert(inlineFrame, from: container)
        UIView.animate(withDuration: transitionDuration(using: context), delay: 0,
                       options: [.curveEaseInOut, .beginFromCurrentState]) {
            host.view.frame = target
            host.view.layoutIfNeeded()
        } completion: { _ in
            if !self.presenting { self.coordinator.attachInline() }
            context.completeTransition(!context.transitionWasCancelled)
        }
    }
}

@MainActor private func move(_ child: UIViewController, to parent: UIViewController) {
    if child.parent === parent { child.view.frame = parent.view.bounds; return }
    child.willMove(toParent: nil)
    child.view.removeFromSuperview()
    child.removeFromParent()
    parent.addChild(child)
    parent.view.addSubview(child.view)
    child.view.frame = parent.view.bounds
    child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    child.didMove(toParent: parent)
}
