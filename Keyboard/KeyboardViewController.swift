import UIKit
import SwiftUI
import SwiftData

// MARK: - Vista contenedora con clic de teclado del sistema

final class FeedbackHostView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

// MARK: - Puente UIKit ↔ SwiftUI

final class KeyboardBridge {
    weak var controller: KeyboardViewController?
    var lexiconWords: [String] = []
    var config = KbPrefs.Config.load()

    private let haptic = UIImpactFeedbackGenerator(style: .light)

    var hasFullAccess: Bool { controller?.hasFullAccess ?? false }
    var needsSwitchKey: Bool { controller?.needsInputModeSwitchKey ?? true }

    func insert(_ text: String) { controller?.textDocumentProxy.insertText(text) }
    func deleteBackward() { controller?.textDocumentProxy.deleteBackward() }
    func contextBefore() -> String { controller?.textDocumentProxy.documentContextBeforeInput ?? "" }
    func adjustCursor(_ offset: Int) { controller?.textDocumentProxy.adjustTextPosition(byCharacterOffset: offset) }
    func nextKeyboard() { controller?.advanceToNextInputMode() }

    func keyFeedback() {
        if config.haptics { haptic.impactOccurred() }
        if config.sound { UIDevice.current.playInputClick() }
    }
}

final class KeyboardViewController: UIInputViewController {

    private let bridge = KeyboardBridge()

    override func viewDidLoad() {
        super.viewDidLoad()
        bridge.controller = self
        bridge.config = KbPrefs.Config.load()

        requestSupplementaryLexicon { [weak self] lexicon in
            DispatchQueue.main.async {
                self?.bridge.lexiconWords = lexicon.entries.map { $0.documentText }
            }
        }

        let container = FeedbackHostView(frame: .zero, inputViewStyle: .keyboard)
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        let host = UIHostingController(rootView: KeyboardRootView(bridge: bridge))
        addChild(host)
        container.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.topAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: container.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        host.didMove(toParent: self)

        let height = view.heightAnchor.constraint(equalToConstant: CGFloat(bridge.config.height))
        height.priority = .defaultHigh
        height.isActive = true
    }
}

// MARK: - Snapshot ligero del historial

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

// MARK: - Vista raíz

struct KeyboardRootView: View {
    let bridge: KeyboardBridge

    enum ShiftState { case off, on, caps }
    enum Panel { case keys, clipboard, emoji }

    @State private var config = KbPrefs.Config.load()
    @State private var shift: ShiftState = .on
    @State private var symbolsMode = false
    @State private var panel: Panel = .keys
    @State private var favoritesOnly = false
    @State private var snapshots: [ClipSnapshot] = []
    @State private var suggestions: [String] = []
    @State private var revertWord: String?          // palabra original tras autocorrección
    @State private var lastCommittedWord = ""
    @State private var hint: String?
    @State private var lastSpaceTap: Date = .distantPast
    @State private var lastShiftTap: Date = .distantPast
    @State private var shiftPressed = false
    @State private var suggestionGeneration = 0
    @State private var deleteTimer: Timer?

    private let keyColor = Color(.secondarySystemBackground)
    private let keyPressColor = Color(.systemGray2)

    var body: some View {
        VStack(spacing: 6) {
            toolbar
            switch panel {
            case .keys:      keysArea
            case .clipboard: clipboardPanel
            case .emoji:     EmojiPanel(insert: { emoji in
                                            bridge.insert(emoji)
                                            EmojiStore.registerRecent(emoji)
                                        },
                                        backToKeys: { panel = .keys },
                                        deleteBackward: { bridge.deleteBackward() })
            }
        }
        .padding(.horizontal, 3)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .task {
            config = KbPrefs.Config.load()
            bridge.config = config
            captureAndLoad()
            updateShiftFromContext()
            // Precalienta el corrector: la primera sugerencia no congela la UI.
            DispatchQueue.main.async {
                let checker = UITextChecker()
                _ = checker.completions(forPartialWordRange: NSRange(location: 0, length: 2),
                                        in: "ho", language: "es_ES")
                _ = checker.completions(forPartialWordRange: NSRange(location: 0, length: 2),
                                        in: "he", language: "en_US")
            }
        }
        .overlay {
            if let hint {
                Text(hint)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
            }
        }
    }

