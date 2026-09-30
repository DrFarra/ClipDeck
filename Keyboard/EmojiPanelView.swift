import UIKit
import CoreText

// MARK: - Recientes

enum EmojiStore {
    static let recentsKey = "keyboard.recentEmojis"
    /// Cuatro filas de ocho.
    static let recentsLimit = 32

    static var recents: [String] { UserDefaults.standard.stringArray(forKey: recentsKey) ?? [] }

    static func registerRecent(_ e: String) {
        var l = recents
        l.removeAll { $0 == e }
        l.insert(e, at: 0)
        UserDefaults.standard.set(Array(l.prefix(recentsLimit)), forKey: recentsKey)
    }
}

// MARK: - Qué sabe dibujar este iPhone
//
// El catálogo trae hasta la última versión de Unicode, pero iOS añade los
// emojis nuevos meses después (y un iPhone con iOS 17 no tiene los de 2024).
// Un emoji sin glifo sale como un cuadrado con interrogante, y una secuencia
// que iOS no conoce, como sus piezas sueltas (🧑 + 🩰). Se miden con CoreText
// sólo los recientes: si caen en otra fuente o miden más de un emoji, fuera.

enum EmojiSupport {
    static let unsupported: Set<String> = findUnsupported()

    private static func findUnsupported() -> Set<String> {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 24, nil)
        let reference = measure("😀", font: font)
        // Si la medida no distingue un emoji de dos, no se quita nada: mejor
        // un cuadrado de más que dejar el panel vacío.
        guard reference.fonts.count == 1, reference.width > 0,
              isSingle(measure("👩‍❤️‍👨", font: font), like: reference),
              !isSingle(measure("😀😀", font: font), like: reference) else { return [] }
        var result = Set<String>()
        for emoji in EmojiCatalog.recentAdditions where !isSingle(measure(emoji, font: font), like: reference) {
            result.insert(emoji)
        }
        return result
    }

    private static func isSingle(_ m: (fonts: Set<String>, width: Double),
                                 like reference: (fonts: Set<String>, width: Double)) -> Bool {
        m.fonts == reference.fonts && m.width < reference.width * 1.4
    }

    private static func measure(_ text: String, font: CTFont) -> (fonts: Set<String>, width: Double) {
        let key = NSAttributedString.Key(kCTFontAttributeName as String)
        let attributed = NSAttributedString(string: text, attributes: [key: font])
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        var fonts = Set<String>()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            if let value = attributes[kCTFontAttributeName as String] {
                fonts.insert(CTFontCopyPostScriptName(value as! CTFont) as String)
            }
        }
        return (fonts, CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Las variantes de tono, sólo si iOS sabe dibujarlas todas.
    static func variants(_ list: [String]?) -> [String]? {
        guard let list, !list.contains(where: { unsupported.contains($0) }) else { return nil }
        return list
    }
}

// MARK: - Celdas

final class EmojiCell: UICollectionViewCell {
    let label = UILabel()
    private let highlight = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        highlight.layer.cornerRadius = 10
        highlight.isHidden = true
        contentView.addSubview(highlight)
        label.textAlignment = .center
        contentView.addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = contentView.bounds
        highlight.frame = contentView.bounds.insetBy(dx: 2, dy: 2)
    }

    override var isHighlighted: Bool {
        didSet { highlight.isHidden = !isHighlighted }
    }

    func configure(_ emoji: String, fontSize: CGFloat) {
        label.text = emoji
        if label.font.pointSize != fontSize { label.font = .systemFont(ofSize: fontSize) }
        applyTheme()
    }

    func applyTheme() {
        highlight.backgroundColor = KeyStyle.theme.letterPressed.withAlphaComponent(0.55)
    }
}

final class EmojiHeaderView: UICollectionReusableView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = CGRect(x: 12, y: 0, width: max(bounds.width - 24, 0), height: bounds.height)
    }

    func configure(_ title: String) {
        label.attributedText = NSAttributedString(string: title.uppercased(), attributes: [
            .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
            .kern: 0.6,
            .foregroundColor: KeyStyle.theme.secondaryText
        ])
    }
}

