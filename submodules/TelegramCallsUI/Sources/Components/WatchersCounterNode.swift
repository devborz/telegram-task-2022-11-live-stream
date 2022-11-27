//
//  WatchersCounterNode.swift
//  _idx_TelegramCallsUI_25F0283C_ios_min11.0
//
//  Created by Усман Туркаев on 27.11.2022.
//

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

private let purple = UIColor(rgb: 0x3252ef)
private let pink = UIColor(rgb: 0xef436c)

private let latePurple = UIColor(rgb: 0x974aa9)
private let latePink = UIColor(rgb: 0xf0436c)

public class WatchersCounterNode: ASDisplayNode {
    
    private let counterNode = ImmediateAnimatedCountLabelNode()
    private let foregroundView = UIView()
    private let foregroundGradientLayer = CAGradientLayer()
    private let maskView = UIView()
    
    private let hierarchyTrackingNode: HierarchyTrackingNode
    private var isCurrentlyInHierarchy = false
    
    override init() {
        var updateInHierarchy: ((Bool) -> Void)?
        self.hierarchyTrackingNode = HierarchyTrackingNode({ value in
            updateInHierarchy?(value)
        })
        super.init()
        self.addSubnode(self.hierarchyTrackingNode)
        
        self.foregroundGradientLayer.type = .radial
        self.foregroundGradientLayer.colors = [pink.cgColor, purple.cgColor, purple.cgColor]
        self.foregroundGradientLayer.locations = [0.0, 0.85, 1.0]
        self.foregroundGradientLayer.startPoint = CGPoint(x: 1.0, y: 1.0)
        self.foregroundGradientLayer.endPoint = CGPoint(x: 0.0, y: 0.0)
        
        self.foregroundView.mask = self.maskView
        self.foregroundView.layer.addSublayer(self.foregroundGradientLayer)
        self.view.addSubview(self.foregroundView)
        self.maskView.addSubnode(self.counterNode)
        
        updateInHierarchy = { [weak self] value in
            if let strongSelf = self {
                strongSelf.isCurrentlyInHierarchy = value
                strongSelf.updateAnimations()
            }
        }
    }
    
    func updateLayout(_ frame: CGRect) {
        self.frame = frame
        self.foregroundView.frame = .init(origin: .zero,
                                          size: self.frame.size)
        let gradientFrame = CGRect(x: 0, y: -70, width: frame.width, height: 200)
        self.foregroundGradientLayer.frame = gradientFrame
        self.updateCounterLayout(animated: false)
    }
    
    private func updateCounterLayout(animated: Bool) {
        let size = self.counterNode
            .updateLayout(size: self.frame.size,
                          animated: animated)
        
        let width = self.frame.width
        let counterNodeOffset = max((width - size.width) / 2, 0)
        let frame = CGRect(x: counterNodeOffset,
                           y: 0,
                           width: width - 2 * counterNodeOffset,
                           height: 60)
        self.counterNode.frame = frame
    }
    
    func update(_ count: Int, animated: Bool) {
        let font: UIFont = Font.with(size: 50.0, design: .round,
                                     weight: .semibold, traits: [.monospacedNumbers])
        let textColor: UIColor = .white
        var segments: [AnimatedCountLabelNode.Segment] = [
        ]
        var count = count
        var textCount = 0
        while count > 0  {
            if segments.count > 0 && segments.count % 3 == 0 {
                segments.append(.text(textCount, .init(string: ",", font: font,
                                                       textColor: textColor)))
                textCount += 1
            }
            let remainder = count % 10
            segments.append(.number(remainder, .init(string: "\(remainder)",
                                                     font: font,
                                                     textColor: textColor)))
            count /= 10
        }
        self.counterNode.segments = segments.reversed()
        self.updateCounterLayout(animated: animated)
    }
    
    private func updateAnimations() {
        if self.isInHierarchy {
            self.setupGradientAnimations()
        } else {
            self.foregroundGradientLayer.removeAllAnimations()
        }
    }
    
    private func setupGradientAnimations() {
        if let _ = self.foregroundGradientLayer.animation(forKey: "movement") {
        } else {
            let previousValue = self.foregroundGradientLayer.startPoint
            let newValue = CGPoint(x: CGFloat.random(in: 0.65 ..< 0.85),
                                   y: CGFloat.random(in: 0.65 ..< 0.85))
            self.foregroundGradientLayer.startPoint = newValue
            
            CATransaction.begin()
            
            let animation = CABasicAnimation(keyPath: "startPoint")
            animation.duration = Double.random(in: 0.8 ..< 1.4)
            animation.fromValue = previousValue
            animation.toValue = newValue
            
            CATransaction.setCompletionBlock { [weak self] in
                if let isCurrentlyInHierarchy = self?.isCurrentlyInHierarchy, isCurrentlyInHierarchy {
                    self?.setupGradientAnimations()
                }
            }
            
            self.foregroundGradientLayer.add(animation, forKey: "movement")
            CATransaction.commit()
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
