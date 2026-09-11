#if canImport(XCTest)
import XCTest
@testable import EchoRename

final class TitleGeneratorTests: XCTestCase {
    func testMakesASafeDescriptiveFilename() {
        let result = TitleGenerator.filename(
            from: "Hola, hoy hablamos del presupuesto para la fiesta de cumpleaños de Maria.",
            preservingExtension: "MOV",
            fallback: "IMG_1024"
        )

        XCTAssertEqual(result, "hoy-hablamos-presupuesto-fiesta-cumpleaños-maria.mov")
    }

    func testUsesTheOriginalNameWhenNoSpeechIsAvailable() {
        let result = TitleGenerator.filename(from: "", preservingExtension: "mp4", fallback: "IMG_1024")
        XCTAssertEqual(result, "IMG_1024.mp4")
    }

    func testRemovesSpanishFillersWithoutChangingSubjectWords() {
        let result = TitleGenerator.filename(
            from: "Preparando parapente para mañana en la montaña.",
            preservingExtension: "MP4",
            fallback: "IMG_1024"
        )

        XCTAssertEqual(result, "preparando-parapente-mañana-montaña.mp4")
    }

    func testLocalizedNamesPreserveNaturalSpanishAndAccents() {
        XCTAssertEqual(TitleGenerator.localizedFilename(from: "Un cumpleaños en la montaña", preservingExtension: "MOV", fallback: "unnamed"),
                       "Un cumpleaños en la montaña.mov")
    }

    func testLocalizedNamesPreserveChineseCharacters() {
        XCTAssertEqual(TitleGenerator.localizedFilename(from: "海边的午后", preservingExtension: "mp4", fallback: "unnamed"), "海边的午后.mp4")
    }

    func testLocalizedNamesRemoveUnsafeCharactersAndDuplicateExtension() {
        XCTAssertEqual(TitleGenerator.localizedFilename(from: "../Una tarde: en / casa.MP4", preservingExtension: "mp4", fallback: "unnamed"),
                       "Una tarde en casa.mp4")
        XCTAssertEqual(TitleGenerator.localizedFilename(from: " : / ", preservingExtension: "mp4", fallback: "unnamed"), "unnamed.mp4")
    }

    func testLocalizedNamesNormalizeUnicodeAndLimitBytesNotCharacters() {
        XCTAssertEqual(TitleGenerator.localizedFilename(from: "Cafe\u{301} en casa", preservingExtension: "mp4", fallback: "unnamed"), "Café en casa.mp4")
        let result = TitleGenerator.localizedFilename(from: String(repeating: "山间的风景", count: 30), preservingExtension: "mp4", fallback: "unnamed")
        XCTAssertLessThanOrEqual(result.utf8.count, 180)
        XCTAssertTrue(result.hasSuffix(".mp4"))
        XCTAssertFalse(result.contains("�"))
    }

    func testAutomaticChineseNamesStayWithinTheFilenameByteLimit() {
        let transcript = String(repeating: "今天我们一起调整自行车刹车", count: 30)
        let result = TitleGenerator.filename(from: transcript, preservingExtension: "MOV", fallback: "original")
        XCTAssertLessThanOrEqual(result.utf8.count, 180)
        XCTAssertTrue(result.hasSuffix(".mov"))
        XCTAssertTrue(result.hasPrefix("今天我们一起调整自行车刹车"))
        XCTAssertFalse(result.contains("�"))
    }

    func testChineseSpeechDoesNotRequireSpaces() {
        XCTAssertTrue(SpeechNamingPolicy.hasUsefulSpeech("今天我们一起去海边看日落，远处有几艘小船。"))
        XCTAssertFalse(SpeechNamingPolicy.hasUsefulSpeech("[音乐]"))
        XCTAssertFalse(SpeechNamingPolicy.hasUsefulSpeech("感谢观看，记得点赞订阅。"))
    }

    func testChineseSignoffsDoNotHideTheSubstantiveTopic() {
        for transcript in [
            "今天我们调整自行车刹车，谢谢观看。",
            "感谢观看，今天我们调整自行车刹车，记得点赞订阅。",
            "今天我們調整自行車煞車，感謝觀看，記得點讚訂閱。",
            "今天我们调整自行车刹车。" + String(repeating: "感谢观看，记得点赞订阅。", count: 5),
        ] {
            XCTAssertTrue(SpeechNamingPolicy.hasUsefulSpeech(transcript), transcript)
        }
    }

    func testChineseSignoffsAndFillersAloneRemainNoise() {
        for transcript in [
            "感谢大家的观看，记得点赞订阅，我们下期再见。",
            "感謝大家的觀看，記得點讚訂閱，我們下期再見。",
            String(repeating: "感谢观看，记得点赞订阅。", count: 5),
            "请 记得 点赞 和 订阅 我们。",
            "嗯，呃，啊，哦，唔。嗯，呃，啊，哦，唔。",
        ] {
            XCTAssertFalse(SpeechNamingPolicy.hasUsefulSpeech(transcript), transcript)
        }
    }

    func testChineseSignoffDoesNotPreventUsefulEnglishOrSpanishSpeech() {
        XCTAssertTrue(SpeechNamingPolicy.hasUsefulSpeech("Today we adjust the bicycle brake. 感谢观看。"))
        XCTAssertTrue(SpeechNamingPolicy.hasUsefulSpeech("Hoy ajustamos los frenos de la bicicleta. 谢谢观看。"))
    }

    func testNamingLocalesHaveExplicitWorkerCodes() {
        XCTAssertEqual(NamingLanguage.chineseSimplified.workerCode, "zh-Hans")
        XCTAssertEqual(NamingLanguage.spanish.workerCode, "es-419")
        XCTAssertEqual(NamingLanguage.original.workerCode, "en")
    }
}
#endif
