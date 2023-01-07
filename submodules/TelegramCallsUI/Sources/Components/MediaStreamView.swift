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

final class MediaStreamView: UIView {
    
    private let call: PresentationGroupCall
    
    let avatarNode: AvatarNode
    let blurView: UIVisualEffectView
    let blurTintView: UIView
    
    private var videoRenderingContext: VideoRenderingContext
    var videoView: VideoRenderingView? = nil
    let streamPreviewImageView: UIImageView
    var blurVideoView: VideoRenderingView? = nil
    
    weak var container: MediaStreamNode?
    
    init(call: PresentationGroupCall) {
        self.call = call
        self.avatarNode = AvatarNode(font: avatarPlaceholderFont(size: 42.0))
        self.streamPreviewImageView = UIImageView()
        self.videoRenderingContext = VideoRenderingContext()
        if #available(iOS 13, *) {
            self.blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
            
        } else {
            self.blurView = UIVisualEffectView(effect: UIBlurEffect(style: .prominent))
        }
        self.blurTintView = UIView()
        super.init(frame: .zero)
        self.setupViews()
    }
    
    func setupViews() {
        self.addSubview(self.blurTintView)
        self.addSubnode(self.avatarNode)
        self.addSubview(self.streamPreviewImageView)
        self.addSubview(self.blurView)
        
        self.avatarNode.imageNode.contentMode = .scaleAspectFill
        self.streamPreviewImageView.contentMode = .scaleAspectFill
        self.streamPreviewImageView.isHidden = true
        
        self.blurTintView.backgroundColor = UIColor(white: 0.0, alpha: 0.55)
        
        self.avatarNode.imageNode.contentMode = .scaleAspectFill
        
        self.layer.cornerRadius = 10
        self.clipsToBounds = true
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        self.blurTintView.frame = self.bounds
        self.avatarNode.frame = self.bounds
        self.streamPreviewImageView.frame = self.bounds
        self.blurView.frame = self.bounds
        self.blurVideoView?.frame = self.bounds
        self.videoView?.frame = self.bounds
        if let videoView = self.videoView {
            var aspect = videoView.getAspect()
            if aspect <= 0.01 {
                aspect = 3.0 / 4.0
            }
            let availableSize = self.frame.size
            let height = availableSize.height
            let videoSize = CGSize(width: aspect * height,
                                   height: height).aspectFitted(availableSize)
            
            videoView.frame.size = videoSize
            videoView.center = .init(x: availableSize.width / 2,
                                     y: availableSize.height / 2)
        }
    }
    
    func setupVideo() {
        if self.videoView == nil {
            if let input = (self.call as! PresentationGroupCallImpl).video(endpointId: "unified") {
                self.container?.lastFrameDisposable = input.start(next: { [weak self] data in
                    self?.container?.lastFrameData = data
                })
                if let blurVideoView = self.videoRenderingContext
                    .makeView(input: input, blur: true, forceSampleBufferDisplayLayer: true) {
                    self.blurVideoView = blurVideoView
                    
                    self.insertSubview(blurVideoView,
                                       belowSubview: self.blurTintView)
                    blurVideoView.clipsToBounds = true
                    blurVideoView.frame = self.bounds
                }
                if let backgroundVideoView = self.videoRenderingContext
                    .makeView(input: input, blur: true, forceSampleBufferDisplayLayer: true) {
                    self.container?.streamBackgroundView.videoView = backgroundVideoView
                }
                if let videoView = self.videoRenderingContext
                    .makeView(input: input, blur: false, forceSampleBufferDisplayLayer: true) {
                    self.videoView = videoView
                    
                    self.insertSubview(videoView,
                                       belowSubview: self.avatarNode.view)
                    videoView.clipsToBounds = true
                    videoView.frame = self.bounds
        
                    if let sampleBufferVideoView = videoView as? SampleBufferVideoRenderingView {
                        if #available(iOS 13.0, *) {
                            sampleBufferVideoView.sampleBufferLayer.preventsDisplaySleepDuringVideoPlayback = true
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
                            
                            pictureInPictureController.delegate = container?.controller
                            pictureInPictureController.canStartPictureInPictureAutomaticallyFromInline = true
                            pictureInPictureController.requiresLinearPlayback = true
                            
                            self.container?.controller?.pictureInPictureController = pictureInPictureController
                        }
                    }
                    videoView.setOnFirstFrameReceived { [weak self] _ in
                        guard let strongSelf = self else {
                            return
                        }

                        if !(strongSelf.container?.streamIsLive ?? false) {
                            strongSelf.container?.setLive(true, animated: true)
                        }
                    }
                }
            }
            self.container?.updateVideos()
        }
        if let videoView = self.videoView {
            
            var aspect = videoView.getAspect()
            if aspect <= 0.01 {
                aspect = 3.0 / 4.0
            }
            let availableSize = self.frame.size
            let height = availableSize.height
            let videoSize = CGSize(width: aspect * height,
                                   height: height).aspectFitted(availableSize)
            
            videoView.frame.size = videoSize
            videoView.center = .init(x: availableSize.width / 2,
                                     y: availableSize.height / 2)
            
            
        } else if !self.call.hasVideo {
            if (self.container?.streamIsLive ?? false) {
                self.container?.setLive(false, animated: true)
            }
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
