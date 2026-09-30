import UIKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Clic de teclado del sistema
//
// `playInputClick()` sólo suena si la vista de entrada del controlador (su
// `inputView`, no una subvista cualquiera) adopta este protocolo. Antes lo
// adoptaba sólo el contenedor propio, que es una subvista, y el sonido de
// tecla podía no sonar nunca.

extension UIInputView: UIInputViewAudioFeedback {
    public var enableInputClicksWhenVisible: Bool { true }
}

// MARK: - Contenedor raíz
//
// Una vista normal: el fondo lo pone el tema con `applyBackdrop`. El del tema
// Clásico es el gris de teclado de siempre, un UIInputView con estilo
// `.keyboard` por debajo de todo; Cristal no pone nada y deja ver el del
// sistema (el cristal redondeado de iOS 26); los demás pintan su color.

final class FeedbackHostView: UIView {
    private var backdropView: UIView?

    func applyBackdrop(_ backdrop: KeyboardTheme.Backdrop) {
        backdropView?.removeFromSuperview()
        backdropView = nil
        let view: UIView
        switch backdrop {
        case .clear:
            return
        case .keyboard:
            view = UIInputView(frame: bounds, inputViewStyle: .keyboard)
        case .solid(let color):
            view = UIView(frame: bounds)
            view.backgroundColor = color
        case .gradient(let top, let bottom):
            view = GradientBackdropView(top: top, bottom: bottom)
        }
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.isUserInteractionEnabled = false
        insertSubview(view, at: 0)
        backdropView = view
    }

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

/// Fondo en degradado vertical (temas Medianoche, Océano, Lavanda).
final class GradientBackdropView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    private let top: UIColor
    private let bottom: UIColor

    init(top: UIColor, bottom: UIColor) {
        self.top = top
        self.bottom = bottom
        super.init(frame: .zero)
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateColors()
    }

    private func updateColors() {
        guard let gradient = layer as? CAGradientLayer else { return }
        gradient.colors = [top.resolvedColor(with: traitCollection).cgColor,
                           bottom.resolvedColor(with: traitCollection).cgColor]
    }
}

// MARK: - Especificación de tecla

enum KeyKind { case char, shift, backspace, mode, globe, space, ret, comma, period }

struct KeySpec {
    var value: String
    var kind: KeyKind
    var widthFactor: CGFloat = 1
    var variants: [String] = []
    /// Tecla de acción (Buscar, Enviar, Ir…): el nombre va en seminegrita y,
    /// si el tema lo pide, la tecla en su color de acento.
    var accent: Bool = false
}

// MARK: - Controlador (UIKit puro para máxima respuesta)

final class KeyboardViewController: UIInputViewController {

    enum ShiftState { case off, on, caps }
    enum Mode { case keys, clipboard, emoji }
    /// Teclado numérico que pide el campo (códigos, importes, teléfonos).
    enum NumPad { case digits, decimal, phone }

    /// Autocorrección aplicada que todavía se puede deshacer: `tail` es lo que
    /// el usuario escribió detrás de la palabra (el espacio, una coma…).
    private struct Revert {
        let original: String
        let fixed: String
        let tail: String
    }

    private var config = KbPrefs.Config.load()
    private var shift: ShiftState = .on
    /// La mayúscula la puso el usuario (no el contexto): un aviso tardío del
    /// campo de texto no debe quitársela.
    private var shiftByUser = false
    private var symbolsMode = false
    private var mode: Mode = .keys
    private var numPad: NumPad?
    /// El usuario pidió letras en un campo numérico: se respeta hasta cambiar de campo.
    private var numPadDismissed = false
    private var lastDocumentID: UUID?
    /// Cambia con cada campo nuevo: una corrección calculada para el campo
    /// anterior no se aplica en el siguiente.
    private var documentEpoch = 0
    /// El último espacio lo puso el teclado (al elegir una sugerencia): si
    /// ahora llega un signo, va pegado a la palabra («hola, » y no «hola ,»).
    private var autoSpaceInserted = false
    private var builtLayoutKey = ""

    /// Completados del diccionario del sistema (contactos, sustituciones).
    private var lexicon: [String] = []
    /// Sustituciones de texto del usuario (Ajustes → General → Teclado):
    /// atajo en minúsculas → texto completo.
    private var replacements: [String: String] = [:]
    /// Palabras del léxico del sistema (nombres de contactos…): no se corrigen.
    private var lexiconWords: Set<String> = []
    private var lastShiftTap = Date.distantPast
    private var lastSpaceTap = Date.distantPast
    private var pendingRevert: Revert?
    /// Palabra recién deshecha con la tecla borrar: no se vuelve a corregir.
    private var noCorrectOnce: String?
    /// Palabra recién escrita deslizando (ya aprendida al insertarla).
    private var justSwiped: String?
    /// Cómo quedó el texto tras nuestra última edición, para distinguir en
    /// `textDidChange` los cambios propios de los que hace la app o el usuario.
    private var ownContext = ""
    private var deleteTimer: Timer?
    private var suggestionWork: DispatchWorkItem?
    private var heightConstraint: NSLayoutConstraint?

    // Búsqueda en el portapapeles: mientras se escribe la consulta, las teclas
    // escriben en ella y no en la app (una extensión de teclado no puede
    // abrir un teclado para sus propios campos de texto).
    private var searchingClips = false
    private var clipQuery = ""
    private let searchField = ClipSearchFieldView()

    // Escritura deslizando
    private var swipeActive = false
    private var swipeReady = false
    private var swipePoints: [CGPoint] = []
    private var swipeTrail: SwipeTrailView?
    private var swipeCenters: [UInt8: CGPoint] = [:]
    private var swipePitch: CGFloat = 40
    private var swipeStartChar = ""
    private var swipeToken = 0
    private var swipeKeySize: CGSize = .zero
    private var lastAreaSize: CGSize = .zero

    // Modelo de toque: dónde cae el dedo en cada tecla.
    private var wordTouches: [CGPoint] = []
    private var lastTypedLetter: Character?
    private var lastTypedPoint: CGPoint?
    private var lastTypedAt: CFTimeInterval = 0
    private var undoneLetter: Character?
    private var undonePoint: CGPoint?
    private var undoneAt: CFTimeInterval = 0

    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private let longPressHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let selectionHaptic = UISelectionFeedbackGenerator()

    // UI
    private var root: FeedbackHostView!
    private let topBar = TopBarView()
    private let pasteChip = PasteChipView()
    private let clipboardButton = IconTouchButton()
    private let emojiButton = IconTouchButton()
    private var suggestionButtons: [SuggestionButton] = []
    private var confirmOverlay: UIView?
    private var confirmWord: String?
    private var separatorViews: [UIView] = []
    private let keyboardArea = KeyAreaView()
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
        KeyStyle.theme = KeyboardTheme.named(config.theme)
        haptic.prepare()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()

        requestSupplementaryLexicon { [weak self] lex in
            var words: [String] = []
            var shortcuts: [String: String] = [:]
            var names = Set<String>()
            for entry in lex.entries {
                words.append(entry.documentText)
                let input = entry.userInput.trimmingCharacters(in: .whitespaces)
                if !input.isEmpty, !input.contains(" "),
                   input.lowercased() != entry.documentText.lowercased() {
                    shortcuts[input.lowercased()] = entry.documentText
                } else if !entry.documentText.contains(" ") {
                    names.insert(entry.documentText.lowercased())
                }
            }
            let found = (words: words, shortcuts: shortcuts, names: names)
            DispatchQueue.main.async {
                self?.lexicon = found.words
                self?.replacements = found.shortcuts
                self?.lexiconWords = found.names
            }
        }

        // El fondo lo pone el tema (ver `FeedbackHostView`).
        view.backgroundColor = .clear
        inputView?.allowsSelfSizing = true
        root = FeedbackHostView(frame: view.bounds)
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        // Prioridad 999 y una sola constraint reutilizada: con menos prioridad
        // el sistema puede imponer su altura estándar.
        let h = view.heightAnchor.constraint(equalToConstant: desiredHeight())
        h.priority = UILayoutPriority(999)
        h.isActive = true
        heightConstraint = h

        setupTopBar()

        keyboardArea.clipsToBounds = false
        keyboardArea.isMultipleTouchEnabled = true
        root.addSubview(keyboardArea)

        popup.textAlignment = .center
        popup.font = .systemFont(ofSize: CGFloat(config.fontSize) + 12, weight: .medium)
        popup.layer.cornerRadius = 9
        popup.layer.masksToBounds = true
        popup.isHidden = true
        popup.isUserInteractionEnabled = false
        root.addSubview(popup)

