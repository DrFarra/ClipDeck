import UIKit
import SwiftUI
import SwiftData

// MARK: - Contenedor con clic de teclado del sistema

final class FeedbackHostView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
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

    private let haptic = UIImpactFeedbackGenerator(style: .light)

    // UI
    private var root: FeedbackHostView!
    private let topBar = UIView()
    private let clipboardButton = UIButton(type: .system)
    private let emojiButton = UIButton(type: .system)
    private var suggestionButtons: [SuggestionButton] = []
    private var confirmOverlay: UIView?
    private var confirmWord: String?
    private var separatorViews: [UIView] = []
    private let keyboardArea = UIView()
    private var keyViews: [KeyRowView] = []
    private var rows: [[KeySpec]] = []
    private var panelHost: UIHostingController<AnyView>?

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
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Recarga preferencias por si cambiaron en la app.
        config = KbPrefs.Config.load()
        popup.font = .systemFont(ofSize: CGFloat(config.fontSize) + 12, weight: .medium)
        if let h = view.constraints.first(where: { $0.firstAttribute == .height }) {
            h.constant = CGFloat(config.height)
        }
        rebuildKeys()
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

        clipboardButton.setImage(UIImage(systemName: "doc.on.clipboard"), for: .normal)
        clipboardButton.tintColor = .label
        clipboardButton.addTarget(self, action: #selector(toggleClipboard), for: .touchDown)
        topBar.addSubview(clipboardButton)

        emojiButton.setImage(UIImage(systemName: "face.smiling"), for: .normal)
        emojiButton.tintColor = .label
        emojiButton.addTarget(self, action: #selector(toggleEmoji), for: .touchDown)
        topBar.addSubview(emojiButton)

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
        for rowView in keyViews { rowView.applyShift(upper) }
    }

    // MARK: Layout manual (rellena toda la altura, sin márgenes)

    private func layoutAll() {
        let W = root.bounds.width
        let H = root.bounds.height
        guard W > 0, H > 0 else { return }

        let topH: CGFloat = 40
        topBar.frame = CGRect(x: 0, y: 0, width: W, height: topH)

        let btn: CGFloat = 44
        clipboardButton.frame = CGRect(x: 4, y: 3, width: btn, height: 34)
        emojiButton.frame = CGRect(x: W - btn - 4, y: 3, width: btn, height: 34)
        let sugX = clipboardButton.frame.maxX + 4
        let sugTotal = max(emojiButton.frame.minX - 4 - sugX, 0)
        let sugW = sugTotal / 3
        for (i, b) in suggestionButtons.enumerated() {
            b.frame = CGRect(x: sugX + CGFloat(i) * sugW, y: 3, width: sugW, height: 34)
        }
        for (i, sep) in separatorViews.enumerated() {
            sep.frame = CGRect(x: sugX + CGFloat(i + 1) * sugW - 0.5, y: 10, width: 1, height: 20)
        }

        let areaY = topH
        let areaH = H - topH
        keyboardArea.frame = CGRect(x: 0, y: areaY, width: W, height: areaH)
        panelHost?.view.frame = keyboardArea.frame

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

    func keyFeedback() {
        if config.haptics { haptic.impactOccurred() }
        if config.sound { UIDevice.current.playInputClick() }
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

    func backspaceDown() {
        keyFeedback()
        textDocumentProxy.deleteBackward()
        scheduleSuggestions()
        deleteRepeats = 0
        deleteTimer?.invalidate()
        deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            self?.scheduleNextDelete()
        }
    }

    /// Cada repetición borra más rápido; tras un rato pasa a borrar palabra a palabra.
    private func scheduleNextDelete() {
        deleteRepeats += 1
        let interval: TimeInterval = deleteRepeats < 8 ? 0.11 : (deleteRepeats < 18 ? 0.06 : 0.035)
        deleteTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.deleteRepeats > 26 { self.deleteWord() } else { self.textDocumentProxy.deleteBackward() }
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

    func returnTap() { commit("\n") }
    func punctTap(_ ch: String) { commit(ch) }

    /// Cierra la palabra: autocorrección + aprendizaje + separador.
    private func commit(_ separator: String) {
        keyFeedback()
        let word = currentWord()
        pendingRevert = nil

        if !word.isEmpty {
            var finalWord = word
            if config.autocorrect, let fix = autocorrection(for: word) {
                replaceCurrentWord(with: fix)
                pendingRevert = word
                finalWord = fix
            }
            if config.learnWords {
                WordLearner.learn(finalWord)
                if !lastCommittedWord.isEmpty {
                    WordLearner.learnBigram(previous: lastCommittedWord, next: finalWord)
                }
            }
            lastCommittedWord = finalWord
        }

        textDocumentProxy.insertText(separator)

        let sentenceEnders: Set<String> = [".", "?", "!", "\n"]
        if sentenceEnders.contains(separator) {
            if config.autoCapital { shift = .on; updateKeyCaps() }
            lastCommittedWord = ""
        } else {
            updateShiftFromContext()
        }
        scheduleSuggestions()
    }

    private func updateShiftFromContext() {
        guard config.autoCapital, shift != .caps else { return }
        let before = (textDocumentProxy.documentContextBeforeInput ?? "")
            .trimmingCharacters(in: .whitespaces)
        let newShift: ShiftState =
            (before.isEmpty || before.hasSuffix(".") || before.hasSuffix("!") || before.hasSuffix("?"))
            ? .on : (shift == .caps ? .caps : .off)
        if newShift != shift { shift = newShift; updateKeyCaps() }
    }

    // MARK: Sugerencias y corrección

    private func precomputeChecker() {
        DispatchQueue.global(qos: .userInitiated).async {
            let c = UITextChecker()
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
        let checker = UITextChecker()
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

    private func autocorrection(for word: String) -> String? {
        guard word.count >= 3, word.count <= 20,
              word.rangeOfCharacter(from: .decimalDigits) == nil,
              word != word.uppercased(),
              !WordLearner.isKnown(word) else { return nil }
        let checker = UITextChecker()
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

    @objc private func toggleClipboard() {
        keyFeedback()
        mode = (mode == .clipboard) ? .keys : .clipboard
        refreshMode()
    }

    @objc private func toggleEmoji() {
        keyFeedback()
        mode = (mode == .emoji) ? .keys : .emoji
        refreshMode()
    }

    private func refreshMode() {
        clipboardButton.tintColor = mode == .clipboard ? .tintColor : .label
        emojiButton.tintColor = mode == .emoji ? .tintColor : .label
        switch mode {
        case .keys:      showKeyboard()
        case .clipboard: showPanel(AnyView(clipboardPanel()))
        case .emoji:     showPanel(AnyView(EmojiPanel(insert: { [weak self] e in
                                            self?.textDocumentProxy.insertText(e)
                                            EmojiStore.registerRecent(e)
                                            self?.keyFeedback()
                                        },
                                        backToKeys: { [weak self] in self?.mode = .keys; self?.refreshMode() },
                                        deleteBackward: { [weak self] in self?.textDocumentProxy.deleteBackward() })))
        }
    }

    private func showKeyboard() {
        panelHost?.view.isHidden = true
        keyboardArea.isHidden = false
        suggestionButtons.forEach { $0.isHidden = $0.text.isEmpty }
        separatorViews.forEach { $0.isHidden = false }
        scheduleSuggestions()
    }

    private func showPanel(_ v: AnyView) {
        keyboardArea.isHidden = true
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
        d.fetchLimit = 40
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
        for spec in specs {
            let k = KeyView(spec: spec, controller: controller)
            addSubview(k)
            keys.append(k)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func applyShift(_ upper: Bool) {
        for k in keys { k.applyShift(upper) }
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
    private var accentLabels: [UILabel] = []
    private var selectedAccent = 0
    private var isDown = false
    private var spaceTracking = false
    private var spaceStartX: CGFloat = 0
    private var spaceConsumed = 0

    init(spec: KeySpec, controller: KeyboardViewController) {
        self.spec = spec
        self.controller = controller
        self.baseValue = spec.value
        super.init(frame: .zero)

        backgroundColor = Self.color(for: spec.kind, pressed: false)
        layer.cornerRadius = 7
        clipsToBounds = false

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

    private func setPressed(_ p: Bool) {
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
        setPressed(true)
        switch spec.kind {
        case .char:
            controller?.insertChar(baseValue)
            controller?.showPopup(for: self, text: upper ? baseValue.uppercased() : baseValue)
            if !spec.variants.isEmpty {
                longTimer?.invalidate()
                longTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
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
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        if accentBar != nil {
            let p = t.location(in: self)
            let slot = Int((p.x + 20) / 34)
            selectedAccent = min(max(slot, 0), spec.variants.count - 1)
            highlightAccent()
            return
        }
        if spec.kind == .space, let controller, controller.trackpadEnabled {
            let x = t.location(in: superview).x
            let dx = x - spaceStartX
            if !spaceTracking && abs(dx) > 16 { spaceTracking = true }
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
        setPressed(false)
        longTimer?.invalidate(); longTimer = nil
        controller?.hidePopup()

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
        let variants = spec.variants
        let cellW: CGFloat = 34, hgt: CGFloat = 44
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
                    HStack(spacing: 8) {
                        chip("Recientes", "clock.arrow.circlepath", active: !favoritesOnly) { onFilter(false) }
                        chip("Favoritos", "star.fill", active: favoritesOnly) { onFilter(true) }
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 6)

                    if snapshots.isEmpty {
                        Text("Historial vacío. Copia algo y vuelve a abrir este panel.")
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

struct EmojiPanel: View {
    let insert: (String) -> Void
    let backToKeys: () -> Void
    let deleteBackward: () -> Void
    @State private var categoryIndex = -1

    private var current: [String] {
        if categoryIndex == -1 {
            let r = EmojiStore.recents
            return r.isEmpty ? EmojiStore.categories[0].emojis : r
        }
        return EmojiStore.categories[categoryIndex].emojis
    }

    var body: some View {
        VStack(spacing: 4) {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 2) {
                    ForEach(current, id: \.self) { e in
                        Text(e).font(.system(size: 28)).frame(maxWidth: .infinity).frame(height: 38)
                            .contentShape(Rectangle())
                            .onTapGesture { insert(e) }
                    }
                }
                .padding(.top, 4)
            }
            HStack(spacing: 2) {
                Text("ABC").font(.subheadline).frame(width: 46, height: 34)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                    .onTapGesture { backToKeys() }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        catButton("🕐", -1)
                        ForEach(Array(EmojiStore.categories.enumerated()), id: \.offset) { i, c in
                            catButton(c.icon, i)
                        }
                    }
                }
                Image(systemName: "delete.left").font(.body).frame(width: 40, height: 34)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                    .onTapGesture { deleteBackward() }
            }
            .padding(.horizontal, 3).padding(.bottom, 3)
        }
    }

    private func catButton(_ icon: String, _ index: Int) -> some View {
        Text(icon).font(.system(size: 18)).frame(width: 34, height: 34)
            .background(categoryIndex == index ? Color.accentColor.opacity(0.22) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .onTapGesture { categoryIndex = index }
    }
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
        longTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
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
