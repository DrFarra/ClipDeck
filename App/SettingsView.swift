import SwiftUI
import SwiftData
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL

    @AppStorage(SettingsKeys.appearance, store: AppGroup.sharedDefaults) private var appearance = "system"
    @AppStorage(SettingsKeys.retentionDays, store: AppGroup.sharedDefaults) private var retentionDays = 0
    @AppStorage(SettingsKeys.capturePaused, store: AppGroup.sharedDefaults) private var capturePaused = false
    @AppStorage(SettingsKeys.moveReusedToTop, store: AppGroup.sharedDefaults) private var moveReusedToTop = true
    @AppStorage(SettingsKeys.confirmDelete, store: AppGroup.sharedDefaults) private var confirmDelete = true
    @AppStorage(SettingsKeys.saveImages, store: AppGroup.sharedDefaults) private var saveImages = true
    @AppStorage(SettingsKeys.ocrEnabled, store: AppGroup.sharedDefaults) private var ocrEnabled = true
    @AppStorage(SettingsKeys.sensitiveDetection, store: AppGroup.sharedDefaults) private var sensitiveDetection = true
    @AppStorage(SettingsKeys.faceIDLock, store: AppGroup.sharedDefaults) private var faceIDLock = false
    @AppStorage(SettingsKeys.blurInSwitcher, store: AppGroup.sharedDefaults) private var blurInSwitcher = true

    @State private var storageText = "Calculando…"
    @State private var showDeleteAll = false

    var body: some View {
        NavigationStack {
            Form {
                Section("General") {
                    Picker("Apariencia", selection: $appearance) {
                        Text("Sistema").tag("system")
                        Text("Clara").tag("light")
                        Text("Oscura").tag("dark")
                    }
                    Toggle("Confirmar antes de eliminar", isOn: $confirmDelete)
                    Toggle("Elementos reutilizados al principio", isOn: $moveReusedToTop)
                }

                Section("Historial") {
                    Picker("Conservar historial", selection: $retentionDays) {
                        Text("Un día").tag(1)
                        Text("Una semana").tag(7)
                        Text("Un mes").tag(30)
                        Text("Tres meses").tag(90)
                        Text("Un año").tag(365)
                        Text("Ilimitado").tag(0)
                    }
                    Toggle("Guardar imágenes", isOn: $saveImages)
                    Toggle("Pausar captura", isOn: $capturePaused)
                    Text("Los favoritos y los elementos en pinboards nunca caducan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Búsqueda") {
                    Toggle("OCR en imágenes", isOn: $ocrEnabled)
                    Text("El texto de capturas y fotos se reconoce en el dispositivo y se añade al índice de búsqueda.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Reglas de captura") {
                    NavigationLink("Reglas") { RulesView() }
                    Toggle("Detectar contenido sensible", isOn: $sensitiveDetection)
                }

                Section("Privacidad") {
                    Toggle("Proteger con Face ID", isOn: $faceIDLock)
                    Toggle("Ocultar en multitarea", isOn: $blurInSwitcher)
                    Text("Todo el procesamiento (incluido el OCR) ocurre en tu dispositivo. Esta app no usa servidores propios.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Teclado y extensiones") {
                    NavigationLink("Configuración del teclado") { KeyboardSettingsView() }
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    } label: {
                        Label("Abrir Ajustes de ClipDeck en iOS", systemImage: "gear")
                    }
                    DisclosureGroup("Cómo activar el teclado") {
                        Text("""
                        1. Abre Ajustes → General → Teclado → Teclados
                        2. Toca «Añadir nuevo teclado»
                        3. Selecciona «Teclado ClipDeck»
                        4. Actívalo y habilita «Permitir acceso completo»

                        El acceso completo es necesario para que el teclado lea tu historial compartido. Sin él, el teclado mostrará un aviso.
                        """)
                        .font(.caption)
                    }
                    DisclosureGroup("Cómo usar la extensión de compartir") {
                        Text("""
                        En cualquier app, toca el botón Compartir y elige «ClipDeck» para guardar texto, enlaces, imágenes o archivos directamente en tu historial.
                        """)
                        .font(.caption)
                    }
                    Text("Nota de iOS: el sistema no permite capturar el portapapeles en segundo plano. ClipDeck captura al abrir la app, desde el teclado o desde la extensión de compartir.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Almacenamiento") {
                    LabeledContent("Espacio utilizado", value: storageText)
                    Button("Eliminar todos los datos", role: .destructive) {
                        showDeleteAll = true
                    }
                }

                Section("Acerca de") {
                    LabeledContent("Versión", value: "1.0")
                    Text("ClipDeck es un gestor de portapapeles local y privado.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
            .task { computeStorage() }
            .confirmationDialog("¿Eliminar todos los datos?", isPresented: $showDeleteAll, titleVisibility: .visible) {
                Button("Eliminar todo", role: .destructive) { deleteAll() }
            } message: {
                Text("Se eliminarán el historial, los pinboards y las reglas. Esta acción no se puede deshacer.")
            }
        }
    }

    private func computeStorage() {
        let url = AppGroup.containerURL
        DispatchQueue.global(qos: .utility).async {
            var total: Int64 = 0
            if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let fileURL as URL in enumerator {
                    total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            }
            let text = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            DispatchQueue.main.async { storageText = text }
        }
    }

    private func deleteAll() {
        try? modelContext.delete(model: ClipItem.self)
        try? modelContext.delete(model: Pinboard.self)
        try? modelContext.delete(model: CaptureRule.self)
        try? modelContext.save()
        CaptureService.updateWidget(context: modelContext)
        computeStorage()
    }
}

// MARK: - Reglas

struct RulesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var rules: [CaptureRule]
    @State private var showEditor = false

    var body: some View {
        List {
            if rules.isEmpty {
                Text("Sin reglas. Crea una para ignorar o marcar contenido automáticamente.")
                    .foregroundStyle(.secondary)
            }
            ForEach(rules) { rule in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(rule.name).font(.subheadline.weight(.medium))
                        Spacer()
                        Toggle("", isOn: Binding(get: { rule.isEnabled },
                                                 set: { rule.isEnabled = $0; try? modelContext.save() }))
                            .labelsHidden()
                    }
                    Text(ruleDescription(rule))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onDelete { indexSet in
                for index in indexSet { modelContext.delete(rules[index]) }
                try? modelContext.save()
            }
        }
        .navigationTitle("Reglas")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showEditor = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showEditor) { RuleEditorView() }
    }

    private func ruleDescription(_ rule: CaptureRule) -> String {
        var parts: [String] = []
        if let pattern = rule.textPattern, !pattern.isEmpty { parts.append("Patrón: \(pattern)") }
        if rule.minimumLength > 0 { parts.append("Mínimo \(rule.minimumLength) caracteres") }
        parts.append(rule.action.label)
        return parts.joined(separator: " · ")
    }
}

struct RuleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var pattern = ""
    @State private var minLength = 0
    @State private var action: CaptureRuleAction = .ignore

    var body: some View {
        NavigationStack {
            Form {
                TextField("Nombre de la regla", text: $name)
                Section("Condición") {
                    TextField("Expresión regular (opcional)", text: $pattern)
                        .autocapitalization(.none)
                        .font(.body.monospaced())
                    Stepper("Longitud mínima: \(minLength)", value: $minLength, in: 0...50)
                }
                Section("Acción") {
                    Picker("Acción", selection: $action) {
                        ForEach(CaptureRuleAction.allCases) { a in Text(a.label).tag(a) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .navigationTitle("Nueva regla")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        let rule = CaptureRule(name: name.isEmpty ? "Regla" : name,
                                               textPattern: pattern.isEmpty ? nil : pattern,
                                               minimumLength: minLength,
                                               action: action)
                        modelContext.insert(rule)
                        try? modelContext.save()
                        dismiss()
                    }
                }
            }
        }
    }
}
