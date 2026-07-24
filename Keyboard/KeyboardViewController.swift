import UIKit
import SwiftUI
import SwiftData

/// Puente entre el controlador UIKit y la vista SwiftUI.
final class KeyboardBridge {
    weak var controller: KeyboardViewController?

    var lexiconWords: [String] = []

    var hasFullAccess: Bool { controller?.hasFullAccess ?? false }
    var needsSwitchKey: Bool { controller?.needsInputModeSwitchKey ?? true }

    func insert(_ text: String) { controller?.textDocumentProxy.insertText(text) }
    func deleteBackward() { controller?.textDocumentProxy.deleteBackward() }
    func contextBefore() -> String { controller?.textDocumentProxy.documentContextBeforeInput ?? "" }
    func nextKeyboard() { controller?.advanceToNextInputMode() }
}

final class KeyboardViewController: UIInputViewController {

    private let bridge = KeyboardBridge()

    override func viewDidLoad() {
        super.viewDidLoad()
        bridge.controller = self

        requestSupplementaryLexicon { [weak self] lexicon in
            DispatchQueue.main.async {
                self?.bridge.lexiconWords = lexicon.entries.map { $0.documentText }
            }
        }

        let host = UIHostingController(rootView: KeyboardRootView(bridge: bridge))
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        host.didMove(toParent: self)

        let height = view.heightAnchor.constraint(equalToConstant: 330)
        height.priority = .defaultHigh
        height.isActive = true
    }
}

