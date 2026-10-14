import SwiftUI
import UIKit

/// A picked photo on its way to becoming an avatar.
struct AloAvatarCropRequest: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Photo preparation for profile and group avatars.
enum AloAvatarImage {
    /// Decodes a picked photo off the main thread, upright and at most `maxSide` pixels, so the
    /// cropper never holds a full-size camera bitmap.
    static func decoded(from data: Data, maxSide: CGFloat = 2048) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
            let scale = min(1, maxSide / max(image.size.width, image.size.height))
            let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            return UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        }.value
    }

    /// The square under the crop circle as a JPEG, at most `side` pixels.
    static func jpeg(cropping image: UIImage, to rect: CGRect, side: CGFloat = 1024) -> Data? {
        let rect = rect.intersection(CGRect(origin: .zero, size: image.size))
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let output = max(1, min(side, (rect.width * image.scale).rounded(.down)))
        let scale = output / rect.width
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: output, height: output), format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: output, height: output))
            image.draw(in: CGRect(x: -rect.minX * scale, y: -rect.minY * scale,
                                  width: image.size.width * scale, height: image.size.height * scale))
        }
        return rendered.jpegData(compressionQuality: 0.88)
    }
}

/// Telegram-style avatar crop: the photo moves and zooms under a fixed circle, everything outside
/// it is dimmed. "Выбрать" returns the square under the circle; the avatar is drawn round anyway.
struct AloAvatarCropView: View {
    let onCancel: () -> Void
    let onChoose: (Data) -> Void
    @State private var image: UIImage
    @State private var canvas = AloAvatarCropHandle()

