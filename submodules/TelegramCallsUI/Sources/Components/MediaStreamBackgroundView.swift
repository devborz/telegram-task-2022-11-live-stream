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

final class MediaStreamBackgroundView: UIView {
    
    var videoView: VideoRenderingView? {
        didSet {
            oldValue?.removeFromSuperview()
            guard let videoView else { return }
            self.videoContainerView.insertSubview(videoView,
                                                  belowSubview: self.imageView)
            videoView.frame = self.bounds
        }
    }
    
    private let videoContainerView = UIView()
    
    private let imageView = UIImageView()
    
    private let blurView: UIVisualEffectView
    
    private let whiteView = UIView()
    
    override init(frame: CGRect) {
        self.blurView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        super.init(frame: frame)
        self.addSubview(self.videoContainerView)
        self.addSubview(self.blurView)
        self.videoContainerView.addSubview(self.imageView)
        self.videoContainerView.addSubview(self.whiteView)
        self.videoContainerView.frame = self.bounds
        self.imageView.frame = self.bounds
        self.blurView.frame = self.bounds
        self.videoContainerView.layer.cornerRadius = 50
        self.videoContainerView.clipsToBounds = true
        
        self.imageView.contentMode = .scaleAspectFill
        self.imageView.backgroundColor = .clear
        
        self.whiteView.backgroundColor = .white.withAlphaComponent(0.1)
        
        self.setupVideoMask()
        self.setupMask()
    }
    
    func updateFrame(_ frame: CGRect) {
        self.frame = frame
        self.videoContainerView.frame = self.bounds
        self.imageView.frame = self.bounds
        self.blurView.frame = self.bounds
        self.whiteView.frame = self.bounds
        self.videoView?.frame = self.bounds
        self.setupVideoMask()
        self.setupMask()
    }
    
    func setImageViewHidden(_ hidden: Bool) {
        self.imageView.isHidden = hidden
    }
    
    func setImage(_ image: UIImage) {
        self.imageView.image = image
    }
    
    private func setupVideoMask() {
        let layer = CAGradientLayer()
        let frame = self.bounds
        layer.colors = [UIColor.clear.cgColor, UIColor.white.cgColor,
                        UIColor.white.cgColor, UIColor.clear.cgColor]
        var locations: [CGFloat] = []
        locations.append(0.0)
        locations.append(20.0 / frame.width)
        locations.append((frame.width - 20.0) / frame.width)
        locations.append(1.0)
        layer.locations = locations.map { NSNumber(value: $0) }
        layer.type = .axial
        layer.startPoint = CGPoint(x: 0.0, y: 0.0)
        layer.endPoint = CGPoint(x: 1.0, y: 0.0)
        layer.frame = frame
        self.videoContainerView.layer.mask = layer
    }
    
    private func setupMask() {
        let layer = CAGradientLayer()
        let frame = self.bounds
        layer.colors = [UIColor.clear.cgColor,
                        UIColor.clear.cgColor,
                        UIColor.white.cgColor,
                        UIColor.white.cgColor,
                        UIColor.clear.cgColor,
                        UIColor.clear.cgColor]
        var locations: [CGFloat] = []
        locations.append(0.0)
        locations.append(20.0 / frame.height)
        locations.append(80.0 / frame.height)
        locations.append((frame.height - 160.0) / frame.height)
        locations.append((frame.height - 40.0) / frame.height)
        locations.append(1.0)
        layer.locations = locations.map { NSNumber(value: $0) }
        layer.type = .axial
        layer.startPoint = CGPoint(x: 0.0, y: 0.0)
        layer.endPoint = CGPoint(x: 0.0, y: 1.0)
        layer.frame = frame
        self.layer.mask = layer
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
    }
}

private let backgroundCornerRadius: CGFloat = 11.0
private let borderLineWidth: CGFloat = 2.0

class MediaStreamShimmeringNode: ASDisplayNode {
    private let effectNode: ShimmerEffectForegroundNode
    
    private let borderNode: ASDisplayNode
    private var borderMaskView: UIView?
    private let borderEffectNode: ShimmerEffectForegroundNode
    
    private var currentShimmeringColor: UIColor?
    private var currentShimmering: Bool?
    private var currentSize: CGSize?
    
    public override init() {
        
        self.effectNode = ShimmerEffectForegroundNode(size: 400.0)
        
        self.borderNode = ASDisplayNode()
        self.borderEffectNode = ShimmerEffectForegroundNode(size: 320.0)
        
        super.init()
        
        self.clipsToBounds = true
        self.cornerRadius = backgroundCornerRadius
        
        self.addSubnode(self.effectNode)
        self.addSubnode(self.borderNode)
        self.borderNode.addSubnode(self.borderEffectNode)
    }
    
    public override func didLoad() {
        super.didLoad()
        
        if self.effectNode.supernode != nil {
            self.effectNode.layer.compositingFilter = "screenBlendMode"
            self.borderEffectNode.layer.compositingFilter = "screenBlendMode"
            
            let borderMaskView = UIView()
            borderMaskView.layer.borderWidth = 1.0
            borderMaskView.layer.borderColor = UIColor.white.cgColor
            borderMaskView.layer.cornerRadius = backgroundCornerRadius
            self.borderMaskView = borderMaskView
            
            if let size = self.currentSize {
                borderMaskView.frame = CGRect(origin: CGPoint(), size: size)
            }
            self.borderNode.view.mask = borderMaskView
            
            if #available(iOS 13.0, *) {
                borderMaskView.layer.cornerCurve = .continuous
            }
        }
        if #available(iOS 13.0, *) {
            self.layer.cornerCurve = .continuous
        }
    }
    
    public func updateAbsoluteRect(_ rect: CGRect, within containerSize: CGSize) {
        self.effectNode.updateAbsoluteRect(rect, within: containerSize)
        self.borderEffectNode.updateAbsoluteRect(rect, within: containerSize)
    }
    
    public func update(shimmeringColor: UIColor, shimmering: Bool, size: CGSize, transition: ContainedViewLayoutTransition) {
        if let currentShimmeringColor = self.currentShimmeringColor, currentShimmeringColor.isEqual(shimmeringColor) && self.currentSize == size && self.currentShimmering == shimmering {
            return
        }
        
        let firstTime = self.currentShimmering == nil
        self.currentShimmeringColor = shimmeringColor
        self.currentShimmering = shimmering
        self.currentSize = size
        
        let transition: ContainedViewLayoutTransition = firstTime ? .immediate : (transition.isAnimated ? transition : .animated(duration: 0.45, curve: .easeInOut))
        transition.updateAlpha(node: self.effectNode, alpha: shimmering ? 1.0 : 0.0)
        transition.updateAlpha(node: self.borderNode, alpha: shimmering ? 1.0 : 0.0)
        
        let bounds = CGRect(origin: CGPoint(), size: size)
        
        self.effectNode.update(foregroundColor: shimmeringColor.withAlphaComponent(0.3))
        transition.updateFrame(node: self.effectNode, frame: bounds)
        
        self.borderEffectNode.update(foregroundColor: shimmeringColor.withAlphaComponent(0.45))
        transition.updateFrame(node: self.borderEffectNode, frame: bounds)
        transition.updateFrame(node: self.borderNode, frame: bounds)
        if let borderMaskView = self.borderMaskView {
            transition.updateFrame(view: borderMaskView, frame: bounds)
        }
    }
}
