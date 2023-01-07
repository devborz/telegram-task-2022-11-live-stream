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
import AvatarNode
import TelegramVoip

private var optionsImage: UIImage? {
    return UIImage(named: "stream.ellipsis")
}

private var pictureInPictureImage: UIImage? {
    return UIImage(named: "stream.pip.enter")
}

private var expandImage: UIImage? {
    return UIImage(named: "stream.expand")
}

private var shareImage: UIImage? {
    return UIImage(named: "stream.share")
}

private var leaveImage: UIImage? {
    return UIImage(named: "stream.leave")
}


public final class MediaStreamNode: ViewControllerTracingNode, UIGestureRecognizerDelegate {
    
    enum State {
        case partial
        case fullscreen
    }

    private struct ListTransition {
        let deletions: [ListViewDeleteItem]
        let insertions: [ListViewInsertItem]
        let updates: [ListViewUpdateItem]
        let isLoading: Bool
        let isEmpty: Bool
        let canInvite: Bool
        let crossFade: Bool
        let count: Int
        let animated: Bool
    }
    
    private var enqueuedTransitions: [ListTransition] = []
    weak var controller: MediaStreamController?
    private let sharedContext: SharedAccountContext
    private let context: AccountContext
    private let call: PresentationGroupCall
    
    private var didSetContentsReady: Bool = false
    private var didSetDataReady: Bool = false
    
    let contentBackgroundNode: ASDisplayNode
    let contentNode: ASDisplayNode
    let dimNode: ASDisplayNode
    let viewNode: ASDisplayNode
    let backgroundNode: ASDisplayNode
    let titleView: MediaStreamTitleView
    let optionsButton: MediaStreamButton
    let pictureInPictureButton: MediaStreamButton
    let watchersCounterNode: WatchersCounterNode
    let watchingLabel: UILabel
    let shareButton: MediaStreamLargeButton
    let leaveButton: MediaStreamLargeButton
    let expandButton: MediaStreamLargeButton
    
    let streamView: MediaStreamView
    var streamBackgroundView = MediaStreamBackgroundView(frame: .zero)
    let shimmerNode = MediaStreamShimmeringNode()
        
    var panGestureRecognizer: UIPanGestureRecognizer?
    var tapGestureRecognizer: UITapGestureRecognizer?
    
    var visibility = false
    var animatingAppearance = false
    var ignoreLayout = false
    private var validLayout: (ContainerViewLayout, CGFloat)?
    private var initialContentViewYOrigin: CGFloat = 0.0
    
    private let hapticFeedback = HapticFeedback()
    
    private var callState: PresentationGroupCallState?
    private var currentPeer: Peer?
    private var callSummaryState: PresentationGroupCallSummaryState?
    
    private var currentTitle: String = "" {
        didSet {
            self.titleView.title = self.currentTitle
        }
    }
    
    private var darkTheme: PresentationTheme
    
    private let inviteLinksPromise = Promise<GroupCallInviteLinks?>(nil)
    
    private var membersDisposable: Disposable?
    private var pictureInPictureDisposable: Disposable?
    private var callStateDisposable: Disposable?
    private var callSummaryStateDisposable: Disposable?
    private var presentationDataDisposable: Disposable?
    private var currentPeerDisposable: Disposable?
    var lastFrameDisposable: Disposable?
    private let leaveDisposable = MetaDisposable()
    
    var isPictureInPictureSupported: Bool = false {
        didSet {
            let alpha: CGFloat = isPictureInPictureSupported ? 1.0 : 0.0
            UIView.animate(withDuration: 0.3) {
                self.pictureInPictureButton.alpha = alpha
            }
        }
    }
    
    private var watchersCountTimer: SwiftSignalKit.Timer?
    
    private var presentationData: PresentationData
    var streamIsLive: Bool = false
    
    static var streamsPreviews: [Int64 : UIImage] = [:]
    private var streamPreviewImage: UIImage?
    var lastFrameData: OngoingGroupCallContext.VideoFrameData?
    
