import XCTest
import SwiftData
import UIKit

// Las fuentes de `Shared` se compilan dentro de este bundle, así que los tipos
// se usan directamente sin `@testable import`.

// MARK: - Clasificación de contenido

final class ContentClassifierTests: XCTestCase {

    func testClasificaColores() {
        XCTAssertEqual(ContentClassifier.classify(text: "#FF8800"), .color)
        XCTAssertEqual(ContentClassifier.classify(text: "rgb(255, 136, 0)"), .color)
    }

    func testNormalizaHex() {
        XCTAssertEqual(ContentClassifier.colorHex(from: "#ff8800"), "#FF8800")
        XCTAssertEqual(ContentClassifier.colorHex(from: "#f80"), "#FF8800")
        XCTAssertEqual(ContentClassifier.colorHex(from: "rgb(255, 136, 0)"), "#FF8800")
    }

    func testHexInvalidoNoEsColor() {
        XCTAssertNil(ContentClassifier.colorHex(from: "#GG0000"))   // no hexadecimal
        XCTAssertNil(ContentClassifier.colorHex(from: "#FF88"))     // longitud inválida
        XCTAssertNil(ContentClassifier.colorHex(from: "rgb(300, 0, 0)")) // fuera de rango
    }

    func testClasificaEnlaceCorreoYTelefono() {
        XCTAssertEqual(ContentClassifier.classify(text: "https://ejemplo.com/ruta?a=1"), .link)
        XCTAssertEqual(ContentClassifier.classify(text: "hola@ejemplo.com"), .email)
        XCTAssertEqual(ContentClassifier.classify(text: "+34 600 123 456"), .phoneNumber)
    }

    func testTextoNormalNoEsEnlace() {
        XCTAssertEqual(ContentClassifier.classify(text: "Recuerda comprar pan"), .plainText)
        // Una URL dentro de una frase no convierte la frase en enlace.
        XCTAssertEqual(ContentClassifier.classify(text: "mira esto https://ejemplo.com ya"), .plainText)
    }

    func testDetectaCodigo() {
        let swift = """
        func saludar(nombre: String) {
            let mensaje = "hola"
            print(mensaje)
        }
        """
        XCTAssertEqual(ContentClassifier.classify(text: swift), .code)
        XCTAssertEqual(ContentClassifier.detectCodeLanguage(swift), "Swift")
    }

    func testUnaLineaNuncaEsCodigo() {
        // Sin salto de línea la heurística no debe dispararse.
        XCTAssertFalse(ContentClassifier.looksLikeCode("let x = 1; func f() {}"))
    }

    func testDetectaSensible() {
        XCTAssertTrue(ContentClassifier.looksSensitive("sk-abc123def456"))
        XCTAssertTrue(ContentClassifier.looksSensitive("-----BEGIN RSA PRIVATE KEY-----"))
        // Token largo de alta entropía sin espacios.
        XCTAssertTrue(ContentClassifier.looksSensitive("aB3xK9-mQ7zR2_pL5wN8tY4vC6"))
    }

    func testTextoNormalNoEsSensible() {
        XCTAssertFalse(ContentClassifier.looksSensitive("Nos vemos mañana a las ocho"))
        XCTAssertFalse(ContentClassifier.looksSensitive("hola"))
    }
}

// MARK: - Alfabeto de escritura deslizando

final class SwipeAlphabetTests: XCTestCase {

    func testCodificaPalabraSimple() {
        // a=0, c=2, s=18
        XCTAssertEqual(SwipeAlphabet.encode("casa"), [2, 0, 18, 0])
    }

    func testPliegaAcentosALaTeclaBase() {
        // "también" se teclea t-a-m-b-i-e-n
        XCTAssertEqual(SwipeAlphabet.encode("también"), SwipeAlphabet.encode("tambien"))
        XCTAssertEqual(SwipeAlphabet.encode("ÁRBOL"), SwipeAlphabet.encode("arbol"))
    }

    func testEñeNoSePliegaAEne() {
        // La ñ tiene tecla propia: plegarla rompería el reconocimiento del trazo.
        XCTAssertEqual(SwipeAlphabet.index("ñ"), 26)
        XCTAssertEqual(SwipeAlphabet.index("n"), 13)
        XCTAssertNotEqual(SwipeAlphabet.encode("año"), SwipeAlphabet.encode("ano"))
    }

