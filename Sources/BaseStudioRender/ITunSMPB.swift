import Foundation

/// Carries the AAC encoder-delay tag (`iTunSMPB`) from an AVAssetWriter .m4a
/// into a finished .mp4. Apple decoders trim the 2112 priming samples either
/// way; ffmpeg only does when this tag (or an edit list it understands) is
/// present. Writing an edit list instead makes Apple trim twice (-45 ms), so
/// the tag is the one form both read the same.
enum ITunSMPB {
    enum Failure: Error { case noTag, moovNotLast, malformed }

    /// Append the source's `moov/udta` (holding the tag) to the destination's
    /// `moov`, rewriting the valid-sample count to `validSamples`. Requires the
    /// destination's moov to be the last top-level box (AVAssetWriter's
    /// default), so no chunk offsets move.
    static func copy(from m4a: URL, into mp4: URL, validSamples: Int64?) throws {
        let src = try Data(contentsOf: m4a)
        guard let moov = box("moov", in: src, range: 0..<src.count),
              let udta = box("udta", in: src, range: (moov.lowerBound + 8)..<moov.upperBound)
        else { throw Failure.noTag }
        var tag = src.subdata(in: udta)
        guard let key = tag.range(of: Data("iTunSMPB".utf8)) else { throw Failure.noTag }
        if let validSamples, let fixed = rewrite(tag: &tag, after: key.upperBound, validSamples: validSamples) {
            tag = fixed
        }

        var dst = try Data(contentsOf: mp4)
        guard let dmoov = box("moov", in: dst, range: 0..<dst.count) else { throw Failure.malformed }
        guard dmoov.upperBound == dst.count else { throw Failure.moovNotLast }
        if box("udta", in: dst, range: (dmoov.lowerBound + 8)..<dmoov.upperBound) != nil {
            return // already tagged / has its own udta — leave it alone
        }
        dst.append(tag)
        let newSize = UInt32(dmoov.count + tag.count)
        dst.replaceSubrange(dmoov.lowerBound..<(dmoov.lowerBound + 4), with: withUnsafeBytes(of: newSize.bigEndian) { Data($0) })
        try dst.write(to: mp4, options: .atomic)
    }

    /// The tag value is " delay padding length ..." in hex; replace the
    /// 16-digit length so ffmpeg does not trim to the pre-mux length.
    private static func rewrite(tag: inout Data, after offset: Int, validSamples: Int64) -> Data? {
        guard let text = String(data: tag.subdata(in: offset..<tag.count), encoding: .ascii),
              let start = text.range(of: " 00000000 ") else { return nil }
        let fields = text[start.lowerBound...].split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 4, fields[3].count == 16 else { return nil }
        let old = String(fields[3])
        let new = String(format: "%016llX", validSamples)
        guard let r = tag.range(of: Data(old.utf8), in: offset..<tag.count) else { return nil }
        var out = tag
        out.replaceSubrange(r, with: Data(new.utf8))
        return out
    }

    /// Byte range of the first box of `type` directly inside `range`.
    static func box(_ type: String, in d: Data, range: Range<Int>) -> Range<Int>? {
        var o = range.lowerBound
        while o + 8 <= range.upperBound {
            var size = Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3])
            if size == 1, o + 16 <= range.upperBound {
                size = d[(o + 8)..<(o + 16)].reduce(0) { $0 << 8 | Int($1) }
            } else if size == 0 {
                size = range.upperBound - o
            }
            guard size >= 8, o + size <= range.upperBound else { return nil }
            if String(data: d[(o + 4)..<(o + 8)], encoding: .ascii) == type { return o..<(o + size) }
            o += size
        }
        return nil
    }
}