    var state: State = .partial
    
    init(controller: MediaStreamController,
         sharedContext: SharedAccountContext,
         call: PresentationGroupCall) {
        self.controller = controller
        self.sharedContext = sharedContext
        self.context = call.accountContext
        self.call = call
        self.contentNode = ASDisplayNode()
        self.contentBackgroundNode = ASDisplayNode()
        self.dimNode = ASDisplayNode()
        self.viewNode = ASDisplayNode()
        self.backgroundNode = ASDisplayNode()
        self.optionsButton = MediaStreamButton()
        self.pictureInPictureButton = MediaStreamButton()
        self.watchersCounterNode = WatchersCounterNode()
        self.watchingLabel = UILabel()
        self.shareButton = MediaStreamLargeButton()
        self.expandButton = MediaStreamLargeButton()
        self.leaveButton = MediaStreamLargeButton()
        self.titleView = MediaStreamTitleView(title: "",
                                              liveState: .off)
        self.streamView = MediaStreamView(call: call)
        let presentationData = sharedContext.currentPresentationData.with { $0 }
        self.presentationData = presentationData
        self.darkTheme = defaultDarkColorPresentationTheme
        
        let dict = MediaStreamNode.streamsPreviews
        let key = call.peerId.id._internalGetInt64Value()
        self.streamPreviewImage = dict[key]
        
        super.init()
        self.setupViews()
        self.setupData()
    }
    
    deinit {
        self.membersDisposable?.dispose()
        self.pictureInPictureDisposable?.dispose()
        self.callStateDisposable?.dispose()
        self.callSummaryStateDisposable?.dispose()
        self.presentationDataDisposable?.dispose()
        self.currentPeerDisposable?.dispose()
        self.leaveDisposable.dispose()
        self.lastFrameDisposable?.dispose()
        self.watchersCountTimer?.invalidate()
    }
    
    func saveLastFrame() {
        guard let lastFrameData,
              let image = videoFrameToImage(lastFrameData) else { return }
        let key = self.call.peerId.id._internalGetInt64Value()
        MediaStreamNode.streamsPreviews[key] = image
    }
    
    var watchersCount: Int = 0
    
    func setupData() {
        if #available(iOSApplicationExtension 15.0, iOS 15.0, *), AVPictureInPictureController.isPictureInPictureSupported() {
            self.isPictureInPictureSupported = true
        } else {
            self.isPictureInPictureSupported = false
        }
        
        self.membersDisposable = (self.call.members |> deliverOnMainQueue).start(next: { [weak self] members in
            guard let strongSelf = self, let members else { return }
            strongSelf.watchersCount = members.totalCount
            if !strongSelf.didSetDataReady {
                strongSelf.didSetDataReady = true
                strongSelf.startWatchersCountTimer()
                strongSelf.controller?.dataReady.set(true)
            }
        })
        