    init(image: UIImage, onCancel: @escaping () -> Void, onChoose: @escaping (Data) -> Void) {
        _image = State(initialValue: image)
        self.onCancel = onCancel
        self.onChoose = onChoose
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            AloAvatarCropCanvas(image: image, handle: canvas)
                .ignoresSafeArea()
                .accessibilityLabel("Фото. Перемещайте и масштабируйте пальцами")
                .accessibilityIdentifier("alo.avatar.crop.canvas")

            HStack {
                Button("Отмена", action: onCancel)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("alo.avatar.crop.cancel")
                Spacer()
                Button {
                    image = image.aloRotatedCounterClockwise()
                } label: {
                    Image(systemName: "rotate.left")
                        .font(.system(size: 20, weight: .regular))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Повернуть")
                .accessibilityIdentifier("alo.avatar.crop.rotate")
                Spacer()
                Button("Выбрать", action: choose)
                    .fontWeight(.semibold)
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    .accessibilityIdentifier("alo.avatar.crop.choose")
            }
            .font(.system(size: 17))
            .foregroundStyle(.white)
            .buttonStyle(AloControlPressStyle())
            .padding(.horizontal, 20)
            .padding(.top, 28)
            // Measured from the screen's bottom edge, so the buttons sit the same 30pt up on every
            // iPhone, with or without a home indicator.
            .padding(.bottom, 30)
            // A zoomed photo runs under the buttons; a soft shade keeps them readable.
            .background(LinearGradient(colors: [.black.opacity(0), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false))
            .frame(maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(edges: .bottom)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func choose() {
        guard let rect = canvas.view?.cropRectInImage,
              let jpeg = AloAvatarImage.jpeg(cropping: image, to: rect) else { return }
        AloHaptics.impact(.light)
        onChoose(jpeg)
    }
}

/// Lets the SwiftUI screen ask the UIKit canvas for the current crop.
final class AloAvatarCropHandle {
    weak var view: AloAvatarCropUIView?
}

private struct AloAvatarCropCanvas: UIViewRepresentable {
    let image: UIImage
    let handle: AloAvatarCropHandle

    func makeUIView(context: Context) -> AloAvatarCropUIView {
        let view = AloAvatarCropUIView()
        view.image = image
        handle.view = view
        return view
    }

    func updateUIView(_ view: AloAvatarCropUIView, context: Context) {
        view.image = image
        handle.view = view
    }
}

final class AloAvatarCropUIView: UIView, UIScrollViewDelegate {
    /// Side margin of the crop circle; the circle is as wide as the screen allows.
    private static let inset: CGFloat = 16
    /// Room kept for the buttons below the circle on short screens.
    private static let bottomBar: CGFloat = 80

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let dimLayer = CAShapeLayer()
    private let ringLayer = CAShapeLayer()
    private var configuredFor: (size: CGSize, image: UIImage)?

    var image: UIImage? {
        didSet {
            guard image !== oldValue else { return }
            imageView.image = image
            configuredFor = nil
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        scrollView.delegate = self
        // The circle is the scroll view's frame, so the photo can never be moved off it;
        // the photo is still drawn, dimmed, around it.
        scrollView.clipsToBounds = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.alwaysBounceVertical = true
        scrollView.bouncesZoom = true
        scrollView.decelerationRate = .fast
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)
        scrollView.addSubview(imageView)

        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = UIColor.black.withAlphaComponent(0.62).cgColor
        layer.addSublayer(dimLayer)
        ringLayer.fillColor = UIColor.clear.cgColor
        ringLayer.strokeColor = UIColor.white.withAlphaComponent(0.35).cgColor
        ringLayer.lineWidth = 1
        layer.addSublayer(ringLayer)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The crop circle's square, centred in the space above the buttons.
    private var cropFrame: CGRect {
        let safe = bounds.inset(by: safeAreaInsets)
        let available = CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: max(0, safe.height - Self.bottomBar))
        let side = max(1, min(available.width - Self.inset * 2, available.height - Self.inset * 2))
        return CGRect(x: available.midX - side / 2, y: available.midY - side / 2, width: side, height: side)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let crop = cropFrame
        if scrollView.frame != crop { scrollView.frame = crop }
        let dim = UIBezierPath(rect: bounds)
        dim.append(UIBezierPath(ovalIn: crop))
        dimLayer.path = dim.cgPath
        ringLayer.path = UIBezierPath(ovalIn: crop.insetBy(dx: 0.5, dy: 0.5)).cgPath
        guard let image, crop.width > 1 else { return }
        if configuredFor?.size != bounds.size || configuredFor?.image !== image {
            configuredFor = (bounds.size, image)
            configure(for: image, side: crop.width)
        }
    }

    /// The photo starts filling the circle, centred, and can zoom up to six times closer.
    private func configure(for image: UIImage, side: CGFloat) {
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 1
        scrollView.zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: image.size)
        scrollView.contentSize = image.size
        let fill = max(side / image.size.width, side / image.size.height)
        scrollView.minimumZoomScale = fill
        scrollView.maximumZoomScale = fill * 6
        scrollView.zoomScale = fill
        scrollView.contentOffset = CGPoint(x: (scrollView.contentSize.width - side) / 2,
                                           y: (scrollView.contentSize.height - side) / 2)
    }

    /// The part of the image under the circle, in image points.
    var cropRectInImage: CGRect {
        scrollView.convert(scrollView.bounds, to: imageView)
    }

    /// Touches anywhere on the screen move the photo, not only inside the circle.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        bounds.contains(point) ? scrollView : nil
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale * 1.05 {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let target = scrollView.minimumZoomScale * 2.5
            let size = CGSize(width: scrollView.bounds.width / target, height: scrollView.bounds.height / target)
            scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
        }
    }
}

extension UIImage {
    /// The same picture turned a quarter turn to the left.
    func aloRotatedCounterClockwise() -> UIImage {
        let rotated = CGSize(width: size.height, height: size.width)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: rotated, format: format).image { context in
            context.cgContext.translateBy(x: 0, y: rotated.height)
            context.cgContext.rotate(by: -.pi / 2)
            draw(at: .zero)
        }
    }
}
