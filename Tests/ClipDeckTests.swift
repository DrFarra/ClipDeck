import XCTest
import SwiftData

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
