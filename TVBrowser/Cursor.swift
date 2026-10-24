import UIKit

enum Cursor {
    /// 圆点的直径（不含阴影留白）。
    static let diameter: CGFloat = 30
    private static let padding: CGFloat = 8

    /// 圆心在图片里的位置，光标坐标对准这里。
    static var hotspot: CGPoint {
        CGPoint(x: padding + diameter / 2, y: padding + diameter / 2)
    }

    /// 画一个白色实心、深色描边、带柔和阴影的圆点，深色和浅色网页上都看得清。
    static func makeImage() -> UIImage {
        let side = diameter + padding * 2
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            let rect = CGRect(x: padding, y: padding, width: diameter, height: diameter)
            let cg = ctx.cgContext
            cg.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: UIColor.black.withAlphaComponent(0.55).cgColor)
            UIColor.white.withAlphaComponent(0.95).setFill()
            cg.fillEllipse(in: rect)
            cg.setShadow(offset: .zero, blur: 0, color: nil)
            UIColor(white: 0.1, alpha: 0.85).setStroke()
            cg.setLineWidth(3)
            cg.strokeEllipse(in: rect.insetBy(dx: 1.5, dy: 1.5))
        }
    }
}

/// 根视图设为可获得焦点，这样遥控器的按键事件才会送到我们的界面。
final class RemoteInputView: UIView {
    override var canBecomeFocused: Bool { true }
}

/// 屏幕下方短暂出现的提示。
final class ToastView: UIView {
    private let label = UILabel()
    private var hideWork: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.1, alpha: 0.92)
        layer.cornerRadius = 22
        layer.borderColor = UIColor(white: 1, alpha: 0.15).cgColor
        layer.borderWidth = 2
        label.font = .systemFont(ofSize: 30, weight: .medium)
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        addSubview(label)
        alpha = 0
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ text: String, in container: CGRect, duration: TimeInterval) {
        label.text = text
        let maxWidth = min(container.width - 240, 1400)
        let textSize = label.sizeThatFits(CGSize(width: maxWidth - 64, height: .greatestFiniteMagnitude))
        let size = CGSize(width: ceil(textSize.width) + 64, height: ceil(textSize.height) + 36)
        frame = CGRect(x: container.midX - size.width / 2, y: container.maxY - size.height - 90,
                       width: size.width, height: size.height)
        label.frame = bounds.insetBy(dx: 32, dy: 18)
        superview?.bringSubviewToFront(self)
        hideWork?.cancel()
        UIView.animate(withDuration: 0.2) { self.alpha = 1 }
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.3) { self?.alpha = 0 }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