        self.presentationDataDisposable = (self.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] state in
            self?.presentationData = state
        })
        
        self.callStateDisposable = (self.call.state |> deliverOnMainQueue).start(next: { [weak self] state in
            self?.callState = state
            self?.streamView.setupVideo()
        })
        
        self.callSummaryStateDisposable = (self.call.summaryState |> deliverOnMainQueue).start(next: { [weak self] state in
            self?.callSummaryState = state
            self?.streamView.setupVideo()
        })
        
        let title: Signal<String?, NoError> = self.call.state
        |> map { state -> String? in
            return (state.title)
        }
        self.currentPeerDisposable = combineLatest(queue: Queue.mainQueue(), self.context.account.viewTracker.peerView(self.call.peerId), title).start(next: { [weak self] view, title in
            guard let strongSelf = self else {
                return
            }
            if let peer = peerViewMainPeer(view) {
                strongSelf.currentTitle = title ?? EnginePeer(peer).displayTitle(strings: strongSelf.presentationData.strings, displayOrder: strongSelf.presentationData.nameDisplayOrder)
                
                let overrideImage: AvatarNodeImageOverride? = nil
                let size = CGSize(width: strongSelf.streamView.avatarNode.frame.size.width,
                                  height: strongSelf.streamView.avatarNode.frame.size.width)
                let viewHeight = strongSelf.streamView.avatarNode.frame.size.height
                strongSelf.streamView.avatarNode.font = avatarPlaceholderFont(size: floor(viewHeight * 16.0 / 37.0))
                strongSelf.streamView.avatarNode.setPeer(context: strongSelf.call.accountContext,
                                                 theme: strongSelf.presentationData.theme,
                                                 peer: EnginePeer(peer),
                                                 overrideImage: overrideImage,
                                                 clipStyle: .none,
                                                 synchronousLoad: true,
                                                 displayDimensions: size)
            }
            if !strongSelf.didSetDataReady {
                strongSelf.didSetDataReady = true
                strongSelf.controller?.dataReady.set(true)
            }
        })
        
        self.controller?.audioOutputStateReady.set(true)
        
        self.inviteLinksPromise.set(.single(nil)
        |> then(call.inviteLinks))
    }
    
    func startWatchersCountTimer() {
        self.watchersCounterNode.update(self.watchersCount, animated: false)
        self.watchersCountTimer = .init(timeout: 5, repeat: true, completion: { [weak self] in
            self?.handleWatchersCountTimer()
        }, queue: Queue.mainQueue())
        self.watchersCountTimer?.start()
    }
    
    @objc
    func handleWatchersCountTimer() {
        self.watchersCounterNode.update(self.watchersCount, animated: true)
    }
    
    func setLive(_ live: Bool, animated: Bool) {
        self.streamIsLive = live
        self.titleView.setLiveState(live ? .on : .off, animated: animated)
        self.streamBackgroundView.setImageViewHidden(live)
        if live {
            self.streamView.avatarNode.isHidden = true
            self.streamView.streamPreviewImageView.isHidden = true
        } else {
            if let image = self.streamPreviewImage {
                self.streamView.streamPreviewImageView.image = image
                self.streamBackgroundView.setImage(image)
                self.streamView.streamPreviewImageView.isHidden = false
                self.streamView.avatarNode.isHidden = true
            } else {
                self.streamView.streamPreviewImageView.isHidden = true
                self.streamView.avatarNode.isHidden = false
            }
        }
        UIView.animate(withDuration: animated ? 0.5 : 0.0) {
            self.streamView.blurView.alpha = live ? 0.0 : 1.0
        }
    }
    
    func updateVideos(enabled: Bool = true) {
        guard self.streamView.videoView != nil else { return }
        var isVisible = enabled
        
        if let pictureInPictureController = self.controller?.pictureInPictureController {
            if pictureInPictureController.isPictureInPictureActive {
                isVisible = true
            }
        }
            
        self.streamView.videoView?.updateIsEnabled(isVisible)
        self.streamView.blurVideoView?.updateIsEnabled(isVisible)
        self.streamBackgroundView.videoView?.updateIsEnabled(isVisible)
    }
    
    func setupViews() {
        self.addSubnode(self.dimNode)
        self.dimNode.backgroundColor = .init(white: 0, alpha: 0.4)
        
        self.addSubnode(self.viewNode)
        self.viewNode.backgroundColor = .clear
        self.viewNode.addSubnode(self.backgroundNode)
        self.viewNode.addSubnode(self.contentBackgroundNode)
        self.contentBackgroundNode.addSubnode(self.contentNode)
        self.viewNode.isHidden = true
        
        self.contentBackgroundNode.backgroundColor = panelBackgroundColor
        self.contentBackgroundNode.layer.maskedCorners = [.layerMinXMinYCorner,
                                                   .layerMaxXMinYCorner]
        self.contentBackgroundNode.layer.cornerRadius = 20
        self.contentBackgroundNode.layer.masksToBounds = true
        
        self.panGestureRecognizer = UIPanGestureRecognizer(target: self,
                                                           action: #selector(handlePanGesture))
        self.tapGestureRecognizer = UITapGestureRecognizer(target: self,
                                                           action: #selector(handleTapGesture))
        self.view.addGestureRecognizer(self.panGestureRecognizer!)
        self.backgroundNode.view
            .addGestureRecognizer(self.tapGestureRecognizer!)
        
        self.optionsButton.layer.cornerRadius = 17
        self.optionsButton.clipsToBounds = true
        self.optionsButton.setup(image: optionsImage,
                                 color: secondaryPanelBackgroundColor,
                                 action: self.handleOptionsTapped)
        self.optionsButton.setTitleColor(.white, for: .normal)
        
        self.pictureInPictureButton.layer.cornerRadius = 17
        self.pictureInPictureButton.clipsToBounds = true
        self.pictureInPictureButton.setup(image: pictureInPictureImage,
                                          color: secondaryPanelBackgroundColor,
                                          action: self.handlePictureInPictureTapped)
        self.pictureInPictureButton.setTitleColor(.white, for: .normal)
        self.pictureInPictureButton.alpha = 0
        
        let contentView = self.contentNode.view
        
        contentView.addSubview(self.streamBackgroundView)
        contentView.addSubview(self.streamView)
        
        self.contentNode.addSubnode(self.watchersCounterNode)
        
        contentView.addSubview(self.optionsButton)
        contentView.addSubview(self.pictureInPictureButton)
        contentView.addSubview(self.titleView)
        contentView.addSubview(self.watchingLabel)
        
        self.streamView.layer.cornerRadius = 10
        self.streamView.clipsToBounds = true
        
        self.watchersCounterNode.update(0, animated: false)
        
        self.watchingLabel.text = "watching"
        self.watchingLabel.textColor = .white
        self.watchingLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        self.watchingLabel.textAlignment = .center
        
        self.shareButton.setup(title: "share",
                               image: shareImage,
                               color: UIColor(hexString: "2A2C5B"),
                               action: self.handleShareTapped)
        self.expandButton.setup(title: "expand",
                                image: expandImage,
                                color: UIColor(hexString: "392948"),
                                action: self.handleExpandTapped)
        self.leaveButton.setup(title: "leave",
                               image: leaveImage,
                               color: UIColor(hexString: "502932"),
                               action: self.handleLeaveTapped)
        
        contentView.addSubview(self.shareButton)
        contentView.addSubview(self.expandButton)
        contentView.addSubview(self.leaveButton)
        
        self.streamView.container = self
    }
    
    func layoutViews() {
        guard let (layout, _) = self.validLayout else {
            return
        }
        let frame: CGRect = .init(origin: .zero,
                                  size: layout.size)
        self.dimNode.frame = frame
        self.viewNode.frame = frame
        self.backgroundNode.frame = frame
        
        self.contentNode.frame.size = layout.size
        self.contentBackgroundNode.frame.size = layout.size
        
        self.setContentPosition()
        self.handleState()
        self.streamBackgroundView.isHidden = layout.orientation == .landscape
        if layout.orientation == .portrait {
            let width = layout.size.width
            self.optionsButton.frame = CGRect(x: 20, y: 12,
                                              width: 34, height: 34)
            self.pictureInPictureButton.frame = CGRect(x: width - 54, y: 12,
                                                       width: 34, height: 34)
            self.titleView.frame = CGRect(x: 64, y: 12,
                                          width: width - 128, height: 34)
            
            let streamViewSize: CGSize = CGSize(width: width - 32,
                                                height: (width - 32) / 16 * 9)
            self.streamView.frame = CGRect(x: 16,
                                            y: self.titleView.frame.maxY + 10,
                                            width: streamViewSize.width,
                                            height: streamViewSize.height)
            self.watchersCounterNode.updateLayout(CGRect(x: 0,
                                                    y: self.streamView.frame.maxY + 35,
                                                    width: width,
                                                    height: 60))
            self.watchingLabel.frame = CGRect(x: 0,
                                              y: self.watchersCounterNode.frame.maxY + 2,
                                              width: width,
                                              height: 18)
            let buttonsSpace = (width - 3 * 60) / 4
            var buttonFrame: CGRect = CGRect(x: buttonsSpace,
                                             y: self.watchingLabel.frame.maxY + 35,
                                             width: 60, height: 80)
            self.shareButton.frame = buttonFrame
            buttonFrame.origin.x = buttonsSpace * 2 + 60
            self.expandButton.frame = buttonFrame
            buttonFrame.origin.x = buttonsSpace * 3 + 60 * 2
            self.leaveButton.frame = buttonFrame
            let streamOrigin = self.streamView.frame.origin
            let backgroundBounds = CGRect(x: 0, y: streamOrigin.y - 50,
                                          width: self.contentNode.view.frame.width,
                                          height: self.streamView.bounds.height + 150)
            self.streamBackgroundView.updateFrame(backgroundBounds)
        } else {
            let height = layout.size.height
            let width = layout.size.width
            self.optionsButton.frame = CGRect(x: width / 4 + 20, y: 12,
                                              width: 34, height: 34)
            self.pictureInPictureButton.frame = CGRect(x: width - 54 - width / 4, y: 12,
                                                       width: 34, height: 34)
            self.titleView.frame = CGRect(x: 64 + width / 4, y: 12,
                                          width: width - 128 - width / 2, height: 34)
            
            let streamViewSize: CGSize = CGSize(width: width - 32 - width / 2,
                                                height: height / 2)
            self.streamView.frame = CGRect(x: 16 + width / 4,
                                            y: self.titleView.frame.maxY + 10,
                                            width: streamViewSize.width,
                                            height: streamViewSize.height)
            self.watchersCounterNode.updateLayout(CGRect(x: width / 4,
                                                    y: self.streamView.frame.maxY + 35,
                                                    width: width / 2,
                                                    height: 60))
            self.watchingLabel.frame = CGRect(x: width / 4,
                                              y: self.watchersCounterNode.frame.maxY + 2,
                                              width: width / 2,
                                              height: 18)
            let buttonsSpace = (height - 3 * 80) / 4
            var buttonFrame: CGRect = CGRect(x: width - self.rightHeight() - 70,
                                             y: buttonsSpace,
                                             width: 60, height: 80)
            self.leaveButton.frame = buttonFrame
            buttonFrame.origin.y = buttonsSpace * 2 + 80
            self.expandButton.frame = buttonFrame
            buttonFrame.origin.y = buttonsSpace * 3 + 80 * 2
            self.shareButton.frame = buttonFrame
            let streamOrigin = self.streamView.frame.origin
            let backgroundBounds = CGRect(x: width / 4, y: streamOrigin.y - 50,
                                          width: self.streamView.bounds.width + 32,
                                          height: self.streamView.bounds.height + 150)
            self.streamBackgroundView.updateFrame(backgroundBounds)
        }
    }
    
    func calculateBackgroundHeight(_ width: CGFloat) -> CGFloat {
        var height: CGFloat = 12
        height += 34
        height += 10
        height += (width - 40) / 16 * 9
        height += 35
        height += 50
        height += 2
        height += 18
        height += 35
        height += 80
        height += 40
        height += self.bottomHeight()
        return height
    }
    
    private func topHeight() -> CGFloat {
        guard let window = UIApplication.shared.windows.first else { return 0 }
        return window.safeAreaInsets.top
    }
    
    private func leftHeight() -> CGFloat {
        guard let window = UIApplication.shared.windows.first else { return 0 }
        return window.safeAreaInsets.left
    }
    
    private func rightHeight() -> CGFloat {
        guard let window = UIApplication.shared.windows.first else { return 0 }
        return window.safeAreaInsets.right
    }
    
    private func bottomHeight() -> CGFloat {
        guard let window = UIApplication.shared.windows.first else { return 0 }
        return window.safeAreaInsets.bottom
    }
    
    private func displayCornerRadius() -> CGFloat {
        guard let window = UIApplication.shared.windows.first else { return 0 }
        return window.value(forKey:"_displayCornerRadius") as? CGFloat ?? 0
    }
    
    func animateIn() {
        guard let (layout, _) = self.validLayout else {
            return
        }
        
        self.dimNode.alpha = 1
        self.visibility = true
        self.animatingAppearance = true
        
        let size = layout.size
        let initialBounds = CGRect(origin: .zero,
                                   size: size)
        self.viewNode.bounds = initialBounds
            .offsetBy(dx: 0, dy: -size.height)
        self.viewNode.isHidden = false
        
        let transition = ContainedViewLayoutTransition.animated(duration: 0.4,
                                                                curve: .spring)
        transition.animateView({
            self.viewNode.view.bounds = initialBounds
        }, completion: { _ in
            self.animatingAppearance = false
            
            self.controller?.currentOverlayController?.dismiss()
            self.controller?.currentOverlayController = nil
        })
        self.dimNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
        
        if !self.streamIsLive {
            self.setLive(false, animated: false)
        }
    }
    
    func animateOut(completion: (() -> Void)?) {
        guard let (layout, _) = self.validLayout else {
            return
        }
        
        self.ignoreLayout = true
        self.dimNode.alpha = 0
        self.visibility = false
        self.animatingAppearance = true
        
        let size = layout.size
        let initialBounds = CGRect(origin: .zero,
                                   size: size)
        let transition = ContainedViewLayoutTransition.animated(duration: 0.4,
                                                                curve: .spring)
        transition.animateView({
            self.viewNode.view.bounds = initialBounds.offsetBy(dx: 0,
                                                                dy: -size.height)
        }, completion: { _ in
            self.animatingAppearance = false
            
            self.controller?.currentOverlayController?.dismiss()
            self.controller?.currentOverlayController = nil
            self.ignoreLayout = false
            completion?()
        })
        self.dimNode.layer.animateAlpha(from: 1.0, to: 0, duration: 0.3)
    }
    
    func containerLayoutUpdated(_ layout: ContainerViewLayout,
                                navigationHeight: CGFloat,
                                transition: ContainedViewLayoutTransition) {
        guard !ignoreLayout else { return }
        let isFirstTime = self.validLayout == nil
        self.validLayout = (layout, navigationHeight)
        if isFirstTime {
            self.controller?.contentsReady.set(true)
        }
        self.layoutViews()
    }
    
    func handleState() {
        guard let (layout, _) = self.validLayout else { return }
        UIView.animate(withDuration: 0.3, delay: 0.0, options: [.curveEaseOut]) {
            if layout.orientation == .portrait {
                switch self.state {
                case .partial:
                    self.contentBackgroundNode.backgroundColor = panelBackgroundColor
                    self.contentBackgroundNode.layer.cornerRadius = 12
                    self.dimNode.backgroundColor = .init(white: 0, alpha: 0.4)
                case .fullscreen:
                    self.contentBackgroundNode.backgroundColor = .black
                    self.contentBackgroundNode.layer.cornerRadius = layout.deviceMetrics.screenCornerRadius - 0.5
                    self.dimNode.backgroundColor = .init(white: 0, alpha: 1)
                }
            } else {
                self.contentBackgroundNode.backgroundColor = .black
                self.contentBackgroundNode.layer.cornerRadius = layout.deviceMetrics.screenCornerRadius - 0.5
                self.dimNode.backgroundColor = .init(white: 0, alpha: 1)
            }
        }
    }
    
    @objc
    private func handleTapGesture() {
        controller?.dismiss(closing: false, manual: true)
    }
    
    @objc
    private func handlePanGesture(_ recognizer: UIPanGestureRecognizer) {
        let state = recognizer.state
        switch state {
        case .began:
            self.initialContentViewYOrigin = self.contentNode.frame.minY
        case .changed:
            let translation = recognizer.translation(in: self.view)
            let y = max(self.initialContentViewYOrigin + translation.y,
                        self.initialContentViewYOrigin)
            self.contentBackgroundNode.frame.origin.y = y
        case .ended:
            let translation = recognizer.translation(in: self.view)
            let velocity = recognizer.velocity(in: self.view)
            if velocity.y >= 300 || translation.y > 150 {
                self.controller?.dismiss(closing: false, manual: true)
            } else {
                self.handleState()
                self.setContentPosition(animated: true)
            }
        default:
            break
        }
    }
    
    // MARK: Actions Handlers
    
    func handleOptionsTapped() {
        
    }
    
    func handlePictureInPictureTapped() {
        self.controller?.pictureInPictureController?.startPictureInPicture()
    }
    
    func handleShareTapped() {
        self.presentShare()
    }
    
    func handleExpandTapped() {
        
    }
    
    func handleLeaveTapped() {
        self.hapticFeedback.impact(.light)
        
        self.leaveDisposable.set((self.call.leave(terminateIfPossible: false)
        |> deliverOnMainQueue).start(completed: { [weak self] in
            self?.controller?.dismiss(closing: true)
        }))
    }
    
    func setContentPosition(animated: Bool = false) {
        guard let (layout, _) = self.validLayout else { return }
        let size = layout.size
        UIView.animate(withDuration: animated ? 0.4 : 0.0,
                       delay: 0.0, options: .curveEaseOut) {
            if layout.orientation == .portrait {
                switch self.state {
                case .fullscreen:
                    self.contentBackgroundNode.frame.origin.y = 0
                    self.contentNode.frame.origin.y = self.topHeight()
                case .partial:
                    let backgroundHeight = self.calculateBackgroundHeight(size.width)
                    self.contentBackgroundNode.frame.origin.y = size.height - backgroundHeight
                    self.contentNode.frame.origin.y = 0
                }
            } else {
                self.contentBackgroundNode.frame.origin.y = 0
                self.contentNode.frame.origin.y = 0
            }
        }
    }
    
    func presentShare() {
        let _ = (self.inviteLinksPromise.get()
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak self] inviteLinks in
            guard let strongSelf = self else {
                return
            }
            
            let _ = (strongSelf.context.engine.data.get(
                TelegramEngine.EngineData.Item.Peer.Peer(id: strongSelf.call.peerId),
                TelegramEngine.EngineData.Item.Peer.ExportedInvitation(id: strongSelf.call.peerId)
            )
            |> map { peer, exportedInvitation -> GroupCallInviteLinks? in
                if let inviteLinks = inviteLinks {
                    return inviteLinks
                } else if let peer = peer, let addressName = peer.addressName, !addressName.isEmpty {
                    return GroupCallInviteLinks(listenerLink: "https://t.me/\(addressName)?voicechat", speakerLink: nil)
                } else if let link = exportedInvitation?.link {
                    return GroupCallInviteLinks(listenerLink: link, speakerLink: nil)
                }
                return nil
            }
            |> deliverOnMainQueue).start(next: { links in
                guard let strongSelf = self else {
                    return
                }
                
                if let links = links {
                    strongSelf.presentShare(links: links)
                }
            })
        })
    }
        
    func presentShare(links inviteLinks: GroupCallInviteLinks) {
        let formatSendTitle: (String) -> String = { string in
            var string = string
            if string.contains("[") && string.contains("]") {
                if let startIndex = string.firstIndex(of: "["), let endIndex = string.firstIndex(of: "]") {
                    string.removeSubrange(startIndex ... endIndex)
                }
            } else {
                string = string.trimmingCharacters(in: CharacterSet(charactersIn: "0123456789-,."))
            }
            return string
        }
        let _ = formatSendTitle
        
        let _ = (combineLatest(queue: .mainQueue(), self.context.account.postbox.loadedPeerWithId(self.call.peerId), self.call.state |> take(1))
        |> deliverOnMainQueue).start(next: { [weak self] peer, callState in
            if let strongSelf = self {
                var inviteLinks = inviteLinks
                
                if let peer = peer as? TelegramChannel, case .group = peer.info, !peer.flags.contains(.isGigagroup), !(peer.addressName ?? "").isEmpty, let defaultParticipantMuteState = callState.defaultParticipantMuteState {
                    let isMuted = defaultParticipantMuteState == .muted
                    
                    if !isMuted {
                        inviteLinks = GroupCallInviteLinks(listenerLink: inviteLinks.listenerLink, speakerLink: nil)
                    }
                }
                
                let presentationData = strongSelf.context.sharedContext.currentPresentationData.with { $0 }
                
                var segmentedValues: [ShareControllerSegmentedValue]?
                segmentedValues = nil
                let shareController = ShareController(context: strongSelf.context, subject: .url(inviteLinks.listenerLink), segmentedValues: segmentedValues, forceTheme: defaultDarkPresentationTheme, forcedActionTitle: presentationData.strings.VoiceChat_CopyInviteLink)
                shareController.completed = { [weak self] peerIds in
                    if let strongSelf = self {
                        let _ = (strongSelf.context.engine.data.get(
                            EngineDataList(
                                peerIds.map(TelegramEngine.EngineData.Item.Peer.Peer.init)
                            )
                        )
                        |> deliverOnMainQueue).start(next: { [weak self] peerList in
                            if let strongSelf = self {
                                let peers = peerList.compactMap { $0 }
                                let presentationData = strongSelf.context.sharedContext.currentPresentationData.with { $0 }
                                
                                let text: String
                                var isSavedMessages = false
                                if peers.count == 1, let peer = peers.first {
                                    isSavedMessages = peer.id == strongSelf.context.account.peerId
                                    let peerName = peer.id == strongSelf.context.account.peerId ? presentationData.strings.DialogList_SavedMessages : peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                                    text = presentationData.strings.VoiceChat_ForwardTooltip_Chat(peerName).string
                                } else if peers.count == 2, let firstPeer = peers.first, let secondPeer = peers.last {
                                    let firstPeerName = firstPeer.id == strongSelf.context.account.peerId ? presentationData.strings.DialogList_SavedMessages : firstPeer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                                    let secondPeerName = secondPeer.id == strongSelf.context.account.peerId ? presentationData.strings.DialogList_SavedMessages : secondPeer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                                    text = presentationData.strings.VoiceChat_ForwardTooltip_TwoChats(firstPeerName, secondPeerName).string
                                } else if let peer = peers.first {
                                    let peerName = peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                                    text = presentationData.strings.VoiceChat_ForwardTooltip_ManyChats(peerName, "\(peers.count - 1)").string
                                } else {
                                    text = ""
                                }
                                
                                strongSelf.controller?.present(UndoOverlayController(presentationData: presentationData, content: .forward(savedMessages: isSavedMessages, text: text), elevatedLayout: false, animateInAsReplacement: true, action: { _ in return false }), in: .current)
                            }
                        })
                    }
                }
                shareController.actionCompleted = {
                    if let strongSelf = self {
                        let presentationData = strongSelf.context.sharedContext.currentPresentationData.with { $0 }
                        strongSelf.controller?.present(UndoOverlayController(presentationData: presentationData, content: .linkCopied(text: presentationData.strings.VoiceChat_InviteLinkCopiedText), elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .window(.root))
                    }
                }
                strongSelf.controller?.present(shareController, in: .window(.root))
            }
        })
    }
}
