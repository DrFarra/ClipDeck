import UIKit
import SwiftUI
import SwiftData

// MARK: - Contenedor con clic de teclado del sistema

final class FeedbackHostView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }

    /// Zonas que se quedan el toque pase lo que pase por encima.
    ///
    /// Los iconos de portapapeles y emoji fallaban en unas posiciones sí y en
    /// otras no: algo por delante les robaba el toque. En vez de seguir
    /// adivinando qué vista era, el reparto se decide aquí, en la raíz, antes
    /// de mirar ninguna otra vista: si el dedo cae en la esquina, va al icono.
    var priorityTargets: [(rect: CGRect, view: UIView)] = []

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard self.point(inside: point, with: event) else { return super.hitTest(point, with: event) }
        for target in priorityTargets
        where !target.view.isHidden && target.view.isUserInteractionEnabled && target.rect.contains(point) {
            return target.view
        }
        return super.hitTest(point, with: event)
    }
}

// MARK: - Especificación de tecla

enum KeyKind { case char, shift, backspace, mode, globe, space, ret, comma, period }

struct KeySpec {
    var value: String
    var kind: KeyKind
    var widthFactor: CGFloat = 1
    var variants: [String] = []
}

// MARK: - Controlador (UIKit puro para máxima respuesta)

final class KeyboardViewController: UIInputViewController {

    enum ShiftState { case off, on, caps }
    enum Mode { case keys, clipboard, emoji }

    private var config = KbPrefs.Config.load()
    private var shift: ShiftState = .on
    private var symbolsMode = false
    private var mode: Mode = .keys

    private var lexicon: [String] = []
    private var lastCommittedWord = ""
    private var lastShiftTap = Date.distantPast
    private var lastSpaceTap = Date.distantPast
    private var pendingRevert: String?
    private var deleteTimer: Timer?
    private var suggestionWork: DispatchWorkItem?

    // Escritura deslizando
    private var swipeActive = false
    private var swipeReady = false
    private var swipePoints: [CGPoint] = []
    private var swipeTrail: SwipeTrailView?
    private var swipeCenters: [UInt8: CGPoint] = [:]
    private var swipePitch: CGFloat = 40
    private var swipeStartChar = ""
    private var swipeToken = 0

    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private let longPressHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let selectionHaptic = UISelectionFeedbackGenerator()

    // UI
    private var root: FeedbackHostView!
    private let topBar = TopBarView()
    private let clipboardButton = IconTouchButton()
    private let emojiButton = IconTouchButton()
    private var suggestionButtons: [SuggestionButton] = []
    private var confirmOverlay: UIView?
    private var confirmWord: String?
    private var separatorViews: [UIView] = []
    private let keyboardArea = UIView()
    private var keyViews: [KeyRowView] = []
    private var rows: [[KeySpec]] = []
    private var panelHost: UIHostingController<AnyView>?
    private var emojiPanel: EmojiPanelView?

    // Popup central reutilizable
    private let popup = UILabel()

    // MARK: Ciclo de vida

    override func viewDidLoad() {
        super.viewDidLoad()
        config = KbPrefs.Config.load()
        haptic.prepare()

        requestSupplementaryLexicon { [weak self] lex in
            DispatchQueue.main.async { self?.lexicon = lex.entries.map { $0.documentText } }
        }

        root = FeedbackHostView(frame: view.bounds, inputViewStyle: .keyboard)
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        let h = view.heightAnchor.constraint(equalToConstant: CGFloat(config.height))
        h.priority = .defaultHigh
        h.isActive = true

        setupTopBar()

        keyboardArea.clipsToBounds = false
        keyboardArea.isMultipleTouchEnabled = true
        root.addSubview(keyboardArea)

        popup.textAlignment = .center
        popup.font = .systemFont(ofSize: CGFloat(config.fontSize) + 12, weight: .medium)
        popup.backgroundColor = UIColor.systemGray3
        popup.layer.cornerRadius = 9
        popup.layer.masksToBounds = true
        popup.isHidden = true
        popup.isUserInteractionEnabled = false
        root.addSubview(popup)

        rebuildKeys()
        precomputeChecker()
        prewarmEmojiPanel()
        prepareSwipe()
    }

