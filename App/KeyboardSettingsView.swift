import SwiftUI

/// Configuración completa del teclado ClipDeck.
/// Se guarda en el App Group para que la extensión la lea.
struct KeyboardSettingsView: View {
    @State private var config = KbPrefs.Config.load()
    @State private var learnedCount = WordLearner.learnedCount
    @State private var showClearConfirm = false
    @State private var buildingDict = false
    @State private var dictProgress = 0.0
    @State private var dictCount = SwipeLexicon.builtCount
    @State private var dictComplete = SwipeLexicon.isComplete
    @State private var touchSamples = Int(TouchModel.totalSamples)
    @State private var showTouchReset = false

    private let punctuationOptions = [",", ".", "?", "!", ":", ";", "-", "'", "@"]

    var body: some View {
        Form {
            designSection
            punctuationSection
            writingSection
            adaptiveSection
            swipeSection
            trackpadSection
            feedbackSection
            learnedSection
            noteSection
        }
        .navigationTitle("Teclado")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: config) { save() }
        .confirmationDialog("¿Olvidar cómo escribís?",
                            isPresented: $showTouchReset, titleVisibility: .visible) {
            Button("Olvidar", role: .destructive) {
                TouchModel.reset()
                touchSamples = 0
            }
        } message: {
            Text("Las teclas vuelven a sus fronteras normales y el teclado empieza a estudiarte de cero.")
        }
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
        }
    }

    @ViewBuilder private var adaptiveSection: some View {
        Section("Se adapta a cómo escribís") {
            Toggle("Corrector inteligente", isOn: $config.smartCorrect)
            Toggle("Ajustar teclas a mi pulsación", isOn: $config.adaptiveKeys)
            LabeledContent("Pulsaciones estudiadas", value: "\(touchSamples)")
            Button("Olvidar cómo escribo", role: .destructive) { showTouchReset = true }
            Text("El teclado anota a qué altura y a qué lado de cada tecla cae tu dedo, y corre las fronteras invisibles entre teclas sin moverlas de sitio. El corrector usa esos mismos datos: sabe si un toque quedó a medio camino entre dos letras, qué teclas están pegadas, tus palabras y cuál sueles escribir después de cuál. Todo se calcula y se guarda solo en tu iPhone.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var swipeSection: some View {
        Section("Escribir deslizando") {
            Toggle("Escribir deslizando el dedo", isOn: $config.swipe)
            LabeledContent("Diccionario", value: dictionaryStatus)
            if buildingDict {
                ProgressView(value: dictProgress)
            } else {
                Button(dictButtonTitle) { buildDictionary(restart: dictComplete) }
            }
            Text("Sin levantar el dedo, pasa por las letras de la palabra. El diccionario se arma en tu iPhone con las palabras del sistema y las tuyas: no se descarga nada y sólo hace falta prepararlo una vez.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var trackpadSection: some View {
        Section("Trackpad del espacio") {
            Toggle("Deslizar espacio mueve el cursor", isOn: $config.trackpad)
            sliderRow("Sensibilidad vertical", value: $config.trackpadStepY,
                      range: 10...40, step: 1, suffix: " pt por línea")
            sliderRow("Ancho de línea estimado", value: $config.trackpadChars,
                      range: 15...80, step: 1, suffix: " caracteres")
            Text("Baja los puntos por línea si te cuesta subir o bajar entre oraciones. El ancho estimado sólo se usa cuando el texto no tiene saltos de línea reales.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var dictionaryStatus: String {
        if buildingDict { return "Preparando… \(Int(dictProgress * 100))%" }
        if dictCount <= 0 { return "Sin preparar" }
        return dictComplete ? "\(dictCount) palabras" : "\(dictCount) palabras (a medias)"
    }

    private var dictButtonTitle: String {
        if dictComplete { return "Rehacer diccionario" }
        return dictCount > 0 ? "Continuar preparación" : "Preparar diccionario"
    }

    /// Se puede cerrar la app a mitad: el avance queda guardado y continúa.
    private func buildDictionary(restart: Bool) {
        buildingDict = true
        dictProgress = 0
        DispatchQueue.global(qos: .utility).async {
            let n = SwipeLexicon.build(restart: restart) { p in
                DispatchQueue.main.async { dictProgress = p }
            }
            DispatchQueue.main.async {
                dictCount = n
                dictComplete = SwipeLexicon.isComplete
                buildingDict = false
            }
        }
    }

    @ViewBuilder private var feedbackSection: some View {
        Section("Respuesta al pulsar") {
            Toggle("Vibración de teclas", isOn: $config.haptics)
            Toggle("Vibración en pulsación larga", isOn: $config.hapticsLongPress)
            Toggle("Sonido de tecla", isOn: $config.sound)
            Text("La segunda es independiente: vibra al abrir el globo de acentos, al pasar entre sus opciones y al activar el trackpad, aunque tengas apagada la de teclas.")
                .font(.caption).foregroundStyle(.secondary)
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
        store.set(config.hapticsLongPress, forKey: KbPrefs.hapticsLongPress)
        store.set(config.swipe, forKey: KbPrefs.swipe)
        store.set(config.adaptiveKeys, forKey: KbPrefs.adaptiveKeys)
        store.set(config.smartCorrect, forKey: KbPrefs.smartCorrect)
        store.set(config.trackpadStepY, forKey: KbPrefs.trackpadStepY)
        store.set(config.trackpadChars, forKey: KbPrefs.trackpadChars)
        store.set(config.punctLeft, forKey: KbPrefs.punctLeft)
        store.set(config.punctRight, forKey: KbPrefs.punctRight)
    }
}
