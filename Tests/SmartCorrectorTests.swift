import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// El autocorrector con un vocabulario pequeño y un «diccionario del sistema»
// de mentira: lo que se prueba es la decisión, no los datos.

final class SmartCorrectorTests: XCTestCase {

    private let lexicon = SwipeLexicon.makeSnapshot([
        ("que", 230), ("como", 225), ("hola", 220), ("bien", 215), ("casa", 200), ("cosa", 200),
        ("tiene", 200), ("vamos", 200), ("hacer", 200), ("cómo", 200), ("también", 190),
        ("estás", 190), ("llamar", 180), ("niño", 170), ("canción", 160), ("silla", 150),
        ("estas", 150), ("mañana", 190), ("gracias", 210),
    ])

    /// Palabras que el «corrector del sistema» da por buenas.
    private let valid: Set<String> = [
        "que", "como", "hola", "bien", "casa", "cosa", "tiene", "vamos", "hacer", "cómo",
        "también", "estás", "llamar", "niño", "canción", "silla", "estas", "mañana", "gracias",
    ]

    private func correct(_ word: String, midSentence: Bool = false, seen: Set<String> = [],
                         spelling: SmartCorrector.Spelling? = nil,
                         known: Set<String> = []) -> String? {
        var input = SmartCorrector.Input(word: word)
        input.midSentence = midSentence
        input.seenWords = seen
        return SmartCorrector.correction(
            input, lexicon: lexicon,
            spelling: { w in
                if let spelling { return spelling }
                if self.valid.contains(w.lowercased()) { return .valid }
                if w.lowercased() == "carlos" { return .properNoun }
                return .unknown
            },
            isKnown: { known.contains($0) },
            successors: { _ in [] })
    }

    func testTeclaVecina() {
        XCTAssertEqual(correct("hols"), "hola")
        XCTAssertEqual(correct("Hols"), "Hola")
    }

    func testRecuperaTildesYEnie() {
        XCTAssertEqual(correct("tambien"), "también")
        XCTAssertEqual(correct("cancion"), "canción")
        XCTAssertEqual(correct("nino"), "niño")
        XCTAssertEqual(correct("manana"), "mañana")
    }

    func testErroresDeEscrituraRapida() {
        XCTAssertEqual(correct("caasa"), "casa")        // la misma tecla dos veces
        XCTAssertEqual(correct("hloa"), "hola")         // dos letras cambiadas
        XCTAssertEqual(correct("lamar"), "llamar")      // la doble que se queda en una
    }

    func testErroresDeOrtografia() {
        XCTAssertEqual(correct("acer"), "hacer")        // la «h» que no suena
        XCTAssertEqual(correct("bamos"), "vamos")       // b/v
    }

    func testPalabrasPegadas() {
        XCTAssertEqual(correct("holaque"), "hola que")
        XCTAssertEqual(correct("holabque"), "hola que") // la «b» en lugar del espacio
        XCTAssertEqual(correct("Holaque"), "Hola que")
    }

    func testNoTocaLoBienEscrito() {
        XCTAssertNil(correct("hola"))
        XCTAssertNil(correct("estas"))
        XCTAssertNil(correct("Gracias"))
    }

    func testRespetaJergaYRisas() {
        for w in ["jaja", "jajaja", "jejeje", "jsjsjs", "xd", "porfa", "finde", "ok"] {
            XCTAssertNil(correct(w), w)
        }
        XCTAssertTrue(SmartCorrector.isChatWord("jajajaj"))
        XCTAssertFalse(SmartCorrector.isChatWord("jose"))
    }

    func testNombrePropioLlevaMayuscula() {
        XCTAssertEqual(correct("carlos"), "Carlos")
    }

    func testNombreAMitadDeFraseNoSeCambia() {
        // «Hols» con mayúscula a mitad de frase: probablemente un nombre.
        XCTAssertNil(correct("Hols", midSentence: true))
        XCTAssertEqual(correct("hols", midSentence: true), "hola")
    }

    func testMayusculaDeMas() {
        XCTAssertEqual(correct("HOla"), "Hola")
        XCTAssertEqual(correct("HOls"), "Hola")
        XCTAssertNil(correct("ONU"))                    // siglas
    }

    func testLoQueElUsuarioYaUsaNoSeCorrige() {
        XCTAssertNil(correct("hols", seen: ["hols"]))   // ya está así en el texto
        XCTAssertNil(correct("hols", known: ["hols"]))  // aprendida o protegida
    }

    func testOtroIdiomaSoloConErrataClarisima() {
        XCTAssertEqual(correct("casq"), "casa")
        XCTAssertNil(correct("casq", spelling: .otherLanguage))
        XCTAssertEqual(correct("tambien", spelling: .otherLanguage), "también")
    }

    func testDondeCayoElDedo() {
        // «cssa» con el primer toque a medio camino entre la «s» y la «a».
        let g = SmartCorrector.Geometry.qwerty
        func key(_ c: Character) -> CGPoint { g[SwipeAlphabet.index(c)!]! }
        var input = SmartCorrector.Input(word: "cssa")
        input.keyCenters = g
        input.keySize = CGSize(width: 1.0001, height: 1)
        let s = key("s"), a = key("a")
        input.touches = [key("c"), CGPoint(x: (s.x + a.x) / 2, y: s.y), s, a]
        let result = SmartCorrector.correction(input, lexicon: lexicon,
                                               spelling: { _ in .unknown },
                                               isKnown: { _ in false }, successors: { _ in [] })
        XCTAssertEqual(result, "casa")
    }

    func testPriorPorFrecuencia() {
        XCTAssertGreaterThan(SwipeLexicon.frequencyPrior(rank: 1, top: 230, floor: 100),
                             SwipeLexicon.frequencyPrior(rank: 1000, top: 230, floor: 100))
        XCTAssertEqual(SwipeLexicon.frequencyPrior(rank: 1_000_000, top: 230, floor: 100), 100)
        XCTAssertEqual(lexicon.lookup(folded: "como")?.word, "como")   // la más usada de las dos
    }
}

final class TextRulesCorrectionTests: XCTestCase {

    func testCorreccionTardiaConLaSiguientePalabraEmpezada() {
        XCTAssertEqual(TextRules.textAfterCorrectable("hla", in: "dijo hla "), " ")
        XCTAssertEqual(TextRules.textAfterCorrectable("hla", in: "dijo hla qu"), " qu")
        XCTAssertNil(TextRules.textAfterCorrectable("hla", in: "dijo hla"))
        XCTAssertNil(TextRules.textAfterCorrectable("hla", in: "ahla qu"))
    }

    func testPalabrasDeUnTexto() {
        XCTAssertEqual(TextRules.words(in: "Hola, ¿qué tal?  bien"), ["Hola", "qué", "tal", "bien"])
    }
}