    func testRechazaCaracteresNoTecleables() {
        XCTAssertNil(SwipeAlphabet.encode("hola mundo"))  // espacio
        XCTAssertNil(SwipeAlphabet.encode("casa1"))       // dígito
        XCTAssertNil(SwipeAlphabet.encode("¿qué?"))       // puntuación
    }
}

// MARK: - Reglas de captura

@MainActor
final class CaptureRuleTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(schema: ClipStore.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ClipStore.schema, configurations: [config])
        return ModelContext(container)
    }

    private func insert(_ rule: CaptureRule, into context: ModelContext) throws {
        context.insert(rule)
        try context.save()
    }

    func testReglaRegexDescartaElTexto() throws {
        let context = try makeContext()
        try insert(CaptureRule(name: "secretos", textPattern: "^secreto", action: .ignore), into: context)

        guard case .ignored = CaptureService.saveText("secreto de estado", context: context) else {
            return XCTFail("la regla debía descartar el texto")
        }
    }

    func testReglaRegexMarcaComoSensible() throws {
        let context = try makeContext()
        try insert(CaptureRule(name: "tarjetas", textPattern: "tarjeta", action: .markSensitive), into: context)

        guard case .saved(let item) = CaptureService.saveText("mi tarjeta 1234", context: context) else {
            return XCTFail("el texto debía guardarse")
        }
        XCTAssertTrue(item.isSensitive)
    }

    func testReglaDeLongitudMinimaDescartaTextoCorto() throws {
        let context = try makeContext()
        try insert(CaptureRule(name: "muy corto", minimumLength: 10, action: .ignore), into: context)

        guard case .ignored = CaptureService.saveText("corto", context: context) else {
            return XCTFail("un texto por debajo del mínimo debía descartarse")
        }
        guard case .saved = CaptureService.saveText("esto ya es suficientemente largo", context: context) else {
            return XCTFail("un texto por encima del mínimo debía guardarse")
        }
    }

    func testTextoRepetidoNoSeDuplica() throws {
        let context = try makeContext()

        guard case .saved(let primero) = CaptureService.saveText("mismo texto", context: context) else {
            return XCTFail("el primer guardado debía funcionar")
        }
        guard case .duplicate(let segundo) = CaptureService.saveText("  mismo texto  ", context: context) else {
            return XCTFail("el segundo guardado debía detectarse como duplicado")
        }
        XCTAssertEqual(primero.id, segundo.id)
    }

    func testTextoVacioNoSeGuarda() throws {
        let context = try makeContext()
        guard case .empty = CaptureService.saveText("   \n  ", context: context) else {
            return XCTFail("un texto en blanco no debía guardarse")
        }
    }
}

// MARK: - Reglas de texto del teclado

final class TextRulesTests: XCTestCase {

    func testMayusculaSoloTrasPuntoYEspacio() {
        XCTAssertTrue(TextRules.startsSentence(""))
        XCTAssertTrue(TextRules.startsSentence("Hola. "))
        XCTAssertTrue(TextRules.startsSentence("¿Vienes? "))
        XCTAssertTrue(TextRules.startsSentence("Hola\n"))
        XCTAssertFalse(TextRules.startsSentence("Hola "))
        // Sin espacio tras el punto no hay frase nueva: direcciones y correos.
        XCTAssertFalse(TextRules.startsSentence("www."))
        XCTAssertFalse(TextRules.startsSentence("juan."))
    }

    func testSignosDeAperturaNoCambianLaMayuscula() {
        XCTAssertTrue(TextRules.startsSentence("¿"))
        XCTAssertTrue(TextRules.startsSentence("Hola. ¿"))
        XCTAssertTrue(TextRules.startsSentence("Hola. ¡"))
        XCTAssertFalse(TextRules.startsSentence("Oye, ¿"))
        XCTAssertTrue(TextRules.startsSentence("Dijo \"hola.\" "))
    }

    func testInicioDePalabra() {
        XCTAssertTrue(TextRules.startsWord(""))
        XCTAssertTrue(TextRules.startsWord("hola "))
        XCTAssertTrue(TextRules.startsWord("hola ("))
        XCTAssertFalse(TextRules.startsWord("hola"))
    }

