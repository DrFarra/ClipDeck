import UIKit

// MARK: - Chip «Pegar» (lo recién copiado)
//
// Una pastilla centrada en la barra de sugerencias, con icono y sin nada más
// al lado: antes era el texto «📋 Pegar» metido como una sugerencia más.

final class PasteChipView: UIView {
    enum Kind { case text, link, image }

    var onTap: ((Kind) -> Void)?

    private(set) var kind: Kind = .text
    private let capsule = UIView()
    private let icon = UIImageView()
    private let label = UILabel()
    private var isDown = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        capsule.isUserInteractionEnabled = false
        addSubview(capsule)
        icon.contentMode = .scaleAspectFit
        capsule.addSubview(icon)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        capsule.addSubview(label)
        isHidden = true
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ kind: Kind) {
        self.kind = kind
        let symbol: String
        let title: String
        switch kind {
        case .text:  symbol = "doc.on.clipboard"; title = "Pegar lo copiado"
        case .link:  symbol = "link";             title = "Pegar enlace"
        case .image: symbol = "photo";            title = "Imagen copiada"
        }
        icon.image = UIImage(systemName: symbol,
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        label.text = title
        accessibilityLabel = title
        isHidden = false
        setNeedsLayout()
    }

    func applyTheme() {
        let theme = KeyStyle.theme
        capsule.backgroundColor = isDown ? theme.letterPressed : theme.letter
        label.textColor = theme.text
        icon.tintColor = theme.accent
        capsule.layer.borderWidth = theme.keyBorder == nil ? 0 : 1
        capsule.layer.borderColor = theme.keyBorder?.resolvedColor(with: traitCollection).cgColor
        capsule.layer.shadowColor = theme.keyShadow?.resolvedColor(with: traitCollection).cgColor
        capsule.layer.shadowOpacity = theme.keyShadow == nil ? 0 : 1
        capsule.layer.shadowRadius = 0
        capsule.layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = min(bounds.height - 10, 34)
        let textW = ceil(label.sizeThatFits(CGSize(width: bounds.width, height: h)).width)
        let w = min(14 + 16 + 7 + textW + 16, bounds.width)
        capsule.frame = CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
        capsule.layer.cornerRadius = h / 2
        icon.frame = CGRect(x: 14, y: (h - 16) / 2, width: 16, height: 16)
        label.frame = CGRect(x: icon.frame.maxX + 7, y: 0, width: max(w - icon.frame.maxX - 7 - 16, 0), height: h)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyTheme()
    }

    // Sólo la pastilla (con algo de margen) responde: el resto de la barra
    // sigue siendo de la barra, que reparte los toques de los extremos.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        !isHidden && capsule.frame.insetBy(dx: -10, dy: -6).contains(point)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        isDown = true
        applyTheme()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let inside = touches.first.map { point(inside: $0.location(in: self), with: event) } ?? false
        release()
        if inside { onTap?(kind) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        release()
    }

    private func release() {
        isDown = false
        applyTheme()
    }
}
