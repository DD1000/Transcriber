import Foundation
import Metal

let output = URL(fileURLWithPath: CommandLine.arguments[1])
var report: [String: Any] = ["status": "unavailable", "operationExecuted": false]
do {
    guard let device = MTLCreateSystemDefaultDevice() else { throw NSError(domain: "ClipName", code: 1, userInfo: [NSLocalizedDescriptionKey: "No Metal device exposed by this runner"] ) }
    report["deviceName"] = device.name
    report["recommendedMaxWorkingSetBytes"] = device.recommendedMaxWorkingSetSize
    let source = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void double_values(device float *a [[buffer(0)]], uint id [[thread_position_in_grid]]) { a[id] *= 2.0; }
    """
    let library = try device.makeLibrary(source: source, options: nil)
    let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "double_values")!)
    guard let buffer = device.makeBuffer(length: 16 * MemoryLayout<Float>.stride, options: .storageModeShared),
          let queue = device.makeCommandQueue(), let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
        throw NSError(domain: "ClipName", code: 2)
    }
    let values = buffer.contents().bindMemory(to: Float.self, capacity: 16)
    for i in 0..<16 { values[i] = Float(i) }
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(buffer, offset: 0, index: 0)
    encoder.dispatchThreads(MTLSize(width: 16, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 1, depth: 1))
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    guard command.status == .completed, (0..<16).allSatisfy({ values[$0] == Float($0 * 2) }) else {
        throw command.error ?? NSError(domain: "ClipName", code: 3)
    }
    report["status"] = "completed"
    report["operationExecuted"] = true
} catch {
    if (error as NSError).domain != "ClipName" || (error as NSError).code != 1 {
        report["status"] = "failed"
    }
    report["error"] = error.localizedDescription
}
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
print(String(data: try JSONSerialization.data(withJSONObject: report), encoding: .utf8)!)
exit(report["status"] as? String == "failed" ? 1 : 0)