    func testPalabraEnCursoYAnterior() {
        XCTAssertEqual(TextRules.wordBefore("hola que"), "que")
        XCTAssertEqual(TextRules.wordBefore("¿que"), "que")
        XCTAssertEqual(TextRules.wordBefore("«hola"), "hola")
        XCTAssertEqual(TextRules.wordBefore("hola "), "")
        XCTAssertEqual(TextRules.previousWord(in: "hola que tal"), "que")
        XCTAssertEqual(TextRules.lastCompleteWord(in: "hola que "), "que")
    }

    func testNoSeCruzaElFinalDeFrase() {
        // Tras un punto no hay «palabra anterior»: no se aprende «hola que»
        // de «Hola. Que».
        XCTAssertEqual(TextRules.previousWord(in: "Hola. que"), "")
        XCTAssertEqual(TextRules.lastCompleteWord(in: "Hola. "), "")
    }

    func testSoloLetrasSeCorrigenYAprenden() {
        XCTAssertTrue(TextRules.isPlainWord("canción"))
        XCTAssertFalse(TextRules.isPlainWord("juan@gmail"))
        XCTAssertFalse(TextRules.isPlainWord("casa1"))
        XCTAssertFalse(TextRules.isPlainWord(""))
    }

    func testLargoDeLaUltimaPalabra() {
        XCTAssertEqual(TextRules.lastWordLength(in: "hola que  "), 5)
        XCTAssertEqual(TextRules.lastWordLength(in: "hola"), 4)
        XCTAssertEqual(TextRules.lastWordLength(in: "hola\nque"), 3)
    }

    func testCorreccionTardiaRespetaLoEscritoDetras() {
        XCTAssertEqual(TextRules.trailingSeparators(after: "hla", in: "dijo hla "), " ")
        // Doble espacio rápido: el espacio ya es «. » cuando llega la corrección.
        XCTAssertEqual(TextRules.trailingSeparators(after: "hla", in: "dijo hla. "), ". ")
        XCTAssertEqual(TextRules.trailingSeparators(after: "hla", in: "hla?"), "?")
        // Siguió escribiendo o la palabra era parte de otra: no se toca.
        XCTAssertNil(TextRules.trailingSeparators(after: "hla", in: "hla d"))
        XCTAssertNil(TextRules.trailingSeparators(after: "hla", in: "ahla "))
        XCTAssertNil(TextRules.trailingSeparators(after: "hla", in: "hla"))
    }

    func testBusquedaSinTildesNiMayusculas() {
        XCTAssertEqual(TextRules.fold("Canción"), TextRules.fold("cancion"))
        XCTAssertEqual(TextRules.fold("CANCIÓN"), TextRules.fold("canción"))
        XCTAssertTrue(TextRules.fold("Mañana en MADRID").contains(TextRules.fold("madrid")))
    }
}

// MARK: - Aprendizaje de palabras

final class WordLearnerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        WordLearner.clear()
    }

    override func tearDown() {
        WordLearner.clear()
        super.tearDown()
    }

    func testUnaErrataNoSeDaPorBuenaHastaQueSeRepite() {
        WordLearner.learn("hopla")
        XCTAssertFalse(WordLearner.isKnown("hopla"), "un solo uso puede ser una errata")
        XCTAssertTrue(WordLearner.matches(prefix: "hop", limit: 3).isEmpty)

        WordLearner.learn("hopla")
        XCTAssertTrue(WordLearner.isKnown("hopla"))
        XCTAssertEqual(WordLearner.matches(prefix: "hop", limit: 3), ["hopla"])
    }

    func testCorreccionDeshechaNoSeRepite() {
        WordLearner.protect("Mordor")
        XCTAssertTrue(WordLearner.isKnown("mordor"))
        // Tampoco pasa a proponerse al escribir.
        XCTAssertTrue(WordLearner.matches(prefix: "mor", limit: 3).isEmpty)
    }
}

// MARK: - Vocabulario de deslizamiento

final class SwipeLexiconTests: XCTestCase {

    func testLaInstantaneaEsCoherente() {
        let lexicon = SwipeLexicon.shared
        lexicon.invalidate()
        XCTAssertNil(lexicon.snapshot)
        lexicon.load()
        guard let snapshot = lexicon.snapshot else {
            return XCTFail("debía cargarse al menos el vocabulario de uso diario")
        }
        XCTAssertGreaterThan(snapshot.count, 50)
        XCTAssertEqual(snapshot.lens.count, snapshot.count)
        XCTAssertEqual(snapshot.starts.count, snapshot.count)
        XCTAssertEqual(snapshot.masks.count, snapshot.count)
        XCTAssertEqual(snapshot.priors.count, snapshot.count)
        XCTAssertEqual(snapshot.flat.count, snapshot.lens.reduce(0) { $0 + Int($1) })
    }
}