        applyTheme()
        rebuildKeys()
        precomputeChecker()
        prewarmClipboard()
        prepareSwipe()
        observeHostForeground()
    }

    /// Carga el vocabulario de deslizamiento en segundo plano: leerlo en el
    /// hilo principal congelaría la apertura del teclado.
    private func prepareSwipe() {
        guard config.swipe || config.smartCorrect else { return }
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
            panel.insert = { [weak self] e in self?.insertEmoji(e) }
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
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        if !reloadConfig() { updateKeyCaps() }
        applyInputTraits()
        updateShiftFromContext()
        noteOwnEdit()
        haptic.prepare()
        if mode == .keys { showKeyboard() }
    }

    /// Recarga las preferencias por si cambiaron en la app y, si cambiaron,
    /// aplica el tema y rehace las teclas. Devuelve si hubo cambios.
    @discardableResult
    private func reloadConfig() -> Bool {
        let newConfig = KbPrefs.Config.load()
        let changed = newConfig != config
        config = newConfig
        updateHeight()
        guard changed else { return false }
        KeyStyle.theme = KeyboardTheme.named(config.theme)
        applyTheme()
        popup.font = .systemFont(ofSize: CGFloat(config.fontSize) + 12, weight: .medium)
        rebuildKeys()
        return true
    }

    /// Volver a una app que ya tenía el teclado abierto no siempre pasa por
    /// `viewWillAppear`: el teclado seguía con el tema y los ajustes de antes
    /// de ir a cambiarlos en ClipDeck.
    private func observeHostForeground() {
        NotificationCenter.default.addObserver(self, selector: #selector(hostWillEnterForeground),
                                               name: .NSExtensionHostWillEnterForeground, object: nil)
    }

    @objc private func hostWillEnterForeground() {
        guard reloadConfig() else { return }
        applyInputTraits()
        if mode == .keys { showKeyboard() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        releaseEdgeTouches()
        // Lo que no hace falta para teclear, después de que el teclado se vea:
        // si la apertura tarda demasiado, la app anfitriona lo cierra.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.prewarmEmojiPanel()
        }
    }

    /// Los reconocedores de gestos del sistema (volver atrás, barra de
    /// inicio) retrasan los toques que empiezan cerca de los bordes de la
    /// pantalla: la «q», la «a», la «p», la «ñ», las mayúsculas, el borrar o
    /// el «123» respondían tarde o se perdían al teclear rápido. Cuelgan de la
    /// ventana o de alguna vista intermedia, así que se recorre toda la cadena
    /// y se repite cuando cambia la jerarquía.
    ///
    /// No basta con el principio del toque. Retenían también el final (los
    /// iconos de portapapeles y emojis actúan al levantar el dedo, y cambiaban
    /// de vista con retraso) y cancelaban los toques cuando un deslizamiento
    /// rápido les parecía un gesto de borde: en el panel de emojis, un
    /// deslizamiento rápido no desplazaba nada. Es la receta que funcionó en
    /// los foros de desarrolladores de Apple (hilo 654645): pedir los bordes
    /// al sistema, quitar las tres esperas y apagar los gestos de borde.
    private func releaseEdgeTouches() {
        var views: [UIView] = []
        var current: UIView? = view
        while let v = current {
            views.append(v)
            current = v.superview
        }
        if let rootView = view.window?.rootViewController?.view, !views.contains(rootView) {
            views.append(rootView)
        }
        for v in views {
            for recognizer in v.gestureRecognizers ?? [] {
                recognizer.delaysTouchesBegan = false
                recognizer.delaysTouchesEnded = false
                recognizer.cancelsTouchesInView = false
                if recognizer is UIScreenEdgePanGestureRecognizer { recognizer.isEnabled = false }
            }
        }
    }

    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { [.left, .right] }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if searchingClips { endClipSearch(showResults: false) }
        // Guardar lo aprendido antes de que el sistema descargue el teclado.
        WordLearner.flush()
        TouchModel.flush()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // El proceso del teclado sigue vivo entre aperturas y la memoria se
        // acumula: fuera el panel de SwiftUI y las miniaturas (se rehacen al
        // volver a abrirlo). Al reaparecer se vuelve a las letras.
        if let host = panelHost {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            panelHost = nil
        }
        allSnapshots = []
        thumbnails = [:]
        clipQuery = ""
        if mode == .clipboard { mode = .keys; refreshMode() }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateHeight()
        // `needsInputModeSwitchKey` no es fiable hasta que el teclado conecta
        // con la app: si cambia, se rehacen las teclas.
        if !searchingClips, layoutKey() != builtLayoutKey { rebuildKeys() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutAll()
        releaseEdgeTouches()
    }

    /// iPhone en horizontal: la altura elegida (pensada en vertical) tapaba
    /// casi toda la pantalla.
    private var isCompactHeight: Bool {
        if traitCollection.verticalSizeClass == .compact { return true }
        // Respaldo por si la extensión no recibe la clase de tamaño: ningún
        // iPhone mide más de 500 pt de ancho en vertical.
        return traitCollection.userInterfaceIdiom == .phone && view.bounds.width > 500
    }

    private func desiredHeight() -> CGFloat {
        let chosen = CGFloat(config.height)
        guard isCompactHeight else { return chosen }
        return max(160, min(chosen * 0.62, 215))
    }

    private func updateHeight() {
        let h = desiredHeight()
        if let c = heightConstraint, c.constant != h { c.constant = h }
    }

    // MARK: Campo de texto de la app

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        applyInputTraits()
        guard !searchingClips else { return }
        let signature = contextSignature()
        // Es el eco de algo que escribimos nosotros: nada que hacer.
        guard signature != ownContext else { return }
        ownContext = signature
        // Lo cambió la app o el usuario: mandó el mensaje (el campo quedó
        // vacío), tocó en otra parte del texto, pegó algo… Lo que sabíamos de
        // la palabra en curso ya no vale y la mayúscula se decide de nuevo.
        wordTouches.removeAll(keepingCapacity: true)
        justSwiped = nil
        noCorrectOnce = nil
        updateShiftFromContext(respectManual: true)
        scheduleSuggestions()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        textDidChange(textInput)
    }

    /// Final del texto antes del cursor y principio del de después. Sólo los
    /// extremos: la app puede recortar el contexto por delante sin que el
    /// texto haya cambiado.
    private func contextSignature() -> String {
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let after = textDocumentProxy.documentContextAfterInput ?? ""
        return String(before.suffix(32)) + "\u{1F}" + String(after.prefix(32))
    }

    private func noteOwnEdit() { ownContext = contextSignature() }

    // Toda edición del documento pasa por aquí para dejar constancia de ella.
    private func put(_ text: String) {
        guard !text.isEmpty else { return }
        textDocumentProxy.insertText(text)
        noteOwnEdit()
    }

    private func deleteBack(_ count: Int = 1) {
        guard count > 0 else { return }
        for _ in 0..<count { textDocumentProxy.deleteBackward() }
        noteOwnEdit()
    }

    private func shiftCursor(_ offset: Int) {
        guard offset != 0 else { return }
        textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
        noteOwnEdit()
    }

    private var contentType: UITextContentType? { textDocumentProxy.textContentType ?? nil }

    /// Campos donde no se corrige, no se pone mayúscula ni se aprende nada:
    /// usuarios, correos, direcciones, códigos.
    private static let literalContentTypes: Set<UITextContentType> = [
        .username, .password, .newPassword, .oneTimeCode, .emailAddress, .URL, .creditCardNumber
    ]

    private var fieldIsLiteral: Bool {
        if numPad != nil { return true }
        switch textDocumentProxy.keyboardType ?? .default {
        case .emailAddress, .URL, .numberPad, .asciiCapableNumberPad, .decimalPad, .phonePad:
            return true
        default:
            break
        }
        if let type = contentType, Self.literalContentTypes.contains(type) { return true }
        return false
    }

    /// Autocorrección y sustituciones de texto, si el usuario y el campo las permiten.
    private var correctionActive: Bool {
        config.autocorrect && !fieldIsLiteral && textDocumentProxy.autocorrectionType != .no
    }

    private var learningActive: Bool {
        config.learnWords && !fieldIsLiteral && textDocumentProxy.autocorrectionType != .no
    }

    private static func numPad(for type: UIKeyboardType?) -> NumPad? {
        switch type ?? .default {
        case .numberPad, .asciiCapableNumberPad: return .digits
        case .decimalPad: return .decimal
        case .phonePad: return .phone
        default: return nil
        }
    }

    /// Adapta el teclado a lo que pide el campo: teclado numérico, «@» en
    /// los correos, tecla de retorno con su nombre (Buscar, Enviar…) y
    /// apariencia clara u oscura. Sólo rehace las teclas si algo cambió.
    private func applyInputTraits() {
        let proxy = textDocumentProxy
        let style: UIUserInterfaceStyle
        switch KeyStyle.theme.appearance {
        // Los temas claros y oscuros fijan la suya: si no, los textos del
        // sistema (etiquetas, el panel del portapapeles) no se leerían.
        case .light: style = .light
        case .dark: style = .dark
        // Sólo se obedece un «oscuro» explícito: muchas apps dicen «claro» (o
        // un valor viejo) aunque el sistema esté en modo oscuro.
        case .system: style = proxy.keyboardAppearance == .dark ? .dark : .unspecified
        }
        if overrideUserInterfaceStyle != style { overrideUserInterfaceStyle = style }
        guard !searchingClips else { return }

        // Campo nuevo: lo elegido en el anterior deja de valer, y lo que
        // estuviera pendiente (una corrección, sugerencias) no debe caer en él.
        // Un nil pasajero (entre campos) no cuenta como campo nuevo: sólo el
        // paso de un identificador a otro.
        if let documentID = currentDocumentID(), documentID != lastDocumentID {
            lastDocumentID = documentID
            documentEpoch += 1
            suggestionWork?.cancel()
            numPadDismissed = false
            symbolsMode = proxy.keyboardType == .numbersAndPunctuation
            pendingRevert = nil
            justSwiped = nil
            noCorrectOnce = nil
            autoSpaceInserted = false
            wordTouches.removeAll(keepingCapacity: true)
        }
        numPad = numPadDismissed ? nil : Self.numPad(for: proxy.keyboardType)
        if layoutKey() != builtLayoutKey { rebuildKeys() }
    }

    /// `documentIdentifier` se declara no opcional, pero entre un campo y otro
    /// vale nil y leerlo desde Swift tumba el teclado (pasa en iOS 26). Se
    /// pregunta por Objective-C, que sí admite el nil.
    private func currentDocumentID() -> UUID? {
        let selector = NSSelectorFromString("documentIdentifier")
        guard let proxy = textDocumentProxy as? NSObject, proxy.responds(to: selector),
              let value = proxy.perform(selector)?.takeUnretainedValue() else { return nil }
        return value as? UUID
    }

    /// Todo lo que decide qué teclas se dibujan.
    private func layoutKey() -> String {
        let punct = punctuationKeys()
        let ret = returnKeyStyle()
        return "\(String(describing: numPad))|\(symbolsMode)|\(punct.left)\(punct.right)|\(ret.title)|\(ret.accent)|\(needsInputModeSwitchKey)"
    }

    private func punctuationKeys() -> (left: String, right: String) {
        if searchingClips { return (config.punctLeft, config.punctRight) }
        switch textDocumentProxy.keyboardType ?? .default {
        case .emailAddress: return ("@", ".")
        case .URL: return ("/", ".")
        case .twitter: return ("@", "#")
        default: return (config.punctLeft, config.punctRight)
        }
    }

    /// Nombre de la tecla de retorno según el campo ("" = ↵ normal).
    private func returnKeyStyle() -> (title: String, accent: Bool) {
        if searchingClips { return ("Buscar", true) }
        switch textDocumentProxy.returnKeyType ?? .default {
        case .go: return ("Ir", true)
        case .google, .search, .yahoo: return ("Buscar", true)
        case .join: return ("Unirse", true)
        case .next: return ("Siguiente", false)
        case .route: return ("Ruta", true)
        case .send: return ("Enviar", true)
        case .done: return ("OK", true)
        case .emergencyCall: return ("SOS", true)
        case .continue: return ("Continuar", true)
        default: return ("", false)
        }
    }

    // MARK: Tema

    /// Pinta lo que no se rehace con las teclas: el fondo, la barra superior,
    /// el globo de la tecla y los paneles. Las teclas toman el tema al
    /// construirse (`rebuildKeys`), y la apariencia clara u oscura la fija
    /// `applyInputTraits`.
    private func applyTheme() {
        let theme = KeyStyle.theme
        root.applyBackdrop(theme.backdrop)
        popup.backgroundColor = theme.popup
        popup.textColor = theme.text
        separatorViews.forEach { $0.backgroundColor = theme.separator }
        suggestionButtons.forEach { $0.applyTheme() }
        pasteChip.applyTheme()
        searchField.applyTheme()
        emojiPanel?.applyTheme()
        updateTopIcons()
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
                topBar.addSubview(sep)
                separatorViews.append(sep)
            }
        }

        pasteChip.onTap = { [weak self] kind in self?.pasteChipTapped(kind) }
        topBar.addSubview(pasteChip)

        searchField.isHidden = true
        searchField.onClear = { [weak self] in
            guard let self else { return }
            self.keyFeedback()
            self.clipQuery = ""
            self.updateSearchField()
        }
        topBar.addSubview(searchField)
    }

    // MARK: Construcción de teclas

    private func makeRows() -> [[KeySpec]] {
        if let numPad { return numPadRows(numPad) }
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
        let punct = punctuationKeys()
        let ret = returnKeyStyle()
        bottom.append(KeySpec(value: punct.left, kind: .comma, widthFactor: 1.0,
                              variants: punctuationVariants(for: punct.left)))
        bottom.append(KeySpec(value: "", kind: .space, widthFactor: 5.0))
        bottom.append(KeySpec(value: punct.right, kind: .period, widthFactor: 1.0,
                              variants: punctuationVariants(for: punct.right)))
        bottom.append(KeySpec(value: ret.title, kind: .ret, widthFactor: 1.6, accent: ret.accent))
        result.append(bottom)

        return result
    }

    /// Teclado numérico grande para códigos, importes y teléfonos, en vez de
    /// obligar a pulsar «123» y buscar los números pequeños.
    private func numPadRows(_ pad: NumPad) -> [[KeySpec]] {
        var result: [[KeySpec]] = ["123", "456", "789"].map { row in
            row.map { KeySpec(value: String($0), kind: .char) }
        }
        var bottom: [KeySpec] = []
        var leftWidth: CGFloat = 1
        if needsInputModeSwitchKey {
            bottom.append(KeySpec(value: "", kind: .globe, widthFactor: 0.5))
            leftWidth -= 0.5
        }
        switch pad {
        case .digits:
            bottom.append(KeySpec(value: "ABC", kind: .mode, widthFactor: leftWidth))
        case .decimal:
            let separator = Locale.current.decimalSeparator ?? ","
            bottom.append(KeySpec(value: separator, kind: .char, widthFactor: leftWidth,
                                  variants: separator == "," ? ["."] : [","]))
        case .phone:
            bottom.append(KeySpec(value: "+", kind: .char, widthFactor: leftWidth, variants: ["*", "#", ",", ";"]))
        }
        bottom.append(KeySpec(value: "0", kind: .char))
        bottom.append(KeySpec(value: "", kind: .backspace))
        result.append(bottom)
        return result
    }

    private func variants(for key: String) -> [String] {
        config.accents ? (KbData.keyVariants[key] ?? []) : []
    }

    /// Pulsación larga en la coma y el punto de la fila de abajo: los signos
    /// del español sin cambiar de capa («¿?», «¡!»), como piden los usuarios
    /// que vienen de Gboard.
    private static let bottomPunctuationVariants: [String: [String]] = [
        ".": ["?", "¿", "!", "¡", "…", ":", ";"],
        ",": [";", ":", "¿", "¡", "\"", "'", "-"],
        "?": ["¿", "!", "¡", ".", ","],
        "!": ["¡", "?", "¿", ".", ","],
        "@": ["#", "_", "."],
        "/": [":", "-", "_", "."],
        "#": ["@", "_"]
    ]

    private func punctuationVariants(for key: String) -> [String] {
        config.accents ? (Self.bottomPunctuationVariants[key] ?? []) : []
    }

    private func rebuildKeys() {
        keyViews.forEach { $0.removeFromSuperview() }
        keyViews.removeAll()
        swipeCenters = [:]
        rows = makeRows()
        builtLayoutKey = layoutKey()

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

        let compact = isCompactHeight
        let topH: CGFloat = compact ? 36 : 44
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
        let edge: CGFloat = 17
        let btn: CGFloat = 46
        clipboardButton.frame = CGRect(x: edge, y: 2, width: btn, height: topH - 4)
        emojiButton.frame = CGRect(x: W - edge - btn, y: 2, width: btn, height: topH - 4)
        root.priorityTargets = [
            (CGRect(x: edge - 8, y: 0, width: btn + 16, height: topH), clipboardButton),
            (CGRect(x: W - edge - btn - 8, y: 0, width: btn + 16, height: topH), emojiButton)
        ]
        let sugX = clipboardButton.frame.maxX + 6
        let sugTotal = max(emojiButton.frame.minX - 6 - sugX, 0)
        let sugW = sugTotal / 3
        let sugY: CGFloat = compact ? 2 : 5
        for (i, b) in suggestionButtons.enumerated() {
            b.frame = CGRect(x: sugX + CGFloat(i) * sugW, y: sugY, width: sugW, height: topH - 2 * sugY)
        }
        for (i, sep) in separatorViews.enumerated() {
            sep.frame = CGRect(x: sugX + CGFloat(i + 1) * sugW - 0.5, y: topH / 2 - 10, width: 1, height: 20)
        }
        pasteChip.frame = CGRect(x: sugX, y: 0, width: sugTotal, height: topH)
        searchField.frame = CGRect(x: sugX, y: 4, width: max(W - sugX - edge, 0), height: topH - 8)

        let areaY = topH
        let areaH = H - topH
        keyboardArea.frame = CGRect(x: 0, y: areaY, width: W, height: areaH)
        // Al girar el iPhone las teclas cambian de sitio: los centros guardados
        // para el deslizamiento y el modelo de toque ya no valen.
        if keyboardArea.bounds.size != lastAreaSize, !swipeActive {
            lastAreaSize = keyboardArea.bounds.size
            swipeCenters = [:]
        }
        panelHost?.view.frame = keyboardArea.frame
        emojiPanel?.frame = keyboardArea.frame
        if trackpadActive {
            trackpadOverlay.frame = keyboardArea.frame
            trackpadHint?.frame = trackpadOverlay.bounds
        }

        // Distribuye las filas para rellenar la altura disponible.
        let rowCount = CGFloat(keyViews.count)
        let rowSpacing: CGFloat = compact ? 4 : 6
        let pad: CGFloat = 3
        let usableH = areaH - rowSpacing * (rowCount - 1) - 4
        let rowH = max(min(usableH / rowCount, 64), compact ? 24 : 34)
        let totalH = rowH * rowCount + rowSpacing * (rowCount - 1)
        var y = max((areaH - totalH) / 2, 2)

        // En el teclado numérico las teclas son el triple de anchas: números grandes.
        let fontSize = CGFloat(config.fontSize) + (numPad != nil ? 6 : 0)
        for rowView in keyViews {
            rowView.frame = CGRect(x: 0, y: y, width: W, height: rowH)
            rowView.layoutKeys(sidePadding: pad, spacing: numPad != nil ? 6 : 5, fontSize: fontSize)
            y += rowH + rowSpacing
        }
    }

    // MARK: Popup de tecla

    func showPopup(for keyView: KeyView, text: String) {
        // En el teclado numérico las teclas ya son grandes: el globo sobra.
        guard config.keyPopup, numPad == nil, keyView.spec.kind == .char, !text.isEmpty else { return }
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
        l.layer.cornerRadius = 12
        l.layer.masksToBounds = true
        l.numberOfLines = 0
        l.isHidden = true
        l.isUserInteractionEnabled = false
        return l
    }()

    /// Aviso breve centrado (p. ej. al olvidar una sugerencia). Los largos
    /// (cómo pegar una imagen) ocupan dos líneas y duran más.
    func showHint(_ text: String, duration: TimeInterval = 1.6) {
        if hintLabel.superview == nil { root.addSubview(hintLabel) }
        hintLabel.text = text
        hintLabel.textColor = KeyStyle.theme.text
        hintLabel.backgroundColor = KeyStyle.theme.menu
        let maxW = max(root.bounds.width - 24, 40)
        let fitted = hintLabel.sizeThatFits(CGSize(width: maxW - 24, height: .greatestFiniteMagnitude))
        let w = min(fitted.width + 24, maxW)
        let h = max(fitted.height + 12, 30)
        hintLabel.frame = CGRect(x: (root.bounds.width - w) / 2, y: topBar.frame.maxY + 2, width: w, height: h)
        hintLabel.isHidden = false
        root.bringSubviewToFront(hintLabel)
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideHint), object: nil)
        perform(#selector(hideHint), with: nil, afterDelay: duration)
    }

    @objc private func hideHint() { hintLabel.isHidden = true }

    // MARK: Acciones de tecla

    /// Corrector compartido: instanciar UITextChecker es caro y antes se creaba
    /// uno nuevo en cada autocorrección y en cada cálculo de sugerencias.
    static let sharedChecker = UITextChecker()

    /// Cola única para todo lo que usa el corrector del sistema. Las
    /// sugerencias y las correcciones iban a la cola global y podían usar el
    /// mismo UITextChecker a la vez desde dos hilos, cosa que no admite.
    static let textQueue = DispatchQueue(label: "clipdeck.keyboard.text", qos: .userInitiated)

    /// Idiomas del corrector del sistema tal como los nombra este iPhone
    /// («es_ES», «es»…). Con un código que no reconoce, UITextChecker da
    /// todo por bien escrito y no completa nada.
    static let checkerLanguages: [String] = {
        let available = UITextChecker.availableLanguages
        func pick(_ preferred: String, _ prefix: String) -> String? {
            if available.contains(preferred) { return preferred }
            return available.first { $0.hasPrefix(prefix) }
        }
        let languages = [pick("es_ES", "es"), pick("en_US", "en")].compactMap { $0 }
        return languages.isEmpty ? ["es_ES", "en_US"] : languages
    }()

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

    @discardableResult
    func insertChar(_ base: String, at point: CGPoint? = nil) -> String {
        // Los signos que cierran palabra desde la capa de símbolos pasan por
        // el mismo camino que la coma y el punto: corrigen y aprenden la
        // palabra anterior («que tal?» corregía «tal» sólo con el punto).
        if symbolsMode, numPad == nil, !searchingClips, Self.closingPunctuation.contains(base) {
            punctTap(base)
            return base
        }
        keyFeedback()
        autoSpaceInserted = false
        var value = base
        if let point, numPad == nil, !searchingClips, base.count == 1, base.first?.isLetter == true, !symbolsMode {
            value = resolveLetter(base, at: point)
        }
        let upper = shift != .off && !symbolsMode
        let out = upper ? value.uppercased() : value
        if searchingClips {
            appendToQuery(out)
        } else {
            put(out)
            if let point, numPad == nil, let ch = value.lowercased().first, ch.isLetter, !symbolsMode {
                noteKeyPress(ch, at: point)
            }
        }
        if shift == .on && !symbolsMode {
            // En los campos «todo en mayúsculas» la mayúscula se queda puesta.
            shift = (!searchingClips && textDocumentProxy.autocapitalizationType == .allCharacters
                     && config.autoCapital && !fieldIsLiteral) ? .on : .off
            shiftByUser = false
            updateKeyCaps()
        }
        pendingRevert = nil
        if !searchingClips { scheduleSuggestions() }
        return out
    }

    static let closingPunctuation: Set<String> = [".", ",", "?", "!", ";", ":"]

    // MARK: - Cómo teclea el usuario
    //
    // Cada pulsación deja dos cosas: el punto exacto dentro de la palabra que se
    // está escribiendo (lo usa el corrector para saber si un toque estuvo a
    // medio camino entre dos teclas) y una muestra del desvío respecto al centro
    // de esa tecla (lo usa el modelo que mueve las fronteras invisibles).

    private func noteKeyPress(_ letter: Character, at point: CGPoint) {
        wordTouches.append(point)
        if swipeCenters.isEmpty { rebuildSwipeGeometry() }
        let size = swipeKeySize
        guard size.width > 1, size.height > 1,
              let idx = SwipeAlphabet.index(letter),
              let center = swipeCenters[idx] else { return }

        // Señal fuerte: borró una letra y escribió su vecina. Ese toque debía
        // haber caído en la tecla nueva, así que cuenta por varias muestras.
        if let previousLetter = undoneLetter, let previousPoint = undonePoint,
           previousLetter != letter,
           CACurrentMediaTime() - undoneAt < 3.0,
           let oldIdx = SwipeAlphabet.index(previousLetter),
           let oldCenter = swipeCenters[oldIdx],
           abs(center.y - oldCenter.y) < size.height * 0.6,
           abs(center.x - oldCenter.x) < size.width * 1.9 {
            TouchModel.record(letter,
                              dx: Double((previousPoint.x - center.x) / size.width),
                              dy: Double((previousPoint.y - center.y) / size.height),
                              weight: 6)
        }
        undoneLetter = nil
        undonePoint = nil

        TouchModel.record(letter,
                          dx: Double((point.x - center.x) / size.width),
                          dy: Double((point.y - center.y) / size.height))
        lastTypedLetter = letter
        lastTypedPoint = point
        lastTypedAt = CACurrentMediaTime()
    }

    /// Decide qué letra quiso escribir según dónde suele tocar el usuario.
    ///
    /// Las teclas no se mueven de sitio: lo que se corre es la frontera
    /// invisible entre una tecla y su vecina. Sólo actúa cerca del borde, con
    /// suficientes muestras acumuladas y cuando la vecina gana con holgura.
    private func resolveLetter(_ base: String, at point: CGPoint) -> String {
        guard config.adaptiveKeys, TouchModel.totalSamples >= 120 else { return base }
        guard let ch = base.lowercased().first, let idx = SwipeAlphabet.index(ch) else { return base }
        if swipeCenters.isEmpty { rebuildSwipeGeometry() }
        let size = swipeKeySize
        guard size.width > 1, let pressed = swipeCenters[idx] else { return base }
        guard abs(point.x - pressed.x) > size.width * 0.26 else { return base }

        let pressedScore = biasedDistance(point, index: idx, center: pressed, size: size)
        var winner = idx
        var winnerScore = pressedScore
        for (other, center) in swipeCenters where other != idx {
            guard abs(center.y - pressed.y) < size.height * 0.6,
                  abs(center.x - pressed.x) < size.width * 1.9 else { continue }
            let d = biasedDistance(point, index: other, center: center, size: size)
            if d < winnerScore { winnerScore = d; winner = other }
        }
        guard winner != idx, winnerScore < pressedScore * 0.82 else { return base }
        return String(SwipeAlphabet.letters[Int(winner)])
    }

    private func biasedDistance(_ p: CGPoint, index: UInt8, center: CGPoint, size: CGSize) -> CGFloat {
        let bias = TouchModel.bias(SwipeAlphabet.letters[Int(index)])
        let dx = (p.x - (center.x + CGFloat(bias.x) * size.width)) / size.width
        let dy = (p.y - (center.y + CGFloat(bias.y) * size.height)) / size.height
        return sqrt(dx * dx + dy * dy)
    }

    /// Reemplaza el último carácter insertado por una variante acentuada.
    func replaceLastWithVariant(_ variant: String) {
        if searchingClips {
            if !clipQuery.isEmpty { clipQuery.removeLast() }
            appendToQuery(variant)
            return
        }
        deleteBack()
        put(variant)
        // «¿» y «¡» al empezar frase dejan la mayúscula puesta.
        if variant.first?.isLetter != true { updateShiftFromContext() }
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
        shiftByUser = shift == .on
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
        autoSpaceInserted = false
        deleteRepeats = 0
        deleteTimer?.invalidate()
        deleteTimer = Self.commonTimer(0.45) { [weak self] in self?.scheduleNextDelete() }

        if searchingClips {
            if !clipQuery.isEmpty { clipQuery.removeLast(); updateSearchField() }
            return
        }
        // Como en Gboard: borrar justo después de una autocorrección la
        // deshace y deja la palabra tal como se escribió.
        if config.undoCorrectOnDelete, undoAutocorrect(fromBackspace: true) { return }

        if let l = lastTypedLetter, let p = lastTypedPoint,
           CACurrentMediaTime() - lastTypedAt < 2.5 {
            undoneLetter = l
            undonePoint = p
            undoneAt = CACurrentMediaTime()
        }
        lastTypedLetter = nil
        if !wordTouches.isEmpty { wordTouches.removeLast() }
        justSwiped = nil
        deleteBack()
        updateShiftFromContext()
        scheduleSuggestions()
    }

    /// Cada repetición borra más rápido; tras un rato pasa a borrar palabra a palabra.
    private func scheduleNextDelete() {
        deleteRepeats += 1
        let interval: TimeInterval = deleteRepeats < 8 ? 0.11 : (deleteRepeats < 18 ? 0.06 : 0.035)
        deleteTimer = Self.commonTimer(interval) { [weak self] in
            guard let self else { return }
            if self.searchingClips {
                if !self.clipQuery.isEmpty { self.clipQuery.removeLast(); self.updateSearchField() }
            } else {
                if self.deleteRepeats > 26 { self.deleteWord() } else { self.deleteBack() }
                self.wordTouches.removeAll(keepingCapacity: true)
                self.updateShiftFromContext()
            }
            self.scheduleNextDelete()
        }
    }

    private func deleteWord() {
        guard let before = textDocumentProxy.documentContextBeforeInput, !before.isEmpty else {
            deleteBack(); return
        }
        deleteBack(max(TextRules.lastWordLength(in: before), 1))
    }

    func backspaceUp() {
        deleteTimer?.invalidate()
        deleteTimer = nil
        deleteRepeats = 0
        guard !searchingClips else { return }
        updateShiftFromContext()
        scheduleSuggestions()
    }

    // MARK: Deslizar desde borrar
    //
    // Arrastrar el dedo hacia la izquierda desde la tecla de borrar elimina
    // palabras enteras, una por cada tramo recorrido; volver hacia la derecha
    // sin soltar las recupera (se guardan en orden).
    private var swipeDeleted: [String] = []

    func backspaceDrag(steps: Int) {
        guard !searchingClips else { return }
        if steps > swipeDeleted.count {
            deleteTimer?.invalidate(); deleteTimer = nil
            while steps > swipeDeleted.count {
                let before = textDocumentProxy.documentContextBeforeInput ?? ""
                let n = TextRules.lastWordLength(in: before)
                guard n > 0 else { break }
                swipeDeleted.append(String(before.suffix(n)))
                deleteBack(n)
                selectionFeedback()
            }
        } else {
            while steps < swipeDeleted.count, let chunk = swipeDeleted.popLast() {
                put(chunk)
                selectionFeedback()
            }
        }
        wordTouches.removeAll(keepingCapacity: true)
        updateShiftFromContext()
    }

    func backspaceDragEnded() {
        swipeDeleted.removeAll()
        scheduleSuggestions()
    }

    func toggleSymbols() {
        keyFeedback()
        if numPad != nil {
            // «ABC» en un campo numérico: letras hasta cambiar de campo.
            numPadDismissed = true
            numPad = nil
            symbolsMode = false
        } else {
            symbolsMode.toggle()
        }
        rebuildKeys()
        if numPad == nil && !symbolsMode && !searchingClips { updateShiftFromContext() }
    }

    func switchKeyboard() { advanceToNextInputMode() }

    func spaceTap() {
        if searchingClips { keyFeedback(); appendToQuery(" "); return }
        let now = Date()
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        if config.doubleSpace,
           now.timeIntervalSince(lastSpaceTap) < 0.6,
           before.hasSuffix(" "),
           let previous = before.dropLast().last,
           previous.isLetter || previous.isNumber || "\")]»”’".contains(previous) {
            // Sólo se cambia el espacio por «. »: la palabra ya se corrigió y
            // aprendió con el primer espacio. Antes se volvía a cerrar, y se
            // aprendía dos veces y como seguida de sí misma («hola hola»).
            keyFeedback()
            deleteBack()
            put(". ")
            updateShiftFromContext()
            scheduleSuggestions()
            lastSpaceTap = .distantPast       // un tercer espacio es un espacio
            return
        }
        commit(" ")
        lastSpaceTap = now
    }

    /// Mueve el cursor `offset` caracteres visibles. `adjustTextPosition`
    /// cuenta en unidades UTF-16, así que un emoji (o una bandera) ocupa
    /// varias: contando letras el cursor quedaba dentro del emoji.
    func moveCursor(_ offset: Int) {
        guard offset != 0 else { return }
        let proxy = textDocumentProxy
        let units: Int
        if offset < 0 {
            let before = proxy.documentContextBeforeInput ?? ""
            units = before.isEmpty ? offset : -before.suffix(-offset).utf16.count
        } else {
            let after = proxy.documentContextAfterInput ?? ""
            units = after.isEmpty ? offset : after.prefix(offset).utf16.count
        }
        shiftCursor(units)
        wordTouches.removeAll(keepingCapacity: true)
        justSwiped = nil
        autoSpaceInserted = false
        pendingRevert = nil
    }

    // MARK: - Trackpad

    var isTrackpadActive: Bool { trackpadActive }

    /// Entra en modo trackpad: las teclas se apagan y toda el área del teclado
    /// pasa a mover el cursor, igual que al mantener el espacio en iOS.
    func enterTrackpad(at point: CGPoint) {
        guard config.trackpad, !trackpadActive, !searchingClips else { return }
        trackpadActive = true
        trackpadMoved = false
        trackpadLastPoint = point
        trackpadAccumX = 0
        trackpadAccumY = 0

        longPressFeedback()

        // Atenúa las teclas (efecto "se apagan las letras").
        keyViews.forEach { $0.setDimmed(true) }

        trackpadOverlay.frame = keyboardArea.frame
        trackpadOverlay.backgroundColor = KeyStyle.theme.function.withAlphaComponent(0.25)
        trackpadOverlay.isUserInteractionEnabled = false
        if trackpadOverlay.superview == nil { root.addSubview(trackpadOverlay) }
        trackpadOverlay.isHidden = false
        root.bringSubviewToFront(trackpadOverlay)

        if trackpadHint == nil {
            let l = UILabel()
            l.text = "Mueve el cursor"
            l.font = .systemFont(ofSize: 14, weight: .medium)
            l.textColor = KeyStyle.theme.secondaryText
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
                moveCursor(chars)
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
        wordTouches.removeAll(keepingCapacity: true)
        justSwiped = nil
        updateShiftFromContext()
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

        // Todo sale de una sola lectura del texto: tras mover el cursor el
        // contexto tarda en actualizarse, y antes, al saltar dos líneas de
        // golpe, se volvía a medir desde el mismo salto de línea. El
        // desplazamiento final va en UTF-16, que es lo que cuenta iOS.
        if lines < 0 {
            var rest = Substring(before)
            for _ in 0..<(-lines) {
                if let idx = rest.lastIndex(of: "\n") {
                    rest = rest[..<idx]
                } else {
                    rest = rest.dropLast(min(fallbackLineLength, rest.count))
                    break
                }
            }
            let units = before.utf16.count - rest.utf16.count
            if units > 0 { shiftCursor(-units) }
        } else {
            var rest = Substring(after)
            for _ in 0..<lines {
                if let idx = rest.firstIndex(of: "\n") {
                    rest = rest[rest.index(after: idx)...]
                } else {
                    rest = rest.dropFirst(min(fallbackLineLength, rest.count))
                    break
                }
            }
            let units = after.utf16.count - rest.utf16.count
            if units > 0 { shiftCursor(units) }
        }
    }

    // MARK: - Escritura deslizando

    var isSwipeActive: Bool { swipeActive }

    /// Sólo con el diccionario ya cargado, en el teclado de letras y fuera del
    /// modo trackpad.
    var swipeEnabled: Bool {
        config.swipe && swipeReady && !symbolsMode && !trackpadActive && numPad == nil && !searchingClips
    }

    /// Empieza un trazo. La letra que se insertó al tocar la tecla se retira,
    /// porque va a ser reemplazada por la palabra completa.
    func beginSwipe(startChar: String, from point: CGPoint) {
        guard !swipeActive, swipeEnabled else { return }
        wordTouches.removeAll(keepingCapacity: true)
        // La letra del arranque la consume el trazo: si luego se borra no es
        // una «letra corregida» y no debe enseñar nada al modelo de toque.
        lastTypedLetter = nil
        swipeActive = true
        swipeStartChar = startChar
        deleteBack()
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
        put(startChar)
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

        // Separación automática con la palabra anterior, como en Gboard (pero
        // no detrás de «¿», «¡», un paréntesis o unas comillas de apertura).
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let previous = TextRules.lastCompleteWord(in: before)
        if let last = before.last, !last.isWhitespace, !TextRules.openingPunctuation.contains(last) {
            put(" ")
        }
        put(word)
        justSwiped = word
        // La confirmación del trazo va con la vibración de gestos, que es la
        // que el usuario deja activa aunque silencie la de teclas.
        longPressFeedback()

        if learningActive {
            Self.textQueue.async {
                WordLearner.learn(best)
                if !previous.isEmpty { WordLearner.learnBigram(previous: previous, next: best) }
            }
        }
        pendingRevert = nil
        wordTouches.removeAll(keepingCapacity: true)
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
        var tallest: CGFloat = 0
        for rowView in keyViews {
            for k in rowView.letterKeys() {
                guard let ch = k.spec.value.lowercased().first,
                      let idx = SwipeAlphabet.index(ch) else { continue }
                let f = k.convert(k.bounds, to: view)
                centers[idx] = CGPoint(x: f.midX, y: f.midY)
                if f.width > widest { widest = f.width }
                if f.height > tallest { tallest = f.height }
            }
        }
        swipeCenters = centers
        swipePitch = widest > 1 ? widest + 5 : 40
        swipeKeySize = CGSize(width: max(widest, 1), height: max(tallest, 1))
    }

    func returnTap() {
        if searchingClips { keyFeedback(); endClipSearch(showResults: true); return }
        commit("\n")
    }

    /// `feedback: false` cuando la tecla ya vibró al apoyar el dedo (los
    /// signos con pulsación larga se escriben al soltar).
    func punctTap(_ ch: String, feedback: Bool = true) {
        if searchingClips {
            if feedback { keyFeedback() }
            appendToQuery(ch)
            return
        }
        commit(ch, feedback: feedback)
    }

    /// Signo elegido en un globo que no cierra palabra («¿», «¡», comillas…):
    /// no gasta la mayúscula de inicio de frase.
    func insertSymbol(_ symbol: String, feedback: Bool = true) {
        if feedback { keyFeedback() }
        if searchingClips { appendToQuery(symbol); return }
        autoSpaceInserted = false
        pendingRevert = nil
        justSwiped = nil
        put(symbol)
        updateShiftFromContext()
        scheduleSuggestions()
    }

    /// Cierra la palabra: sustitución de texto, autocorrección, aprendizaje y separador.
    private func commit(_ separator: String, feedback: Bool = true) {
        if feedback { keyFeedback() }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let word = TextRules.wordBefore(before)
        let previous = TextRules.previousWord(in: before)
        pendingRevert = nil
        let swiped = justSwiped
        justSwiped = nil
        let keepAsTyped = noCorrectOnce
        noCorrectOnce = nil

        // Sustituciones de texto del usuario («xq» → «porque»), que con un
        // teclado de terceros se perdían.
        if !word.isEmpty, correctionActive, let replacement = replacements[word.lowercased()] {
            deleteBack(word.count)
            put(replacement + separator)
            wordTouches.removeAll(keepingCapacity: true)
            updateShiftFromContext()
            scheduleSuggestions()
            return
        }

        // Tras elegir una sugerencia el teclado ya dejó un espacio: un signo
        // de cierre va pegado a la palabra y el espacio pasa detrás.
        if autoSpaceInserted, word.isEmpty, Self.closingPunctuation.contains(separator),
           before.hasSuffix(" ") {
            autoSpaceInserted = false
            deleteBack()
            put(separator + " ")
            updateShiftFromContext()
            scheduleSuggestions()
            return
        }
        autoSpaceInserted = false

        // El separador se inserta de inmediato: la escritura nunca espera al
        // corrector ni al aprendizaje.
        put(separator)
        updateShiftFromContext()

        let plain = TextRules.isPlainWord(word)
        let lower = word.lowercased()
        // No se corrige: lo recién escrito deslizando (ya es del vocabulario),
        // lo que el usuario acaba de deshacer ni los nombres de sus contactos.
        let doCorrect = plain && correctionActive && word != swiped
            && lower != keepAsTyped && !lexiconWords.contains(lower)
        let doLearn = plain && learningActive && word != swiped
        let smart = config.smartCorrect
        let touches = wordTouches
        let centers = swipeCenters
        let keySize = swipeKeySize
        let epoch = documentEpoch
        wordTouches.removeAll(keepingCapacity: true)

        if doCorrect || doLearn {
            // Corrector y aprendizaje en segundo plano; sólo el reemplazo del
            // texto vuelve al hilo principal, y sólo si hace falta.
            Self.textQueue.async { [weak self] in
                var fix: String?
                if doCorrect {
                    if smart, SwipeLexicon.shared.isLoaded {
                        fix = SmartCorrector.correction(for: word, touches: touches,
                                                        keyCenters: centers, keySize: keySize,
                                                        previous: previous)
                    } else {
                        fix = KeyboardViewController.autocorrection(for: word)
                    }
                }
                if doLearn {
                    let finalWord = fix ?? word
                    WordLearner.learn(finalWord)
                    if !previous.isEmpty {
                        WordLearner.learnBigram(previous: previous, next: finalWord)
                    }
                }
                guard let fix else { return }
                DispatchQueue.main.async {
                    guard let self, self.documentEpoch == epoch else { return }
                    self.applyCorrection(original: word, fixed: fix)
                }
            }
        }
        scheduleSuggestions()
    }

    /// Sustituye la palabra ya escrita por su corrección, respetando lo que el
    /// usuario tecleó detrás (espacio, «. », «?»…) y sin pisar lo que haya
    /// escrito después. Antes sólo se aceptaba el separador exacto: un doble
    /// espacio rápido tras una errata dejaba la palabra sin corregir.
    private func applyCorrection(original: String, fixed: String) {
        guard !searchingClips else { return }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        // Lo escrito tras la palabra: sólo espacios y signos. Si ya empezó
        // otra palabra o movió el cursor, no se toca nada.
        guard let tail = TextRules.trailingSeparators(after: original, in: before) else { return }
        deleteBack(original.count + tail.count)
        put(fixed + tail)
        pendingRevert = Revert(original: original, fixed: fixed, tail: tail)
        scheduleSuggestions()
    }

    /// La última autocorrección, si el texto sigue como la dejamos.
    private func validRevert() -> Revert? {
        guard let revert = pendingRevert else { return nil }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        guard before.hasSuffix(revert.fixed + revert.tail) else {
            pendingRevert = nil
            return nil
        }
        return revert
    }

    /// Deshace la última autocorrección. Desde la barra se conserva lo escrito
    /// detrás; con la tecla borrar, como en Gboard, se borra además el último
    /// signo (normalmente el espacio) y el cursor queda al final de la palabra.
    /// En los dos casos esa palabra no se vuelve a corregir.
    @discardableResult
    private func undoAutocorrect(fromBackspace: Bool) -> Bool {
        guard let revert = validRevert() else { return false }
        pendingRevert = nil
        deleteBack(revert.fixed.count + revert.tail.count)
        put(revert.original + (fromBackspace ? String(revert.tail.dropLast()) : revert.tail))
        wordTouches.removeAll(keepingCapacity: true)
        if fromBackspace {
            noCorrectOnce = revert.original.lowercased()
        } else {
            WordLearner.learn(revert.original)
        }
        WordLearner.protect(revert.original)
        updateShiftFromContext()
        scheduleSuggestions()
        return true
    }

    /// Decide la mayúscula según lo que pide el campo y el texto previo.
    /// Con `respectManual` no se quita una mayúscula que puso el usuario.
    private func updateShiftFromContext(respectManual: Bool = false) {
        guard shift != .caps, !searchingClips else { return }
        if respectManual && shiftByUser && shift == .on { return }
        let newShift: ShiftState = contextWantsCapital() ? .on : .off
        shiftByUser = false
        if newShift != shift { shift = newShift; updateKeyCaps() }
    }

    private func contextWantsCapital() -> Bool {
        guard config.autoCapital, numPad == nil, !fieldIsLiteral else { return false }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        switch textDocumentProxy.autocapitalizationType ?? .sentences {
        case .none: return false
        case .allCharacters: return true
        case .words: return TextRules.startsWord(before)
        default: return TextRules.startsSentence(before)
        }
    }

    // MARK: Sugerencias y corrección

    private func precomputeChecker() {
        let languages = Self.checkerLanguages      // se resuelve aquí, en el hilo principal
        Self.textQueue.async {
            let c = KeyboardViewController.sharedChecker
            for language in languages {
                _ = c.completions(forPartialWordRange: NSRange(location: 0, length: 2),
                                  in: "ho", language: language)
            }
        }
    }

    /// Programa el cálculo de sugerencias en segundo plano con debounce, para
    /// que el corrector no bloquee nunca la siguiente pulsación de tecla.
    private func scheduleSuggestions() {
        guard !searchingClips else { return }
        guard config.prediction, numPad == nil else { setSuggestions([]); return }
        suggestionWork?.cancel()
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let lex = lexicon
        let shortcuts = correctionActive ? replacements : [:]
        let capNext = shift != .off
        let work = DispatchWorkItem {
            let result = KeyboardViewController.computeSuggestions(before: before, lexicon: lex,
                                                                  replacements: shortcuts,
                                                                  capitalizeNext: capNext)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.mode == .keys, !self.searchingClips else { return }
                self.setSuggestions(result)
            }
        }
        suggestionWork = work
        Self.textQueue.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// Cálculo puro (sin tocar UI) — seguro en segundo plano.
    private static func computeSuggestions(before: String, lexicon: [String],
                                           replacements: [String: String],
                                           capitalizeNext: Bool) -> [String] {
        let word = TextRules.wordBefore(before)
        if word.isEmpty || word.rangeOfCharacter(from: .letters) == nil {
            return nextWords(lastWord: TextRules.lastCompleteWord(in: before), capitalizeNext: capitalizeNext)
        }

        let lower = word.lowercased()
        let capitalize = word.first?.isUppercase == true
        let blocked = WordLearner.blockedWords()
        // La sustitución de texto del usuario va primero y tal cual.
        let pinned = replacements[lower].map { [$0] } ?? []
        var results: [String] = []

        if word.count < 2 {
            // Con una sola letra: lo que suele seguir a la palabra anterior y
            // empieza por esa letra, antes que cualquier otra cosa.
            let previous = TextRules.previousWord(in: before)
            if !previous.isEmpty {
                results += WordLearner.successors(of: previous).filter { $0.hasPrefix(lower) }
            }
            results += WordLearner.matches(prefix: lower, limit: 3)
            results += KbData.commonWords.filter { $0.hasPrefix(lower) }
        } else {
            results += WordLearner.matches(prefix: lower, limit: 2)
            for entry in lexicon where entry.lowercased().hasPrefix(lower) {
                results.append(entry)
                if results.count >= 4 { break }
            }
            let checker = KeyboardViewController.sharedChecker
            let range = NSRange(location: 0, length: word.utf16.count)
            for language in checkerLanguages {
                if let c = checker.completions(forPartialWordRange: range, in: word, language: language) {
                    results.append(contentsOf: c)
                }
                if results.count >= 12 { break }
            }
        }

        var seen = Set(pinned.map { $0.lowercased() })
        var unique = pinned
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

    private func setSuggestions(_ words: [String]) {
        guard !searchingClips else { return }
        var titles = words
        var paste: PasteChipView.Kind?
        if mode == .keys, let revert = validRevert() {
            titles = ["↺ " + revert.original] + Array(words.prefix(2))
        } else if mode == .keys, currentWord().isEmpty, let kind = recentPasteKind() {
            // Lo recién copiado ocupa la barra entera: nada de predicciones al lado.
            paste = kind
            titles = []
        }
        if let paste { pasteChip.show(paste) } else { pasteChip.isHidden = true }
        for (i, b) in suggestionButtons.enumerated() {
            b.text = i < titles.count ? titles[i] : ""
        }
        for (i, sep) in separatorViews.enumerated() {
            sep.isHidden = (i + 1) >= titles.count
        }
    }

    private func applySuggestionWord(_ title: String) {
        keyFeedback()
        wordTouches.removeAll(keepingCapacity: true)
        if title.hasPrefix("↺ ") {
            undoAutocorrect(fromBackspace: false)
            return
        }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let current = TextRules.wordBefore(before)
        let previous = current.isEmpty ? TextRules.lastCompleteWord(in: before) : TextRules.previousWord(in: before)
        deleteBack(current.count)
        put(title + " ")
        autoSpaceInserted = true
        if learningActive, TextRules.isPlainWord(title) {
            WordLearner.learn(title)
            if !previous.isEmpty { WordLearner.learnBigram(previous: previous, next: title) }
        }
        pendingRevert = nil
        justSwiped = nil
        noCorrectOnce = nil
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

    // MARK: Pegar lo recién copiado
    //
    // Si se copió algo nuevo, la barra ofrece pegarlo de un toque, como
    // Gboard. Para saber qué hay bastan `changeCount` y `hasImages`,
    // `hasURLs` y `hasStrings`, que no leen el contenido: iOS no pide
    // «Permitir pegar» hasta que el usuario toca.
    //
    // La imagen va primero: una captura o una foto copiadas suelen traer
    // también un texto (el nombre o la fecha de la captura), y antes el chip
    // pegaba ese texto. Un teclado no puede escribir imágenes, así que el
    // chip lo dice y explica cómo pegarla.

    private var pasteSeenCount = -1
    private var pasteSeenAt: CFTimeInterval = 0
    private var pasteKind: PasteChipView.Kind?

    private func recentPasteKind() -> PasteChipView.Kind? {
        guard hasFullAccess, numPad == nil else { return nil }
        let pasteboard = UIPasteboard.general
        let count = pasteboard.changeCount
        guard count != AppGroup.sharedDefaults.integer(forKey: SettingsKeys.lastPasteboardChange) else { return nil }
        if count != pasteSeenCount {
            pasteSeenCount = count
            pasteSeenAt = CACurrentMediaTime()
            if pasteboard.hasImages {
                pasteKind = .image
            } else if pasteboard.hasURLs {
                pasteKind = .link
            } else if pasteboard.hasStrings {
                pasteKind = .text
            } else {
                pasteKind = nil
            }
        }
        // Sólo un rato: pasado ese tiempo ya no es «lo recién copiado».
        guard CACurrentMediaTime() - pasteSeenAt < 120 else { return nil }
        return pasteKind
    }

    private func pasteChipTapped(_ kind: PasteChipView.Kind) {
        keyFeedback()
        switch kind {
        case .text, .link:
            pasteRecent()
        case .image:
            // Se queda en el portapapeles del sistema y entra en el historial.
            if clipContainer == nil { clipContainer = ClipStore.makeContainer() }
            if let container = clipContainer {
                CaptureService.captureIfNeeded(context: ModelContext(container), lightweight: true)
            }
            AppGroup.sharedDefaults.set(UIPasteboard.general.changeCount, forKey: SettingsKeys.lastPasteboardChange)
            allSnapshots = []
            pasteChip.isHidden = true
            showHint(Self.pasteImageHint, duration: 4)
            scheduleSuggestions()
        }
    }

    /// iOS no deja a los teclados de terceros escribir imágenes ni archivos,
    /// sólo texto: se pegan desde el menú del propio campo.
    private static let pasteImageHint = "iOS no deja a los teclados pegar imágenes. Mantén pulsado el campo de texto y toca «Pegar»."

    private func pasteRecent() {
        let pasteboard = UIPasteboard.general
        guard let text = pasteboard.string ?? pasteboard.url?.absoluteString, !text.isEmpty else {
            showHint("No se pudo leer lo copiado")
            return
        }
        put(text)
        // Queda también en el historial, y el botón desaparece.
        if clipContainer == nil { clipContainer = ClipStore.makeContainer() }
        if let container = clipContainer {
            CaptureService.saveText(text, context: ModelContext(container), lightweight: true)
        }
        AppGroup.sharedDefaults.set(pasteboard.changeCount, forKey: SettingsKeys.lastPasteboardChange)
        allSnapshots = []
        pendingRevert = nil
        justSwiped = nil
        updateShiftFromContext()
        scheduleSuggestions()
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
        card.backgroundColor = KeyStyle.theme.letter
        card.layer.cornerRadius = 14
        dim.addSubview(card)

        let label = UILabel(frame: CGRect(x: 14, y: 14, width: cardW - 28, height: 56))
        label.numberOfLines = 2
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 15)
        label.text = "¿Olvidar «\(word)»?\nNo se volverá a sugerir."
        label.textColor = KeyStyle.theme.text
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
        for language in checkerLanguages {
            let m = checker.rangeOfMisspelledWord(in: word, range: range,
                                                  startingAt: 0, wrap: false, language: language)
            if m.location == NSNotFound { return nil }
        }
        for language in checkerLanguages {
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

    private func currentWord() -> String {
        TextRules.wordBefore(textDocumentProxy.documentContextBeforeInput ?? "")
    }

    // MARK: Paneles (portapapeles en SwiftUI y emojis en UIKit, no críticos para latencia)

    private func toggleClipboard() {
        keyFeedback()
        if searchingClips {
            // Mientras se escribe la búsqueda, el icono hace de «volver».
            endClipSearch(showResults: true)
            return
        }
        mode = (mode == .clipboard) ? .keys : .clipboard
        refreshMode()
    }

    private func toggleEmoji() {
        keyFeedback()
        if searchingClips { endClipSearch(showResults: false) }
        mode = (mode == .emoji) ? .keys : .emoji
        refreshMode()
    }

    private func refreshMode() {
        updateTopIcons()
        emojiButton.isHidden = searchingClips
        searchField.isHidden = !searchingClips
        switch mode {
        case .keys:      showKeyboard()
        case .clipboard: showPanel(AnyView(clipboardPanel()))
        case .emoji:     showEmojiPanel()
        }
    }

    private func updateTopIcons() {
        if searchingClips {
            clipboardButton.setSymbol("chevron.backward", active: true)
        } else {
            clipboardButton.setSymbol(mode == .clipboard ? "keyboard" : "doc.on.clipboard",
                                      active: mode == .clipboard)
        }
        emojiButton.setSymbol(mode == .emoji ? "keyboard" : "face.smiling",
                              active: mode == .emoji)
    }

    private func insertEmoji(_ emoji: String) {
        put(emoji)
        EmojiStore.registerRecent(emoji)
        keyFeedback()
        pendingRevert = nil
        justSwiped = nil
    }

    private func showEmojiPanel() {
        keyboardArea.isHidden = true
        panelHost?.view.isHidden = true
        pasteChip.isHidden = true
        suggestionButtons.forEach { $0.isHidden = true }
        separatorViews.forEach { $0.isHidden = true }
        if emojiPanel == nil {
            let panel = EmojiPanelView()
            panel.insert = { [weak self] e in self?.insertEmoji(e) }
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
        if searchingClips {
            pasteChip.isHidden = true
            suggestionButtons.forEach { $0.isHidden = true }
            separatorViews.forEach { $0.isHidden = true }
            updateSearchField()
        } else {
            suggestionButtons.forEach { $0.isHidden = $0.text.isEmpty }
            separatorViews.forEach { $0.isHidden = false }
            scheduleSuggestions()
        }
        // Los recientes se rehacen con el panel de emojis oculto, mientras se
        // escribe: así abrirlo no espera a recolocar la colección entera.
        if emojiPanel != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.mode != .emoji else { return }
                self.emojiPanel?.reloadCurrent()
            }
        }
    }

    private func showPanel(_ v: AnyView) {
        keyboardArea.isHidden = true
        emojiPanel?.isHidden = true
        pasteChip.isHidden = true
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

    // Portapapeles: contenedor y tarjetas en caché.
    private var clipContainer: ModelContainer?
    private var allSnapshots: [ClipSnapshot] = []
    private var snapshotsAt = Date.distantPast
    private var snapshotRefreshQueued = false
    /// Texto de búsqueda ya plegado, por elemento: plegar las tildes de 60
    /// textos largos era lo más lento de releer el historial al abrir el panel.
    private var searchTextCache: [UUID: (updatedAt: Date, sensitive: Bool, text: String)] = [:]
    /// Miniaturas ya hechas (en segundo plano), por elemento.
    private var thumbnails: [UUID: UIImage] = [:]
    private var thumbnailsPending = Set<UUID>()
    var trackpadEnabled: Bool { config.trackpad }

    private func clipboardPanel() -> ClipboardPanel {
        ensureSnapshots()
        return ClipboardPanel(hasFullAccess: hasFullAccess,
                              snapshots: visibleSnapshots(),
                              historyIsEmpty: allSnapshots.isEmpty,
                              favoritesOnly: favoritesOnly,
                              query: clipQuery,
                              onFilter: { [weak self] fav in
                                  guard let self else { return }
                                  self.keyFeedback()
                                  self.favoritesOnly = fav
                                  self.snapshotsAt = Date()   // filtra en memoria, sin releer
                                  self.refreshMode()
                              },
                              onSearch: { [weak self] in self?.beginClipSearch() },
                              onClearQuery: { [weak self] in
                                  guard let self else { return }
                                  self.keyFeedback()
                                  self.clipQuery = ""
                                  self.snapshotsAt = Date()
                                  self.refreshMode()
                              },
                              onPick: { [weak self] snap in self?.pickClip(snap) })
    }

    private func pickClip(_ snap: ClipSnapshot) {
        keyFeedback()
        if let text = snap.insertable {
            put(text)
            pendingRevert = nil
            justSwiped = nil
            wordTouches.removeAll(keepingCapacity: true)
            mode = .keys
            refreshMode()
            updateShiftFromContext()
        } else {
            copyAssetToPasteboard(snap.id)
        }
    }

    /// Un teclado de terceros sólo puede escribir texto: iOS no le deja pegar
    /// imágenes ni archivos en la app. Se dejan en el portapapeles del sistema
    /// (los archivos con su nombre) y se explica cómo pegarlos desde el menú
    /// del campo. Antes la imagen se copiaba con un aviso de un segundo y medio
    /// y los archivos ni eso.
    private func copyAssetToPasteboard(_ id: UUID) {
        guard let container = clipContainer else { return }
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let item = try? context.fetch(descriptor).first else {
            showHint("No se encontró en el historial")
            return
        }
        let isImage = item.type == .image
        // Leer el archivo entero puede pasar del límite de memoria del teclado.
        if let size = item.fileSize, size > 20_000_000 {
            showHint("Es demasiado grande para copiarlo desde el teclado: ábrelo en ClipDeck", duration: 3)
            return
        }
        guard let data = item.assetData, data.count <= 20_000_000 else {
            showHint(isImage ? "No se encontró la imagen" : "No se encontró el archivo")
            return
        }
        if isImage {
            let type = ImageTools.typeIdentifier(of: data) ?? UTType.jpeg.identifier
            UIPasteboard.general.setData(data, forPasteboardType: type)
        } else {
            let name = item.fileName ?? "Archivo"
            let ext = (name as NSString).pathExtension
            let type = UTType(filenameExtension: ext) ?? .data
            let provider = NSItemProvider(item: data as NSData, typeIdentifier: type.identifier)
            provider.suggestedName = (name as NSString).deletingPathExtension
            UIPasteboard.general.setItemProviders([provider], localOnly: false, expirationDate: nil)
        }
        // Que no vuelva a entrar al historial como captura nueva.
        AppGroup.sharedDefaults.set(UIPasteboard.general.changeCount, forKey: SettingsKeys.lastPasteboardChange)
        let what = isImage ? "Imagen copiada" : "Archivo copiado"
        showHint("\(what). iOS no deja a los teclados pegarlo: mantén pulsado el campo de texto y toca «Pegar».",
                 duration: 4)
    }

    /// Prepara la base de datos por adelantado, en segundo plano.
    ///
    /// Abrir el contenedor de SwiftData (montar el esquema y la base) es lo
    /// caro, y antes se hacía entero en el hilo principal cada vez que se
    /// tocaba el icono del portapapeles: por eso el panel tardaba en aparecer.
    /// Ahora se abre una sola vez por sesión de teclado.
    private func prewarmClipboard() {
        guard hasFullAccess else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let container = ClipStore.makeContainer()
            DispatchQueue.main.async { self?.clipContainer = container }
        }
    }

    private func ensureSnapshots() {
        guard hasFullAccess else { return }
        // El filtro de favoritos y las reaperturas seguidas usan lo que ya está
        // en memoria: no hace falta volver a leer la base.
        if allSnapshots.isEmpty {
            refreshSnapshots()
        } else if Date().timeIntervalSince(snapshotsAt) > 0.8, !snapshotRefreshQueued {
            // Con algo ya en memoria el panel se abre con eso y la base se relee
            // justo después, con el panel ya en pantalla: antes el cambio de
            // vista esperaba a SwiftData.
            snapshotRefreshQueued = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                self.snapshotRefreshQueued = false
                guard self.mode == .clipboard, !self.searchingClips else { return }
                self.refreshSnapshots()
                self.refreshMode()
            }
        }
    }

    /// Lo que se ve: favoritos y búsqueda (sin distinguir tildes ni mayúsculas).
    private func visibleSnapshots() -> [ClipSnapshot] {
        var list = favoritesOnly ? allSnapshots.filter { $0.isFavorite } : allSnapshots
        let query = TextRules.fold(clipQuery.trimmingCharacters(in: .whitespaces))
        if !query.isEmpty { list = list.filter { $0.searchText.contains(query) } }
        return list
    }

    private func refreshSnapshots() {
        if clipContainer == nil { clipContainer = ClipStore.makeContainer() }
        guard let container = clipContainer else { return }
        let context = ModelContext(container)
        // Modo ligero: sin decodificar imágenes, sin OCR ni descargas.
        CaptureService.captureIfNeeded(context: context, lightweight: true)
        var d = FetchDescriptor<ClipItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        d.fetchLimit = 60
        let items = (try? context.fetch(d)) ?? []
        var wanted: [UUID] = []
        allSnapshots = items.map { item in
            let isImage = item.type == .image
            if isImage, !item.isSensitive, wanted.count < 24 { wanted.append(item.id) }
            let searchText: String
            if let cached = searchTextCache[item.id], cached.updatedAt == item.updatedAt,
               cached.sensitive == item.isSensitive {
                searchText = cached.text
            } else {
                searchText = Self.searchText(for: item)
                searchTextCache[item.id] = (item.updatedAt, item.isSensitive, searchText)
            }
            return ClipSnapshot(id: item.id, typeLabel: item.type.label, systemImage: item.type.systemImage,
                                preview: item.displayTitle, insertable: insertableText(for: item),
                                searchText: searchText,
                                isImage: isImage, thumbnail: thumbnails[item.id],
                                isSensitive: item.isSensitive, isFavorite: item.isFavorite)
        }
        snapshotsAt = Date()
        requestThumbnails(for: wanted)
    }

    /// Miniaturas en segundo plano y sin decodificar la imagen entera: antes
    /// cada tarjeta guardaba la imagen original y SwiftUI la decodificaba a
    /// tamaño completo (una captura de pantalla son unos 12 MB en memoria), y
    /// con unas pocas el sistema cerraba el teclado.
    private func requestThumbnails(for ids: [UUID]) {
        guard let container = clipContainer else { return }
        let missing = ids.filter { thumbnails[$0] == nil && !thumbnailsPending.contains($0) }
        guard !missing.isEmpty else { return }
        thumbnailsPending.formUnion(missing)
        let maxPixel = 130 * max(traitCollection.displayScale, 2)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let context = ModelContext(container)
            var made: [UUID: UIImage] = [:]
            for id in missing {
                autoreleasepool {
                    var descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.id == id })
                    descriptor.fetchLimit = 1
                    if let item = try? context.fetch(descriptor).first, let data = item.assetData,
                       let image = ImageTools.thumbnail(from: data, maxPixelSize: maxPixel) {
                        made[id] = image
                    }
                }
            }
            let ready = made
            DispatchQueue.main.async {
                guard let self else { return }
                self.thumbnailsPending.subtract(missing)
                guard !ready.isEmpty else { return }
                for (id, image) in ready { self.thumbnails[id] = image }
                self.allSnapshots = self.allSnapshots.map { snap in
                    var copy = snap
                    if copy.thumbnail == nil { copy.thumbnail = ready[copy.id] }
                    return copy
                }
                if self.mode == .clipboard {
                    self.snapshotsAt = Date()
                    self.refreshMode()
                }
            }
        }
    }

    private static func searchText(for item: ClipItem) -> String {
        var parts = [item.type.label]
        if !item.isSensitive {
            let fields = [item.title, item.plainText, item.urlString, item.linkTitle,
                          item.recognizedText, item.fileName]
            parts += fields.compactMap { $0 }.map { String($0.prefix(2000)) }
        }
        return TextRules.fold(parts.joined(separator: " "))
    }

    private func insertableText(for item: ClipItem) -> String? {
        switch item.type {
        case .link:  return item.urlString ?? item.plainText
        case .image, .file: return nil
        default:     return item.plainText
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Si iOS aprieta, se suelta lo que se puede rehacer.
        if mode != .clipboard {
            allSnapshots = []
            thumbnails = [:]
            searchTextCache = [:]
        }
    }

    // MARK: Búsqueda en el portapapeles
    //
    // Un campo de texto dentro de un teclado no puede recibir texto: el
    // teclado del sistema no se abre para él. Antes el buscador del panel se
    // podía tocar pero no escribir en él. Ahora, al tocarlo, vuelven las
    // teclas y escriben en la búsqueda; «Buscar» (o el icono de la izquierda)
    // muestra los resultados.

    private func beginClipSearch() {
        keyFeedback()
        searchingClips = true
        numPad = nil
        symbolsMode = false
        shift = .off
        shiftByUser = false
        suggestionWork?.cancel()
        mode = .keys
        rebuildKeys()
        refreshMode()
    }

    private func endClipSearch(showResults: Bool) {
        searchingClips = false
        numPad = numPadDismissed ? nil : Self.numPad(for: textDocumentProxy.keyboardType)
        rebuildKeys()
        mode = showResults ? .clipboard : .keys
        refreshMode()
        if !showResults { updateShiftFromContext() }
    }

    private func appendToQuery(_ text: String) {
        clipQuery += text
        updateSearchField()
    }

    private func updateSearchField() {
        let count: Int? = clipQuery.trimmingCharacters(in: .whitespaces).isEmpty ? nil : visibleSnapshots().count
        searchField.update(query: clipQuery, matches: count)
    }
}

