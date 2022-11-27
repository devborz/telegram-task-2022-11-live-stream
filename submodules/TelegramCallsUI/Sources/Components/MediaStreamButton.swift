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

final public class MediaStreamButton: UIButton {
    
    private var image: UIImage?
    
    private var actionBlock: (() -> Void)?
    
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
