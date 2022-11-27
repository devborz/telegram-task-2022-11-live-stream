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

final public class MediaStreamTitleView: UIView {
    
    public enum LiveState {
        case on, off
        
        var color: UIColor {
            switch self {
            case .on:
                return UIColor(hexString: "F02D52")!
            case .off:
                return UIColor(hexString: "979898")!
            }
        }
    }
    
    public var title: String? {
        didSet {
            self.titleLabel.text = title
            self.layout()
        }
    }
    
    public var liveState: LiveState {
        return _liveState
    }
    
    private var _liveState: LiveState
    
    let titleLabel = UILabel()
    
    let liveLabel = UILabel()
    
    init(title: String, liveState: LiveState) {
        self.title = title
        self._liveState = liveState
        super.init(frame: .zero)
        
        self.addSubview(self.titleLabel)
        self.addSubview(self.liveLabel)
        
        self.titleLabel.text = title
        self.titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        self.titleLabel.textColor = .white
        self.titleLabel.textAlignment = .center
        
        self.liveLabel.layer.backgroundColor = liveState.color.cgColor
        self.liveLabel.layer.cornerRadius = 11
        self.liveLabel.clipsToBounds = true
        self.liveLabel.textAlignment = .center
        self.liveLabel.text = "LIVE"
        self.liveLabel.font = .systemFont(ofSize: 11, weight: .bold)
        self.liveLabel.textColor = .white
    }
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        self.layout()
    }
    
    private func layout() {
        let width = self.frame.width
        self.titleLabel.sizeToFit()
        let liveWidth: CGFloat = 38
        let space: CGFloat = 6
        let height: CGFloat = 22
        let titleWidth = min(self.titleLabel.frame.width,
                             width - liveWidth - space)
        let offset = (width - titleWidth - space - liveWidth) / 2
        self.titleLabel.frame = CGRect(x: offset,
                                       y: 6,
                                       width: titleWidth,
                                       height: height)
        self.liveLabel.frame = CGRect(x: width - offset - liveWidth,
                                      y: 6,
                                      width: liveWidth,
                                      height: height)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func setLiveState(_ state: LiveState, animated: Bool = true) {
        guard self._liveState != state else { return }
        self._liveState = state
        if animated {
            let duration: Double = 0.5
            var animations: [CABasicAnimation] = []
            
            let scaleAnimation1 = CABasicAnimation(keyPath: "transform.scale")
            scaleAnimation1.fromValue = 1
            scaleAnimation1.toValue = 1.2
            scaleAnimation1.duration = duration * 0.4
            scaleAnimation1.isRemovedOnCompletion = false
            scaleAnimation1.timingFunction = .init(name: .easeOut)
            animations.append(scaleAnimation1)
            
            let scaleAnimation2 = CABasicAnimation(keyPath: "transform.scale")
            scaleAnimation2.fromValue = 1.2
            scaleAnimation2.toValue = 0.9
            scaleAnimation2.duration = duration * 0.4
            scaleAnimation2.beginTime = duration * 0.4
            scaleAnimation2.isRemovedOnCompletion = false
            animations.append(scaleAnimation2)
            
            let scaleAnimation3 = CABasicAnimation(keyPath: "transform.scale")
            scaleAnimation3.fromValue = 0.9
            scaleAnimation3.toValue = 1
            scaleAnimation3.duration = duration * 0.2
            scaleAnimation3.beginTime = duration  * 0.8
            scaleAnimation3.isRemovedOnCompletion = false
            animations.append(scaleAnimation3)
            
            let colorAnimation = CABasicAnimation(keyPath: "backgroundColor")
            colorAnimation.fromValue = self.liveLabel.layer.backgroundColor
            colorAnimation.toValue = state.color.cgColor
            colorAnimation.duration = duration
            colorAnimation.isRemovedOnCompletion = false
            animations.append(colorAnimation)
            
            let animationsGroup = CAAnimationGroup()
            animationsGroup.animations = animations
            animationsGroup.duration = duration
            animationsGroup.timingFunction = .init(name: .easeOut)
            self.liveLabel.layer.add(animationsGroup, forKey: nil)
        }
        self.liveLabel.layer.backgroundColor = state.color.cgColor
    }
}