// MARK: - Zona de teclas sin huecos muertos
//
// Entre tecla y tecla hay 5 pt de separación, 6 pt entre filas y un margen en
// los laterales: un toque que caía ahí no llegaba a ninguna tecla y se perdía
// sin más (en torno a una cuarta parte de la superficie del teclado). Como en
// el teclado de iOS, cualquier punto de la zona pertenece a la tecla más
// cercana.

final class KeyAreaView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, isUserInteractionEnabled, alpha > 0.01,
              self.point(inside: point, with: event) else { return nil }
        if let hit = super.hitTest(point, with: event), hit !== self, !(hit is KeyRowView) {
            return hit
        }
        return nearestKey(to: point) ?? super.hitTest(point, with: event)
    }

    func nearestKey(to point: CGPoint) -> KeyView? {
        var best: KeyView?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for case let row as KeyRowView in subviews where !row.isHidden {
            for key in row.keyViews {
                let f = key.frame.offsetBy(dx: row.frame.minX, dy: row.frame.minY)
                let dx = max(f.minX - point.x, 0, point.x - f.maxX)
                let dy = max(f.minY - point.y, 0, point.y - f.maxY)
                let d = dx * dx + dy * dy
                if d < bestDistance {
                    bestDistance = d
                    best = key
                }
            }
        }
        return best
    }
}

