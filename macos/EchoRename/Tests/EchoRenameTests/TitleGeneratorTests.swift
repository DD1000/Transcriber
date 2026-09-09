#if canImport(XCTest)
import XCTest
@testable import EchoRename

final class TitleGeneratorTests: XCTestCase {
    func testMakesASafeDescriptiveFilename() {
        let result = TitleGenerator.filename(
            from: "Hola, hoy hablamos del presupuesto para la fiesta de cumpleaños de Maria.",
            preservingExtension: "MOV",
            fallback: "IMG_1024",
        )

        XCTAssertEqual(result, "hoy-hablamos-presupuesto-fiesta-cumpleaños-maria.mov")
    }

    func testUsesTheOriginalNameWhenNoSpeechIsAvailable() {
        let result = TitleGenerator.filename(from: "", preservingExtension: "mp4", fallback: "IMG_1024")
        XCTAssertEqual(result, "IMG_1024.mp4")
    }
}
#endif
