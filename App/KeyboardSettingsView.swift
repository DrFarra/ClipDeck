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
            Section("Diseño") {
                VStack(alignment: .leading) {
                    Text("Altura del teclado: \(Int(config.height)) pt")
                    Slider(value: $config.height, in: 280...380, step: 5)
                }
                VStack(alignment: .leading) {
                    Text("Altura de teclas: \(Int(config.keyHeight)) pt")
                    Slider(value: $config.keyHeight, in: 36...50, step: 1)
                }
                VStack(alignment: .leading) {
                    Text("Tamaño de letra: \(Int(config.fontSize)) pt")
                    Slider(value: $config.fontSize, in: 18...26, step: 1)
                }
                Toggle("Fila de números", isOn: $config.numberRow)
                Toggle("Globo al pulsar tecla", isOn: $config.keyPopup)
            }

            Section("Teclas de puntuación") {
                Picker("Tecla izquierda (junto al espacio)", selection: $config.punctLeft) {
                    ForEach(punctuationOptions, id: \.self) { Text($0).tag($0) }
                }
                Picker("Tecla derecha (junto al espacio)", selection: $config.punctRight) {
                    ForEach(punctuationOptions, id: \.self) { Text($0).tag($0) }
                }
                Text("Por defecto son «,» y «.». Puedes cambiar la derecha por «?» u otro signo.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Escritura") {
                Toggle("Predicción de palabras", isOn: $config.prediction)
                Toggle("Autocorrección", isOn: $config.autocorrect)
                Toggle("Aprender mis palabras", isOn: $config.learnWords)
                Toggle("Acentos con pulsación larga", isOn: $config.accents)
                Toggle("Doble espacio inserta punto", isOn: $config.doubleSpace)
                Toggle("Mayúsculas automáticas", isOn: $config.autoCapital)
                Toggle("Deslizar espacio mueve el cursor", isOn: $config.trackpad)
            }

            Section("Respuesta al pulsar") {
                Toggle("Vibración", isOn: $config.haptics)
                Toggle("Sonido de tecla", isOn: $config.sound)
            }

            Section("Palabras aprendidas") {
                LabeledContent("Vocabulario personal", value: "\(learnedCount) palabras")
                Button("Borrar palabras aprendidas", role: .destructive) {
                    showClearConfirm = true
                }
                Text("El teclado aprende las palabras que escribes y qué palabra suele seguir a otra, todo localmente en tu dispositivo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Los cambios se aplican la próxima vez que se abra el teclado (cambia de app o ciérralo y ábrelo).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Teclado")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: config.height) { save() }
        .onChange(of: config.keyHeight) { save() }
        .onChange(of: config.fontSize) { save() }
        .onChange(of: config.numberRow) { save() }
        .onChange(of: config.keyPopup) { save() }
        .onChange(of: config.prediction) { save() }
        .onChange(of: config.autocorrect) { save() }
        .onChange(of: config.learnWords) { save() }
        .onChange(of: config.accents) { save() }
        .onChange(of: config.doubleSpace) { save() }
        .onChange(of: config.autoCapital) { save() }
        .onChange(of: config.trackpad) { save() }
        .onChange(of: config.haptics) { save() }
        .onChange(of: config.sound) { save() }
        .onChange(of: config.punctLeft) { save() }
        .onChange(of: config.punctRight) { save() }
        .confirmationDialog("¿Borrar el vocabulario aprendido?",
                            isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Borrar", role: .destructive) {
                WordLearner.clear()
                learnedCount = 0
            }
        }
    }

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