// MARK: - Temas del teclado

final class KeyboardThemeTests: XCTestCase {

    func testLosIdsNoSeRepiten() {
        let ids = KeyboardTheme.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testPorDefectoEsElClasico() {
        XCTAssertEqual(KeyboardTheme.defaultID, "classic")
        XCTAssertEqual(KeyboardTheme.named(KeyboardTheme.defaultID).name, "Clásico")
    }

    func testUnTemaQueYaNoExisteVuelveAlClasico() {
        XCTAssertEqual(KeyboardTheme.named("tema-borrado").id, KeyboardTheme.defaultID)
    }

    func testCadaFamiliaTieneTemas() {
        for family in KeyboardTheme.Family.allCases {
            XCTAssertFalse(KeyboardTheme.all.filter { $0.family == family }.isEmpty, family.rawValue)
        }
    }

    func testLosTemasDeAparienciaFijaNoCambianConElModo() {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        for theme in KeyboardTheme.all where theme.appearance != .system {
            XCTAssertEqual(theme.letter.resolvedColor(with: light), theme.letter.resolvedColor(with: dark), theme.name)
            XCTAssertEqual(theme.text.resolvedColor(with: light), theme.text.resolvedColor(with: dark), theme.name)
        }
    }
}

// MARK: - Búsqueda de emojis

final class EmojiSearchTests: XCTestCase {

    private let index = EmojiSearchIndex(data: """
        😺\tgato sonriendo\tcara sonrisa
        🐱\tcara de gato\tanimal mascota
        🐈\tgato\tanimal mascota
        ❤️\tcorazon rojo\tamor emocion
        😍\tcara sonriendo con ojos de corazon\tamor sonrisa
        ☀️\tsol\tbrillante rayos soleado
        🧴\tbote de crema\tprotector solar
        🎂\ttarta de cumpleanos|pastel de cumpleanos\tcelebracion dulce
        🌷\ttulipan\tflor planta
        """)

    func testPrimeroElQueSeLlamaAsi() {
        XCTAssertEqual(index.search("gato"), ["🐈", "😺", "🐱"])
    }

    func testSinTildesNiMayusculas() {
        XCTAssertEqual(index.search("CORAZÓN").first, "❤️")
    }

    func testPalabrasAMedioEscribir() {
        XCTAssertEqual(Set(index.search("gat")), ["😺", "🐱", "🐈"])
        XCTAssertEqual(index.search("corazon roj"), ["❤️"])
    }

    func testLasPalabrasVaciasNoHacenFalta() {
        XCTAssertEqual(index.search("cara de gato").first, "🐱")
        XCTAssertEqual(index.search("cara gato"), ["🐱", "😺"])
    }

    func testLaPalabraExactaVaAntesQueLaQueEmpiezaIgual() {
        XCTAssertEqual(index.search("sol"), ["☀️", "🧴"])
    }

    func testPluralesYVariantesDelEspanol() {
        XCTAssertEqual(index.search("flores"), ["🌷"])
        XCTAssertEqual(index.search("gatos").first, "🐈")
        XCTAssertEqual(index.search("pastel"), ["🎂"])
    }

    func testSinResultadosYConsultaVacia() {
        XCTAssertTrue(index.search("xyz").isEmpty)
        XCTAssertTrue(index.search("   ").isEmpty)
    }

    func testLaEñeEsOtraLetra() {
        let words = EmojiSearchIndex(data: "🐒\tmono\n🎀\tlazo|moño")
        XCTAssertEqual(words.search("mono"), ["🐒"])
        XCTAssertEqual(words.search("MOÑO"), ["🎀"])
    }

    func testLoQueNoSeSabeDibujarNoSale() {
        let filtered = EmojiSearchIndex(data: "🐈\tgato\n😺\tgato sonriendo", excluding: ["🐈"])
        XCTAssertEqual(filtered.search("gato"), ["😺"])
    }
}

// MARK: - Cuándo leer el portapapeles

final class PasteboardWatchTests: XCTestCase {

    private let plainText = ["public.utf8-plain-text"]
    private var plainSignature: String { PasteboardWatch.signature(itemCount: 1, types: plainText) }

