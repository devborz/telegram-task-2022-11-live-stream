import Foundation
import UIKit
import ComponentFlow
import Display
import AsyncDisplayKit
import AccountContext
import SwiftSignalKit
import AVKit
import TelegramCore
import Postbox
import ShareController
import UndoUI
import TelegramPresentationData
import PresentationDataUtils
import LottieAnimationComponent
import ContextUI
import ViewControllerComponent
import BundleIconComponent
import CreateExternalMediaStreamScreen
import HierarchyTrackingLayer
import UndoPanelComponent
import AnimatedCountLabelNode

// MARK: - New StreamController

public final class MediaStreamController: ViewController, VoiceChatController {
    
    
   
    private let sharedContext: SharedAccountContext
    public let call: PresentationGroupCall
    private let presentationData: PresentationData
    public var parentNavigationController: NavigationController?
        
    public let contentsReady = ValuePromise<Bool>(false, ignoreRepeated: true)
    public let dataReady = ValuePromise<Bool>(false, ignoreRepeated: true)
    public let audioOutputStateReady = ValuePromise<Bool>(false, ignoreRepeated: true)
    private let _ready = Promise<Bool>(false)
    override public var ready: Promise<Bool> {
        return self._ready
    }
    
    public var onFullScreen: ((UIInterfaceOrientation?) -> Void)?
    public var onViewDidAppear: (() -> Void)?
    public var onViewDidDisappear: (() -> Void)?
    private var reclaimActionButton: (() -> Void)?
    
    private var didAppearOnce: Bool = false
    private var isDismissed: Bool = false
    private var isDisconnected: Bool = false
    
    private var controllerNode: MediaStreamNode {
        return self.displayNode as! MediaStreamNode
    }
    
    private let idleTimerExtensionDisposable = MetaDisposable()
    
    public weak var currentOverlayController: VoiceChatOverlayController?
    
    private var validLayout: ContainerViewLayout?
    
    var pictureInPictureController: AVPictureInPictureController?
    
    public init(sharedContext: SharedAccountContext,
                accountContext: AccountContext,
                call: PresentationGroupCall) {
        self.sharedContext = sharedContext
        self.call = call
        self.presentationData = sharedContext.currentPresentationData.with { $0 }
        
        super.init(navigationBarPresentationData: nil)
        
        self.automaticallyControlPresentationContextLayout = false
        self.blocksBackgroundWhenInOverlay = true
        
        self.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .all)
                 
        self.statusBar.statusBarStyle = .Ignore
        
        self._ready.set(combineLatest([
            self.contentsReady.get(),
            self.dataReady.get(),
            self.audioOutputStateReady.get()
        ])
        |> map { values -> Bool in
            for value in values {
                if !value {
                    return false
                }
            }
            return true
        }
        |> filter { $0 })
    }
    
    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        view.clipsToBounds = false
    }
    
    deinit {
        self.idleTimerExtensionDisposable.dispose()
        
        if let currentOverlayController = self.currentOverlayController {
            currentOverlayController.animateOut(reclaim: false, targetPosition: CGPoint(), completion: { _ in })
        }
    }
    
    override public func loadDisplayNode() {
        self.displayNode = MediaStreamNode(controller: self, sharedContext: self.sharedContext, call: self.call)
        
        self.displayNodeDidLoad()
    }
        
    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        self.isDismissed = false
        
        if !self.didAppearOnce {
            self.didAppearOnce = true
            
            self.reclaimActionButton?()
            self.controllerNode.animateIn()
            self.controllerNode.updateVideos()
            
            self.idleTimerExtensionDisposable.set(self.sharedContext.applicationBindings.pushIdleTimerExtension())
        }
        
        DispatchQueue.main.async {
            self.onViewDidAppear?()
        }
    }
    
    override public func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        self.idleTimerExtensionDisposable.set(nil)
        DispatchQueue.main.async {
            self.didAppearOnce = false
            self.isDismissed = true
            self.detachActionButton()
            self.onViewDidDisappear?()
        }
    }
    
    var requestedExpansion = false
    

    func expandFromPictureInPicture() {
        if let pictureInPictureController = self.pictureInPictureController, pictureInPictureController.isPictureInPictureActive {
            self.requestedExpansion = true
            self.pictureInPictureController?.stopPictureInPicture()
        }
    }
        
    private var dismissedManually: Bool = false
    public func dismiss(closing: Bool, manual: Bool = false) {
        self.controllerNode.saveLastFrame()
        self.controllerNode.updateVideos(enabled: false)
        if closing {
            self.isDisconnected = true
        } else {
            if let navigationController = self.navigationController as? NavigationController {
                let count = navigationController.viewControllers.count
                if count == 2 || navigationController.viewControllers[count - 2] is ChatController {
                    if let chatController = navigationController.viewControllers[count - 2] as? ChatController, chatController.isSendButtonVisible {
                    } else if let tabBarController = navigationController.viewControllers[count - 2] as? TabBarController, let chatListController = tabBarController.controllers[tabBarController.selectedIndex] as? ChatListController, chatListController.isSearchActive {
                    } else {
                        if manual {
                            self.dismissedManually = true
                            Queue.mainQueue().after(0.05) {
                                self.detachActionButton()
                            }
                        } else {
                            self.detachActionButton()
                        }
                    }
                }
            }
        }
        
        self.dismiss()
    }
    
    private func detachActionButton() {
        guard self.currentOverlayController == nil && !self.isDisconnected else {
            return
        }
    }
    
    override public func dismiss(completion: (() -> Void)? = nil) {
        if !self.isDismissed {
            self.isDismissed = true
            self.didAppearOnce = false
            
            self.controllerNode.animateOut(completion: { [weak self] in
                completion?()
                self?.dismiss(animated: false)
            })

            DispatchQueue.main.async {
                self.onViewDidDisappear?()
            }
        }
    }
    
    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.validLayout = layout
        self.controllerNode.containerLayoutUpdated(layout, navigationHeight: self.navigationLayout(layout: layout).navigationFrame.maxY, transition: transition)
    }
    

}

extension MediaStreamController: AVPictureInPictureControllerDelegate {
    
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
//        guard let component = self.component else {
//            completionHandler(false)
//            return
//        }
//
//        component.bringBackControllerForPictureInPictureDeactivation {
//            completionHandler(true)
//        }
    }
    
    public func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
//        self.state?.updated(transition: .immediate)
    }
    
    public func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
//        if self.requestedExpansion {
//            self.requestedExpansion = false
//        } else {
//            self.component?.pictureInPictureClosed()
//        }
    }
    
    public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
//        self.state?.updated(transition: .immediate)
    }
}