// MARK: - Tema activo
//
// Lo elige el usuario en la app (Configuración del teclado → Tema) y el
// controlador lo fija al cargar la configuración. Las vistas lo leen al
// construirse o al repintarse; el Clásico, el de por defecto, son los colores
// de siempre.

enum KeyStyle {
    static var theme = KeyboardTheme.named(KeyboardTheme.defaultID)
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

    var keyViews: [KeyView] { keys }

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
    private let icon = UIImageView()
    private var globeButton: UIButton?

    private var baseValue: String
    private var upper = false
    private var longTimer: Timer?
    private var accentBar: UIView?
    private var accentBarFrame: CGRect = .zero
    private var accentLabels: [UILabel] = []
    private let accentCellWidth: CGFloat = 34
    private var selectedAccent = 0
    /// Opciones de derecha a izquierda (teclas de la mitad derecha).
    private var accentRTL = false
    private var accentOriginX: CGFloat = 0
    private var accentTracking = false
    private var accentUpper = false
    private var isDown = false
    private var shiftActive = false
    private var pressStart: CFTimeInterval = 0
    private var spaceTracking = false
    private var startPoint: CGPoint = .zero
    private var lastPoint: CGPoint = .zero
    private var insertedChar = ""
    private var swiping = false
    private var spaceStartX: CGFloat = 0
    private var spaceConsumed = 0
    private var trackpadTimer: Timer?
    private var backspaceDragging = false