    func testNadaSiNoCambioElContador() {
        let last = PasteboardMark(count: 10, signature: plainSignature, contentHash: nil)
        XCTAssertEqual(PasteboardWatch.classify(count: 10, itemCount: 1, types: plainText, last: last), .none)
    }

    func testContadorQueSubeConLosMismosTiposEsDudoso() {
        // iOS sube el contador dos veces cuando un campo de texto toma el foco.
        let last = PasteboardMark(count: 10, signature: plainSignature, contentHash: "x")
        XCTAssertEqual(PasteboardWatch.classify(count: 12, itemCount: 1, types: plainText, last: last), .sameKind)
    }

    func testOtrosTiposSonAlgoNuevo() {
        let last = PasteboardMark(count: 10, signature: plainSignature, contentHash: "x")
        XCTAssertEqual(PasteboardWatch.classify(count: 11, itemCount: 1,
                                                types: ["public.url", "public.utf8-plain-text"], last: last), .newKind)
        XCTAssertEqual(PasteboardWatch.classify(count: 11, itemCount: 2, types: plainText, last: last), .newKind)
        // Sin nada anterior, o guardado por una versión que no anotaba tipos.
        XCTAssertEqual(PasteboardWatch.classify(count: 1, itemCount: 1, types: ["public.png"], last: nil), .newKind)
        let legacy = PasteboardMark(count: 10, signature: "", contentHash: nil)
        XCTAssertEqual(PasteboardWatch.classify(count: 11, itemCount: 1, types: plainText, last: legacy), .newKind)
    }

    func testLoCopiadoPorClipDeckNoSeVuelveALeer() {
        let last = PasteboardMark(count: 10, signature: plainSignature, contentHash: nil)
        let types = plainText + [PasteboardWatch.ownType]
        XCTAssertEqual(PasteboardWatch.classify(count: 14, itemCount: 1, types: types, last: last), .own)
        XCTAssertFalse(PasteboardWatch.shouldAutoRead(.own, askMode: false))
    }

    func testElCambioDeCampoNoEsUnaCopia() {
        let seen = PasteboardSighting(count: 10, signature: plainSignature)
        // iOS sube el contador de dos en dos al tomar el foco un campo.
        XCTAssertFalse(PasteboardWatch.contentMayHaveChanged(
            from: seen, to: PasteboardSighting(count: 12, signature: plainSignature)))
        XCTAssertFalse(PasteboardWatch.contentMayHaveChanged(
            from: seen, to: PasteboardSighting(count: 14, signature: plainSignature)))
        XCTAssertFalse(PasteboardWatch.contentMayHaveChanged(from: seen, to: seen))
    }

    func testUnaCopiaSeNotaAunqueTengaLosMismosTipos() {
        let seen = PasteboardSighting(count: 10, signature: plainSignature)
        XCTAssertTrue(PasteboardWatch.contentMayHaveChanged(
            from: seen, to: PasteboardSighting(count: 11, signature: plainSignature)))
        // Copia y cambio de campo antes de mirar.
        XCTAssertTrue(PasteboardWatch.contentMayHaveChanged(
            from: seen, to: PasteboardSighting(count: 13, signature: plainSignature)))
        // Otros tipos, o el contador empezó de cero (reinicio).
        let image = PasteboardWatch.signature(itemCount: 1, types: ["public.png"])
        XCTAssertTrue(PasteboardWatch.contentMayHaveChanged(
            from: seen, to: PasteboardSighting(count: 12, signature: image)))
        XCTAssertTrue(PasteboardWatch.contentMayHaveChanged(
            from: seen, to: PasteboardSighting(count: 2, signature: plainSignature)))
        XCTAssertTrue(PasteboardWatch.contentMayHaveChanged(
            from: nil, to: PasteboardSighting(count: 2, signature: plainSignature)))
    }

    func testElOrdenDeLosTiposNoImporta() {
        XCTAssertEqual(PasteboardWatch.signature(itemCount: 1, types: ["b", "a"]),
                       PasteboardWatch.signature(itemCount: 1, types: ["a", "b"]))
    }

    func testSiIOSPreguntaSoloSeLeeAPedido() {
        XCTAssertTrue(PasteboardWatch.shouldAutoRead(.sameKind, askMode: false))
        XCTAssertTrue(PasteboardWatch.shouldAutoRead(.newKind, askMode: false))
        XCTAssertFalse(PasteboardWatch.shouldAutoRead(.sameKind, askMode: true))
        XCTAssertFalse(PasteboardWatch.shouldAutoRead(.newKind, askMode: true))
        XCTAssertFalse(PasteboardWatch.shouldAutoRead(.none, askMode: false))
    }