    /// Carga el vocabulario de deslizamiento en segundo plano: leerlo en el
    /// hilo principal congelaría la apertura del teclado.
    private func prepareSwipe() {
        guard config.swipe else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            SwipeLexicon.shared.load()
            let ready = SwipeLexicon.shared.isLoaded
            DispatchQueue.main.async { self?.swipeReady = ready }
        }
    }

    /// Crea el panel de emojis por adelantado (oculto) para que el primer
    /// toque en el icono no tenga que construir la colección completa.
    private func prewarmEmojiPanel() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.emojiPanel == nil else { return }
            let panel = EmojiPanelView()
            panel.insert = { [weak self] e in
                self?.textDocumentProxy.insertText(e)
                EmojiStore.registerRecent(e)
                self?.keyFeedback()
            }
            panel.backToKeys = { [weak self] in self?.mode = .keys; self?.refreshMode() }
            panel.deleteDown = { [weak self] in self?.backspaceDown() }
            panel.deleteUp = { [weak self] in self?.backspaceUp() }
            panel.onLongPressFeedback = { [weak self] in self?.longPressFeedback() }
            panel.onSelectionFeedback = { [weak self] in self?.selectionFeedback() }
            panel.frame = self.keyboardArea.frame
            panel.isHidden = true
            self.root.addSubview(panel)
            self.emojiPanel = panel
            panel.reloadCurrent()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Recarga preferencias por si cambiaron en la app.
        let newConfig = KbPrefs.Config.load()
        let changed = newConfig != config
        config = newConfig
        if changed {
            popup.font = .systemFont(ofSize: CGFloat(config.fontSize) + 12, weight: .medium)
            if let h = view.constraints.first(where: { $0.firstAttribute == .height }) {
                h.constant = CGFloat(config.height)
            }
            rebuildKeys()
        } else {
            updateKeyCaps()
        }
        updateShiftFromContext()
        if mode == .keys { showKeyboard() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutAll()
    }

    // MARK: Barra superior

    private func setupTopBar() {
        root.addSubview(topBar)

        clipboardButton.setSymbol("doc.on.clipboard")
        clipboardButton.onTap = { [weak self] in self?.toggleClipboard() }
        clipboardButton.onFeedback = { [weak self] in self?.longPressFeedback() }
        topBar.addSubview(clipboardButton)

        emojiButton.setSymbol("face.smiling")
        emojiButton.onTap = { [weak self] in self?.toggleEmoji() }
        emojiButton.onFeedback = { [weak self] in self?.longPressFeedback() }
        topBar.addSubview(emojiButton)

        topBar.leftButton = clipboardButton
        topBar.rightButton = emojiButton

        for i in 0..<3 {
            let b = SuggestionButton()
            b.onTap = { [weak self] word in self?.applySuggestionWord(word) }
            b.onLongPress = { [weak self] word in self?.confirmForget(word) }
            topBar.addSubview(b)
            suggestionButtons.append(b)
            if i > 0 {
                let sep = UIView()
                sep.backgroundColor = .separator
                topBar.addSubview(sep)
                separatorViews.append(sep)
            }
        }
    }

    // MARK: Construcción de teclas

    private func makeRows() -> [[KeySpec]] {
        var result: [[KeySpec]] = []

        if config.numberRow {
            result.append("1234567890".map { KeySpec(value: String($0), kind: .char) })
        }

        if symbolsMode {
            result.append(["@","#","$","_","&","-","+","(",")","/"].map {
                KeySpec(value: $0, kind: .char, variants: variants(for: $0))
            })
            result.append(["*","\"","'",":",";","!","?","¿","¡","%"].map {
                KeySpec(value: $0, kind: .char, variants: variants(for: $0))
            })
            var third: [KeySpec] = ["=","<",">","{","}","[","]"].map {
                KeySpec(value: $0, kind: .char, variants: variants(for: $0))
            }
            third.append(KeySpec(value: "", kind: .backspace, widthFactor: 1.4))
            result.append(third)
        } else {
            result.append("qwertyuiop".map {
                KeySpec(value: String($0), kind: .char, variants: variants(for: String($0)))
            })
            result.append("asdfghjklñ".map {
                KeySpec(value: String($0), kind: .char, variants: variants(for: String($0)))
            })
            var third: [KeySpec] = [KeySpec(value: "", kind: .shift, widthFactor: 1.4)]
            third += "zxcvbnm".map {
                KeySpec(value: String($0), kind: .char, variants: variants(for: String($0)))
            }
            third.append(KeySpec(value: "", kind: .backspace, widthFactor: 1.4))
            result.append(third)
        }

        var bottom: [KeySpec] = [KeySpec(value: symbolsMode ? "ABC" : "123", kind: .mode, widthFactor: 1.3)]
        if needsInputModeSwitchKey {
            bottom.append(KeySpec(value: "", kind: .globe, widthFactor: 1.0))
        }
        bottom.append(KeySpec(value: config.punctLeft, kind: .comma, widthFactor: 1.0))
        bottom.append(KeySpec(value: "", kind: .space, widthFactor: 5.0))
        bottom.append(KeySpec(value: config.punctRight, kind: .period, widthFactor: 1.0))
        bottom.append(KeySpec(value: "", kind: .ret, widthFactor: 1.6))
        result.append(bottom)

        return result
    }

    private func variants(for key: String) -> [String] {
        config.accents ? (KbData.keyVariants[key] ?? []) : []
    }

    private func rebuildKeys() {
        keyViews.forEach { $0.removeFromSuperview() }
        keyViews.removeAll()
        rows = makeRows()

        for row in rows {
            let rowView = KeyRowView(specs: row, controller: self)
            keyboardArea.addSubview(rowView)
            keyViews.append(rowView)
        }
        updateKeyCaps()
        view.setNeedsLayout()
    }

    private func updateKeyCaps() {
        let upper = shift != .off && !symbolsMode
        for rowView in keyViews { rowView.applyShift(upper, caps: shift == .caps) }
    }

    // MARK: Layout manual (rellena toda la altura, sin márgenes)

    private func layoutAll() {
        let W = root.bounds.width
        let H = root.bounds.height
        guard W > 0, H > 0 else { return }

        let topH: CGFloat = 44
        topBar.frame = CGRect(x: 0, y: 0, width: W, height: topH)

        // Los iconos NO tocan los bordes de la pantalla.
        //
        // Cuando fallaban no había ni respuesta visual: el toque no llegaba a
        // la vista, lo interceptaba el sistema antes. Las franjas de unos 20 pt
        // pegadas a los laterales están reservadas para los gestos de borde del
        // sistema, y ahí los toques se retrasan o se cancelan. Todo lo que
        // fallaba estaba en esa franja; la barra de sugerencias, que siempre
        // respondió bien, empieza mucho más adentro. Por eso los iconos se
        // apartan del borde.
        let edge: CGFloat = 26
        let btn: CGFloat = 52
        clipboardButton.frame = CGRect(x: edge, y: 2, width: btn, height: topH - 4)
        emojiButton.frame = CGRect(x: W - edge - btn, y: 2, width: btn, height: topH - 4)
        root.priorityTargets = [
            (CGRect(x: edge - 8, y: 0, width: btn + 16, height: topH), clipboardButton),
            (CGRect(x: W - edge - btn - 8, y: 0, width: btn + 16, height: topH), emojiButton)
        ]
        let sugX = clipboardButton.frame.maxX + 6
        let sugTotal = max(emojiButton.frame.minX - 6 - sugX, 0)
        let sugW = sugTotal / 3
        for (i, b) in suggestionButtons.enumerated() {
            b.frame = CGRect(x: sugX + CGFloat(i) * sugW, y: 5, width: sugW, height: 34)
        }
        for (i, sep) in separatorViews.enumerated() {
            sep.frame = CGRect(x: sugX + CGFloat(i + 1) * sugW - 0.5, y: 12, width: 1, height: 20)
        }

        let areaY = topH
        let areaH = H - topH
        keyboardArea.frame = CGRect(x: 0, y: areaY, width: W, height: areaH)
        panelHost?.view.frame = keyboardArea.frame
        emojiPanel?.frame = keyboardArea.frame
        if trackpadActive {
            trackpadOverlay.frame = keyboardArea.frame
            trackpadHint?.frame = trackpadOverlay.bounds
        }

        // Distribuye las filas para rellenar la altura disponible.
        let rowCount = CGFloat(keyViews.count)
        let rowSpacing: CGFloat = 6
        let pad: CGFloat = 3
        let usableH = areaH - rowSpacing * (rowCount - 1) - 4
        let rowH = max(min(usableH / rowCount, 64), 34)
        let totalH = rowH * rowCount + rowSpacing * (rowCount - 1)
        var y = max((areaH - totalH) / 2, 2)

        for rowView in keyViews {
            rowView.frame = CGRect(x: 0, y: y, width: W, height: rowH)
            rowView.layoutKeys(sidePadding: pad, spacing: 5, fontSize: CGFloat(config.fontSize))
            y += rowH + rowSpacing
        }
    }

    // MARK: Popup de tecla

    func showPopup(for keyView: KeyView, text: String) {
        guard config.keyPopup, keyView.spec.kind == .char, !text.isEmpty else { return }
        popup.text = text
        popup.sizeToFit()
        let kf = keyView.convert(keyView.bounds, to: root)
        let w = max(kf.width * 1.25, popup.bounds.width + 18)
        let hgt = kf.height + 12
        var x = kf.midX - w / 2
        x = min(max(x, 3), root.bounds.width - w - 3)   // no sale de los márgenes
        let yTop = max(kf.minY - hgt - 4, 2)
        popup.frame = CGRect(x: x, y: yTop, width: w, height: hgt)
        popup.isHidden = false
        root.bringSubviewToFront(popup)
    }

    func hidePopup() { popup.isHidden = true }

    private lazy var hintLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 13, weight: .medium)
        l.textAlignment = .center
        l.textColor = .label
        l.backgroundColor = UIColor.systemGray4
        l.layer.cornerRadius = 12
        l.layer.masksToBounds = true
        l.numberOfLines = 1
        l.isHidden = true
        l.isUserInteractionEnabled = false
        return l
    }()

    /// Aviso breve centrado (p. ej. al olvidar una sugerencia).
    func showHint(_ text: String) {
        if hintLabel.superview == nil { root.addSubview(hintLabel) }
        hintLabel.text = "  \(text)  "
        hintLabel.sizeToFit()
        let w = hintLabel.bounds.width + 16
        let h: CGFloat = 30
        hintLabel.frame = CGRect(x: (root.bounds.width - w) / 2, y: 44, width: w, height: h)
        hintLabel.isHidden = false
        root.bringSubviewToFront(hintLabel)
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideHint), object: nil)
        perform(#selector(hideHint), with: nil, afterDelay: 1.6)
    }

    @objc private func hideHint() { hintLabel.isHidden = true }

    // MARK: Acciones de tecla

    /// Corrector compartido: instanciar UITextChecker es caro y antes se creaba
    /// uno nuevo en cada autocorrección y en cada cálculo de sugerencias.
    static let sharedChecker = UITextChecker()

    /// Timer que sí dispara mientras hay un dedo apoyado (modo .common).
    static func commonTimer(_ interval: TimeInterval, _ block: @escaping () -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: false) { _ in block() }
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    func keyFeedback() {
        if config.haptics {
            haptic.impactOccurred()
            haptic.prepare()          // reduce la latencia del siguiente toque
        }
        if config.sound { UIDevice.current.playInputClick() }
    }

    /// Vibración al abrir el globo de opciones o entrar en modo trackpad.
    /// Es independiente de la vibración de teclas: se puede tener una sin la otra.
    func longPressFeedback() {
        guard config.hapticsLongPress else { return }
        longPressHaptic.impactOccurred()
        longPressHaptic.prepare()
    }

    /// Vibración corta al pasar de una opción a otra dentro del globo.
    func selectionFeedback() {
        guard config.hapticsLongPress else { return }
        selectionHaptic.selectionChanged()
        selectionHaptic.prepare()
    }

    func insertChar(_ base: String) {
        keyFeedback()
        let upper = shift != .off && !symbolsMode
        textDocumentProxy.insertText(upper ? base.uppercased() : base)
        if shift == .on && !symbolsMode {
            shift = .off
            updateKeyCaps()
        }
        pendingRevert = nil
        scheduleSuggestions()
    }

    /// Reemplaza el último carácter insertado por una variante acentuada.
    func replaceLastWithVariant(_ variant: String) {
        textDocumentProxy.deleteBackward()
        textDocumentProxy.insertText(variant)
        scheduleSuggestions()
    }

    func handleShift() {
        keyFeedback()
        let now = Date()
        if now.timeIntervalSince(lastShiftTap) < 0.3 {
            shift = .caps
        } else {
            shift = shift == .off ? .on : .off
        }
        lastShiftTap = now
        updateKeyCaps()
    }

    private var deleteRepeats = 0

    // MARK: Modo trackpad (como iOS: mantener espacio → todo el teclado)
    private var trackpadActive = false
    private var trackpadLastPoint: CGPoint = .zero
    private var trackpadAccumX: CGFloat = 0
    private var trackpadAccumY: CGFloat = 0
    private var trackpadMoved = false
    private let trackpadOverlay = UIView()
    private var trackpadHint: UILabel?

    func backspaceDown() {
        keyFeedback()
        textDocumentProxy.deleteBackward()
        updateShiftFromContext()
        scheduleSuggestions()
        deleteRepeats = 0
        deleteTimer?.invalidate()
        deleteTimer = Self.commonTimer(0.45) { [weak self] in self?.scheduleNextDelete() }
    }

    /// Cada repetición borra más rápido; tras un rato pasa a borrar palabra a palabra.
    private func scheduleNextDelete() {
        deleteRepeats += 1
        let interval: TimeInterval = deleteRepeats < 8 ? 0.11 : (deleteRepeats < 18 ? 0.06 : 0.035)
        deleteTimer = Self.commonTimer(interval) { [weak self] in
            guard let self else { return }
            if self.deleteRepeats > 26 { self.deleteWord() } else { self.textDocumentProxy.deleteBackward() }
            self.updateShiftFromContext()
            self.scheduleNextDelete()
        }
    }

    private func deleteWord() {
        guard let before = textDocumentProxy.documentContextBeforeInput, !before.isEmpty else {
            textDocumentProxy.deleteBackward(); return
        }
        var chars = Array(before)
        var count = 0
        while let last = chars.last, last == " " { chars.removeLast(); count += 1 }
        while let last = chars.last, last != " ", last != "\n" { chars.removeLast(); count += 1 }
        for _ in 0..<max(count, 1) { textDocumentProxy.deleteBackward() }
    }

    func backspaceUp() {
        deleteTimer?.invalidate()
        deleteTimer = nil
        deleteRepeats = 0
        updateShiftFromContext()
        scheduleSuggestions()
    }

    func toggleSymbols() {
        keyFeedback()
        symbolsMode.toggle()
        rebuildKeys()
    }

    func switchKeyboard() { advanceToNextInputMode() }

    func spaceTap() {
        let now = Date()
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        if config.doubleSpace,
           now.timeIntervalSince(lastSpaceTap) < 0.4,
           before.hasSuffix(" "),
           before.dropLast().last?.isLetter == true {
            textDocumentProxy.deleteBackward()
            commit(".")
            textDocumentProxy.insertText(" ")
            if config.autoCapital { shift = .on; updateKeyCaps() }
        } else {
            commit(" ")
        }
        lastSpaceTap = now
    }

    func moveCursor(_ offset: Int) {
        textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
    }

    // MARK: - Trackpad

    var isTrackpadActive: Bool { trackpadActive }

    /// Entra en modo trackpad: las teclas se apagan y toda el área del teclado
    /// pasa a mover el cursor, igual que al mantener el espacio en iOS.
    func enterTrackpad(at point: CGPoint) {
        guard config.trackpad, !trackpadActive else { return }
        trackpadActive = true
        trackpadMoved = false
        trackpadLastPoint = point
        trackpadAccumX = 0
        trackpadAccumY = 0

        longPressFeedback()

        // Atenúa las teclas (efecto "se apagan las letras").
        keyViews.forEach { $0.setDimmed(true) }

        trackpadOverlay.frame = keyboardArea.frame
        trackpadOverlay.backgroundColor = UIColor.systemGray4.withAlphaComponent(0.25)
        trackpadOverlay.isUserInteractionEnabled = false
        if trackpadOverlay.superview == nil { root.addSubview(trackpadOverlay) }
        trackpadOverlay.isHidden = false
        root.bringSubviewToFront(trackpadOverlay)

        if trackpadHint == nil {
            let l = UILabel()
            l.text = "Mueve el cursor"
            l.font = .systemFont(ofSize: 14, weight: .medium)
            l.textColor = .secondaryLabel
            l.textAlignment = .center
            trackpadOverlay.addSubview(l)
            trackpadHint = l
        }
        trackpadHint?.frame = trackpadOverlay.bounds
        trackpadHint?.isHidden = false
    }

    /// Mueve el cursor a partir del desplazamiento del dedo en cualquier punto
    /// del teclado. Horizontal = caracteres; vertical = línea aproximada.
    func trackpadMove(to point: CGPoint) {
        guard trackpadActive else { return }
        let dx = point.x - trackpadLastPoint.x
        let dy = point.y - trackpadLastPoint.y
        trackpadLastPoint = point

        // Horizontal: 1 carácter cada ~7 pt (preciso y estable).
        trackpadAccumX += dx
        let stepX: CGFloat = 7
        if abs(trackpadAccumX) >= stepX {
            let chars = Int(trackpadAccumX / stepX)
            trackpadAccumX -= CGFloat(chars) * stepX
            if chars != 0 {
                textDocumentProxy.adjustTextPosition(byCharacterOffset: chars)
                trackpadMoved = true
                trackpadHint?.isHidden = true
            }
        }

        // Vertical: cada N pt salta una línea (configurable en ajustes).
        trackpadAccumY += dy
        let stepY = max(CGFloat(config.trackpadStepY), 8)
        if abs(trackpadAccumY) >= stepY {
            let lines = Int(trackpadAccumY / stepY)
            trackpadAccumY -= CGFloat(lines) * stepY
            if lines != 0 {
                moveByLines(lines)
                trackpadMoved = true
                trackpadHint?.isHidden = true
            }
        }
    }

    func exitTrackpad() {
        guard trackpadActive else { return }
        trackpadActive = false
        keyViews.forEach { $0.setDimmed(false) }
        trackpadOverlay.isHidden = true
        trackpadHint?.isHidden = true
        scheduleSuggestions()
    }

    /// ¿Se llegó a mover el cursor? (para no insertar un espacio al salir)
    var trackpadDidMove: Bool { trackpadMoved }

    /// Movimiento vertical aproximado.
    ///
    /// Una extensión de teclado sólo puede desplazar el cursor por offset de
    /// caracteres (`adjustTextPosition`), no existe API para "línea arriba".
    /// Si hay saltos de línea reales se usan como referencia; si el texto va
    /// envuelto, se estima con un ancho de línea típico.
    private func moveByLines(_ lines: Int) {
        guard lines != 0 else { return }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let after = textDocumentProxy.documentContextAfterInput ?? ""
        let fallbackLineLength = max(Int(config.trackpadChars), 8)

        if lines < 0 {
            for _ in 0..<(-lines) {
                if let idx = before.lastIndex(of: "\n") {
                    let distance = before.distance(from: idx, to: before.endIndex)
                    textDocumentProxy.adjustTextPosition(byCharacterOffset: -distance)
                } else {
                    let step = min(fallbackLineLength, before.count)
                    if step > 0 { textDocumentProxy.adjustTextPosition(byCharacterOffset: -step) }
                    break
                }
            }
        } else {
            for _ in 0..<lines {
                if let idx = after.firstIndex(of: "\n") {
                    let distance = after.distance(from: after.startIndex, to: idx) + 1
                    textDocumentProxy.adjustTextPosition(byCharacterOffset: distance)
                } else {
                    let step = min(fallbackLineLength, after.count)
                    if step > 0 { textDocumentProxy.adjustTextPosition(byCharacterOffset: step) }
                    break
                }
            }
        }
    }

    // MARK: - Escritura deslizando

    var isSwipeActive: Bool { swipeActive }

    /// Sólo con el diccionario ya cargado, en el teclado de letras y fuera del
    /// modo trackpad.
    var swipeEnabled: Bool { config.swipe && swipeReady && !symbolsMode && !trackpadActive }

    /// Empieza un trazo. La letra que se insertó al tocar la tecla se retira,
    /// porque va a ser reemplazada por la palabra completa.
    func beginSwipe(startChar: String, from point: CGPoint) {
        guard !swipeActive, swipeEnabled else { return }
        swipeActive = true
        swipeStartChar = startChar
        textDocumentProxy.deleteBackward()
        suggestionWork?.cancel()
        hidePopup()
        selectionFeedback()
        rebuildSwipeGeometry()
        swipePoints = [point]

        let trail: SwipeTrailView
        if let existing = swipeTrail {
            trail = existing
        } else {
            let t = SwipeTrailView(frame: view.bounds)
            root.addSubview(t)
            swipeTrail = t
            trail = t
        }
        trail.frame = view.bounds
        root.bringSubviewToFront(trail)
        trail.begin(at: point)
    }

    func swipeMove(to point: CGPoint) {
        guard swipeActive else { return }
        if let last = swipePoints.last, hypot(point.x - last.x, point.y - last.y) < 2 { return }
        swipePoints.append(point)
        swipeTrail?.add(point)
    }

    func endSwipe(cancelled: Bool) {
        guard swipeActive else { return }
        swipeActive = false
        swipeTrail?.finish()

        let points = swipePoints
        swipePoints = []
        let startChar = swipeStartChar
        swipeStartChar = ""

        let long = SwipeRecognizer.traceLength(points) > swipePitch * 1.6
        guard !cancelled, points.count > 3, long else {
            restoreSwipeStart(startChar)
            return
        }

        swipeToken += 1
        let token = swipeToken
        let centers = swipeCenters
        let pitch = swipePitch
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let words = SwipeRecognizer.recognize(points: points, keyCenters: centers, pitch: pitch)
            DispatchQueue.main.async {
                guard let self, self.swipeToken == token else { return }
                self.applySwipe(words, startChar: startChar)
            }
        }
    }

    /// El trazo fue demasiado corto o se canceló: se devuelve la letra tocada.
    private func restoreSwipeStart(_ startChar: String) {
        guard !startChar.isEmpty else { return }
        textDocumentProxy.insertText(startChar)
        scheduleSuggestions()
    }

    private func applySwipe(_ words: [String], startChar: String) {
        guard let best = words.first else {
            showHint("Sin coincidencia")
            scheduleSuggestions()
            return
        }

        let capitalize = startChar.first?.isUppercase == true
        let word = capitalize ? best.prefix(1).uppercased() + best.dropFirst() : best

        // Separación automática con la palabra anterior, como en Gboard.
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        if let last = before.last, last != " ", last != "\n" {
            textDocumentProxy.insertText(" ")
        }
        textDocumentProxy.insertText(word)
        // La confirmación del trazo va con la vibración de gestos, que es la
        // que el usuario deja activa aunque silencie la de teclas.
        longPressFeedback()

        if config.learnWords {
            let previous = lastCommittedWord
            DispatchQueue.global(qos: .utility).async {
                WordLearner.learn(best)
                if !previous.isEmpty { WordLearner.learnBigram(previous: previous, next: best) }
            }
        }
        lastCommittedWord = best
        pendingRevert = nil
        if shift == .on && !symbolsMode { shift = .off; updateKeyCaps() }

        // Alternativas a un toque en la barra de sugerencias.
        var alternatives: [String] = []
        for w in words.dropFirst().prefix(3) {
            alternatives.append(capitalize ? w.prefix(1).uppercased() + w.dropFirst() : w)
        }
        if alternatives.isEmpty {
            scheduleSuggestions()
        } else {
            setSuggestions(alternatives)
        }
    }

    /// Centro de cada tecla de letra, para comparar el trazo con las palabras.
    private func rebuildSwipeGeometry() {
        var centers: [UInt8: CGPoint] = [:]
        var widest: CGFloat = 0
        for rowView in keyViews {
            for k in rowView.letterKeys() {
                guard let ch = k.spec.value.lowercased().first,
                      let idx = SwipeAlphabet.index(ch) else { continue }
                let f = k.convert(k.bounds, to: view)
                centers[idx] = CGPoint(x: f.midX, y: f.midY)
                if f.width > widest { widest = f.width }
            }
        }
        swipeCenters = centers
        swipePitch = widest > 1 ? widest + 5 : 40
    }

    func returnTap() { commit("\n") }
    func punctTap(_ ch: String) { commit(ch) }

    /// Cierra la palabra: autocorrección + aprendizaje + separador.
    private func commit(_ separator: String) {
        keyFeedback()
        let word = currentWord()
        pendingRevert = nil

        // El separador se inserta de inmediato: la escritura nunca espera al
        // corrector ni al aprendizaje.
        textDocumentProxy.insertText(separator)

        let sentenceEnders: Set<String> = [".", "?", "!", "\n"]
        if sentenceEnders.contains(separator) {
            if config.autoCapital { shift = .on; updateKeyCaps() }
        } else {
            updateShiftFromContext()
        }

        if !word.isEmpty {
            let previous = lastCommittedWord
            lastCommittedWord = word
            let doCorrect = config.autocorrect
            let doLearn = config.learnWords

            // Corrector y aprendizaje en segundo plano; sólo el reemplazo del
            // texto vuelve al hilo principal, y sólo si hace falta.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let fix = doCorrect ? KeyboardViewController.autocorrection(for: word) : nil
                let finalWord = fix ?? word
                if doLearn {
                    WordLearner.learn(finalWord)
                    if !previous.isEmpty {
                        WordLearner.learnBigram(previous: previous, next: finalWord)
                    }
                }
                guard let fix else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.applyCorrection(original: word, fixed: fix, separator: separator)
                }
            }
        } else if sentenceEnders.contains(separator) {
            lastCommittedWord = ""
        }

        scheduleSuggestions()
    }

    /// Sustituye la palabra ya escrita por su corrección, respetando el
    /// separador que el usuario tecleó y sin pisar lo que haya escrito después.
    private func applyCorrection(original: String, fixed: String, separator: String) {
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        // Sólo corrige si el texto sigue tal cual lo dejamos (usuario no siguió
        // escribiendo ni movió el cursor).
        guard before.hasSuffix(original + separator) else { return }
        for _ in 0..<(original.count + separator.count) { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(fixed + separator)
        pendingRevert = original
        lastCommittedWord = fixed
        scheduleSuggestions()
    }

    private func updateShiftFromContext() {
        guard config.autoCapital, shift != .caps else { return }
        let raw = textDocumentProxy.documentContextBeforeInput ?? ""
        let before = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldCapitalize = before.isEmpty
            || before.hasSuffix(".") || before.hasSuffix("!") || before.hasSuffix("?")
            || before.hasSuffix("\n")
        let newShift: ShiftState = shouldCapitalize ? .on : .off
        if newShift != shift { shift = newShift; updateKeyCaps() }
    }

    // MARK: Sugerencias y corrección

    private func precomputeChecker() {
        DispatchQueue.global(qos: .userInitiated).async {
            let c = KeyboardViewController.sharedChecker
            _ = c.completions(forPartialWordRange: NSRange(location: 0, length: 2),
                              in: "ho", language: "es_ES")
            _ = c.completions(forPartialWordRange: NSRange(location: 0, length: 2),
                              in: "he", language: "en_US")
        }
    }

    /// Programa el cálculo de sugerencias en segundo plano con debounce, para
    /// que el corrector no bloquee nunca la siguiente pulsación de tecla.
    private func scheduleSuggestions() {
        guard config.prediction else { setSuggestions([]); return }
        suggestionWork?.cancel()
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let lex = lexicon
        let last = lastCommittedWord
        let capNext = shift != .off
        let work = DispatchWorkItem {
            let result = KeyboardViewController.computeSuggestions(before: before, lexicon: lex,
                                                                  lastWord: last, capitalizeNext: capNext)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.mode == .keys else { return }
                self.setSuggestions(result)
            }
        }
        suggestionWork = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// Cálculo puro (sin tocar UI) — seguro en segundo plano.
    private static func computeSuggestions(before: String, lexicon: [String],
                                           lastWord: String, capitalizeNext: Bool) -> [String] {
        let word = wordBefore(before)
        if word.isEmpty || word.count < 2 || word.rangeOfCharacter(from: .letters) == nil {
            return nextWords(lastWord: lastWord, capitalizeNext: capitalizeNext)
        }

        let lower = word.lowercased()
        let capitalize = word.first?.isUppercase == true
        let blocked = WordLearner.blockedWords()
        var results = WordLearner.matches(prefix: lower, limit: 2)

        for entry in lexicon where entry.lowercased().hasPrefix(lower) {
            results.append(entry)
            if results.count >= 4 { break }
        }
        let checker = KeyboardViewController.sharedChecker
        let range = NSRange(location: 0, length: word.utf16.count)
        for language in ["es_ES", "en_US"] {
            if let c = checker.completions(forPartialWordRange: range, in: word, language: language) {
                results.append(contentsOf: c)
            }
            if results.count >= 12 { break }
        }
        var seen = Set<String>(); var unique: [String] = []
        for cand in results {
            let k = cand.lowercased()
            guard k != lower, !seen.contains(k), !blocked.contains(k) else { continue }
            seen.insert(k)
            unique.append(capitalize ? cand.prefix(1).uppercased() + cand.dropFirst() : cand)
            if unique.count == 3 { break }
        }
        // Si la palabra en curso no tiene completados (p. ej. "xd"), proponemos
        // igualmente la próxima palabra probable en vez de dejar la barra vacía.
        if unique.isEmpty {
            return nextWords(lastWord: word, capitalizeNext: capitalizeNext)
        }
        return unique
    }

    private static func nextWords(lastWord: String, capitalizeNext: Bool) -> [String] {
        var r: [String] = []
        if !lastWord.isEmpty { r += WordLearner.successors(of: lastWord) }
        let blocked = WordLearner.blockedWords()
        for w in KbData.commonWords {
            if r.count >= 3 { break }
            if !r.contains(w) && !blocked.contains(w) { r.append(w) }
        }
        return Array(r.prefix(3)).map { capitalizeNext ? $0.prefix(1).uppercased() + $0.dropFirst() : $0 }
    }

    private func setSuggestions(_ words: [String], revert: String? = nil) {
        let showRevert = revert ?? pendingRevert
        var titles = words
        if let showRevert, mode == .keys {
            titles = ["↺ " + showRevert] + Array(words.prefix(2))
        }
        for (i, b) in suggestionButtons.enumerated() {
            b.text = i < titles.count ? titles[i] : ""
        }
        for (i, sep) in separatorViews.enumerated() {
            sep.isHidden = (i + 1) >= titles.count
        }
    }

    private func applySuggestionWord(_ title: String) {
        keyFeedback()
        if title.hasPrefix("↺ ") {
            undoCorrection(to: String(title.dropFirst(2)))
            return
        }
        let current = currentWord()
        for _ in 0..<current.count { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(title + " ")
        if config.learnWords {
            WordLearner.learn(title)
            if !lastCommittedWord.isEmpty && !current.isEmpty {
                WordLearner.learnBigram(previous: lastCommittedWord, next: title)
            }
        }
        lastCommittedWord = title
        pendingRevert = nil
        updateShiftFromContext()
        scheduleSuggestions()
    }

    private func confirmForget(_ title: String) {
        var word = title
        if word.hasPrefix("↺ ") { word = String(word.dropFirst(2)) }
        guard !word.isEmpty else { return }
        keyFeedback()
        showForgetConfirm(word: word)
    }

    // MARK: Confirmación para olvidar una sugerencia (sin UIAlertController, no
    // disponible en teclados: se dibuja dentro del propio teclado).

    private func showForgetConfirm(word: String) {
        dismissConfirm()
        confirmWord = word

        let dim = UIView(frame: root.bounds)
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dismissConfirm)))
        root.addSubview(dim)

        let cardW = min(root.bounds.width - 48, 320)
        let cardH: CGFloat = 130
        let card = UIView(frame: CGRect(x: (root.bounds.width - cardW) / 2,
                                        y: (root.bounds.height - cardH) / 2,
                                        width: cardW, height: cardH))
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 14
        dim.addSubview(card)

        let label = UILabel(frame: CGRect(x: 14, y: 14, width: cardW - 28, height: 56))
        label.numberOfLines = 2
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 15)
        label.text = "¿Olvidar «\(word)»?\nNo se volverá a sugerir."
        card.addSubview(label)

        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancelar", for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 16)
        cancel.frame = CGRect(x: 10, y: cardH - 46, width: cardW / 2 - 15, height: 38)
        cancel.addTarget(self, action: #selector(dismissConfirm), for: .touchUpInside)
        card.addSubview(cancel)

        let confirm = UIButton(type: .system)
        confirm.setTitle("Olvidar", for: .normal)
        confirm.setTitleColor(.systemRed, for: .normal)
        confirm.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        confirm.frame = CGRect(x: cardW / 2 + 5, y: cardH - 46, width: cardW / 2 - 15, height: 38)
        confirm.addTarget(self, action: #selector(confirmForgetAction), for: .touchUpInside)
        card.addSubview(confirm)

        confirmOverlay = dim
    }

    @objc private func dismissConfirm() {
        confirmOverlay?.removeFromSuperview()
        confirmOverlay = nil
        confirmWord = nil
    }

    @objc private func confirmForgetAction() {
        if let w = confirmWord {
            WordLearner.forget(w)
            showHint("«\(w)» ya no se sugerirá")
        }
        dismissConfirm()
        scheduleSuggestions()
    }

    private static func autocorrection(for word: String) -> String? {
        guard word.count >= 3, word.count <= 20,
              word.rangeOfCharacter(from: .decimalDigits) == nil,
              word != word.uppercased(),
              !WordLearner.isKnown(word) else { return nil }
        let checker = KeyboardViewController.sharedChecker
        let range = NSRange(location: 0, length: word.utf16.count)
        for language in ["es_ES", "en_US"] {
            let m = checker.rangeOfMisspelledWord(in: word, range: range,
                                                  startingAt: 0, wrap: false, language: language)
            if m.location == NSNotFound { return nil }
        }
        for language in ["es_ES", "en_US"] {
            if let guesses = checker.guesses(forWordRange: range, in: word, language: language) {
                for g in guesses.prefix(3) where !g.contains(" ") {
                    if abs(g.count - word.count) <= 2 && g.lowercased() != word.lowercased() {
                        return word.first?.isUppercase == true
                            ? g.prefix(1).uppercased() + g.dropFirst() : g
                    }
                }
            }
        }
        return nil
    }

    private func undoCorrection(to original: String) {
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        guard let last = before.last else { return }
        let sep = String(last)
        let corrected = KeyboardViewController.wordBefore(String(before.dropLast()))
        for _ in 0..<(corrected.count + 1) { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(original + sep)
        WordLearner.learn(original)
        pendingRevert = nil
        scheduleSuggestions()
    }

    private func replaceCurrentWord(with replacement: String) {
        let current = currentWord()
        for _ in 0..<current.count { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(replacement)
    }

    private func currentWord() -> String {
        KeyboardViewController.wordBefore(textDocumentProxy.documentContextBeforeInput ?? "")
    }

    private static func wordBefore(_ text: String) -> String {
        let sep = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ".,;:!?¿¡\"'()[]{}"))
        if let r = text.rangeOfCharacter(from: sep, options: .backwards) {
            return String(text[r.upperBound...])
        }
        return text
    }

    // MARK: Paneles (portapapeles / emoji en SwiftUI, no críticos para latencia)

    private func toggleClipboard() {
        keyFeedback()
        mode = (mode == .clipboard) ? .keys : .clipboard
        refreshMode()
    }

    private func toggleEmoji() {
        keyFeedback()
        mode = (mode == .emoji) ? .keys : .emoji
        refreshMode()
    }

    private func refreshMode() {
        clipboardButton.setSymbol(mode == .clipboard ? "keyboard" : "doc.on.clipboard",
                                  active: mode == .clipboard)
        emojiButton.setSymbol(mode == .emoji ? "keyboard" : "face.smiling",
                              active: mode == .emoji)
        switch mode {
        case .keys:      showKeyboard()
        case .clipboard: showPanel(AnyView(clipboardPanel()))
        case .emoji:     showEmojiPanel()
        }
    }

    private func showEmojiPanel() {
        keyboardArea.isHidden = true
        panelHost?.view.isHidden = true
        suggestionButtons.forEach { $0.isHidden = true }
        separatorViews.forEach { $0.isHidden = true }
        if emojiPanel == nil {
            let panel = EmojiPanelView()
            panel.insert = { [weak self] e in
                self?.textDocumentProxy.insertText(e)
                EmojiStore.registerRecent(e)
                self?.keyFeedback()
            }
            panel.backToKeys = { [weak self] in self?.mode = .keys; self?.refreshMode() }
            panel.deleteDown = { [weak self] in self?.backspaceDown() }
            panel.deleteUp = { [weak self] in self?.backspaceUp() }
            panel.onLongPressFeedback = { [weak self] in self?.longPressFeedback() }
            panel.onSelectionFeedback = { [weak self] in self?.selectionFeedback() }
            root.addSubview(panel)
            emojiPanel = panel
        }
        emojiPanel?.isHidden = false
        emojiPanel?.frame = keyboardArea.frame
        if trackpadActive {
            trackpadOverlay.frame = keyboardArea.frame
            trackpadHint?.frame = trackpadOverlay.bounds
        }
        emojiPanel?.reloadCurrent()
        if let ep = emojiPanel { root.bringSubviewToFront(ep) }
    }

    private func showKeyboard() {
        panelHost?.view.isHidden = true
        emojiPanel?.isHidden = true
        keyboardArea.isHidden = false
        suggestionButtons.forEach { $0.isHidden = $0.text.isEmpty }
        separatorViews.forEach { $0.isHidden = false }
        scheduleSuggestions()
    }

    private func showPanel(_ v: AnyView) {
        keyboardArea.isHidden = true
        emojiPanel?.isHidden = true
        suggestionButtons.forEach { $0.isHidden = true }
        separatorViews.forEach { $0.isHidden = true }
        if panelHost == nil {
            let host = UIHostingController(rootView: v)
            host.view.backgroundColor = .clear
            addChild(host)
            root.addSubview(host.view)
            host.didMove(toParent: self)
            panelHost = host
        } else {
            panelHost?.rootView = v
        }
        panelHost?.view.isHidden = false
        panelHost?.view.frame = keyboardArea.frame
        emojiPanel?.frame = keyboardArea.frame
        if trackpadActive {
            trackpadOverlay.frame = keyboardArea.frame
            trackpadHint?.frame = trackpadOverlay.bounds
        }
        if let hv = panelHost?.view { root.bringSubviewToFront(hv) }
    }

    private var favoritesOnly = false
    var trackpadEnabled: Bool { config.trackpad }

    private func clipboardPanel() -> ClipboardPanel {
        ClipboardPanel(hasFullAccess: hasFullAccess,
                       snapshots: loadSnapshots(),
                       favoritesOnly: favoritesOnly,
                       onFilter: { [weak self] fav in
                           self?.favoritesOnly = fav
                           self?.refreshMode()
                       },
                       onPick: { [weak self] snap in
                           guard let self else { return }
                           self.keyFeedback()
                           if let text = snap.insertable {
                               self.textDocumentProxy.insertText(text)
                               self.mode = .keys
                               self.refreshMode()
                           } else if let data = snap.imageData, let img = UIImage(data: data) {
                               UIPasteboard.general.image = img
                           }
                       })
    }

    private func loadSnapshots() -> [ClipSnapshot] {
        guard hasFullAccess else { return [] }
        let context = ModelContext(ClipStore.makeContainer())
        CaptureService.captureIfNeeded(context: context)
        var d = FetchDescriptor<ClipItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        d.fetchLimit = 120
        let items = (try? context.fetch(d)) ?? []
        return items.filter { favoritesOnly ? $0.isFavorite : true }.map { item in
            ClipSnapshot(id: item.id, typeLabel: item.type.label, systemImage: item.type.systemImage,
                         preview: item.displayTitle, insertable: insertableText(for: item),
                         imageData: item.type == .image ? item.assetData : nil,
                         isSensitive: item.isSensitive, isFavorite: item.isFavorite)
        }
    }

    private func insertableText(for item: ClipItem) -> String? {
        switch item.type {
        case .link:  return item.urlString ?? item.plainText
        case .image, .file: return nil
        default:     return item.plainText
        }
    }
}