    /// Signos con pulsación larga: se escriben al soltar, no al apoyar, para
    /// que elegir «¿» o «!» no tenga que deshacer nada.
    private var insertsOnRelease: Bool {
        guard !spec.variants.isEmpty else { return false }
        switch spec.kind {
        case .comma, .period: return true
        case .char: return KeyboardViewController.closingPunctuation.contains(spec.value)
        default: return false
        }
    }

    init(spec: KeySpec, controller: KeyboardViewController) {
        self.spec = spec
        self.controller = controller
        self.baseValue = spec.value
        super.init(frame: .zero)

        let theme = KeyStyle.theme
        layer.cornerRadius = theme.cornerRadius
        if theme.keyShadow != nil {
            layer.shadowOffset = CGSize(width: 0, height: 1)
            layer.shadowRadius = 0
            layer.shadowOpacity = 1
        }
        if theme.keyBorder != nil {
            layer.borderWidth = 1
        }
        clipsToBounds = false
        isMultipleTouchEnabled = true
        isExclusiveTouch = false

        label.textAlignment = .center
        label.textColor = theme.text
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        addSubview(label)

        icon.contentMode = .center
        icon.tintColor = theme.text
        icon.isHidden = true
        addSubview(icon)

        switch spec.kind {
        case .shift:     setIcon(["shift"], fallback: "⇧")
        case .backspace: setIcon(["delete.left"], fallback: "⌫")
        case .globe:     setIcon(["globe"], fallback: "🌐")
        case .ret:
            if spec.value.isEmpty {
                setIcon(["return.left", "return"], fallback: "↵")
            } else {
                label.text = spec.value
                label.font = .systemFont(ofSize: 16, weight: spec.accent ? .semibold : .regular)
                if spec.accent && theme.accentReturn { label.textColor = theme.accentText }
            }
        case .space:
            label.text = "espacio"
            label.textColor = theme.secondaryText
            label.font = .systemFont(ofSize: 15, weight: theme.boldKeys ? .semibold : .regular)
        case .mode:      label.text = spec.value; label.font = .systemFont(ofSize: 16, weight: theme.boldKeys ? .semibold : .regular)
        default:         label.text = spec.value
        }
        backgroundColor = baseColor(pressed: false)
        updateLayerColors()

        // El globo pasa todos sus toques al sistema: un toque cambia de
        // teclado y una pulsación larga muestra la lista, como en iOS.
        if spec.kind == .globe {
            let button = UIButton(type: .custom)
            button.addTarget(controller, action: #selector(UIInputViewController.handleInputModeList(from:with:)),
                             for: .allTouchEvents)
            button.addTarget(self, action: #selector(globeDown), for: .touchDown)
            button.addTarget(self, action: #selector(globeUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
            addSubview(button)
            globeButton = button
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setIcon(_ names: [String], fallback: String) {
        let config = UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)
        for name in names {
            if let image = UIImage(systemName: name, withConfiguration: config) {
                icon.image = image
                icon.isHidden = false
                label.isHidden = true
                return
            }
        }
        icon.isHidden = true
        label.isHidden = false
        label.text = fallback
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 2, dy: 0)
        icon.frame = bounds
        globeButton?.frame = bounds
        if layer.shadowOpacity > 0 {
            layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
        }
    }

    /// La sombra y el borde son CGColor: no cambian solos con el modo claro u oscuro.
    private func updateLayerColors() {
        let theme = KeyStyle.theme
        layer.shadowColor = theme.keyShadow?.resolvedColor(with: traitCollection).cgColor
        layer.borderColor = theme.keyBorder?.resolvedColor(with: traitCollection).cgColor
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateLayerColors()
    }

    @objc private func globeDown() {
        setPressed(true)
        controller?.keyFeedback()
    }

    @objc private func globeUp() { setPressed(false) }

    func setFontSize(_ size: CGFloat) {
        if spec.kind == .char || spec.kind == .comma || spec.kind == .period {
            label.font = .systemFont(ofSize: size, weight: KeyStyle.theme.boldKeys ? .semibold : .regular)
        }
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
        icon.alpha = dimmed ? 0.15 : 1
        alpha = dimmed ? 0.5 : 1
    }

    /// Resalta la tecla de mayúsculas según el estado actual.
    func setShiftActive(_ active: Bool, caps: Bool) {
        guard spec.kind == .shift else { return }
        shiftActive = active
        setIcon([caps ? "capslock.fill" : (active ? "shift.fill" : "shift")], fallback: caps ? "⇪" : "⇧")
        let theme = KeyStyle.theme
        icon.tintColor = active ? theme.shiftOnText : theme.text
        label.textColor = active ? theme.shiftOnText : theme.text
        backgroundColor = baseColor(pressed: false)
    }

    private func setPressed(_ p: Bool) {
        backgroundColor = baseColor(pressed: p)
    }

    private func baseColor(pressed: Bool) -> UIColor {
        let theme = KeyStyle.theme
        switch spec.kind {
        case .char, .space:
            return pressed ? theme.letterPressed : theme.letter
        case .ret where spec.accent && theme.accentReturn:
            return pressed ? theme.accent.withAlphaComponent(0.7) : theme.accent
        case .shift where shiftActive && !pressed:
            return theme.shiftOn
        default:
            return pressed ? theme.functionPressed : theme.function
        }
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isDown else { return }
        isDown = true
        swiping = false
        backspaceDragging = false
        insertedChar = ""
        if let t = touches.first, let root = controller?.view {
            startPoint = t.location(in: root)
            lastPoint = startPoint
        }
        pressStart = CACurrentMediaTime()
        setPressed(true)
        if insertsOnRelease {
            controller?.keyFeedback()
            if spec.kind == .char { controller?.showPopup(for: self, text: baseValue) }
            startLongPressTimer()
            return
        }
        switch spec.kind {
        case .char:
            // La letra insertada puede no ser la de la tecla: si el usuario
            // tiende a tocar corrido, el teclado elige la vecina más probable.
            let typed = controller?.insertChar(baseValue, at: startPoint) ?? baseValue
            insertedChar = typed
            controller?.showPopup(for: self, text: typed)
            if !spec.variants.isEmpty { startLongPressTimer() }
        case .shift:     controller?.handleShift()
        case .backspace: controller?.backspaceDown()
        case .mode:      controller?.toggleSymbols()
        case .globe:     controller?.switchKeyboard()     // toque en el hueco junto al globo
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

    private func startLongPressTimer() {
        longTimer?.invalidate()
        longTimer = KeyboardViewController.commonTimer(0.4) { [weak self] in
            self?.showAccents()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        if let root = controller?.view { lastPoint = t.location(in: root) }

        // Trazo en curso: el dedo dibuja la palabra.
        if swiping {
            controller?.swipeMove(to: lastPoint)
            return
        }

        // Modo trackpad activo: el dedo mueve el cursor esté donde esté.
        if controller?.isTrackpadActive == true {
            controller?.trackpadMove(to: lastPoint)
            return
        }

        // Globo de opciones abierto. La opción marcada sólo sigue al dedo
        // cuando éste se mueve de verdad: antes el menor temblor al abrirse
        // saltaba de «á» a la opción que quedara bajo el dedo.
        if accentBar != nil {
            let px = lastPoint.x
            if !accentTracking {
                guard abs(px - accentOriginX) > 6 else { return }
                accentTracking = true
            }
            let count = spec.variants.count
            let slot = min(max(Int(floor((px - accentBarFrame.minX - 4) / accentCellWidth)), 0), count - 1)
            let index = accentRTL ? count - 1 - slot : slot
            if index != selectedAccent {
                selectedAccent = index
                highlightAccent()
                controller?.selectionFeedback()
            }
            return
        }

        // Deslizar desde borrar hacia la izquierda: borra palabras enteras.
        if spec.kind == .backspace {
            let dx = startPoint.x - lastPoint.x
            if !backspaceDragging && dx > 24 { backspaceDragging = true }
            if backspaceDragging {
                controller?.backspaceDrag(steps: max(Int((dx - 10) / 28), 0))
            }
            return
        }

        // ¿El dedo salió de la tecla sin levantarse? Entonces es un trazo.
        // Hace falta además un recorrido mínimo: un toque rápido con el dedo
        // algo corrido no debe convertirse en un deslizamiento.
        if spec.kind == .char, !insertedChar.isEmpty,
           baseValue.first?.isLetter == true, controller?.swipeEnabled == true {
            let local = t.location(in: self)
            let travelled = hypot(lastPoint.x - startPoint.x, lastPoint.y - startPoint.y)
            if travelled > 8, !bounds.insetBy(dx: -4, dy: -4).contains(local) {
                longTimer?.invalidate(); longTimer = nil
                swiping = true
                controller?.beginSwipe(startChar: insertedChar, from: startPoint)
                controller?.swipeMove(to: lastPoint)
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

        if insertsOnRelease {
            var chosen: String? = cancelled ? nil : baseValue
            if accentBar != nil {
                chosen = !cancelled && spec.variants.indices.contains(selectedAccent)
                    ? spec.variants[selectedAccent] : nil
                closeAccents()
            }
            if let chosen {
                if KeyboardViewController.closingPunctuation.contains(chosen) {
                    controller?.punctTap(chosen, feedback: false)
                } else {
                    controller?.insertSymbol(chosen, feedback: false)
                }
            }
            return
        }

        if accentBar != nil {
            if !cancelled, spec.variants.indices.contains(selectedAccent) {
                let v = spec.variants[selectedAccent]
                controller?.replaceLastWithVariant(accentUpper ? v.uppercased() : v)
            }
            closeAccents()
            return
        }

        if spec.kind == .backspace {
            if backspaceDragging {
                backspaceDragging = false
                controller?.backspaceDragEnded()
            }
            controller?.backspaceUp()
        }
        if spec.kind == .space {
            if !cancelled && !spaceTracking { controller?.spaceTap() }
            spaceTracking = false
        }
    }

    // MARK: Globo de opciones (pulsación larga)

    private func showAccents() {
        guard let root = controller?.view, !spec.variants.isEmpty else { return }
        controller?.hidePopup()
        controller?.longPressFeedback()
        let variants = spec.variants
        let cellW = accentCellWidth
        let hgt: CGFloat = 44
        let w = CGFloat(variants.count) * cellW + 8
        let kf = convert(bounds, to: root)
        // La opción principal (la tilde aguda) queda justo encima de la tecla
        // y el resto se abre hacia el centro del teclado. El orden de cada
        // tecla es siempre el mismo, para que sirva la memoria muscular.
        accentRTL = kf.midX > root.bounds.width / 2
        var x = accentRTL ? kf.midX + cellW / 2 + 4 - w : kf.midX - cellW / 2 - 4
        x = min(max(x, 3), root.bounds.width - w - 3)
        let bar = UIView(frame: CGRect(x: x, y: max(kf.minY - hgt - 6, 2), width: w, height: hgt))
        let theme = KeyStyle.theme
        bar.backgroundColor = theme.menu
        bar.layer.cornerRadius = 10
        // El Clásico lo tiene plano, como siempre; los temas con relieve, con sombra.
        if theme.keyShadow != nil {
            bar.layer.shadowColor = UIColor.black.cgColor
            bar.layer.shadowOpacity = 0.25
            bar.layer.shadowRadius = 4
            bar.layer.shadowOffset = CGSize(width: 0, height: 1)
        }
        if let border = theme.keyBorder {
            bar.layer.borderWidth = 1
            bar.layer.borderColor = border.resolvedColor(with: traitCollection).cgColor
        }
        root.addSubview(bar)
        // Mayúscula si lo que se escribió al apoyar ya lo era (la tecla ya
        // vuelve a minúscula después de la primera letra de la frase).
        accentUpper = insertedChar.first?.isUppercase == true
        accentLabels = []
        for slot in 0..<variants.count {
            let v = variants[accentRTL ? variants.count - 1 - slot : slot]
            let l = UILabel(frame: CGRect(x: 4 + CGFloat(slot) * cellW, y: 4, width: cellW, height: hgt - 8))
            l.text = accentUpper ? v.uppercased() : v
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
        accentOriginX = lastPoint.x
        accentTracking = false
        highlightAccent()
    }

    private func closeAccents() {
        accentBar?.removeFromSuperview()
        accentBar = nil
        accentLabels = []
    }

    private func highlightAccent() {
        let count = accentLabels.count
        for (slot, l) in accentLabels.enumerated() {
            let index = accentRTL ? count - 1 - slot : slot
            let theme = KeyStyle.theme
            l.backgroundColor = index == selectedAccent ? theme.accent : .clear
            l.textColor = index == selectedAccent ? theme.accentText : theme.text
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
    /// Texto para buscar, ya sin tildes ni mayúsculas.
    let searchText: String
    let isImage: Bool
    /// Miniatura pequeña; nunca la imagen original.
    var thumbnail: UIImage?
    let isSensitive: Bool
    let isFavorite: Bool
}

// MARK: - Panel del portapapeles (SwiftUI, sólo al abrirlo)

struct ClipboardPanel: View {
    let hasFullAccess: Bool
    /// Ya filtrados por favoritos y por la búsqueda.
    let snapshots: [ClipSnapshot]
    let historyIsEmpty: Bool
    let favoritesOnly: Bool
    let query: String
    let onFilter: (Bool) -> Void
    let onSearch: () -> Void
    let onClearQuery: () -> Void
    let onPick: (ClipSnapshot) -> Void

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

                    if historyIsEmpty {
                        message("Historial vacío. Copia algo y vuelve a abrir este panel.")
                    } else if snapshots.isEmpty {
                        message(query.isEmpty ? "Todavía no hay favoritos." : "Sin resultados para «\(query)».")
                    } else {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())],
                                      spacing: 6) {
                                ForEach(snapshots) { snap in
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

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// No es un TextField: dentro de un teclado no se puede escribir en uno.
    /// Al tocarlo vuelven las teclas y escriben en la búsqueda.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            Text(query.isEmpty ? "Buscar en el portapapeles" : query)
                .font(.caption)
                .foregroundStyle(query.isEmpty ? Color.secondary : Color.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !query.isEmpty {
                Image(systemName: "xmark.circle.fill").font(.callout).foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClearQuery)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(height: 32)
        .background(Color(KeyStyle.theme.letter), in: Capsule())
        .contentShape(Capsule())
        .onTapGesture(perform: onSearch)
        .padding(.horizontal, 6)
        .padding(.top, 6)
    }

    private func chip(_ text: String, _ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption)
        }
        .padding(.horizontal, 10).frame(height: 28)
        .background(active ? Color(KeyStyle.theme.accent).opacity(0.22) : Color(KeyStyle.theme.letter), in: Capsule())
        .foregroundStyle(active ? Color(KeyStyle.theme.accent) : Color.primary)
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
            } else if let thumbnail = snap.thumbnail {
                FillImage(image: thumbnail)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if snap.isImage {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            } else {
                Text(snap.preview).font(.caption).lineLimit(3).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8).frame(height: 92, alignment: .topLeading)
        .background(Color(KeyStyle.theme.letter), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Campo de búsqueda del portapapeles (mientras se escribe)

final class ClipSearchFieldView: UIView {
    var onClear: (() -> Void)?

    private let icon = UIImageView()
    private let label = UILabel()
    private let caret = UIView()
    private let countLabel = UILabel()
    private let clearButton = IconTouchButton()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 10

        icon.image = UIImage(systemName: "magnifyingglass")
        icon.contentMode = .center
        addSubview(icon)

        label.font = .systemFont(ofSize: 16)
        label.lineBreakMode = .byTruncatingHead      // se ve siempre el final de lo escrito
        addSubview(label)

        caret.isUserInteractionEnabled = false
        addSubview(caret)

        countLabel.font = .systemFont(ofSize: 12)
        addSubview(countLabel)

        clearButton.setSymbol("xmark.circle.fill")
        clearButton.onTap = { [weak self] in self?.onClear?() }
        addSubview(clearButton)
        update(query: "", matches: nil)
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    private var showsPlaceholder = true

    func applyTheme() {
        let theme = KeyStyle.theme
        backgroundColor = theme.letter
        icon.tintColor = theme.secondaryText
        caret.backgroundColor = theme.accent
        countLabel.textColor = theme.secondaryText
        label.textColor = showsPlaceholder ? theme.secondaryText : theme.text
        clearButton.setSymbol("xmark.circle.fill")
    }

    func update(query: String, matches: Int?) {
        showsPlaceholder = query.isEmpty
        if query.isEmpty {
            label.text = "Buscar en el portapapeles"
            label.textColor = KeyStyle.theme.secondaryText
        } else {
            label.text = query
            label.textColor = KeyStyle.theme.text
        }
        if let matches {
            countLabel.text = matches == 1 ? "1 resultado" : "\(matches) resultados"
        } else {
            countLabel.text = nil
        }
        clearButton.isHidden = query.isEmpty
        caret.frame.origin.x = -100          // se recoloca en layoutSubviews
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        icon.frame = CGRect(x: 4, y: 0, width: 28, height: h)
        let clearW: CGFloat = clearButton.isHidden ? 0 : 34
        clearButton.frame = CGRect(x: bounds.width - 34, y: 0, width: 34, height: h)
        let countW = countLabel.text == nil ? 0 : countLabel.sizeThatFits(CGSize(width: 200, height: h)).width
        countLabel.frame = CGRect(x: bounds.width - clearW - countW - 6, y: 0, width: countW, height: h)
        let textX: CGFloat = 32
        let maxTextW = max(countLabel.frame.minX - textX - 8, 0)
        let isPlaceholder = clearButton.isHidden
        let fitted = label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: h)).width
        label.frame = CGRect(x: textX, y: 0, width: min(fitted, maxTextW), height: h)
        let caretX = isPlaceholder ? textX - 1 : label.frame.maxX + 1
        caret.frame = CGRect(x: caretX, y: h * 0.22, width: 2, height: h * 0.56)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        caret.layer.removeAnimation(forKey: "blink")
        guard window != nil else { return }
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1
        blink.toValue = 0
        blink.duration = 0.5
        blink.autoreverses = true
        blink.repeatCount = .infinity
        caret.layer.add(blink, forKey: "blink")
    }

    // Los toques en el campo se quedan aquí: no deben llegar a la barra
    // superior, que los reparte entre los iconos de los extremos.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
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
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        layer.cornerRadius = 6
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        label.textColor = KeyStyle.theme.text
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !text.isEmpty else { return }
        isDown = true
        didLong = false
        backgroundColor = KeyStyle.theme.function
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
        imageView.tintColor = KeyStyle.theme.text
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
        let theme = KeyStyle.theme
        imageView.tintColor = active ? theme.accent : theme.text
        backgroundColor = active ? theme.accent.withAlphaComponent(0.22) : .clear
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
        backgroundColor = KeyStyle.theme.functionPressed
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
        if let left = leftButton, !left.isHidden, x <= left.frame.maxX + 6 {
            left.fire()
        } else if let right = rightButton, !right.isHidden, x >= right.frame.minX - 6 {
            right.fire()
        }
    }
}