    func testSeDeduceSiIOSPregunta() {
        XCTAssertEqual(PasteboardWatch.promptEvidence(denied: true, seconds: 0, isText: false, isRemote: false), true)
        XCTAssertEqual(PasteboardWatch.promptEvidence(denied: false, seconds: 1.4, isText: true, isRemote: false), true)
        XCTAssertEqual(PasteboardWatch.promptEvidence(denied: false, seconds: 0.01, isText: true, isRemote: false), false)
        // Las imágenes y el portapapeles universal tardan por sí mismos.
        XCTAssertNil(PasteboardWatch.promptEvidence(denied: false, seconds: 2, isText: false, isRemote: false))
        XCTAssertNil(PasteboardWatch.promptEvidence(denied: false, seconds: 2, isText: true, isRemote: true))
        XCTAssertNil(PasteboardWatch.promptEvidence(denied: false, seconds: 0.3, isText: true, isRemote: false))
    }
}

// MARK: - Relecturas del portapapeles

@MainActor
final class CaptureIngestTests: XCTestCase {

    /// Base vacía y sin nada anotado del portapapeles.
    private func makeContext() throws -> ModelContext {
        PasteboardWatch.lastMark = nil
        PasteboardWatch.askMode = false
        let config = ModelConfiguration(schema: ClipStore.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ClipStore.schema, configurations: [config])
        return ModelContext(container)
    }

    private func reading(_ content: PasteboardWatch.Content, count: Int,
                         seconds: TimeInterval = 0.01) -> PasteboardWatch.Reading {
        PasteboardWatch.Reading(content: content, count: count,
                                signature: PasteboardWatch.signature(itemCount: 1, types: ["public.utf8-plain-text"]),
                                seconds: seconds, isRemote: false)
    }

    func testReleerLoMismoNoLoSubeNiLoDuplica() throws {
        let context = try makeContext()
        guard case .saved(let item) = CaptureService.ingest(reading(.text("hola mundo"), count: 1),
                                                            context: context, lightweight: true) else {
            return XCTFail("la primera lectura debía guardarse")
        }
        let before = Date(timeIntervalSince1970: 1_000)
        item.createdAt = before
        try context.save()

        // iOS subió el contador sin que se copiara nada.
        guard case .unchanged = CaptureService.ingest(reading(.text("hola mundo"), count: 3),
                                                      context: context, lightweight: true) else {
            return XCTFail("lo mismo de antes no debía tocarse")
        }
        XCTAssertEqual(item.createdAt, before)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ClipItem>()), 1)
    }

    func testPegarAPedidoGuardaAunqueSeaLoMismo() throws {
        let context = try makeContext()
        CaptureService.ingest(reading(.text("hola mundo"), count: 1), context: context, lightweight: true)
        guard case .duplicate = CaptureService.ingest(reading(.text("hola mundo"), count: 1), context: context,
                                                      lightweight: true, userInitiated: true) else {
            return XCTFail("al pedirlo el usuario debía encontrar lo ya guardado")
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ClipItem>()), 1)
    }

    func testUnaLecturaLentaIndicaQueIOSPregunta() throws {
        let context = try makeContext()
        CaptureService.ingest(reading(.text("algo"), count: 1, seconds: 1.2), context: context, lightweight: true)
        XCTAssertTrue(PasteboardWatch.askMode)
        CaptureService.ingest(reading(.text("otra cosa"), count: 2), context: context, lightweight: true)
        XCTAssertFalse(PasteboardWatch.askMode)
    }

    func testSiNoDejaLeerSeRecuerdaLoAnterior() throws {
        let context = try makeContext()
        CaptureService.ingest(reading(.text("hola mundo"), count: 1), context: context, lightweight: true)
        guard case .denied = CaptureService.ingest(reading(.denied, count: 4, seconds: 0.8),
                                                   context: context, lightweight: true) else {
            return XCTFail("una lectura denegada debía notarse")
        }
        XCTAssertTrue(PasteboardWatch.askMode)
        XCTAssertEqual(PasteboardWatch.lastMark?.count, 4)
        XCTAssertEqual(PasteboardWatch.lastMark?.contentHash, HashService.sha256("hola mundo"))
    }
}
