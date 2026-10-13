import XCTest

// Correos y números habituales: qué se reconoce, qué nunca se guarda y qué
// se propone. Sólo la lógica pura (sin tocar el almacenamiento compartido).

final class EntryMemoryTests: XCTestCase {

    private func kinds(_ text: String) -> [String] {
        EntryMemory.extract(text).map { "\($0.kind.rawValue):\($0.text)" }
    }

    func testReconoceCorreosYNumeros() {
        XCTAssertEqual(kinds("Escríbeme a Ana.Lopez@gmail.com o llama al +34 612 345 678."),
                       ["email:Ana.Lopez@gmail.com", "number:+34 612 345 678"])
        XCTAssertEqual(kinds("mi DNI es 12345678Z"), [])               // pegado a una letra: no
        XCTAssertEqual(kinds("DNI 12345678"), ["number:12345678"])
    }

    func testNoGuardaLoQueNoDebe() {
        XCTAssertEqual(kinds("tarjeta 4111 1111 1111 1111"), [])        // pasa Luhn: tarjeta
        XCTAssertEqual(kinds("código 1111111"), [])                     // todas iguales
        XCTAssertEqual(kinds("son 123 euros"), [])                      // corto
        XCTAssertEqual(kinds("ana@gmail"), [])                          // correo a medias
    }

    func testCuentaUnUsoYUnifica() {
        var list: [EntryMemory.Entry] = []
        EntryMemory.remember([("ana@gmail.com", .email)], into: &list)
        EntryMemory.remember([("Ana@Gmail.com", .email), ("612 345 678", .number)], into: &list)
        EntryMemory.remember([("612-345-678", .number)], into: &list)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.first { $0.kind == .email }?.uses, 2)
        XCTAssertEqual(list.first { $0.kind == .number }?.text, "612-345-678")   // la forma más reciente
    }

    private let entries: [EntryMemory.Entry] = [
        .init(text: "emilio@gmail.com", kind: .email, uses: 5, last: Date(timeIntervalSince1970: 10)),
        .init(text: "emilio.trabajo@empresa.es", kind: .email, uses: 1, last: Date(timeIntervalSince1970: 20)),
        .init(text: "612 345 678", kind: .number, uses: 3, last: Date(timeIntervalSince1970: 30)),
    ]

    func testEnCampoDeCorreoDesdeLaPrimeraLetra() {
        XCTAssertEqual(EntryMemory.suggestions(for: "", field: .email, in: entries),
                       ["emilio@gmail.com", "emilio.trabajo@empresa.es"])
        XCTAssertEqual(EntryMemory.suggestions(for: "emilio.", field: .email, in: entries),
                       ["emilio.trabajo@empresa.es"])
    }

    func testEnCampoDeTelefonoPorCifras() {
        XCTAssertEqual(EntryMemory.suggestions(for: "612", field: .number, in: entries), ["612 345 678"])
        XCTAssertEqual(EntryMemory.suggestions(for: "", field: .number, in: entries), ["612 345 678"])
    }

    func testEnTextoNormalSoloConArrobaOCifrasYUsoRepetido() {
        XCTAssertEqual(EntryMemory.suggestions(for: "emi", field: nil, in: entries), [])
        XCTAssertEqual(EntryMemory.suggestions(for: "emilio@", field: nil, in: entries), ["emilio@gmail.com"])
        XCTAssertEqual(EntryMemory.suggestions(for: "612", field: nil, in: entries), ["612 345 678"])
        // Usado una sola vez: fuera de su campo no se propone.
        XCTAssertEqual(EntryMemory.suggestions(for: "emilio.trabajo@", field: nil, in: entries), [])
    }

    func testNoProponeLoYaEscrito() {
        XCTAssertEqual(EntryMemory.suggestions(for: "emilio@gmail.com", field: .email, in: entries), [])
    }
}
