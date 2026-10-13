import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// El modelo de contexto con unas frases y un vocabulario pequeños: lo que se
// prueba es cómo decide, no los datos del teclado.

final class ContextModelTests: XCTestCase {

    private let corpus = ContextModel.bigrams(fromCorpus: """
        Hola, ¿cómo estás? Muchas gracias por todo. Buenas noches.
        Hasta mañana. Nos vemos mañana. Muchas gracias.
        I don't know. Thank you so much.
        """)

    private let lexicon = SwipeLexicon.makeSnapshot([
        ("de", 230), ("que", 230), ("más", 183), ("gracias", 210), ("graciosa", 120), ("hola", 220),
        ("cómo", 200), ("como", 225), ("mañana", 190), ("manzana", 120), ("noches", 170),
        ("casa", 200), ("casas", 170), ("cosa", 200), ("todo", 215), ("tiene", 200),
    ])

    private func context(_ previous: String, learned: [String: Int] = [:]) -> ContextModel.Context {
        ContextModel.Context(previous: previous, learned: learned, builtIn: corpus)
    }

    private func next(_ previous: String, learned: [String: Int] = [:]) -> [String] {
        ContextModel.nextWords(context(previous, learned: learned), lexicon: lexicon,
                               common: ["de", "que", "la"], blocked: [])
    }

    private func complete(_ typed: String, after previous: String = "") -> [String] {
        ContextModel.completions(for: typed, touches: [], keyCenters: [:], keySize: .zero,
                                 context: context(previous), lexicon: lexicon)
    }

    func testFrasesDePartida() {
        XCTAssertEqual(corpus.next["hola"]?["cómo"], 1)
        XCTAssertEqual(corpus.next[ContextModel.sentenceStart]?["hola"], 1)
        XCTAssertEqual(corpus.next["don't"]?["know"], 1)     // el apóstrofo se conserva
    }

    func testSiguientePalabra() {
        XCTAssertEqual(next("muchas").first, "gracias")
        XCTAssertEqual(next("buenas").first, "noches")
        XCTAssertEqual(next("Hola").first, "cómo")
        // Sin contexto conocido: las frecuentes de siempre.
        XCTAssertEqual(next("zzz").first, "de")
    }

    func testInicioDeFrase() {
        XCTAssertTrue(next("").contains("hola"))
    }

    func testLoAprendidoPesaMas() {
        XCTAssertEqual(next("muchas", learned: ["besos": 2]).first, "besos")
    }

    func testBonificacionSoloConContexto() {
        let c = context("muchas")
        XCTAssertGreaterThan(c.boost("gracias", prior: 210), 1)
        XCTAssertEqual(c.boost("casa", prior: 200), 0)
    }

    func testCompletaPorFrecuencia() {
        XCTAssertEqual(complete("grac").first, "gracias")
        XCTAssertEqual(complete("cas").first, "casa")
    }

    func testCompletaConLaTeclaVecina() {
        // La «h» está junto a la «g».
        XCTAssertEqual(complete("hrac").first, "gracias")
    }

    func testElContextoElige() {
        // Sola, «com» es «como» (más usada); tras «hola», «cómo».
        XCTAssertEqual(complete("com").first, "como")
        XCTAssertEqual(complete("com", after: "hola").first, "cómo")
        XCTAssertEqual(complete("ma", after: "hasta").first, "mañana")
    }

    func testRespetaLaTildePuesta() {
        XCTAssertEqual(complete("cóm"), ["cómo"])
    }

    func testNoProponeLoMismo() {
        XCTAssertFalse(complete("casa").contains("casa"))
    }
}