// MARK: - Botones de la barra inferior (toque directo, como las teclas)

final class EmojiBarButton: UIView {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    /// Con fondo de tecla (ABC, borrar); sin él, icono de categoría.
    var isKey = false
    var isSelected = false { didSet { applyTheme() } }

    private let imageView = UIImageView()
    private let label = UILabel()
    private let indicator = UIView()
    private var isDown = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        indicator.isUserInteractionEnabled = false
        addSubview(indicator)
        imageView.contentMode = .center
        addSubview(imageView)
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 15, weight: .medium)
        addSubview(label)
        isMultipleTouchEnabled = false
        isExclusiveTouch = false
    }
    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ names: [String], pointSize: CGFloat = 17) {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        imageView.image = names.lazy.compactMap { UIImage(systemName: $0, withConfiguration: config) }.first
        label.text = nil
    }

    func setTitle(_ title: String) {
        label.text = title
        imageView.image = nil
    }

    func applyTheme() {
        let theme = KeyStyle.theme
        if isKey {
            indicator.backgroundColor = isDown ? theme.functionPressed : theme.function
            indicator.layer.borderWidth = theme.keyBorder == nil ? 0 : 1
            indicator.layer.borderColor = theme.keyBorder?.resolvedColor(with: traitCollection).cgColor
            imageView.tintColor = theme.text
            label.textColor = theme.text
        } else {
            indicator.backgroundColor = isSelected ? theme.function : (isDown ? theme.letterPressed.withAlphaComponent(0.5) : .clear)
            indicator.layer.borderWidth = 0
            imageView.tintColor = isSelected ? theme.text : theme.secondaryText
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        label.frame = bounds
        if isKey {
            indicator.frame = bounds
            indicator.layer.cornerRadius = KeyStyle.theme.cornerRadius
        } else {
            let side = min(bounds.width - 2, bounds.height - 4, 32)
            indicator.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2,
                                     width: side, height: side)
            indicator.layer.cornerRadius = side / 2
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyTheme()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        isDown = true
        applyTheme()
        onDown?()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { release() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { release() }

    private func release() {
        guard isDown else { return }
        isDown = false
        applyTheme()
        onUp?()
    }
}

// MARK: - Pulsación larga sólo donde hay tonos

/// Delegado de la pulsación larga de los tonos. El delegado de un gesto es
/// `weak`, así que lo guarda el panel.
private final class ToneGestureGate: NSObject, UIGestureRecognizerDelegate {
    var shouldBegin: ((UIGestureRecognizer) -> Bool)?

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        shouldBegin?(gestureRecognizer) ?? true
    }
}

// MARK: - Panel de emojis
//
// Todas las categorías en un solo desplazamiento vertical con su título, como
// Gboard, y la barra de abajo con iconos monocromos que siguen al scroll. Antes
// se veía una categoría cada vez, los iconos eran emojis de colores y las
// banderas quedaban escondidas al final de una barra que había que desplazar.

final class EmojiPanelView: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    var insert: ((String) -> Void)?
    var backToKeys: (() -> Void)?
    var deleteDown: (() -> Void)?
    var deleteUp: (() -> Void)?
    /// Vibración al abrir el selector de tono y al pasar de una opción a otra.
    /// Las pone el controlador para respetar el ajuste de vibración.
    var onLongPressFeedback: (() -> Void)?
    var onSelectionFeedback: (() -> Void)?

    private struct Section {
        let title: String
        let symbols: [String]
        let emojis: [String]
        /// Los recientes se escriben tal cual: ya llevan el tono con que se usaron.
        var isRecents = false
    }

    /// Las pestañas sin lo que este iOS no sabe dibujar. Una vez por proceso.
    private static let catalog: [Section] = EmojiCatalog.categories.map { category in
        Section(title: category.title, symbols: category.symbols,
                emojis: category.emojis.filter { !EmojiSupport.unsupported.contains($0) })
    }

    private var sections: [Section] = []
    private var recents: [String] = []
    private var sectionOffsets: [CGFloat] = []
    private var selectedSection = 0

    private let layout = UICollectionViewFlowLayout()
    private var collection: UICollectionView!
    private let bottomBar = UIView()
    private let abcButton = EmojiBarButton()
    private let deleteButton = EmojiBarButton()
    private var categoryButtons: [EmojiBarButton] = []

    private var itemSize = CGSize(width: 44, height: 44)
    private var emojiFontSize: CGFloat = 30
    private var lastWidth: CGFloat = 0

    private let tonesKey = "keyboard.emojiTones"   // [emoji base: índice del tono]
    private let toneGate = ToneGestureGate()
    private lazy var savedTones: [String: Int] =
        UserDefaults.standard.dictionary(forKey: tonesKey) as? [String: Int] ?? [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.backgroundColor = .clear
        collection.dataSource = self
        collection.delegate = self
        collection.alwaysBounceVertical = true
        collection.showsVerticalScrollIndicator = false
        collection.register(EmojiCell.self, forCellWithReuseIdentifier: "e")
        collection.register(EmojiHeaderView.self,
                            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                            withReuseIdentifier: "h")
        addSubview(collection)

        let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        lp.minimumPressDuration = 0.35
        lp.allowableMovement = 30      // permite arrastrar hasta el selector de tono
        // Sólo sobre emojis con tonos. Antes empezaba sobre cualquiera: si el
        // dedo tardaba en moverse, a los 0,35 s la pulsación larga se quedaba
        // el toque y el desplazamiento no arrancaba hasta volver a intentarlo.
        toneGate.shouldBegin = { [weak self] gr in
            guard let self else { return false }
            return self.baseWithTones(at: gr.location(in: self.collection)) != nil
        }
        lp.delegate = toneGate
        collection.addGestureRecognizer(lp)

        bottomBar.backgroundColor = .clear
        addSubview(bottomBar)

        abcButton.isKey = true
        abcButton.setTitle("ABC")
        abcButton.onDown = { [weak self] in self?.backToKeys?() }
        bottomBar.addSubview(abcButton)

        deleteButton.isKey = true
        deleteButton.setSymbol(["delete.left"], pointSize: 18)
        deleteButton.onDown = { [weak self] in self?.deleteDown?() }
        deleteButton.onUp = { [weak self] in self?.deleteUp?() }
        bottomBar.addSubview(deleteButton)

        rebuildSections(recents: EmojiStore.recents)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Datos

    private func rebuildSections(recents: [String]) {
        self.recents = recents
        var list: [Section] = []
        if !recents.isEmpty {
            list.append(Section(title: "Recientes", symbols: ["clock"], emojis: recents, isRecents: true))
        }
        list += Self.catalog.filter { !$0.emojis.isEmpty }
        sections = list

        categoryButtons.forEach { $0.removeFromSuperview() }
        categoryButtons = sections.indices.map { index in
            let b = EmojiBarButton()
            b.setSymbol(sections[index].symbols)
            b.accessibilityLabel = sections[index].title
            b.onDown = { [weak self] in self?.jump(to: index) }
            bottomBar.addSubview(b)
            return b
        }
        selectedSection = 0
        collection.reloadData()
        setNeedsLayout()
        applyTheme()
    }

    /// Al mostrar el panel: los recientes cambian mientras se escribe, pero no
    /// se reordenan con el panel abierto (se movería lo que está bajo el dedo).
    func reloadCurrent() {
        let latest = EmojiStore.recents
        guard latest != recents else {
            applyTheme()
            return
        }
        rebuildSections(recents: latest)
        collection.setContentOffset(.zero, animated: false)
    }

    func applyTheme() {
        abcButton.applyTheme()
        deleteButton.applyTheme()
        for (i, b) in categoryButtons.enumerated() {
            b.isSelected = i == selectedSection
        }
        let kind = UICollectionView.elementKindSectionHeader
        for ip in collection.indexPathsForVisibleSupplementaryElements(ofKind: kind) where ip.section < sections.count {
            (collection.supplementaryView(forElementKind: kind, at: ip) as? EmojiHeaderView)?
                .configure(sections[ip.section].title)
        }
        for case let cell as EmojiCell in collection.visibleCells {
            cell.applyTheme()
        }
    }

    // Aplica el tono guardado a un emoji base (si lo tiene).
    private func displayed(_ base: String) -> String {
        guard let i = savedTones[base], let variants = toneVariants(of: base).list,
              variants.indices.contains(i) else { return base }
        return variants[i]
    }

    /// El emoji bajo el dedo, si tiene tonos que elegir.
    private func baseWithTones(at point: CGPoint) -> String? {
        guard let ip = collection.indexPathForItem(at: point) else { return nil }
        let base = sections[ip.section].emojis[ip.item]
        return toneVariants(of: base).list == nil ? nil : base
    }

    private func toneVariants(of base: String) -> (list: [String]?, isPair: Bool) {
        if let pair = EmojiSupport.variants(EmojiCatalog.pairToneVariants[base]) { return (pair, true) }
        return (EmojiSupport.variants(EmojiCatalog.toneVariants[base]), false)
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let barH: CGFloat = 44
        collection.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height - barH, 0))
        bottomBar.frame = CGRect(x: 0, y: bounds.height - barH, width: bounds.width, height: barH)

        let keyW: CGFloat = 52
        abcButton.frame = CGRect(x: 6, y: 5, width: keyW, height: barH - 10)
        deleteButton.frame = CGRect(x: bounds.width - 6 - keyW, y: 5, width: keyW, height: barH - 10)
        let startX = abcButton.frame.maxX + 4
        let slot = categoryButtons.isEmpty ? 0 : (deleteButton.frame.minX - 4 - startX) / CGFloat(categoryButtons.count)
        for (i, b) in categoryButtons.enumerated() {
            b.frame = CGRect(x: startX + CGFloat(i) * slot, y: 2, width: slot, height: barH - 4)
        }

        let width = collection.bounds.width
        guard width > 0 else { return }
        if width != lastWidth {
            lastWidth = width
            // Unos 46 pt por emoji: 8 columnas en un iPhone en vertical.
            let columns = max(7, Int((width - 8) / 46))
            let side = floor((width - 8) / CGFloat(columns))
            itemSize = CGSize(width: side, height: min(max(side * 0.95, 38), 50))
            emojiFontSize = min(floor(side * 0.68), 34)
            layout.sectionInset = UIEdgeInsets(top: 0, left: 4, bottom: 8, right: 4)
            layout.invalidateLayout()
        }
        collection.layoutIfNeeded()
        computeSectionOffsets()
    }

    private func computeSectionOffsets() {
        sectionOffsets = sections.indices.map { s in
            layout.layoutAttributesForSupplementaryView(ofKind: UICollectionView.elementKindSectionHeader,
                                                        at: IndexPath(item: 0, section: s))?.frame.minY ?? 0
        }
    }

    // MARK: Categorías

    private func jump(to section: Int) {
        guard section < sections.count else { return }
        collection.layoutIfNeeded()
        if sectionOffsets.count != sections.count { computeSectionOffsets() }
        let maxY = max(collection.contentSize.height - collection.bounds.height, 0)
        let y = min(sectionOffsets[section], maxY)
        collection.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        select(section)
    }

    private func select(_ section: Int) {
        guard section != selectedSection else { return }
        selectedSection = section
        for (i, b) in categoryButtons.enumerated() {
            b.isSelected = i == section
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === collection, !sectionOffsets.isEmpty else { return }
        let y = scrollView.contentOffset.y + 12
        var current = 0
        for (i, offset) in sectionOffsets.enumerated() where offset <= y {
            current = i
        }
        select(current)
    }

    // MARK: DataSource

    func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }

    func collectionView(_ c: UICollectionView, numberOfItemsInSection s: Int) -> Int {
        sections[s].emojis.count
    }

    func collectionView(_ c: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let cell = c.dequeueReusableCell(withReuseIdentifier: "e", for: ip) as! EmojiCell
        cell.configure(emoji(at: ip), fontSize: emojiFontSize)
        return cell
    }

    func collectionView(_ c: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                        at ip: IndexPath) -> UICollectionReusableView {
        let header = c.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "h",
                                                        for: ip) as! EmojiHeaderView
        header.configure(sections[ip.section].title)
        return header
    }

    func collectionView(_ c: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt ip: IndexPath) -> CGSize { itemSize }

    func collectionView(_ c: UICollectionView, layout: UICollectionViewLayout,
                        referenceSizeForHeaderInSection s: Int) -> CGSize {
        CGSize(width: c.bounds.width, height: 30)
    }

    func collectionView(_ c: UICollectionView, didSelectItemAt ip: IndexPath) {
        insert?(emoji(at: ip))
    }

    /// Lo que se ve y se escribe: los recientes tal cual, el resto con su tono.
    private func emoji(at ip: IndexPath) -> String {
        let section = sections[ip.section]
        let raw = section.emojis[ip.item]
        return section.isRecents ? raw : displayed(raw)
    }

    // MARK: Tonos de piel
    //
    // Mantienes pulsado, aparece el selector, arrastras sin levantar el dedo y
    // al soltar se escribe la opción marcada. Los emojis de una persona tienen
    // una fila con sus cinco tonos; los de dos personas (🤝, parejas, besos)
    // una cuadrícula de 5 × 5: la fila es el tono de la primera persona y la
    // columna el de la segunda. Las variantes salen del catálogo de Unicode ya
    // construidas: el modificador va detrás de cada persona, no al final.

    private var tonePopup: UIView?
    private var toneBase: String?
    private var toneOptions: [String] = []
    private var toneFrames: [CGRect] = []     // en coordenadas del panel
    private var toneLabels: [UILabel] = []
    private var toneIndex = 0
    private var toneIsPair = false

    @objc private func handleLongPress(_ gr: UILongPressGestureRecognizer) {
        switch gr.state {
        case .began:
            let pt = gr.location(in: collection)
            guard let ip = collection.indexPathForItem(at: pt) else { return }
            let base = sections[ip.section].emojis[ip.item]
            let variants = toneVariants(of: base)
            guard let list = variants.list, let cell = collection.cellForItem(at: ip) else { return }
            openTonePicker(base: base, variants: list, isPair: variants.isPair, over: cell)
        case .changed:
            guard tonePopup != nil else { return }
            updateToneSelection(at: gr.location(in: self))
        case .ended:
            guard tonePopup != nil else { return }
            commitTone()
        default:
            closeTonePicker()
        }
    }

    private func openTonePicker(base: String, variants: [String], isPair: Bool, over cell: UICollectionViewCell) {
        closeTonePicker()
        collection.isScrollEnabled = false      // el dedo elige, no desplaza
        let theme = KeyStyle.theme
        toneBase = base
        toneIsPair = isPair
        toneOptions = [base] + variants

        let cellSide: CGFloat = isPair ? 38 : 42
        let pad: CGFloat = 5
        // Una persona: [base | 5 tonos] en fila. Dos: la base a la izquierda y
        // la cuadrícula de 5 × 5 al lado.
        var local: [CGRect] = [CGRect(x: pad, y: pad, width: cellSide, height: cellSide)]
        let gridX = pad + cellSide + (isPair ? 8 : 0)
        for i in 0..<variants.count {
            let col = isPair ? i % 5 : i
            let row = isPair ? i / 5 : 0
            local.append(CGRect(x: gridX + CGFloat(col) * cellSide, y: pad + CGFloat(row) * cellSide,
                                width: cellSide, height: cellSide))
        }
        let w = gridX + CGFloat(isPair ? 5 : variants.count) * cellSide + pad
        let h = pad * 2 + cellSide * CGFloat(isPair ? 5 : 1)
        if isPair {
            // La base centrada en altura, junto a la cuadrícula.
            local[0].origin.y = (h - cellSide) / 2
        }

        let cf = cell.convert(cell.bounds, to: self)
        var x = cf.midX - w / 2
        x = min(max(x, 4), max(bounds.width - w - 4, 4))
        var y = cf.minY - h - 6
        if y < 2 { y = min(max(cf.maxY + 6, 2), max(bounds.height - h - 2, 2)) }
        if isPair { y = min(max(y, 2), max(bounds.height - h - 2, 2)) }

        let bar = UIView(frame: CGRect(x: x, y: y, width: w, height: h))
        bar.backgroundColor = theme.menu
        bar.layer.cornerRadius = 14
        bar.layer.shadowColor = UIColor.black.cgColor
        bar.layer.shadowOpacity = 0.25
        bar.layer.shadowRadius = 6
        bar.layer.shadowOffset = CGSize(width: 0, height: 2)
        if let border = theme.keyBorder {
            bar.layer.borderWidth = 1
            bar.layer.borderColor = border.resolvedColor(with: traitCollection).cgColor
        }
        addSubview(bar)

        if isPair {
            let divider = UIView(frame: CGRect(x: pad + cellSide + 3.5, y: pad + 6, width: 1, height: h - 2 * pad - 12))
            divider.backgroundColor = theme.separator
            bar.addSubview(divider)
        }

        toneLabels = []
        for (opt, frame) in zip(toneOptions, local) {
            let l = UILabel(frame: frame.insetBy(dx: 1, dy: 1))
            l.text = opt
            l.textAlignment = .center
            l.font = .systemFont(ofSize: isPair ? 26 : 28)
            l.layer.cornerRadius = 8
            l.clipsToBounds = true
            bar.addSubview(l)
            toneLabels.append(l)
        }
        tonePopup = bar
        toneFrames = local.map { $0.offsetBy(dx: x, dy: y) }

        // Arranca marcando el tono que ya tenías elegido para ese emoji.
        var start = 0
        if let i = savedTones[base], i >= 0, i < variants.count { start = i + 1 }
        toneIndex = start
        highlightTone()
        onLongPressFeedback?()
    }

    private func updateToneSelection(at point: CGPoint) {
        guard !toneFrames.isEmpty else { return }
        var best = toneIndex
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (i, frame) in toneFrames.enumerated() {
            let dx = point.x - frame.midX
            // En la fila de un tono sólo cuenta el desplazamiento horizontal.
            let dy = toneIsPair ? point.y - frame.midY : 0
            let d = dx * dx + dy * dy
            if d < bestDistance {
                bestDistance = d
                best = i
            }
        }
        guard best != toneIndex else { return }
        toneIndex = best
        highlightTone()
        onSelectionFeedback?()
    }

    private func highlightTone() {
        let theme = KeyStyle.theme
        for (i, l) in toneLabels.enumerated() {
            l.backgroundColor = i == toneIndex ? theme.accent : .clear
        }
    }

    private func commitTone() {
        guard let base = toneBase, toneOptions.indices.contains(toneIndex) else {
            closeTonePicker()
            return
        }
        let result = toneOptions[toneIndex]
        if toneIndex == 0 { savedTones[base] = nil } else { savedTones[base] = toneIndex - 1 }
        UserDefaults.standard.set(savedTones, forKey: tonesKey)
        closeTonePicker()
        insert?(result)
        collection.reloadData()
    }

    private func closeTonePicker() {
        tonePopup?.removeFromSuperview()
        tonePopup = nil
        toneLabels = []
        toneOptions = []
        toneFrames = []
        toneBase = nil
        collection.isScrollEnabled = true
    }
}
