import SwiftUI

/// Configuración completa del teclado ClipDeck.
/// Se guarda en el App Group para que la extensión la lea.
struct KeyboardSettingsView: View {
    @State private var config = KbPrefs.Config.load()
    @State private var learnedCount = WordLearner.learnedCount
    @State private var showClearConfirm = false

    private let punctuationOptions = [",", ".", "?", "!", ":", ";", "-", "'", "@"]

    var body: some View {
        Form {
            designSection
            punctuationSection
            writingSection
            feedbackSection
            learnedSection
            noteSection
        }
        .navigationTitle("Teclado")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: config) { save() }
        .confirmationDialog("¿Borrar el vocabulario aprendido?",
                            isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Borrar", role: .destructive) {
                WordLearner.clear()
                learnedCount = 0
            }
        }
    }

    // MARK: Secciones

    @ViewBuilder private var designSection: some View {
        Section("Diseño") {
            sliderRow("Altura del teclado", value: $config.height, range: 280...380, step: 5, suffix: " pt")
            sliderRow("Altura de teclas", value: $config.keyHeight, range: 36...50, step: 1, suffix: " pt")
            sliderRow("Tamaño de letra", value: $config.fontSize, range: 18...26, step: 1, suffix: " pt")
            Toggle("Fila de números", isOn: $config.numberRow)
            Toggle("Globo al pulsar tecla", isOn: $config.keyPopup)
        }
    }

    @ViewBuilder private var punctuationSection: some View {
        Section("Teclas de puntuación") {
            Picker("Tecla izquierda", selection: $config.punctLeft) {
                ForEach(punctuationOptions, id: \.self) { Text($0).tag($0) }
            }
            Picker("Tecla derecha", selection: $config.punctRight) {
                ForEach(punctuationOptions, id: \.self) { Text($0).tag($0) }
            }
            Text("Por defecto «,» y «.». Puedes cambiar la derecha por «?» u otro signo.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var writingSection: some View {
        Section("Escritura") {
            Toggle("Predicción de palabras", isOn: $config.prediction)
            Toggle("Autocorrección", isOn: $config.autocorrect)
            Toggle("Aprender mis palabras", isOn: $config.learnWords)
            Toggle("Acentos con pulsación larga", isOn: $config.accents)
            Toggle("Doble espacio inserta punto", isOn: $config.doubleSpace)
            Toggle("Mayúsculas automáticas", isOn: $config.autoCapital)
            Toggle("Deslizar espacio mueve el cursor", isOn: $config.trackpad)
        }
    }

    @ViewBuilder private var feedbackSection: some View {
        Section("Respuesta al pulsar") {
            Toggle("Vibración", isOn: $config.haptics)
            Toggle("Sonido de tecla", isOn: $config.sound)
        }
    }

    @ViewBuilder private var learnedSection: some View {
        Section("Palabras aprendidas") {
            NavigationLink {
                LearnedWordsView()
            } label: {
                LabeledContent("Vocabulario personal", value: "\(learnedCount) palabras")
            }
            Button("Borrar palabras aprendidas", role: .destructive) {
                showClearConfirm = true
            }
            Text("El teclado aprende tus palabras y qué palabra suele seguir a otra, todo localmente en tu dispositivo.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var noteSection: some View {
        Section {
            Text("Los cambios se aplican la próxima vez que se abra el teclado (cambia de app o ciérralo y ábrelo).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Fila de slider reutilizable

    private func sliderRow(_ title: String, value: Binding<Double>,
                           range: ClosedRange<Double>, step: Double, suffix: String) -> some View {
        VStack(alignment: .leading) {
            Text("\(title): \(Int(value.wrappedValue))\(suffix)")
            Slider(value: value, in: range, step: step)
        }
    }

    // MARK: Guardado

    private func save() {
        let store = KbPrefs.store
        store.set(config.height, forKey: KbPrefs.height)
        store.set(config.keyHeight, forKey: KbPrefs.keyHeight)
        store.set(config.fontSize, forKey: KbPrefs.fontSize)
        store.set(config.numberRow, forKey: KbPrefs.numberRow)
        store.set(config.keyPopup, forKey: KbPrefs.keyPopup)
        store.set(config.prediction, forKey: KbPrefs.prediction)
        store.set(config.autocorrect, forKey: KbPrefs.autocorrect)
        store.set(config.learnWords, forKey: KbPrefs.learnWords)
        store.set(config.accents, forKey: KbPrefs.longPressAccents)
        store.set(config.doubleSpace, forKey: KbPrefs.doubleSpace)
        store.set(config.autoCapital, forKey: KbPrefs.autoCapital)
        store.set(config.trackpad, forKey: KbPrefs.spaceTrackpad)
        store.set(config.haptics, forKey: KbPrefs.haptics)
        store.set(config.sound, forKey: KbPrefs.sound)
        store.set(config.punctLeft, forKey: KbPrefs.punctLeft)
        store.set(config.punctRight, forKey: KbPrefs.punctRight)
    }
}