// MARK: - Snapshot ligero

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

    @State private var shift: ShiftState = .on
    @State private var symbolsMode = false
    @State private var panel: Panel = .keys
    @State private var favoritesOnly = false
    @State private var snapshots: [ClipSnapshot] = []
    @State private var suggestions: [String] = []
    @State private var hint: String?
    @State private var lastSpaceTap: Date = .distantPast
    @State private var deleteTimer: Timer?

    private let keyColor = Color(.secondarySystemBackground)
    private let keyPressColor = Color(.systemGray2)

    var body: some View {
        VStack(spacing: 6) {
            toolbar
            switch panel {
            case .keys:      keysArea
            case .clipboard: clipboardPanel
            case .emoji:     EmojiPanel(insert: { insertEmoji($0) },
                                        backToKeys: { panel = .keys },
                                        deleteBackward: { bridge.deleteBackward() })
            }
        }
        .padding(.horizontal, 3)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .task {
            captureAndLoad()
            updateShiftFromContext()
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

    // MARK: Barra superior: portapapeles + predicciones + emoji

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button {
                if panel == .clipboard {
                    panel = .keys
                } else {
                    panel = .clipboard
                    captureAndLoad()
                }
            } label: {
                Image(systemName: panel == .clipboard ? "keyboard" : "doc.on.clipboard")
                    .font(.body.weight(.medium))
                    .frame(width: 44, height: 34)
                    .background(panel == .clipboard ? Color.accentColor.opacity(0.25) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(panel == .clipboard ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.plain)

            if suggestions.isEmpty {
                Spacer()
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(suggestions.prefix(3).enumerated()), id: \.offset) { index, word in
                        if index > 0 {
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

            Button {
                panel = panel == .emoji ? .keys : .emoji
            } label: {
                Image(systemName: panel == .emoji ? "keyboard" : "face.smiling")
                    .font(.body.weight(.medium))
                    .frame(width: 44, height: 34)
                    .background(panel == .emoji ? Color.accentColor.opacity(0.25) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(panel == .emoji ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.plain)
        }
        .frame(height: 36)
    }

    // MARK: Teclas

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
        VStack(spacing: 7) {
            HStack(spacing: 4) {
                ForEach(numberRow, id: \.self) { key in
                    charKey(key, small: true)
                }
            }

            ForEach(0..<2, id: \.self) { index in
                HStack(spacing: 4) {
                    ForEach((symbolsMode ? symbolRows : letterRows)[index], id: \.self) { key in
                        charKey(key)
                    }
                }
            }

            HStack(spacing: 4) {
                if symbolsMode {
                    ForEach(thirdRowSymbols, id: \.self) { charKey($0) }
                } else {
                    shiftKey
                    ForEach(thirdRowLetters, id: \.self) { charKey($0) }
                }
                backspaceKey
            }

            HStack(spacing: 4) {
                pressKey(width: 46) {
                    symbolsMode.toggle()
                } label: {
                    Text(symbolsMode ? "ABC" : "123").font(.subheadline)
                }
                if bridge.needsSwitchKey {
                    pressKey(width: 40) { bridge.nextKeyboard() } label: {
                        Image(systemName: "globe").font(.body)
                    }
                }
                pressKey(width: 36) { insertAndRefresh(",") } label: {
                    Text(",").font(.system(size: 20))
                }
                spaceKey
                pressKey(width: 36) { insertSentenceEnd(".") } label: {
                    Text(".").font(.system(size: 20))
                }
                pressKey(width: 56) { insertAndRefresh("\n") } label: {
                    Image(systemName: "return").font(.body)
                }
            }
        }
    }

    /// Tecla que dispara al TOCAR (no al soltar): respuesta inmediata.
    private func pressKey<Label: View>(width: CGFloat? = nil,
                                       height: CGFloat = 41,
                                       action: @escaping () -> Void,
                                       @ViewBuilder label: () -> Label) -> some View {
        PressableKey(width: width, height: height,
                     normal: keyColor, pressed: keyPressColor,
                     onPress: action, content: label())
    }

    private func charKey(_ key: String, small: Bool = false) -> some View {
        let display = (shift == .off || symbolsMode) ? key : key.uppercased()
        return pressKey(height: small ? 34 : 41) {
            let output = (shift == .off || symbolsMode) ? key : key.uppercased()
            bridge.insert(output)
            if shift == .on && !symbolsMode { shift = .off }
            refreshSuggestions()
        } label: {
            Text(display).font(.system(size: small ? 18 : 22))
        }
    }

    private var shiftKey: some View {
        let icon = shift == .caps ? "capslock.fill" : (shift == .on ? "shift.fill" : "shift")
        return Image(systemName: icon)
            .font(.body)
            .frame(width: 40, height: 41)
            .background(shift != .off ? Color(.systemGray3) : keyColor,
                        in: RoundedRectangle(cornerRadius: 7))
            .gesture(
                ExclusiveGesture(
                    TapGesture(count: 2).onEnded { shift = .caps },
                    TapGesture().onEnded { shift = shift == .off ? .on : .off }
                )
            )
    }

    /// Borrado con repetición al mantener pulsado.
    private var backspaceKey: some View {
        PressableKey(width: 40, height: 41,
                     normal: keyColor, pressed: keyPressColor,
                     onPress: {
                         bridge.deleteBackward()
                         refreshSuggestions()
                         deleteTimer?.invalidate()
                         deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { _ in
                             deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { _ in
                                 DispatchQueue.main.async {
                                     bridge.deleteBackward()
                                 }
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

    private var spaceKey: some View {
        pressKey { handleSpace() } label: {
            Text("espacio").font(.footnote).foregroundStyle(.secondary)
        }
    }

    // MARK: Lógica de escritura

    private func handleSpace() {
        let now = Date()
        let before = bridge.contextBefore()
        // Doble espacio rápido → ". "
        if now.timeIntervalSince(lastSpaceTap) < 0.4,
           before.hasSuffix(" "),
           before.dropLast().last?.isLetter == true {
            bridge.deleteBackward()
            bridge.insert(". ")
            shift = .on
        } else {
            bridge.insert(" ")
            updateShiftFromContext()
        }
        lastSpaceTap = now
        refreshSuggestions()
    }

    private func insertSentenceEnd(_ char: String) {
        bridge.insert(char)
        shift = .on
        refreshSuggestions()
    }

    private func insertAndRefresh(_ text: String) {
        bridge.insert(text)
        refreshSuggestions()
    }

    private func insertEmoji(_ emoji: String) {
        bridge.insert(emoji)
        EmojiStore.registerRecent(emoji)
    }

    private func updateShiftFromContext() {
        guard shift != .caps else { return }
        let before = bridge.contextBefore().trimmingCharacters(in: .whitespaces)
        if before.isEmpty || before.hasSuffix(".") || before.hasSuffix("!") || before.hasSuffix("?") {
            shift = .on
        }
    }

    // MARK: Predicción (diccionario del sistema + léxico del usuario)

    private func currentWord() -> String {
        let before = bridge.contextBefore()
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ".,;:!?¿¡\"'()[]{}"))
        if let lastRange = before.rangeOfCharacter(from: separators, options: .backwards) {
            return String(before[lastRange.upperBound...])
        }
        return before
    }

    private func refreshSuggestions() {
        let word = currentWord()
        guard word.count >= 2, word.rangeOfCharacter(from: .letters) != nil else {
            suggestions = []
            return
        }
        let lower = word.lowercased()
        let capitalizeOutput = word.first?.isUppercase == true

        var results: [String] = []

        // 1. Léxico personal del usuario (nombres, atajos de iOS)
        for entry in bridge.lexiconWords where entry.lowercased().hasPrefix(lower) {
            results.append(entry)
            if results.count >= 2 { break }
        }

        // 2. Completados del diccionario del sistema (español e inglés)
        let checker = UITextChecker()
        let range = NSRange(location: 0, length: word.utf16.count)
        for language in ["es_ES", "en_US"] {
            if let completions = checker.completions(forPartialWordRange: range,
                                                     in: word,
                                                     language: language) {
                results.append(contentsOf: completions)
            }
            if results.count >= 10 { break }
        }

        // Dedupe conservando orden, sin la palabra ya escrita
        var seen = Set<String>()
        var unique: [String] = []
        for candidate in results {
            let key = candidate.lowercased()
            guard key != lower, !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(capitalizeOutput ? candidate.prefix(1).uppercased() + candidate.dropFirst() : candidate)
            if unique.count == 3 { break }
        }
        suggestions = unique
    }

    private func applySuggestion(_ word: String) {
        let current = currentWord()
        for _ in 0..<current.count {
            bridge.deleteBackward()
        }
        bridge.insert(word + " ")
        suggestions = []
        updateShiftFromContext()
    }

    // MARK: Panel del portapapeles (pantalla completa, sin teclas)

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
                                Button { handleClipTap(snap) } label: {
                                    clipCard(snap)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.bottom, 6)
                    }
                }
            }
        }
    }

    private func filterChip(_ text: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
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

// MARK: - Tecla que reacciona al tocar (touch-down) con repetición opcional

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
        ("💡", ["📱","💻","⌨️","🖥️","🖨️","🖱️","💽","💾","💿","📀","📷","📸","📹","🎥","📞","☎️","📟","📠","📺","📻","🎙️","⏰","⌚","🔋","🔌","💡","🔦","🕯️","🗑️","🛢️","💵","💴","💶","💷","💰","💳","💎","⚖️","🔧","🔨","⚒️","🛠️","⛏️","🔩","⚙️","🧱","⛓️","🧲","🔫","💣","🔪","🗡️","🛡️","🚬","⚰️","🔮","📿","🧿","💈","⚗️","🔭","🔬","🕳️","💊","💉","🩹","🩺","🌡️","🧬","🦠","🧫","🧪"]),
        ("🔣", ["✅","❌","❓","❗","‼️","⁉️","💯","🔞","📵","🚭","🚫","💤","♨️","💢","💬","👁️‍🗨️","🗨️","🗯️","💭","🕐","✳️","✴️","❇️","©️","®️","™️","#️⃣","*️⃣","0️⃣","1️⃣","2️⃣","3️⃣","4️⃣","5️⃣","6️⃣","7️⃣","8️⃣","9️⃣","🔟","🔢","▶️","⏸️","⏯️","⏹️","⏺️","⏭️","⏮️","⏩","⏪","🔀","🔁","🔂","◀️","🔼","🔽","➡️","⬅️","⬆️","⬇️","↗️","↘️","↙️","↖️","↕️","↔️","🔄","🔃","🎵","🎶","➕","➖","➗","✖️","🟰","💲","💱"])
    ]
}

struct EmojiPanel: View {
    let insert: (String) -> Void
    let backToKeys: () -> Void
    let deleteBackward: () -> Void

    @State private var categoryIndex = -1   // -1 = recientes

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
                        Button {
                            insert(emoji)
                        } label: {
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
                Button {
                    backToKeys()
                } label: {
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

                Button {
                    deleteBackward()
                } label: {
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
        Button {
            categoryIndex = index
        } label: {
            Text(icon)
                .font(.system(size: 18))
                .frame(width: 34, height: 34)
                .background(categoryIndex == index ? Color.accentColor.opacity(0.22) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}
