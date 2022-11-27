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
import LibYuvBinding

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
    
    let backgroundNode: ASDisplayNode
    let dimNode: ASDisplayNode
    let contentContainer: ASDisplayNode
    let contentContainerBackgroundNode: ASDisplayNode
    let titleView: MediaStreamTitleView
    let optionsButton: MediaStreamButton
    let pictureInPictureButton: MediaStreamButton
    let watchersCounterNode: WatchersCounterNode
    let watchingLabel: UILabel
    let buttonsStackView: UIStackView
    let shareButton: MediaStreamButton
    let leaveButton: MediaStreamButton
    let expandButton: MediaStreamButton
    let labelsStackView: UIStackView
    let shareLabel: UILabel
    let expandLabel: UILabel
    let leaveLabel: UILabel
    
    let avatarNode: AvatarNode
    let blurView: UIVisualEffectView
    let blurTintView: UIView
    let streamContainerView = UIView()
    
    private var videoRenderingContext: VideoRenderingContext
    var videoView: VideoRenderingView? = nil
    var blurVideoView: VideoRenderingView? = nil
        
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
    private var lastFrameDisposable: Disposable?
    private let leaveDisposable = MetaDisposable()
    
    var isPictureInPictureSupported: Bool = false {
        didSet {
            let alpha: CGFloat = isPictureInPictureSupported ? 1.0 : 0.0
            UIView.animate(withDuration: 0.3) {
                self.pictureInPictureButton.alpha = alpha
            }
        }
    }
    
    private var presentationData: PresentationData
    private var streamIsLive: Bool = false
    
    static var streamsPreviews: [Int64 : UIImage] = [:]
    let streamPreviewImageView: UIImageView
    private var streamPreviewImage: UIImage?
    
    var lastFrameData: OngoingGroupCallContext.VideoFrameData?
    
    init(controller: MediaStreamController,
         sharedContext: SharedAccountContext,
         call: PresentationGroupCall) {
        self.controller = controller
        self.sharedContext = sharedContext
        self.context = call.accountContext
        self.call = call
        self.backgroundNode = ASDisplayNode()
        self.dimNode = ASDisplayNode()
        self.contentContainer = ASDisplayNode()
        self.contentContainerBackgroundNode = ASDisplayNode()
        self.optionsButton = MediaStreamButton()
        self.pictureInPictureButton = MediaStreamButton()
        self.watchersCounterNode = WatchersCounterNode()
        self.watchingLabel = UILabel()
        self.shareButton = MediaStreamButton()
        self.expandButton = MediaStreamButton()
        self.leaveButton = MediaStreamButton()
        self.avatarNode = AvatarNode(font: avatarPlaceholderFont(size: 42.0))
        self.streamPreviewImageView = UIImageView()
        self.videoRenderingContext = VideoRenderingContext()
        self.titleView = MediaStreamTitleView(title: "",
                                              liveState: .off)
        self.buttonsStackView = UIStackView()
        self.shareLabel = UILabel()
        self.expandLabel = UILabel()
        self.leaveLabel = UILabel()
        self.labelsStackView = UIStackView()
        if #available(iOS 13, *) {
            self.blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
            
        } else {
            self.blurView = UIVisualEffectView(effect: UIBlurEffect(style: .prominent))
        }
        
        self.blurTintView = UIView()
        
        self.blurTintView.alpha = 0.5
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
    }
    
    func saveLastFrame() {
        guard let lastFrameData,
              let image = videoFrameToImage(lastFrameData) else { return }
        print(image)
        let key = self.call.peerId.id._internalGetInt64Value()
        MediaStreamNode.streamsPreviews[key] = image
    }
    
    func setupData() {
        if #available(iOSApplicationExtension 15.0, iOS 15.0, *), AVPictureInPictureController.isPictureInPictureSupported() {
            self.isPictureInPictureSupported = true
        } else {
            self.isPictureInPictureSupported = false
        }
        
        self.membersDisposable = (self.call.members |> deliverOnMainQueue).start(next: { [weak self] members in
            guard let strongSelf = self, let members else { return }
            self?.watchersCounterNode.update(members.totalCount, animated: true)
            if !strongSelf.didSetDataReady {
                strongSelf.didSetDataReady = true
                strongSelf.controller?.dataReady.set(true)
            }
        })
        
        self.presentationDataDisposable = (self.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] state in
            self?.presentationData = state
        })
        
        self.callStateDisposable = (self.call.state |> deliverOnMainQueue).start(next: { [weak self] state in
            self?.callState = state
            self?.update()
        })
        
        self.callSummaryStateDisposable = (self.call.summaryState |> deliverOnMainQueue).start(next: { [weak self] state in
            self?.callSummaryState = state
            self?.update()
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
                let size = CGSize(width: strongSelf.avatarNode.frame.size.width,
                                  height: strongSelf.avatarNode.frame.size.width)
                let viewHeight = strongSelf.avatarNode.frame.size.height
                strongSelf.avatarNode.font = avatarPlaceholderFont(size: floor(viewHeight * 16.0 / 37.0))
                strongSelf.avatarNode.setPeer(context: strongSelf.call.accountContext,
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
    
    func update() {
        if self.videoView == nil {
            if let input = (self.call as! PresentationGroupCallImpl).video(endpointId: "unified") {
                self.lastFrameDisposable = input.start(next: { [weak self] data in
                    self?.lastFrameData = data
                })
                if let blurVideoView = self.videoRenderingContext
                    .makeView(input: input, blur: true, forceSampleBufferDisplayLayer: true) {
                    self.blurVideoView = blurVideoView
                    
                    self.streamContainerView.insertSubview(blurVideoView,
                                                           belowSubview: self.blurTintView)
                    blurVideoView.layer.cornerRadius = 10
                    blurVideoView.clipsToBounds = true
                    blurVideoView.frame = self.streamContainerView.bounds
                }
                if let videoView = self.videoRenderingContext
                    .makeView(input: input, blur: false, forceSampleBufferDisplayLayer: true) {
                    self.videoView = videoView
                    
                    self.streamContainerView.insertSubview(videoView,
                                                           belowSubview: self.avatarNode.view)
                    videoView.layer.cornerRadius = 10
                    videoView.clipsToBounds = true
                    videoView.frame = self.avatarNode.frame
        
                    if let sampleBufferVideoView = videoView as? SampleBufferVideoRenderingView {
                        if #available(iOS 13.0, *) {
                            sampleBufferVideoView.sampleBufferLayer.preventsDisplaySleepDuringVideoPlayback = true
                            print(sampleBufferVideoView.sampleBufferLayer.preventsCapture)
                            sampleBufferVideoView.sampleBufferLayer.preventsCapture = false
                        }
                        
                        if #available(iOSApplicationExtension 15.0, iOS 15.0, *), AVPictureInPictureController.isPictureInPictureSupported() {
                            final class PlaybackDelegateImpl: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
                                func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
                                    
                                }

                                func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
                                    return CMTimeRange(start: .zero, duration: .positiveInfinity)
                                }

                                func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
                                    return false
                                }

                                func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
                                }

                                func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
                                    completionHandler()
                                }

                                public func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
                                    return false
                                }
                            }
                            let pictureInPictureController = AVPictureInPictureController(contentSource: AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: sampleBufferVideoView.sampleBufferLayer, playbackDelegate: PlaybackDelegateImpl()))
                            
                            pictureInPictureController.delegate = controller
                            pictureInPictureController.canStartPictureInPictureAutomaticallyFromInline = true
                            pictureInPictureController.requiresLinearPlayback = true
                            
                            self.controller?.pictureInPictureController = pictureInPictureController
                        }
                    }
                    videoView.setOnFirstFrameReceived { [weak self] _ in
                        guard let strongSelf = self else {
                            return
                        }

                        if !strongSelf.streamIsLive {
                            strongSelf.setLive(true, animated: true)
                        }
                    }
                }
            }
        }
        if let videoView = self.videoView {
            var isVideoVisible = self.isVisible
            if let pictureInPictureController = self.controller?.pictureInPictureController {
                if pictureInPictureController.isPictureInPictureActive {
                    isVideoVisible = true
                }
            }
            
            videoView.updateIsEnabled(isVideoVisible)
            
            var aspect = videoView.getAspect()
            if aspect <= 0.01 {
                aspect = 3.0 / 4.0
            }
            let availableSize = self.streamContainerView.frame.size
            let height = availableSize.height
            let videoSize = CGSize(width: aspect * height,
                                   height: height).aspectFitted(availableSize)
            
            videoView.frame.size = videoSize
            videoView.center = .init(x: availableSize.width / 2,
                                     y: availableSize.height / 2)
            
        } else if !self.call.hasVideo {
            if self.streamIsLive {
                self.setLive(false, animated: true)
            }
        }
    }
    
    func setLive(_ live: Bool, animated: Bool) {
        self.streamIsLive = live
        self.titleView.setLiveState(live ? .on : .off, animated: animated)
        if live {
            self.avatarNode.isHidden = true
            self.streamPreviewImageView.isHidden = true
        } else {
            if let image = self.streamPreviewImage {
                self.streamPreviewImageView.image = image
                self.streamPreviewImageView.isHidden = false
                self.avatarNode.isHidden = true
            } else {
                self.streamPreviewImageView.isHidden = true
                self.avatarNode.isHidden = false
            }
        }
        UIView.animate(withDuration: animated ? 0.5 : 0.0) {
            self.blurView.alpha = live ? 0.0 : 1.0
        }
    }
    
    func setupViews() {
        self.addSubnode(self.dimNode)
        self.dimNode.backgroundColor = .init(white: 0, alpha: 0.4)
        
        self.addSubnode(self.contentContainer)
        self.contentContainer.backgroundColor = .clear
        self.contentContainer.addSubnode(self.contentContainerBackgroundNode)
        self.contentContainer.addSubnode(self.backgroundNode)
        self.contentContainer.isHidden = true
        
        self.backgroundNode.backgroundColor = panelBackgroundColor
        self.backgroundNode.layer.maskedCorners = [.layerMinXMinYCorner,
                                                   .layerMaxXMinYCorner]
        self.backgroundNode.layer.cornerRadius = 10
        self.backgroundNode.layer.masksToBounds = true
        
        self.panGestureRecognizer = UIPanGestureRecognizer(target: self,
                                                           action: #selector(handlePanGesture))
        self.tapGestureRecognizer = UITapGestureRecognizer(target: self,
                                                           action: #selector(handleTapGesture))
        self.view.addGestureRecognizer(self.panGestureRecognizer!)
        self.contentContainerBackgroundNode.view
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
        
        let backgroundView = self.backgroundNode.view
        
        backgroundView.addSubview(self.streamContainerView)
        self.streamContainerView.addSubview(self.blurTintView)
        self.streamContainerView.addSubnode(self.avatarNode)
        self.streamContainerView.addSubview(self.streamPreviewImageView)
        self.streamContainerView.addSubview(self.blurView)
        
        self.backgroundNode.addSubnode(self.watchersCounterNode)
        
        backgroundView.addSubview(self.optionsButton)
        backgroundView.addSubview(self.pictureInPictureButton)
        backgroundView.addSubview(self.titleView)
        backgroundView.addSubview(self.watchingLabel)
        backgroundView.addSubview(self.buttonsStackView)
        backgroundView.addSubview(self.labelsStackView)
    
        self.avatarNode.imageNode.contentMode = .scaleAspectFill

//        self.streamPreviewImageNode.layer.shadowColor = UIColor(white: 0.7,
//                                                                alpha: 0.7).cgColor
//        self.streamPreviewImageNode.layer.shadowOpacity = 0.2
//        self.streamPreviewImageNode.layer.shadowOffset = CGSize(width: 0,
//                                                                height: 10)
//        self.streamPreviewImageNode.layer.shadowRadius = 30
        self.streamPreviewImageView.contentMode = .scaleAspectFill
        self.streamPreviewImageView.isHidden = true
        

        self.blurTintView.backgroundColor = UIColor(white: 0.0, alpha: 0.55)
        
        self.streamContainerView.layer.cornerRadius = 10
        self.streamContainerView.clipsToBounds = true
        
        self.watchersCounterNode.update(0, animated: false)
        
        self.watchingLabel.text = "watching"
        self.watchingLabel.textColor = .white
        self.watchingLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        self.watchingLabel.textAlignment = .center
        
        let bottomButtonsSize = CGSize(width: 60, height: 60)
        self.shareButton.setup(image: shareImage,
                               color: UIColor(hexString: "2A2C5B"),
                               action: self.handleShareTapped)
        self.shareButton.frame.size = bottomButtonsSize
        self.shareButton.layer.cornerRadius = bottomButtonsSize.width / 2
        self.shareButton.clipsToBounds = true
        self.shareButton.setTitleColor(.white, for: .normal)
        self.expandButton.setup(image: expandImage,
                                color: UIColor(hexString: "392948"),
                                action: self.handleExpandTapped)
        self.expandButton.frame.size = bottomButtonsSize
        self.expandButton.layer.cornerRadius = bottomButtonsSize.width / 2
        self.expandButton.clipsToBounds = true
        self.expandButton.setTitleColor(.white, for: .normal)
        self.leaveButton.setup(image: leaveImage,
                               color: UIColor(hexString: "502932"),
                               action: self.handleLeaveTapped)
        self.leaveButton.frame.size = bottomButtonsSize
        self.leaveButton.layer.cornerRadius = bottomButtonsSize.width / 2
        self.leaveButton.clipsToBounds = true
        self.leaveButton.setTitleColor(.white, for: .normal)
        
        self.buttonsStackView.axis = .horizontal
        self.buttonsStackView.distribution = .fillEqually
        self.buttonsStackView.addArrangedSubview(self.shareButton)
        self.buttonsStackView.addArrangedSubview(self.expandButton)
        self.buttonsStackView.addArrangedSubview(self.leaveButton)
        
        self.shareLabel.text = "share"
        self.shareLabel.textColor = .white
        self.shareLabel.font = .systemFont(ofSize: 14)
        self.shareLabel.textAlignment = .center
        
        self.expandLabel.text = "expand"
        self.expandLabel.textColor = .white
        self.expandLabel.font = .systemFont(ofSize: 14)
        self.expandLabel.textAlignment = .center
        
        self.leaveLabel.text = "leave"
        self.leaveLabel.textColor = .white
        self.leaveLabel.font = .systemFont(ofSize: 14)
        self.leaveLabel.textAlignment = .center
        
        self.labelsStackView.axis = .horizontal
        self.labelsStackView.distribution = .fillEqually
        
        self.labelsStackView.addArrangedSubview(self.shareLabel)
        self.labelsStackView.addArrangedSubview(self.expandLabel)
        self.labelsStackView.addArrangedSubview(self.leaveLabel)
    }
    
    func layoutViews() {
        guard let (layout, _) = self.validLayout else {
            return
        }
        let width = layout.size.width
        
        self.optionsButton.frame = CGRect(x: 20, y: 12,
                                          width: 34, height: 34)
        self.pictureInPictureButton.frame = CGRect(x: width - 54, y: 12,
                                                   width: 34, height: 34)
        self.titleView.frame = CGRect(x: 64, y: 12,
                                      width: width - 128, height: 34)
        
        let streamViewSize: CGSize = CGSize(width: width - 32,
                                            height: (width - 32) / 16 * 9)
        
        self.streamContainerView.frame = CGRect(x: 16,
                                                y: self.titleView.frame.maxY + 10,
                                                width: streamViewSize.width,
                                                height: streamViewSize.height)
        self.avatarNode.frame = CGRect(origin: .zero, size: streamViewSize)
        self.streamPreviewImageView.frame = CGRect(origin: .zero, size: streamViewSize)
        self.blurView.frame = CGRect(origin: .zero, size: streamViewSize)
        self.blurTintView.frame = CGRect(origin: .zero, size: streamViewSize)
    
        self.watchersCounterNode.updateLayout(CGRect(x: 0,
                                                y: self.streamContainerView.frame.maxY + 35,
                                                width: width,
                                                height: 60))
        
        self.watchingLabel.frame = CGRect(x: 0,
                                          y: self.watchersCounterNode.frame.maxY + 2,
                                          width: width,
                                          height: 18)
        
        let buttonsSpace = (width - 3 * 60) / 4
        self.buttonsStackView.frame = CGRect(x: buttonsSpace,
                                             y: self.watchingLabel.frame.maxY + 35,
                                             width: width - 2 * buttonsSpace,
                                             height: 60)
        
        self.labelsStackView.frame = CGRect(x: buttonsSpace,
                                            y: self.watchingLabel.frame.maxY + 97,
                                            width: width - 2 * buttonsSpace,
                                            height: 18)
        self.buttonsStackView.spacing = buttonsSpace
        self.labelsStackView.spacing = buttonsSpace
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
        height += bottomHeight()
        return height
    }
    
    private func bottomHeight() -> CGFloat {
        guard let window = UIApplication.shared.windows.first else { return 0 }
        return window.safeAreaInsets.bottom
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
        self.contentContainer.bounds = initialBounds
            .offsetBy(dx: 0, dy: -size.height)
        self.contentContainer.isHidden = false
        
        let transition = ContainedViewLayoutTransition.animated(duration: 0.4,
                                                                curve: .spring)
        transition.animateView({
            self.contentContainer.view.bounds = initialBounds
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
            self.contentContainer.view.bounds = initialBounds.offsetBy(dx: 0,
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
        let frame: CGRect = .init(origin: .zero,
                                  size: layout.size)
        self.dimNode.frame = frame
        self.contentContainer.frame = frame
        self.contentContainerBackgroundNode.frame = frame
        let backgroundHeight = calculateBackgroundHeight(frame.width)
        self.backgroundNode.frame = CGRect(x: 0,
                                           y: frame.height - backgroundHeight,
                                           width: frame.width,
                                           height: backgroundHeight)
        
        if isFirstTime {
            self.controller?.contentsReady.set(true)
        }
        layoutViews()
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
            self.initialContentViewYOrigin = self.contentContainer.frame.minY
        case .changed:
            let translation = recognizer.translation(in: self.view)
            let y = max(0, self.initialContentViewYOrigin + translation.y)
            self.contentContainer.frame.origin.y = y
        case .ended:
            let translation = recognizer.translation(in: self.view)
            let velocity = recognizer.velocity(in: self.view)
            if translation.y >= 150 || velocity.y >= 300 {
                controller?.dismiss(closing: false, manual: true)
            } else {
                let bounds = CGRect(origin: .zero,
                                    size: self.contentContainer.frame.size)
                let transition = ContainedViewLayoutTransition.animated(duration: 0.4, curve: .spring)
                transition.animateView({
                    self.contentContainer.frame = bounds
                }, completion: { _ in
                    
                    self.controller?.currentOverlayController?.dismiss()
                    self.controller?.currentOverlayController = nil
                })
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
        self.controller?.dismissAllTooltips()
        
        self.leaveDisposable.set((self.call.leave(terminateIfPossible: false)
        |> deliverOnMainQueue).start(completed: { [weak self] in
            self?.controller?.dismiss(closing: true)
        }))
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