    // MARK: Barra superior

    private var toolbar: some View {
        HStack(spacing: 6) {
            TouchDownButton(action: {
                bridge.keyFeedback()
                if panel == .clipboard { panel = .keys }
                else { panel = .clipboard; captureAndLoad() }
            }) {
                Image(systemName: panel == .clipboard ? "keyboard" : "doc.on.clipboard")
                    .font(.body.weight(.medium))
                    .frame(width: 44, height: 34)
                    .background(panel == .clipboard ? Color.accentColor.opacity(0.25) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(panel == .clipboard ? Color.accentColor : Color.primary)
            }

            suggestionBar

            TouchDownButton(action: {
                bridge.keyFeedback()
                panel = panel == .emoji ? .keys : .emoji
            }) {
                Image(systemName: panel == .emoji ? "keyboard" : "face.smiling")
                    .font(.body.weight(.medium))
                    .frame(width: 44, height: 34)
                    .background(panel == .emoji ? Color.accentColor.opacity(0.25) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(panel == .emoji ? Color.accentColor : Color.primary)
            }
        }
        .frame(height: 36)
    }

    @ViewBuilder private var suggestionBar: some View {
        if !config.prediction || (suggestions.isEmpty && revertWord == nil) {
            Spacer()
        } else {
            HStack(spacing: 0) {
                if let revertWord {
                    Button {
                        undoCorrection(to: revertWord)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.uturn.backward").font(.caption2)
                            Text(revertWord).font(.subheadline)
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                ForEach(Array(suggestions.prefix(revertWord == nil ? 3 : 2).enumerated()),
                        id: \.offset) { index, word in
                    if index > 0 || revertWord != nil {
                        Divider().frame(height: 18)
                    }
                    Button {
                        applySuggestion(word)
                    } label: {
                        Text(word)
                            .font(.subheadline)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Distribuciones

    private var numberRow: [String] { ["1","2","3","4","5","6","7","8","9","0"] }
    private var letterRows: [[String]] {
        [["q","w","e","r","t","y","u","i","o","p"],
         ["a","s","d","f","g","h","j","k","l","ñ"]]
    }
    private var thirdRowLetters: [String] { ["z","x","c","v","b","n","m"] }
    private var symbolRows: [[String]] {
        [["@","#","$","_","&","-","+","(",")","/"],
         ["*","\"","'",":",";","!","?","¿","¡","%"]]
    }
    private var thirdRowSymbols: [String] { ["=","<",">","{","}","[","]"] }

    private var keysArea: some View {
        GeometryReader { geo in
            let rowCount: CGFloat = config.numberRow ? 5 : 4
            let spacing: CGFloat = 6
            let rowH = min(max((geo.size.height - spacing * (rowCount - 1) - 4) / rowCount, 36), 64)

            VStack(spacing: spacing) {
                if config.numberRow {
                    HStack(spacing: 4) {
                        ForEach(numberRow, id: \.self) { charKey($0, height: rowH) }
                    }
                }

                ForEach(0..<2, id: \.self) { index in
                    HStack(spacing: 4) {
                        ForEach((symbolsMode ? symbolRows : letterRows)[index], id: \.self) { key in
                            charKey(key, height: rowH)
                        }
                    }
                }

                HStack(spacing: 4) {
                    if symbolsMode {
                        ForEach(thirdRowSymbols, id: \.self) { charKey($0, height: rowH) }
                    } else {
                        shiftKey(height: rowH)
                        ForEach(thirdRowLetters, id: \.self) { charKey($0, height: rowH) }
                    }
                    backspaceKey(height: rowH)
                }

                HStack(spacing: 4) {
                    utilKey(width: 46, height: rowH) { symbolsMode.toggle() } label: {
                        Text(symbolsMode ? "ABC" : "123").font(.subheadline)
                    }
                    if bridge.needsSwitchKey {
                        utilKey(width: 40, height: rowH) { bridge.nextKeyboard() } label: {
                            Image(systemName: "globe").font(.body)
                        }
                    }
                    utilKey(width: 36, height: rowH) { commitSeparator(",") } label: {
                        Text(",").font(.system(size: 20))
                    }
                    SpaceKeyView(height: rowH,
                                 trackpadEnabled: config.trackpad,
                                 normal: keyColor, pressed: keyPressColor,
                                 feedback: { bridge.keyFeedback() },
                                 moveCursor: { bridge.adjustCursor($0) },
                                 onSpace: { handleSpace() })
                    utilKey(width: 36, height: rowH) { commitSeparator(".") } label: {
                        Text(".").font(.system(size: 20))
                    }
                    utilKey(width: 56, height: rowH) { commitSeparator("\n") } label: {
                        Image(systemName: "return").font(.body)
                    }
                }
            }
        }
    }

    private func utilKey<L: View>(width: CGFloat, height: CGFloat,
                                  action: @escaping () -> Void,
                                  @ViewBuilder label: () -> L) -> some View {
        PressableKey(width: width, height: height,
                     normal: keyColor, pressed: keyPressColor,
                     onPress: { bridge.keyFeedback(); action() },
                     content: label())
    }

    private func charKey(_ key: String, height: CGFloat) -> some View {
        let shifted = shift != .off && !symbolsMode
        let display = shifted ? key.uppercased() : key
        let variants = config.accents ? (KbData.keyVariants[key] ?? []) : []
        let shiftedVariants = shifted ? variants.map { $0.uppercased() } : variants

        return CharKeyView(display: display,
                           variants: shiftedVariants,
                           height: height,
                           fontSize: CGFloat(config.fontSize),
                           popupEnabled: config.keyPopup,
                           normal: keyColor,
                           pressed: keyPressColor,
                           onTouchDown: {
                               bridge.keyFeedback()
                               bridge.insert(display)
                               if shift == .on && !symbolsMode { shift = .off }
                               refreshSuggestions()
                           },
                           onReplaceWithVariant: { variant in
                               bridge.deleteBackward()
                               bridge.insert(variant)
                               refreshSuggestions()
                           })
    }

    private func shiftKey(height: CGFloat) -> some View {
        let icon = shift == .caps ? "capslock.fill" : (shift == .on ? "shift.fill" : "shift")
        return Image(systemName: icon)
            .font(.body)
            .frame(width: 40, height: height)
            .background(shift != .off ? Color(.systemGray3) : keyColor,
                        in: RoundedRectangle(cornerRadius: 7))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !shiftPressed else { return }
                        shiftPressed = true
                        bridge.keyFeedback()
                        let now = Date()
                        if now.timeIntervalSince(lastShiftTap) < 0.3 {
                            shift = .caps
                        } else {
                            shift = shift == .off ? .on : .off
                        }
                        lastShiftTap = now
                    }
                    .onEnded { _ in shiftPressed = false }
            )
    }

    private func backspaceKey(height: CGFloat) -> some View {
        PressableKey(width: 40, height: height,
                     normal: keyColor, pressed: keyPressColor,
                     onPress: {
                         bridge.keyFeedback()
                         bridge.deleteBackward()
                         refreshSuggestions()
                         deleteTimer?.invalidate()
                         deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { _ in
                             deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { _ in
                                 DispatchQueue.main.async { bridge.deleteBackward() }
                             }
                         }
                     },
                     onRelease: {
                         deleteTimer?.invalidate()
                         deleteTimer = nil
                         refreshSuggestions()
                     },
                     content: Image(systemName: "delete.left").font(.body))
    }

    // MARK: Escritura

    private func handleSpace() {
        let now = Date()
        let before = bridge.contextBefore()
        if config.doubleSpace,
           now.timeIntervalSince(lastSpaceTap) < 0.4,
           before.hasSuffix(" "),
           before.dropLast().last?.isLetter == true {
            bridge.deleteBackward()
            bridge.insert(". ")
            if config.autoCapital { shift = .on }
        } else {
            commitSeparator(" ")
        }
        lastSpaceTap = now
    }

    /// Cierra la palabra actual: autocorrección, aprendizaje y separador.
    private func commitSeparator(_ separator: String) {
        bridge.keyFeedback()
        let word = currentWord()
        revertWord = nil

        if !word.isEmpty {
            var finalWord = word
            if config.autocorrect, let fix = autocorrection(for: word) {
                replaceCurrentWord(with: fix)
                revertWord = word
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

        bridge.insert(separator)
        if separator == "." || separator == "\n" {
            if config.autoCapital { shift = .on }
            lastCommittedWord = ""
        } else {
            updateShiftFromContext()
        }
        refreshSuggestions()
    }

    private func updateShiftFromContext() {
        guard config.autoCapital, shift != .caps else { return }
        let before = bridge.contextBefore().trimmingCharacters(in: .whitespaces)
        if before.isEmpty || before.hasSuffix(".") || before.hasSuffix("!") || before.hasSuffix("?") {
            shift = .on
        }
    }

    // MARK: Autocorrección

    private func autocorrection(for word: String) -> String? {
        guard word.count >= 3, word.count <= 20,
              word.rangeOfCharacter(from: .decimalDigits) == nil,
              word != word.uppercased(),
              !WordLearner.isKnown(word) else { return nil }

        let checker = UITextChecker()
        let range = NSRange(location: 0, length: word.utf16.count)

        // Si es correcta en español o inglés, no tocar.
        for language in ["es_ES", "en_US"] {
            let misspelled = checker.rangeOfMisspelledWord(in: word, range: range,
                                                           startingAt: 0, wrap: false,
                                                           language: language)
            if misspelled.location == NSNotFound { return nil }
        }

        // Buscar una corrección razonable (español primero).
        for language in ["es_ES", "en_US"] {
            if let guesses = checker.guesses(forWordRange: range, in: word, language: language) {
                for guess in guesses.prefix(3) {
                    let sameish = abs(guess.count - word.count) <= 2 && !guess.contains(" ")
                    if sameish && guess.lowercased() != word.lowercased() {
                        // Respeta la mayúscula inicial del usuario
                        if word.first?.isUppercase == true {
                            return guess.prefix(1).uppercased() + guess.dropFirst()
                        }
                        return guess
                    }
                }
            }
        }
        return nil
    }

    private func undoCorrection(to original: String) {
        // Borra "palabraCorregida<separador>" y restaura la original.
        let before = bridge.contextBefore()
        guard let lastChar = before.last else { return }
        let separator = String(lastChar)
        let corrected = wordBefore(String(before.dropLast()))
        for _ in 0..<(corrected.count + 1) { bridge.deleteBackward() }
        bridge.insert(original + separator)
        WordLearner.learn(original)   // no volver a corregirla
        revertWord = nil
        refreshSuggestions()
    }

    // MARK: Sugerencias

    private func currentWord() -> String {
        wordBefore(bridge.contextBefore())
    }

    private func wordBefore(_ text: String) -> String {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ".,;:!?¿¡\"'()[]{}"))
        if let lastRange = text.rangeOfCharacter(from: separators, options: .backwards) {
            return String(text[lastRange.upperBound...])
        }
        return text
    }

    private func refreshSuggestions() {
        guard config.prediction else { return }
        suggestionGeneration += 1
        let generation = suggestionGeneration
        // Se calcula tras despachar el toque para no retrasar la siguiente pulsación.
        DispatchQueue.main.async {
            guard generation == suggestionGeneration else { return }
            computeSuggestions()
        }
    }

    private func computeSuggestions() {
        let word = currentWord()

        if word.isEmpty {
            suggestions = nextWordSuggestions()
            return
        }
        revertWord = nil
        guard word.count >= 2, word.rangeOfCharacter(from: .letters) != nil else {
            suggestions = []
            return
        }

        let lower = word.lowercased()
        let capitalize = word.first?.isUppercase == true
        var results: [String] = []

        results += WordLearner.matches(prefix: lower, limit: 2)

        for entry in bridge.lexiconWords where entry.lowercased().hasPrefix(lower) {
            results.append(entry)
            if results.count >= 4 { break }
        }

        let checker = UITextChecker()
        let range = NSRange(location: 0, length: word.utf16.count)
        for language in ["es_ES", "en_US"] {
            if let completions = checker.completions(forPartialWordRange: range,
                                                     in: word, language: language) {
                results.append(contentsOf: completions)
            }
            if results.count >= 12 { break }
        }

        var seen = Set<String>()
        var unique: [String] = []
        for candidate in results {
            let key = candidate.lowercased()
            guard key != lower, !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(capitalize ? candidate.prefix(1).uppercased() + candidate.dropFirst()
                                     : candidate)
            if unique.count == 3 { break }
        }
        suggestions = unique
    }

    /// Predicción de palabra siguiente: bigramas aprendidos + frecuentes.
    private func nextWordSuggestions() -> [String] {
        var results: [String] = []
        if !lastCommittedWord.isEmpty {
            results += WordLearner.successors(of: lastCommittedWord)
        }
        for word in KbData.commonWords {
            if results.count >= 3 { break }
            if !results.contains(word) { results.append(word) }
        }
        let capitalize = shift != .off
        return Array(results.prefix(3)).map {
            capitalize ? $0.prefix(1).uppercased() + $0.dropFirst() : $0
        }
    }

    private func applySuggestion(_ word: String) {
        bridge.keyFeedback()
        let current = currentWord()
        for _ in 0..<current.count { bridge.deleteBackward() }
        bridge.insert(word + " ")
        if config.learnWords {
            WordLearner.learn(word)
            if !lastCommittedWord.isEmpty && !current.isEmpty {
                WordLearner.learnBigram(previous: lastCommittedWord, next: word)
            }
        }
        lastCommittedWord = word
        revertWord = nil
        updateShiftFromContext()
        suggestions = nextWordSuggestions()
    }

    private func replaceCurrentWord(with replacement: String) {
        let current = currentWord()
        for _ in 0..<current.count { bridge.deleteBackward() }
        bridge.insert(replacement)
    }

    // MARK: Panel del portapapeles

    @ViewBuilder private var clipboardPanel: some View {
        if !bridge.hasFullAccess {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.lock").font(.title2).foregroundStyle(.secondary)
                Text("Activa «Permitir acceso completo» en Ajustes → ClipDeck → Teclados.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxHeight: .infinity)
        } else {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    filterChip("Recientes", icon: "clock.arrow.circlepath", active: !favoritesOnly) {
                        favoritesOnly = false; loadItems()
                    }
                    filterChip("Favoritos", icon: "star.fill", active: favoritesOnly) {
                        favoritesOnly = true; loadItems()
                    }
                    Spacer()
                }
                if snapshots.isEmpty {
                    Text("Historial vacío. Copia algo en cualquier app y vuelve a abrir este panel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())],
                                  spacing: 6) {
                            ForEach(snapshots) { snap in
                                Button { handleClipTap(snap) } label: { clipCard(snap) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.bottom, 6)
                    }
                }
            }
        }
    }

    private func filterChip(_ text: String, icon: String, active: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2)
                Text(text).font(.caption)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(active ? Color.accentColor.opacity(0.22) : Color(.secondarySystemBackground),
                        in: Capsule())
            .foregroundStyle(active ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func clipCard(_ snap: ClipSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Image(systemName: snap.systemImage).font(.caption2)
                Text(snap.typeLabel).font(.caption2)
                if snap.isFavorite {
                    Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.yellow)
                }
            }
            .foregroundStyle(.secondary)

            if snap.isSensitive {
                Label("Sensible", systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let data = snap.imageData, let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Text(snap.preview)
                    .font(.caption)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .frame(height: 92, alignment: .topLeading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private func handleClipTap(_ snap: ClipSnapshot) {
        bridge.keyFeedback()
        if let text = snap.insertable {
            bridge.insert(text)
            panel = .keys
        } else if let data = snap.imageData, let image = UIImage(data: data) {
            UIPasteboard.general.image = image
            showHint("Copiado: mantén pulsado el campo y elige Pegar")
        } else {
            showHint("Este elemento no se puede insertar como texto")
        }
    }

    // MARK: Datos

    private func captureAndLoad() {
        guard bridge.hasFullAccess else { return }
        let container = ClipStore.makeContainer()
        let context = ModelContext(container)
        CaptureService.captureIfNeeded(context: context)
        loadItems(context: context)
    }

    private func loadItems(context: ModelContext? = nil) {
        guard bridge.hasFullAccess else { return }
        let ctx = context ?? ModelContext(ClipStore.makeContainer())
        var descriptor = FetchDescriptor<ClipItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 40
        let items = (try? ctx.fetch(descriptor)) ?? []
        snapshots = items
            .filter { favoritesOnly ? $0.isFavorite : true }
            .map { item in
                ClipSnapshot(id: item.id,
                             typeLabel: item.type.label,
                             systemImage: item.type.systemImage,
                             preview: item.displayTitle,
                             insertable: insertableText(for: item),
                             imageData: item.type == .image ? item.assetData : nil,
                             isSensitive: item.isSensitive,
                             isFavorite: item.isFavorite)
            }
    }

    private func insertableText(for item: ClipItem) -> String? {
        switch item.type {
        case .link:  return item.urlString ?? item.plainText
        case .image: return nil
        case .file:  return nil
        default:     return item.plainText
        }
    }

    private func showHint(_ text: String) {
        withAnimation { hint = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation { if hint == text { hint = nil } }
        }
    }
}

// MARK: - Tecla básica: dispara al tocar, con resaltado

struct PressableKey<Content: View>: View {
    var width: CGFloat? = nil
    var height: CGFloat = 41
    var normal: Color
    var pressed: Color
    var onPress: () -> Void
    var onRelease: (() -> Void)? = nil
    let content: Content

    @State private var isPressed = false

    var body: some View {
        content
            .frame(maxWidth: width == nil ? .infinity : nil)
            .frame(width: width, height: height)
            .background(isPressed ? pressed : normal,
                        in: RoundedRectangle(cornerRadius: 7))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressed {
                            isPressed = true
                            onPress()
                        }
                    }
                    .onEnded { _ in
                        isPressed = false
                        onRelease?()
                    }
            )
    }
}

// MARK: - Tecla de carácter: popup al pulsar y variantes con pulsación larga

struct CharKeyView: View {
    let display: String
    let variants: [String]
    let height: CGFloat
    let fontSize: CGFloat
    let popupEnabled: Bool
    let normal: Color
    let pressed: Color
    let onTouchDown: () -> Void
    let onReplaceWithVariant: (String) -> Void

    @State private var isPressed = false
    @State private var showVariants = false
    @State private var selectedVariant = 0
    @State private var longPressTimer: Timer?

    var body: some View {
        Text(display)
            .font(.system(size: fontSize))
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(isPressed ? pressed : normal,
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .top) {
                if showVariants {
                    variantsBar
                        .offset(y: -(height + 16))
                } else if isPressed && popupEnabled {
                    keyPopup
                        .offset(y: -(height + 14))
                }
            }
            .zIndex(isPressed || showVariants ? 10 : 0)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isPressed {
                            isPressed = true
                            onTouchDown()
                            if !variants.isEmpty {
                                longPressTimer?.invalidate()
                                longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.4,
                                                                      repeats: false) { _ in
                                    DispatchQueue.main.async {
                                        showVariants = true
                                        selectedVariant = 0
                                    }
                                }
                            }
                        }
                        if showVariants {
                            let slot = Int((value.translation.width + 16) / 34)
                            selectedVariant = min(max(slot, 0), variants.count - 1)
                        }
                    }
                    .onEnded { _ in
                        longPressTimer?.invalidate()
                        longPressTimer = nil
                        if showVariants {
                            onReplaceWithVariant(variants[selectedVariant])
                        }
                        showVariants = false
                        isPressed = false
                    }
            )
    }

    private var keyPopup: some View {
        Text(display)
            .font(.system(size: fontSize + 12, weight: .medium))
            .frame(minWidth: 40)
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .background(Color(.systemGray4), in: RoundedRectangle(cornerRadius: 9))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .allowsHitTesting(false)
            .fixedSize()
    }

    private var variantsBar: some View {
        HStack(spacing: 2) {
            ForEach(Array(variants.enumerated()), id: \.offset) { index, variant in
                Text(variant)
                    .font(.system(size: fontSize + 2))
                    .frame(width: 32, height: 40)
                    .background(index == selectedVariant ? Color.accentColor : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(index == selectedVariant ? Color.white : Color.primary)
            }
        }
        .padding(4)
        .background(Color(.systemGray4), in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
        .allowsHitTesting(false)
        .fixedSize()
    }
}

// MARK: - Barra espaciadora con trackpad (deslizar mueve el cursor)

struct SpaceKeyView: View {
    let height: CGFloat
    let trackpadEnabled: Bool
    let normal: Color
    let pressed: Color
    let feedback: () -> Void
    let moveCursor: (Int) -> Void
    let onSpace: () -> Void

    @State private var isPressed = false
    @State private var isTracking = false
    @State private var consumedSteps = 0

    var body: some View {
        Text(isTracking ? "◂ cursor ▸" : "espacio")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(isPressed ? pressed : normal,
                        in: RoundedRectangle(cornerRadius: 7))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isPressed {
                            isPressed = true
                            isTracking = false
                            consumedSteps = 0
                            feedback()
                        }
                        guard trackpadEnabled else { return }
                        let dx = value.translation.width
                        if !isTracking && abs(dx) > 18 {
                            isTracking = true
                        }
                        if isTracking {
                            let steps = Int(dx / 9)
                            let delta = steps - consumedSteps
                            if delta != 0 {
                                moveCursor(delta)
                                consumedSteps = steps
                            }
                        }
                    }
                    .onEnded { _ in
                        if !isTracking { onSpace() }
                        isPressed = false
                        isTracking = false
                        consumedSteps = 0
                    }
            )
    }
}

// MARK: - Emojis

enum EmojiStore {
    static let recentsKey = "keyboard.recentEmojis"

    static var recents: [String] {
        UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
    }

    static func registerRecent(_ emoji: String) {
        var list = recents
        list.removeAll { $0 == emoji }
        list.insert(emoji, at: 0)
        UserDefaults.standard.set(Array(list.prefix(24)), forKey: recentsKey)
    }

    static let categories: [(icon: String, emojis: [String])] = [
        ("😀", ["😀","😃","😄","😁","😆","😅","😂","🤣","🥲","😊","😇","🙂","😉","😌","😍","🥰","😘","😗","😋","😛","😜","🤪","🤨","🧐","🤓","😎","🥳","😏","😒","😞","😔","😟","😕","🙁","😣","😖","😫","😩","🥺","😢","😭","😤","😠","😡","🤬","🤯","😳","🥵","🥶","😱","😨","😰","😥","😓","🤗","🤔","🤭","🤫","🤥","😶","😐","😑","😬","🙄","😯","😴","🤤","😪","😵","🤐","🥴","🤢","🤮","🤧","😷","🤒","🤕","🤑","🤠","😈","👿","💀","👻","👽","🤖","💩","🤡"]),
        ("👋", ["👋","🤚","✋","🖖","👌","🤌","🤏","✌️","🤞","🤟","🤘","🤙","👈","👉","👆","👇","☝️","👍","👎","✊","👊","🤛","🤜","👏","🙌","👐","🤲","🤝","🙏","💪","🦾","✍️","💅","🤳","🫶"]),
        ("❤️", ["❤️","🧡","💛","💚","💙","💜","🖤","🤍","🤎","💔","❤️‍🔥","❤️‍🩹","💕","💞","💓","💗","💖","💘","💝","💟","♥️","💌","💋"]),
        ("🐶", ["🐶","🐱","🐭","🐹","🐰","🦊","🐻","🐼","🐨","🐯","🦁","🐮","🐷","🐸","🐵","🐔","🐧","🐦","🐤","🦆","🦅","🦉","🐺","🐗","🐴","🦄","🐝","🐛","🦋","🐌","🐞","🐜","🕷️","🐢","🐍","🦎","🐙","🦑","🦐","🦀","🐡","🐠","🐟","🐬","🐳","🐋","🦈","🐊"]),
        ("🍕", ["🍏","🍎","🍐","🍊","🍋","🍌","🍉","🍇","🍓","🫐","🍈","🍒","🍑","🥭","🍍","🥥","🥝","🍅","🥑","🌽","🥕","🍔","🍟","🍕","🌭","🥪","🌮","🌯","🥗","🍝","🍜","🍲","🍣","🍱","🍤","🍙","🍚","🍘","🍥","🍦","🍰","🎂","🍮","🍭","🍬","🍫","🍿","🍩","🍪","☕","🍵","🧉","🥤","🍺","🍷","🥂"]),
        ("⚽", ["⚽","🏀","🏈","⚾","🥎","🎾","🏐","🏉","🥏","🎱","🏓","🏸","🏒","🥅","⛳","🏹","🎣","🥊","🥋","🎽","🛹","🛼","⛸️","🎿","🏋️","🚴","🏊","🏄","🧗","🏆","🥇","🥈","🥉","🏅","🎖️","🎮","🕹️","🎲","♟️","🧩","🎯","🎳"]),
        ("💡", ["📱","💻","⌨️","🖥️","🖨️","🖱️","💽","💾","💿","📀","📷","📸","📹","🎥","📞","☎️","📟","📠","📺","📻","🎙️","⏰","⌚","🔋","🔌","💡","🔦","🕯️","🗑️","💵","💴","💶","💷","💰","💳","💎","⚖️","🔧","🔨","⚒️","🛠️","⛏️","🔩","⚙️","🧱","⛓️","🧲","💣","🔪","🛡️","🔮","📿","🧿","💊","💉","🩹","🩺","🌡️","🧬","🦠","🧫","🧪","🔭","🔬"]),
        ("🔣", ["✅","❌","❓","❗","‼️","⁉️","💯","🔞","📵","🚭","🚫","💤","♨️","💢","💬","🗨️","🗯️","💭","✳️","✴️","❇️","©️","®️","™️","#️⃣","*️⃣","0️⃣","1️⃣","2️⃣","3️⃣","4️⃣","5️⃣","6️⃣","7️⃣","8️⃣","9️⃣","🔟","🔢","▶️","⏸️","⏯️","⏹️","⏺️","⏭️","⏮️","⏩","⏪","🔀","🔁","🔂","◀️","🔼","🔽","➡️","⬅️","⬆️","⬇️","↗️","↘️","↙️","↖️","↕️","↔️","🔄","🔃","🎵","🎶","➕","➖","➗","✖️","🟰","💲","💱"])
    ]
}

struct EmojiPanel: View {
    let insert: (String) -> Void
    let backToKeys: () -> Void
    let deleteBackward: () -> Void

    @State private var categoryIndex = -1

    private var currentEmojis: [String] {
        if categoryIndex == -1 {
            let recents = EmojiStore.recents
            return recents.isEmpty ? EmojiStore.categories[0].emojis : recents
        }
        return EmojiStore.categories[categoryIndex].emojis
    }

    var body: some View {
        VStack(spacing: 4) {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 2) {
                    ForEach(currentEmojis, id: \.self) { emoji in
                        Button { insert(emoji) } label: {
                            Text(emoji)
                                .font(.system(size: 28))
                                .frame(maxWidth: .infinity)
                                .frame(height: 38)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 2) {
                Button { backToKeys() } label: {
                    Text("ABC")
                        .font(.subheadline)
                        .frame(width: 46, height: 34)
                        .background(Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        categoryButton(icon: "🕐", index: -1)
                        ForEach(Array(EmojiStore.categories.enumerated()), id: \.offset) { index, category in
                            categoryButton(icon: category.icon, index: index)
                        }
                    }
                }

                Button { deleteBackward() } label: {
                    Image(systemName: "delete.left")
                        .font(.body)
                        .frame(width: 40, height: 34)
                        .background(Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func categoryButton(icon: String, index: Int) -> some View {
        Button { categoryIndex = index } label: {
            Text(icon)
                .font(.system(size: 18))
                .frame(width: 34, height: 34)
                .background(categoryIndex == index ? Color.accentColor.opacity(0.22) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}


// MARK: - Botón que dispara al tocar (respuesta inmediata)

struct TouchDownButton<Content: View>: View {
    private let action: () -> Void
    private let content: Content
    @State private var down = false

    init(action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.action = action
        self.content = content()
    }

    var body: some View {
        content
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !down { down = true; action() }
                    }
                    .onEnded { _ in down = false }
            )
    }
}
