import Foundation

@main
struct SceneSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("Pass a test video path")
        }
        let result = try await LocalSceneNamer().describe(videoAt: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("Scene title: \(result.title)")
        print("Description: \(result.description)")
        print("Filename: \(TitleGenerator.filename(from: result.title, preservingExtension: "mp4", fallback: "original"))")
    }
}