// MARK: - Fila de teclas (UIKit)

final class KeyRowView: UIView {
    private var keys: [KeyView] = []
    private let specs: [KeySpec]

    init(specs: [KeySpec], controller: KeyboardViewController) {
        self.specs = specs
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        for spec in specs {
            let k = KeyView(spec: spec, controller: controller)
            addSubview(k)
            keys.append(k)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func setDimmed(_ dimmed: Bool) {
        for k in keys { k.setDimmed(dimmed) }
    }

    /// Teclas de carácter (para calcular la geometría del deslizamiento).
    func letterKeys() -> [KeyView] { keys.filter { $0.spec.kind == .char } }

    func applyShift(_ upper: Bool, caps: Bool) {
        for k in keys {
            k.applyShift(upper)
            k.setShiftActive(upper || caps, caps: caps)
        }
    }

    func layoutKeys(sidePadding: CGFloat, spacing: CGFloat, fontSize: CGFloat) {
        let totalFactor = specs.reduce(0) { $0 + $1.widthFactor }
        let n = CGFloat(specs.count)
        let unit = (bounds.width - 2 * sidePadding - spacing * (n - 1)) / totalFactor
        var x = sidePadding
        for k in keys {
            let w = k.spec.widthFactor * unit
            k.frame = CGRect(x: x, y: 0, width: w, height: bounds.height)
            k.setFontSize(fontSize)
            x += w + spacing
        }
    }
}

// MARK: - Tecla individual (UIKit, respuesta inmediata al tocar)

final class KeyView: UIView {
    let spec: KeySpec
    private weak var controller: KeyboardViewController?
    private let label = UILabel()

    private var baseValue: String
    private var upper = false
    private var longTimer: Timer?
    private var accentBar: UIView?
    private var accentBarFrame: CGRect = .zero
    private var accentLabels: [UILabel] = []
    private let accentCellWidth: CGFloat = 34
    private var selectedAccent = 0
    private var isDown = false
    private var shiftActive = false
    private var pressStart: CFTimeInterval = 0
    private var spaceTracking = false
    private var startPoint: CGPoint = .zero
    private var insertedChar = ""
    private var swiping = false
    private var spaceStartX: CGFloat = 0
    private var spaceConsumed = 0
    private var trackpadTimer: Timer?

    init(spec: KeySpec, controller: KeyboardViewController) {
        self.spec = spec
        self.controller = controller
        self.baseValue = spec.value
        super.init(frame: .zero)

        backgroundColor = Self.color(for: spec.kind, pressed: false)
        layer.cornerRadius = 7
        clipsToBounds = false
        isMultipleTouchEnabled = true
        isExclusiveTouch = false

        label.textAlignment = .center
        label.textColor = .label
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        addSubview(label)

        switch spec.kind {
        case .shift:     label.text = "⇧"
        case .backspace: label.text = "⌫"
        case .globe:     label.text = "🌐"
        case .ret:       label.text = "↵"
        case .space:     label.text = "espacio"; label.textColor = .secondaryLabel; label.font = .systemFont(ofSize: 15)
        case .mode:      label.text = spec.value; label.font = .systemFont(ofSize: 15)
        default:         label.text = spec.value
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
    }

    func setFontSize(_ size: CGFloat) {
        if spec.kind == .char { label.font = .systemFont(ofSize: size) }
    }

    func applyShift(_ up: Bool) {
        upper = up
        if spec.kind == .char, baseValue.rangeOfCharacter(from: .letters) != nil {
            label.text = up ? baseValue.uppercased() : baseValue
        }
    }

    /// Atenúa la tecla mientras el teclado actúa como trackpad.
    func setDimmed(_ dimmed: Bool) {
        label.alpha = dimmed ? 0.15 : 1
        alpha = dimmed ? 0.5 : 1
    }

    /// Resalta la tecla de mayúsculas según el estado actual.
    func setShiftActive(_ active: Bool, caps: Bool) {
        guard spec.kind == .shift else { return }
        shiftActive = active
        label.text = caps ? "⇪" : "⇧"
        backgroundColor = active ? UIColor.systemGray : UIColor.systemGray4
        label.textColor = active ? .white : .label
    }

    private func setPressed(_ p: Bool) {
        if spec.kind == .shift && !p {
            backgroundColor = shiftActive ? UIColor.systemGray : UIColor.systemGray4
            return
        }
        backgroundColor = Self.color(for: spec.kind, pressed: p)
    }

    static func color(for kind: KeyKind, pressed: Bool) -> UIColor {
        switch kind {
        case .char, .space:
            return pressed ? .systemGray2 : .secondarySystemBackground
        default:
            return pressed ? .systemGray2 : .systemGray4
        }
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isDown else { return }
        isDown = true
        swiping = false
        insertedChar = ""
        if let t = touches.first, let root = controller?.view {
            startPoint = t.location(in: root)
        }
        pressStart = CACurrentMediaTime()
        setPressed(true)
        switch spec.kind {
        case .char:
            controller?.insertChar(baseValue)
            insertedChar = upper ? baseValue.uppercased() : baseValue
            controller?.showPopup(for: self, text: upper ? baseValue.uppercased() : baseValue)
            if !spec.variants.isEmpty {
                longTimer?.invalidate()
                longTimer = KeyboardViewController.commonTimer(0.4) { [weak self] in
                    self?.showAccents()
                }
            }
        case .shift:     controller?.handleShift()
        case .backspace: controller?.backspaceDown()
        case .mode:      controller?.toggleSymbols()
        case .globe:     controller?.switchKeyboard()
        case .comma, .period: controller?.punctTap(spec.value)
        case .ret:       controller?.returnTap()
        case .space:
            if let t = touches.first {
                spaceStartX = t.location(in: superview).x
                spaceTracking = false
                spaceConsumed = 0
                // Mantener pulsado el espacio → todo el teclado es trackpad,
                // igual que en el teclado nativo de iOS.
                if controller?.trackpadEnabled == true, let root = controller?.view {
                    let p = t.location(in: root)
                    trackpadTimer?.invalidate()
                    trackpadTimer = KeyboardViewController.commonTimer(0.35) { [weak self] in
                        guard let self, self.isDown else { return }
                        self.controller?.enterTrackpad(at: p)
                    }
                }
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }

        // Trazo en curso: el dedo dibuja la palabra.
        if swiping {
            if let root = controller?.view { controller?.swipeMove(to: t.location(in: root)) }
            return
        }

        // Modo trackpad activo: el dedo mueve el cursor esté donde esté.
        if controller?.isTrackpadActive == true {
            if let root = controller?.view {
                controller?.trackpadMove(to: t.location(in: root))
            }
            return
        }

        // La barra se recorta contra los bordes de la pantalla, así que la
        // opción seleccionada se calcula sobre la posición REAL de la barra y
        // no sobre la tecla: si no, en las teclas laterales la última opción
        // caía fuera del alcance del dedo.
        if accentBar != nil, let rootView = controller?.view {
            let px = t.location(in: rootView).x
            let slot = Int(floor((px - accentBarFrame.minX - 4) / accentCellWidth))
            let newIndex = min(max(slot, 0), spec.variants.count - 1)
            if newIndex != selectedAccent {
                selectedAccent = newIndex
                highlightAccent()
                controller?.selectionFeedback()
            }
            return
        }
        // ¿El dedo salió de la tecla sin levantarse? Entonces es un trazo.
        if spec.kind == .char, accentBar == nil, !insertedChar.isEmpty,
           baseValue.first?.isLetter == true, controller?.swipeEnabled == true {
            let local = t.location(in: self)
            if !bounds.insetBy(dx: -4, dy: -4).contains(local), let root = controller?.view {
                longTimer?.invalidate(); longTimer = nil
                swiping = true
                controller?.beginSwipe(startChar: insertedChar, from: startPoint)
                controller?.swipeMove(to: t.location(in: root))
                setPressed(false)
                return
            }
        }

        if spec.kind == .space, let controller, controller.trackpadEnabled {
            let x = t.location(in: superview).x
            let dx = x - spaceStartX
            if !spaceTracking && abs(dx) > 16 {
                spaceTracking = true
                trackpadTimer?.invalidate(); trackpadTimer = nil
            }
            if spaceTracking {
                let steps = Int(dx / 9)
                let delta = steps - spaceConsumed
                if delta != 0 {
                    controller.moveCursor(delta)
                    spaceConsumed = steps
                }
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishTouch(cancelled: false)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishTouch(cancelled: true)
    }

    private func finishTouch(cancelled: Bool) {
        isDown = false
        longTimer?.invalidate(); longTimer = nil
        trackpadTimer?.invalidate(); trackpadTimer = nil

        // Fin de un trazo: la palabra la resuelve el controlador.
        if swiping {
            swiping = false
            insertedChar = ""
            controller?.endSwipe(cancelled: cancelled)
            setPressed(false)
            controller?.hidePopup()
            return
        }

        // Si estábamos en modo trackpad, salir y no escribir nada.
        if controller?.isTrackpadActive == true {
            let moved = controller?.trackpadDidMove ?? false
            controller?.exitTrackpad()
            setPressed(false)
            controller?.hidePopup()
            spaceTracking = false
            if !moved && !cancelled && spec.kind == .space {
                controller?.spaceTap()      // mantuvo pulsado sin mover: espacio normal
            }
            return
        }

        // Si el toque fue muy corto, deja ver el resaltado un instante.
        let elapsed = CACurrentMediaTime() - pressStart
        let minVisible: CFTimeInterval = 0.06
        if elapsed < minVisible && accentBar == nil {
            let delay = minVisible - elapsed
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.isDown else { return }
                self.setPressed(false)
                self.controller?.hidePopup()
            }
        } else {
            setPressed(false)
            controller?.hidePopup()
        }

        if accentBar != nil {
            if !cancelled, spec.variants.indices.contains(selectedAccent) {
                let v = spec.variants[selectedAccent]
                controller?.replaceLastWithVariant(upper ? v.uppercased() : v)
            }
            accentBar?.removeFromSuperview()
            accentBar = nil
            accentLabels = []
            return
        }

        if spec.kind == .backspace { controller?.backspaceUp() }
        if spec.kind == .space {
            if !cancelled && !spaceTracking { controller?.spaceTap() }
            spaceTracking = false
        }
    }

    // MARK: Barra de acentos (pulsación larga)

    private func showAccents() {
        guard let root = controller?.view, !spec.variants.isEmpty else { return }
        controller?.hidePopup()
        controller?.longPressFeedback()
        let variants = spec.variants
        let cellW = accentCellWidth
        let hgt: CGFloat = 44
        let w = CGFloat(variants.count) * cellW + 8
        let kf = convert(bounds, to: root)
        var x = kf.midX - w / 2
        x = min(max(x, 3), root.bounds.width - w - 3)
        let bar = UIView(frame: CGRect(x: x, y: max(kf.minY - hgt - 6, 2), width: w, height: hgt))
        bar.backgroundColor = .systemGray4
        bar.layer.cornerRadius = 10
        root.addSubview(bar)
        accentLabels = []
        for (i, v) in variants.enumerated() {
            let l = UILabel(frame: CGRect(x: 4 + CGFloat(i) * cellW, y: 4, width: cellW, height: hgt - 8))
            l.text = upper ? v.uppercased() : v
            l.textAlignment = .center
            l.font = .systemFont(ofSize: 22)
            l.layer.cornerRadius = 6
            l.clipsToBounds = true
            bar.addSubview(l)
            accentLabels.append(l)
        }
        accentBar = bar
        accentBarFrame = bar.frame
        selectedAccent = 0
        highlightAccent()
    }

    private func highlightAccent() {
        for (i, l) in accentLabels.enumerated() {
            l.backgroundColor = i == selectedAccent ? .tintColor : .clear
            l.textColor = i == selectedAccent ? .white : .label
        }
    }
}

// MARK: - Snapshot del historial para el panel

struct ClipSnapshot: Identifiable {
    let id: UUID
    let typeLabel: String
    let systemImage: String
    let preview: String
    let insertable: String?
    let imageData: Data?
    let isSensitive: Bool
    let isFavorite: Bool
}

// MARK: - Panel del portapapeles (SwiftUI, sólo al abrirlo)

struct ClipboardPanel: View {
    let hasFullAccess: Bool
    let snapshots: [ClipSnapshot]
    let favoritesOnly: Bool
    let onFilter: (Bool) -> Void
    let onPick: (ClipSnapshot) -> Void

    @State private var query: String = ""

    private var filtered: [ClipSnapshot] {
        guard !query.isEmpty else { return snapshots }
        let q = query.lowercased()
        return snapshots.filter {
            $0.preview.lowercased().contains(q) || $0.typeLabel.lowercased().contains(q)
        }
    }

    var body: some View {
        Group {
            if !hasFullAccess {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.lock").font(.title2).foregroundStyle(.secondary)
                    Text("Activa «Permitir acceso completo» en Ajustes → ClipDeck → Teclados.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 6) {
                    searchField

                    HStack(spacing: 8) {
                        chip("Recientes", "clock.arrow.circlepath", active: !favoritesOnly) { onFilter(false) }
                        chip("Favoritos", "star.fill", active: favoritesOnly) { onFilter(true) }
                        Spacer()
                    }
                    .padding(.horizontal, 6)

                    if snapshots.isEmpty {
                        Text("Historial vacío. Copia algo y vuelve a abrir este panel.")
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if filtered.isEmpty {
                        Text("Sin resultados para «\(query)».")
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())],
                                      spacing: 6) {
                                ForEach(filtered) { snap in
                                    card(snap)
                                        .contentShape(Rectangle())
                                        .onTapGesture { onPick(snap) }
                                }
                            }
                            .padding([.horizontal, .bottom], 6)
                        }
                    }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            TextField("Buscar en el portapapeles", text: $query)
                .font(.caption)
                .textFieldStyle(.plain)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color(.secondarySystemBackground), in: Capsule())
        .padding(.horizontal, 6)
        .padding(.top, 6)
    }

    private func chip(_ text: String, _ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption)
        }
        .padding(.horizontal, 10).frame(height: 28)
        .background(active ? Color.accentColor.opacity(0.22) : Color(.secondarySystemBackground), in: Capsule())
        .foregroundStyle(active ? Color.accentColor : Color.primary)
        .contentShape(Capsule())
        .onTapGesture(perform: action)
    }

    private func card(_ snap: ClipSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Image(systemName: snap.systemImage).font(.caption2)
                Text(snap.typeLabel).font(.caption2)
                if snap.isFavorite { Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.yellow) }
            }
            .foregroundStyle(.secondary)
            if snap.isSensitive {
                Label("Sensible", systemImage: "eye.slash").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let data = snap.imageData, let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFill()
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Text(snap.preview).font(.caption).lineLimit(3).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8).frame(height: 92, alignment: .topLeading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Emojis

enum EmojiStore {
    static let recentsKey = "keyboard.recentEmojis"
    static var recents: [String] { UserDefaults.standard.stringArray(forKey: recentsKey) ?? [] }
    static func registerRecent(_ e: String) {
        var l = recents; l.removeAll { $0 == e }; l.insert(e, at: 0)
        UserDefaults.standard.set(Array(l.prefix(24)), forKey: recentsKey)
    }
    static let categories: [(icon: String, emojis: [String])] = [
        ("😀", ["😀","😃","😄","😁","😆","😅","😂","🤣","🥲","🥹","😊","😇","🙂","🙃","😉","😌","😍","🥰","😘","😗","😙","😚","😋","😛","😝","😜","🤪","🤨","🧐","🤓","😎","🥸","🤩","🥳","😏","😒","😞","😔","😟","😕","🙁","☹️","😣","😖","😫","😩","🥺","😢","😭","😤","😠","😡","🤬","🤯","😳","🥵","🥶","😱","😨","😰","😥","😓","🫣","🤗","🫡","🤔","🫢","🤭","🤫","🤥","😶","🫥","😐","😑","😬","🙄","😯","😦","😧","😮","😲","🥱","😴","🤤","😪","😵","😵‍💫","🫠","🤐","🥴","🤢","🤮","🤧","😷","🤒","🤕","🤑","🤠","😈","👿","👹","👺","🤡","💩","👻","💀","☠️","👽","👾","🤖","🎃","😺","😸","😹","😻","😼","😽","🙀","😿","😾"]),
        ("👋", ["👋","🤚","🖐️","✋","🖖","🫱","🫲","🫳","🫴","👌","🤌","🤏","✌️","🤞","🫰","🤟","🤘","🤙","👈","👉","👆","🖕","👇","☝️","👍","👎","✊","👊","🤛","🤜","👏","🙌","🫶","👐","🤲","🤝","🙏","✍️","💅","🤳","💪","🦾","🦵","🦿","🦶","👣","👂","🦻","👃","🧠","🫀","🫁","🦷","🦴","👀","👁️","👅","👄","🫦","💋","🩸"]),
        ("❤️", ["❤️","🧡","💛","💚","💙","🩵","💜","🖤","🤍","🤎","💔","❤️‍🔥","❤️‍🩹","❣️","💕","💞","💓","💗","💖","💘","💝","💟","♥️","💌","💐","🌹","🌷","🌸","💮","🏵️","🌺","🌻","🌼","🌈","⭐","🌟","✨","💫","🔥","💥","💯"]),
        ("🐶", ["🐶","🐱","🐭","🐹","🐰","🦊","🐻","🐼","🐻‍❄️","🐨","🐯","🦁","🐮","🐷","🐽","🐸","🐵","🙈","🙉","🙊","🐒","🐔","🐧","🐦","🐤","🐣","🦆","🦅","🦉","🦇","🐺","🐗","🐴","🦄","🐝","🪱","🐛","🦋","🐌","🐞","🐜","🪰","🐢","🐍","🦎","🦖","🐙","🦑","🦐","🦞","🦀","🐡","🐠","🐟","🐬","🐳","🐋","🦈","🐊","🐅","🐆","🦓","🦍","🐘","🦣","🦏","🐪","🐫","🦒","🐃","🐂","🐄","🐎","🐖","🐏","🐑","🦙","🐐","🦌","🐕","🐩","🦮","🐈","🐓","🦃","🦤","🦚","🦜","🦢","🕊️","🐇","🦝","🦨","🦡","🦫","🦦","🦥","🐁","🐀","🐿️","🦔"]),
        ("🍕", ["🍏","🍎","🍐","🍊","🍋","🍌","🍉","🍇","🍓","🫐","🍈","🍒","🍑","🥭","🍍","🥥","🥝","🍅","🍆","🥑","🥦","🥬","🥒","🌶️","🫑","🌽","🥕","🫒","🧄","🧅","🥔","🍠","🥐","🥯","🍞","🥖","🥨","🧀","🥚","🍳","🧈","🥞","🧇","🥓","🥩","🍗","🍖","🌭","🍔","🍟","🍕","🫓","🥪","🥙","🧆","🌮","🌯","🫔","🥗","🥘","🫕","🍝","🍜","🍲","🍛","🍣","🍱","🥟","🦪","🍤","🍙","🍚","🍘","🍥","🥠","🍢","🍡","🍧","🍨","🍦","🥧","🧁","🍰","🎂","🍮","🍭","🍬","🍫","🍿","🍩","🍪","🌰","🥜","🍯","🥛","🍼","🫖","☕","🍵","🧃","🥤","🧋","🍶","🍺","🍻","🥂","🍷","🥃","🍸","🍹","🍾","🧉"]),
        ("⚽", ["⚽","🏀","🏈","⚾","🥎","🎾","🏐","🏉","🥏","🎱","🪀","🏓","🏸","🏒","🏑","🥍","🏏","🪃","🥅","⛳","🪁","🏹","🎣","🤿","🥊","🥋","🎽","🛹","🛼","🛷","⛸️","🥌","🎿","⛷️","🏂","🪂","🏋️","🤼","🤸","🤺","⛹️","🤾","🏌️","🏇","🧘","🏄","🏊","🤽","🚣","🧗","🚴","🚵","🏆","🥇","🥈","🥉","🏅","🎖️","🏵️","🎗️","🎫","🎟️","🎪","🎭","🎨","🎬","🎤","🎧","🎼","🎹","🥁","🎷","🎺","🎸","🪕","🎻","🎲","♟️","🎯","🎳","🎮","🎰","🧩"]),
        ("🚗", ["🚗","🚕","🚙","🚌","🚎","🏎️","🚓","🚑","🚒","🚐","🛻","🚚","🚛","🚜","🦯","🦽","🦼","🛴","🚲","🛵","🏍️","🛺","🚨","🚔","🚍","🚘","🚖","🚡","🚠","🚟","🚃","🚋","🚞","🚝","🚄","🚅","🚈","🚂","🚆","🚇","🚊","🚉","✈️","🛫","🛬","🛩️","💺","🛰️","🚀","🛸","🚁","🛶","⛵","🚤","🛥️","🛳️","⛴️","🚢","⚓","🪝","⛽","🚧","🚦","🚥","🗺️","🗿","🗽","🗼","🏰","🏯","🏟️","🎡","🎢","🎠","⛲","⛱️","🏖️","🏝️","🏔️","⛰️","🌋","🗻","🏕️","⛺","🏠","🏡","🏘️","🏙️","🌆","🌃","🌉","🌁"]),
        ("💡", ["⌚","📱","📲","💻","⌨️","🖥️","🖨️","🖱️","🖲️","🕹️","🗜️","💽","💾","💿","📀","📼","📷","📸","📹","🎥","📽️","🎞️","📞","☎️","📟","📠","📺","📻","🎙️","🎚️","🎛️","🧭","⏱️","⏲️","⏰","🕰️","⌛","⏳","📡","🔋","🪫","🔌","💡","🔦","🕯️","🪔","🧯","🛢️","💸","💵","💴","💶","💷","🪙","💰","💳","🧾","💎","⚖️","🪜","🧰","🪛","🔧","🔨","⚒️","🛠️","⛏️","🪚","🔩","⚙️","🪤","🧱","⛓️","🧲","🔫","💣","🧨","🪓","🔪","🗡️","⚔️","🛡️","🚬","⚰️","🪦","⚱️","🏺","🔮","📿","🧿","💈","⚗️","🔭","🔬","🕳️","🩻","🩹","🩺","💊","💉","🩸","🧬","🦠","🧫","🧪","🌡️","🧹","🪠","🧺","🧻","🚽","🚰","🚿","🛁","🛀","🧼","🪥","🪒","🧽","🪣","🧴","🛎️","🔑","🗝️","🚪","🪑","🛋️","🛏️","🛌","🧸","🪆","🖼️","🪞","🪟","🛍️","🛒","🎁","🎈","🎏","🎀","🪄","🪅","🎊","🎉"]),
        ("🔣", ["✅","❌","❎","✔️","☑️","❓","❔","❗","❕","‼️","⁉️","💯","🔞","📵","🚭","🚫","💤","♨️","💢","💬","🗨️","🗯️","💭","🔍","🔎","🔒","🔓","🔏","🔐","🔗","⛓️","📛","🆔","⚠️","🚸","☢️","☣️","⬆️","↗️","➡️","↘️","⬇️","↙️","⬅️","↖️","↕️","↔️","↩️","↪️","⤴️","⤵️","🔃","🔄","🔙","🔚","🔛","🔜","🔝","🛐","⚛️","🕉️","✡️","☸️","☯️","✝️","☦️","☪️","☮️","🕎","🔯","♈","♉","♊","♋","♌","♍","♎","♏","♐","♑","♒","♓","⛎","▶️","⏸️","⏯️","⏹️","⏺️","⏭️","⏮️","⏩","⏪","⏫","⏬","◀️","🔼","🔽","🔀","🔁","🔂","🔄","🔊","🔉","🔈","🔇","📢","📣","🔔","🔕","🎵","🎶","➕","➖","➗","✖️","🟰","♾️","💲","💱","™️","©️","®️","〰️","➰","➿","🔚","🔙","#️⃣","*️⃣","0️⃣","1️⃣","2️⃣","3️⃣","4️⃣","5️⃣","6️⃣","7️⃣","8️⃣","9️⃣","🔟","🔢","🔣","🔤","🅰️","🆎","🅱️","🆑","🆒","🆓","ℹ️","🆔","Ⓜ️","🆕","🆖","🅾️","🆗","🅿️","🆘","🆙","🆚","🈁","🔴","🟠","🟡","🟢","🔵","🟣","🟤","⚫","⚪","🟥","🟧","🟨","🟩","🟦","🟪","🟫","⬛","⬜","◼️","◻️","▪️","▫️","🔶","🔷","🔸","🔹","🔺","🔻","💠","🔘","🔳","🔲","🏁","🚩","🎌","🏴","🏳️","🏳️‍🌈","🏳️‍⚧️","🏴‍☠️"])
    ]
}


// MARK: - Botón de sugerencia (toque propio, fiable en teclados)

final class SuggestionButton: UIView {
    var text: String = "" {
        didSet {
            label.text = text
            isHidden = text.isEmpty
        }
    }
    var onTap: ((String) -> Void)?
    var onLongPress: ((String) -> Void)?

    private let label = UILabel()
    private var longTimer: Timer?
    private var didLong = false
    private var isDown = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 17)
        label.textColor = .label
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        layer.cornerRadius = 6
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !text.isEmpty else { return }
        isDown = true
        didLong = false
        backgroundColor = UIColor.systemGray4
        longTimer?.invalidate()
        longTimer = KeyboardViewController.commonTimer(0.5) { [weak self] in
            guard let self, self.isDown else { return }
            self.didLong = true
            self.backgroundColor = .clear
            self.onLongPress?(self.text)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(tap: !didLong)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(tap: false)
    }

    private func finish(tap: Bool) {
        isDown = false
        longTimer?.invalidate(); longTimer = nil
        backgroundColor = .clear
        if tap && !didLong && !text.isEmpty { onTap?(text) }
        didLong = false
    }
}

// MARK: - Panel de emojis en UIKit (scroll fluido + tonos de piel)

final class EmojiCell: UICollectionViewCell {
    let label = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 30)
        label.frame = bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class EmojiPanelView: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    var insert: ((String) -> Void)?
    var backToKeys: (() -> Void)?
    var deleteDown: (() -> Void)?
    var deleteUp: (() -> Void)?

    private var collection: UICollectionView!
    private let bottomBar = UIView()
    private let abcButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let categoryScroll = UIScrollView()
    private var categoryButtons: [UIButton] = []

    private var categoryIndex = -1            // -1 = recientes
    private var current: [String] = []
    private var tonePopup: UIView?

    private let tonesKey = "keyboard.emojiTones"   // [baseEmoji: toneIndex 0...4]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 2
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.backgroundColor = .clear
        collection.dataSource = self
        collection.delegate = self
        collection.alwaysBounceVertical = true
        collection.register(EmojiCell.self, forCellWithReuseIdentifier: "e")
        addSubview(collection)

        let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        lp.minimumPressDuration = 0.35
        lp.allowableMovement = 30      // permite arrastrar hasta la barra de tonos
        collection.addGestureRecognizer(lp)

        bottomBar.backgroundColor = .clear
        addSubview(bottomBar)

        abcButton.setTitle("ABC", for: .normal)
        abcButton.titleLabel?.font = .systemFont(ofSize: 15)
        abcButton.setTitleColor(.label, for: .normal)
        abcButton.backgroundColor = .secondarySystemBackground
        abcButton.layer.cornerRadius = 7
        abcButton.addTarget(self, action: #selector(tapABC), for: .touchDown)
        bottomBar.addSubview(abcButton)

        deleteButton.setImage(UIImage(systemName: "delete.left"), for: .normal)
        deleteButton.tintColor = .label
        deleteButton.backgroundColor = .secondarySystemBackground
        deleteButton.layer.cornerRadius = 7
        deleteButton.addTarget(self, action: #selector(delDown), for: .touchDown)
        deleteButton.addTarget(self, action: #selector(delUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        bottomBar.addSubview(deleteButton)

        categoryScroll.showsHorizontalScrollIndicator = false
        bottomBar.addSubview(categoryScroll)
        for (i, cat) in EmojiCatalog.categories.enumerated() {
            let b = makeCatButton(cat.icon, index: i)
            categoryScroll.addSubview(b)
            categoryButtons.append(b)
        }
        // botón de recientes al inicio
        let rec = makeCatButton("🕐", index: -1)
        categoryScroll.addSubview(rec)
        categoryButtons.insert(rec, at: 0)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func makeCatButton(_ icon: String, index: Int) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(icon, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 18)
        b.tag = index
        b.layer.cornerRadius = 7
        b.addTarget(self, action: #selector(tapCategory(_:)), for: .touchDown)
        return b
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let barH: CGFloat = 42
        collection.frame = CGRect(x: 0, y: 2, width: bounds.width, height: bounds.height - barH - 2)
        bottomBar.frame = CGRect(x: 0, y: bounds.height - barH, width: bounds.width, height: barH)

        abcButton.frame = CGRect(x: 4, y: 4, width: 48, height: 34)
        deleteButton.frame = CGRect(x: bounds.width - 48, y: 4, width: 44, height: 34)
        categoryScroll.frame = CGRect(x: 56, y: 4, width: bounds.width - 56 - 52, height: 34)
        var x: CGFloat = 0
        for b in categoryButtons {
            b.frame = CGRect(x: x, y: 0, width: 36, height: 34)
            x += 38
        }
        categoryScroll.contentSize = CGSize(width: x, height: 34)
        highlightCategory()
    }

    func reloadCurrent() {
        if categoryIndex == -1 {
            let recents = EmojiStore.recents
            current = recents.isEmpty ? EmojiCatalog.categories.first?.emojis ?? [] : recents
        } else if categoryIndex >= 0 && categoryIndex < EmojiCatalog.categories.count {
            current = EmojiCatalog.categories[categoryIndex].emojis
        }
        collection.reloadData()
        collection.setContentOffset(.zero, animated: false)
        highlightCategory()
    }

    private func highlightCategory() {
        for b in categoryButtons {
            b.backgroundColor = (b.tag == categoryIndex) ? UIColor.tintColor.withAlphaComponent(0.22) : .clear
        }
    }

    // Aplica el tono guardado a un emoji base (si lo tiene).
    private func displayed(_ base: String) -> String {
        guard let variants = EmojiCatalog.toneVariants[base] else { return base }
        let dict = UserDefaults.standard.dictionary(forKey: tonesKey) as? [String: Int] ?? [:]
        if let i = dict[base], variants.indices.contains(i) { return variants[i] }
        return base
    }

    // MARK: DataSource

    func collectionView(_ c: UICollectionView, numberOfItemsInSection s: Int) -> Int { current.count }

    func collectionView(_ c: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let cell = c.dequeueReusableCell(withReuseIdentifier: "e", for: ip) as! EmojiCell
        cell.label.text = displayed(current[ip.item])
        return cell
    }

    func collectionView(_ c: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt ip: IndexPath) -> CGSize {
        let cols: CGFloat = 8
        let w = floor(bounds.width / cols)
        return CGSize(width: w, height: 40)
    }

    func collectionView(_ c: UICollectionView, didSelectItemAt ip: IndexPath) {
        insert?(displayed(current[ip.item]))
    }

    // MARK: Acciones

    @objc private func tapABC() { backToKeys?() }
    @objc private func delDown() { deleteDown?() }
    @objc private func delUp() { deleteUp?() }
    @objc private func tapCategory(_ sender: UIButton) {
        categoryIndex = sender.tag
        reloadCurrent()
    }

    // MARK: Tonos de piel
    //
    // Misma mecánica que el globo de acentos de las teclas: mantienes pulsado,
    // aparece la barra, arrastras sin levantar el dedo y al soltar se inserta
    // la opción marcada. Antes era un popup de botones que había que tocar
    // aparte, y encima componía el tono pegando el modificador al final, cosa
    // que sólo funciona en los emojis simples: en las secuencias con ZWJ
    // (🧑‍🍳, 👩‍❤️‍👨…) el modificador va detrás de la persona, no al final. Ahora
    // las variantes salen del catálogo de Unicode ya construidas.

    /// Vibración al abrir el selector y al pasar de un tono a otro. Las pone el
    /// controlador para respetar el ajuste de vibración en pulsación larga.
    var onLongPressFeedback: (() -> Void)?
    var onSelectionFeedback: (() -> Void)?

    private var toneBase: String?
    private var toneOptions: [String] = []
    private var toneLabels: [UILabel] = []
    private var toneBarFrame: CGRect = .zero
    private var toneIndex = 0
    private let toneCellWidth: CGFloat = 42

    @objc private func handleLongPress(_ gr: UILongPressGestureRecognizer) {
        switch gr.state {
        case .began:
            let pt = gr.location(in: collection)
            guard let ip = collection.indexPathForItem(at: pt) else { return }
            let base = current[ip.item]
            guard let variants = EmojiCatalog.toneVariants[base],
                  let cell = collection.cellForItem(at: ip) else { return }
            openTonePicker(base: base, variants: variants, over: cell)
        case .changed:
            guard tonePopup != nil else { return }
            updateToneSelection(at: gr.location(in: self).x)
        case .ended:
            guard tonePopup != nil else { return }
            commitTone()
        default:
            closeTonePicker()
        }
    }

    private func openTonePicker(base: String, variants: [String], over cell: UICollectionViewCell) {
        closeTonePicker()
        collection.isScrollEnabled = false      // el dedo elige, no desplaza
        toneBase = base
        toneOptions = [base] + variants

        let w = CGFloat(toneOptions.count) * toneCellWidth + 8
        let h: CGFloat = 50
        let cf = cell.convert(cell.bounds, to: self)
        var x = cf.midX - w / 2
        x = min(max(x, 4), max(bounds.width - w - 4, 4))
        let y = max(cf.minY - h - 4, 2)
        let bar = UIView(frame: CGRect(x: x, y: y, width: w, height: h))
        bar.backgroundColor = .systemGray4
        bar.layer.cornerRadius = 12
        bar.layer.shadowColor = UIColor.black.cgColor
        bar.layer.shadowOpacity = 0.25
        bar.layer.shadowRadius = 5
        bar.layer.shadowOffset = CGSize(width: 0, height: 2)
        addSubview(bar)

        toneLabels = []
        for (i, opt) in toneOptions.enumerated() {
            let l = UILabel(frame: CGRect(x: 4 + CGFloat(i) * toneCellWidth, y: 5,
                                          width: toneCellWidth, height: h - 10))
            l.text = opt
            l.textAlignment = .center
            l.font = .systemFont(ofSize: 28)
            l.layer.cornerRadius = 8
            l.clipsToBounds = true
            bar.addSubview(l)
            toneLabels.append(l)
        }
        tonePopup = bar
        toneBarFrame = bar.frame

        // Arranca marcando el tono que ya tenías elegido para ese emoji.
        let saved = UserDefaults.standard.dictionary(forKey: tonesKey) as? [String: Int] ?? [:]
        var start = 0
        if let i = saved[base], i >= 0, i < variants.count { start = i + 1 }
        toneIndex = start
        highlightTone()
        onLongPressFeedback?()
    }

    private func updateToneSelection(at x: CGFloat) {
        guard !toneOptions.isEmpty else { return }
        let slot = Int(floor((x - toneBarFrame.minX - 4) / toneCellWidth))
        let clamped = min(max(slot, 0), toneOptions.count - 1)
        guard clamped != toneIndex else { return }
        toneIndex = clamped
        highlightTone()
        onSelectionFeedback?()
    }

    private func highlightTone() {
        for (i, l) in toneLabels.enumerated() {
            l.backgroundColor = i == toneIndex ? UIColor.tintColor : .clear
        }
    }

    private func commitTone() {
        guard let base = toneBase, toneOptions.indices.contains(toneIndex) else {
            closeTonePicker()
            return
        }
        let result = toneOptions[toneIndex]
        var dict = UserDefaults.standard.dictionary(forKey: tonesKey) as? [String: Int] ?? [:]
        if toneIndex == 0 { dict[base] = nil } else { dict[base] = toneIndex - 1 }
        UserDefaults.standard.set(dict, forKey: tonesKey)
        closeTonePicker()
        insert?(result)
        EmojiStore.registerRecent(result)
        collection.reloadData()
    }

    private func closeTonePicker() {
        tonePopup?.removeFromSuperview()
        tonePopup = nil
        toneLabels = []
        toneOptions = []
        toneBase = nil
        collection.isScrollEnabled = true
    }
}


// MARK: - Botón de icono con toque directo
//
// Los UIButton dentro de una extensión de teclado pueden tragarse el primer
// toque cuando el sistema está entregando otros toques; las teclas y la barra
// de sugerencias ya usan toques crudos, así que estos botones hacen lo mismo.

final class IconTouchButton: UIView {
    var onTap: (() -> Void)?
    /// Vibración al registrar el toque: sirve para notar que llegó sin mirar.
    var onFeedback: (() -> Void)?

    private let imageView = UIImageView()
    private var lastFire: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .center
        imageView.tintColor = .label
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)
        layer.cornerRadius = 8
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
    }

    func setSymbol(_ name: String, active: Bool = false) {
        imageView.image = UIImage(systemName: name,
                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 19,
                                                                                 weight: .medium))
        imageView.tintColor = active ? .tintColor : .label
        backgroundColor = active ? UIColor.tintColor.withAlphaComponent(0.22) : .clear
    }

    /// Dispara la acción con un destello bien visible.
    ///
    /// El destello no es adorno: si el botón vuelve a fallar, sirve para saber
    /// si el toque llegó (destella pero no abre) o no llegó (no destella).
    func fire() {
        let now = CACurrentMediaTime()
        guard now - lastFire > 0.25 else { return }
        lastFire = now
        flash()
        onFeedback?()
        onTap?()
    }

    private func flash() {
        let normal = backgroundColor
        backgroundColor = UIColor.systemGray2
        UIView.animate(withDuration: 0.22) { self.backgroundColor = normal }
    }

    private func setDown(_ down: Bool) {
        alpha = down ? 0.55 : 1
    }

    // Se marca al apoyar y se ejecuta al soltar. Ejecutarlo al apoyar era peor:
    // abrir el panel añade vistas en pleno toque y UIKit deja de entregar el
    // final del toque, que era justo lo que dejaba el botón bloqueado.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        setDown(true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        setDown(false)
        guard let t = touches.first else { fire(); return }
        let p = t.location(in: self)
        if bounds.insetBy(dx: -20, dy: -14).contains(p) { fire() }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        setDown(false)
    }
}

// MARK: - Barra superior
//
// Red de seguridad para los iconos de los extremos: si por lo que sea el toque
// no llega al botón (queda a un pixel, lo intercepta otra vista, el botón se
// quedó en un estado raro), lo recoge la propia barra y ejecuta la acción
// igual. Toda la esquina izquierda y toda la derecha son zona activa.

final class TopBarView: UIView {
    weak var leftButton: IconTouchButton?
    weak var rightButton: IconTouchButton?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let x = t.location(in: self).x
        if let left = leftButton, x <= left.frame.maxX + 6 {
            left.fire()
        } else if let right = rightButton, x >= right.frame.minX - 6 {
            right.fire()
        }
    }
}
