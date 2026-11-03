import AVFoundation
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let sem = DispatchSemaphore(value: 0)
Task {
    let asset = AVURLAsset(url: url)
    let track = try! await asset.loadTracks(withMediaType: .audio).first!
    let reader = try! AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
    reader.add(out); reader.startReading()
    var samples: [Float] = []; var firstPTS: Double? = nil
    while let sb = out.copyNextSampleBuffer() {
        if firstPTS == nil { firstPTS = CMSampleBufferGetPresentationTimeStamp(sb).seconds }
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
        var len = 0; var p: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &p)
        p!.withMemoryRebound(to: Float.self, capacity: len/4) { samples.append(contentsOf: UnsafeBufferPointer(start: $0, count: len/4)) }
    }
    let win = 240; var env: [Float] = []
    var i = 0; while i + win < samples.count { var s: Float = 0; for k in i..<(i+win) { s += samples[k]*samples[k] }; env.append((s/Float(win)).squareRoot()); i += win }
    let thr = (env.max() ?? 0) * 0.25; var ticks: [Double] = []; var last = -9.0
    for (j, e) in env.enumerated() { let t = (firstPTS ?? 0) + Double(j*win)/48000; if e > thr && t - last > 1 { ticks.append(t); last = t } }
    print("firstPTS=\(firstPTS ?? -1) ticks=\(ticks.prefix(12).map { String(format: "%.3f", $0) })")
    sem.signal()
}
sem.wait()
