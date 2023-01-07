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

public class StreamButton: UIButton {
    
    fileprivate var image: UIImage?
    
    fileprivate var actionBlock: (() -> Void)?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addTarget(self, action: #selector(handleTap),
                       for: .touchUpInside)
        imageView?.contentMode = .center
        tintColor = .white
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func setup(image: UIImage?,
               color: UIColor?,
               action: (() -> Void)?) {
        self.image = image
        self.backgroundColor = color
        self.actionBlock = action
        self.setImage(image, for: .normal)
    }
    
    @objc
    private func handleTap() {
        actionBlock?()
    }
    
}

public class MediaStreamButton: StreamButton {
    
    public override var isHighlighted: Bool {
        didSet {
            if oldValue != isHighlighted {
                UIView.animate(withDuration: 0.2) {
                    if self.isHighlighted {
                        self.transform = self.transform.scaledBy(x: 0.8, y: 0.8)
                    } else {
                        self.transform = .identity
                    }
                }
            }
        }
    }
}

public class MediaStreamLargeButton: UIView {
    
    class Button: StreamButton {
        
        override var isHighlighted: Bool {
            didSet {
                if oldValue != isHighlighted {
                    self.onHighlightedChanged?(self.isHighlighted)
                }
            }
        }
        
        var onHighlightedChanged: ((Bool) -> Void)?
    }
    
    private let button = Button()
    
    private let nameLabel = UILabel()
    
    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        self.button.onHighlightedChanged = { [weak self] isHighlighted in
            guard let strongSelf = self else { return }
            UIView.animate(withDuration: 0.2) {
                if isHighlighted {
                    strongSelf.transform = strongSelf.transform.scaledBy(x: 0.8, y: 0.8)
                } else {
                    strongSelf.transform = .identity
                }
            }
        }
        self.nameLabel.textAlignment = .center
        self.nameLabel.textColor = .white
        self.nameLabel.font = .systemFont(ofSize: 14)
        self.nameLabel.textAlignment = .center
        self.button.setTitleColor(.white, for: .normal)
    }
    
    func setup(title: String?,
               image: UIImage?,
               color: UIColor?,
               action: (() -> Void)?) {
        self.button.setup(image: image,
                          color: color,
                          action: action)
        self.nameLabel.text = title
        self.addSubview(self.button)
        self.addSubview(self.nameLabel)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        let size = self.frame.width
        self.button.frame = CGRect(x: 0, y: 0,
                                   width: size,
                                   height: size)
        self.nameLabel.frame = CGRect(x: 0, y: size + 2,
                                      width: size,
                                      height: 18)
        self.button.layer.cornerRadius = size / 2
        self.button.clipsToBounds = true
    }
    
    
}
