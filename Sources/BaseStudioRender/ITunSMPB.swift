import Foundation

/// Carries the AAC encoder-delay tag (`iTunSMPB`) from an AVAssetWriter .m4a
/// into a finished .mp4. Apple decoders trim the 2112 priming samples either
/// way; ffmpeg only does when this tag (or an edit list it understands) is
/// present. Writing an edit list instead makes Apple trim twice (-45 ms), so
/// the tag is the one form both read the same.
///
/// File I/O is bounded: only box headers and the `moov` box (sample tables,
/// not media) are read; the tag is appended in place and the size fields are
/// patched. A long take never loads its media into memory or gets rewritten.
enum ITunSMPB {
    enum Failure: Error, Equatable {
        case noTag
        case moovNotLast
        case udtaNotLastChild
        case malformed(String)
    }

    /// Tag `mp4` with the encoder delay from `m4a`, with the valid-sample
    /// count set to `validSamples`. Throws instead of shipping an untagged file.
    static func copy(from m4a: URL, into mp4: URL, validSamples: Int64?) throws {
        // Source: read just its moov, take moov/udta (meta/ilst/----:iTunSMPB).
        let src = try FileHandle(forReadingFrom: m4a)
        defer { try? src.close() }
        guard let srcMoov = try topLevelBox("moov", in: src) else { throw Failure.noTag }
        let srcMoovData = try read(src, at: srcMoov.offset, count: srcMoov.size)
        guard let udta = box("udta", in: srcMoovData, range: srcMoov.header..<srcMoovData.count) else {
            throw Failure.noTag
        }
        var tagUdta = srcMoovData.subdata(in: udta)
        guard let key = tagUdta.range(of: Data("iTunSMPB".utf8)) else { throw Failure.noTag }
        if let validSamples {
            guard let fixed = rewrite(tag: tagUdta, after: key.upperBound, validSamples: validSamples) else {
                throw Failure.malformed("iTunSMPB value")
            }
            tagUdta = fixed
        }

        // Destination: moov must be the last top-level box so appending moves
        // no chunk offsets.
        let dst = try FileHandle(forUpdating: mp4)
        defer { try? dst.close() }
        let end = try dst.seekToEnd()
        guard let moov = try topLevelBox("moov", in: dst) else { throw Failure.malformed("no moov") }
        guard moov.offset + moov.size == Int(end) else { throw Failure.moovNotLast }
        let moovData = try read(dst, at: moov.offset, count: moov.size)

        var appended: Data
        var patches: [(offset: Int, header: Int, newSize: Int)] = []
        if let existing = box("udta", in: moovData, range: moov.header..<moovData.count) {
            let existingData = moovData.subdata(in: existing)
            if existingData.range(of: Data("iTunSMPB".utf8)) != nil { return } // already tagged
            // Merge: our udta's children go at the end of the existing udta,
            // which is only possible without moving anything if it is moov's
            // last child.
            guard existing.upperBound == moovData.count else { throw Failure.udtaNotLastChild }
            let udtaHeader = headerSize(tagUdta, at: 0)
            appended = tagUdta.subdata(in: udtaHeader..<tagUdta.count)
            let existingHeader = headerSize(moovData, at: existing.lowerBound)
            patches.append((moov.offset + existing.lowerBound, existingHeader, existing.count + appended.count))
        } else {
            appended = tagUdta
        }
        patches.append((moov.offset, moov.header, moov.size + appended.count))

        // Append first, then fix sizes: if we stop in between, the extra bytes
        // sit after a consistent moov and parsers skip them.
        try dst.seekToEnd()
        try dst.write(contentsOf: appended)
        try dst.synchronize()
        for p in patches {
            try dst.seek(toOffset: UInt64(p.offset))
            if p.header == 16 {
                try dst.write(contentsOf: Data([0, 0, 0, 1]))
                try dst.seek(toOffset: UInt64(p.offset + 8))
                try dst.write(contentsOf: withUnsafeBytes(of: UInt64(p.newSize).bigEndian) { Data($0) })
            } else {
                guard p.newSize <= Int(UInt32.max) else { throw Failure.malformed("box too large for 32-bit size") }
                try dst.write(contentsOf: withUnsafeBytes(of: UInt32(p.newSize).bigEndian) { Data($0) })
            }
        }
        try dst.synchronize()
    }

    /// The tag value is " delay padding length ..." in hex; replace the
    /// 16-digit length so ffmpeg does not trim to the pre-mux length.
    static func rewrite(tag: Data, after offset: Int, validSamples: Int64) -> Data? {
        guard let text = String(data: tag.subdata(in: offset..<tag.count), encoding: .ascii),
              let start = text.range(of: " 00000000 ") else { return nil }
        let fields = text[start.lowerBound...].split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 4, fields[3].count == 16,
              let r = tag.range(of: Data(fields[3].utf8), in: offset..<tag.count) else { return nil }
        var out = tag
        out.replaceSubrange(r, with: Data(String(format: "%016llX", validSamples).utf8))
        return out
    }

    // MARK: - box walking

    struct TopBox { var offset: Int; var size: Int; var header: Int }

    /// Walk top-level box headers only (16 bytes per box), never the payloads.
    static func topLevelBox(_ type: String, in fh: FileHandle) throws -> TopBox? {
        let end = Int(try fh.seekToEnd())
        var o = 0
        while o + 8 <= end {
            let h = try read(fh, at: o, count: min(16, end - o))
            var size = Int(h[0]) << 24 | Int(h[1]) << 16 | Int(h[2]) << 8 | Int(h[3])
            var header = 8
            if size == 1 {
                guard h.count >= 16 else { throw Failure.malformed("short largesize header") }
                size = h[8..<16].reduce(0) { $0 << 8 | Int($1) }
                header = 16
            } else if size == 0 {
                size = end - o
            }
            guard size >= header, o + size <= end else { throw Failure.malformed("box at \(o)") }
            if String(data: h[4..<8], encoding: .ascii) == type { return TopBox(offset: o, size: size, header: header) }
            o += size
        }
        return nil
    }

    static func read(_ fh: FileHandle, at offset: Int, count: Int) throws -> Data {
        try fh.seek(toOffset: UInt64(offset))
        guard let d = try fh.read(upToCount: count), d.count == count else {
            throw Failure.malformed("short read at \(offset)")
        }
        return d
    }

    static func headerSize(_ d: Data, at o: Int) -> Int {
        let s = d.startIndex + o
        return (Int(d[s]) << 24 | Int(d[s + 1]) << 16 | Int(d[s + 2]) << 8 | Int(d[s + 3])) == 1 ? 16 : 8
    }

    /// Byte range of the first box of `type` directly inside `range` of `d`.
    static func box(_ type: String, in d: Data, range: Range<Int>) -> Range<Int>? {
        var o = range.lowerBound
        let b = d.startIndex
        while o + 8 <= range.upperBound {
            var size = Int(d[b + o]) << 24 | Int(d[b + o + 1]) << 16 | Int(d[b + o + 2]) << 8 | Int(d[b + o + 3])
            if size == 1, o + 16 <= range.upperBound {
                size = d[(b + o + 8)..<(b + o + 16)].reduce(0) { $0 << 8 | Int($1) }
            } else if size == 0 {
                size = range.upperBound - o
            }
            guard size >= 8, o + size <= range.upperBound else { return nil }
            if String(data: d[(b + o + 4)..<(b + o + 8)], encoding: .ascii) == type { return o..<(o + size) }
            o += size
        }
        return nil
    }
}
