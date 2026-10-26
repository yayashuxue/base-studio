import XCTest
@testable import BaseStudioRender

/// Box surgery for the AAC priming tag, on hand-built files: bounded in-place
/// append, size patching, merging into an existing udta, and loud failures.
final class ITunSMPBTests: XCTestCase {

    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("smpb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: builders
    private func box(_ type: String, _ payload: Data) -> Data {
        var d = withUnsafeBytes(of: UInt32(8 + payload.count).bigEndian) { Data($0) }
        d.append(Data(type.utf8)); d.append(payload); return d
    }
    private let smpbValue = " 00000000 00000840 000003C0 000000000002F000 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000"
    private func tagUdta() -> Data {
        let free = box("----", Data("mean".utf8) + Data("com.apple.iTunes".utf8) + Data("iTunSMPB".utf8) + Data(smpbValue.utf8))
        return box("udta", box("meta", Data([0, 0, 0, 0]) + box("ilst", free)))
    }
    private func write(_ d: Data, _ name: String) throws -> URL {
        let u = dir.appendingPathComponent(name); try d.write(to: u); return u
    }
    private func m4a() throws -> URL { try write(box("ftyp", Data("M4A ".utf8)) + box("moov", box("mvhd", Data(count: 20)) + tagUdta()), "a.m4a") }
    private let mdat = Data((0..<4096).map { UInt8($0 & 0xff) })
    private func mp4(moovChildren: Data, moovLast: Bool = true) throws -> URL {
        let moov = box("moov", box("mvhd", Data(count: 20)) + moovChildren)
        let body = moovLast ? box("mdat", mdat) + moov : moov + box("mdat", mdat)
        return try write(box("ftyp", Data("isom".utf8)) + body, "v.mp4")
    }

    // MARK: tests
    func testAppendsTagInPlaceAndPatchesMoovSize() throws {
        let src = try m4a(), dst = try mp4(moovChildren: box("trak", Data(count: 12)))
        let before = try Data(contentsOf: dst)
        try ITunSMPB.copy(from: src, into: dst, validSamples: 0x1234)
        let after = try Data(contentsOf: dst)
        XCTAssertEqual(after.count, before.count + tagUdta().count)
        let moovStart = ITunSMPB.box("moov", in: before, range: 0..<before.count)!.lowerBound
        XCTAssertEqual(after.prefix(moovStart), before.prefix(moovStart), "everything before moov (incl. media) is untouched")
        let moov = ITunSMPB.box("moov", in: after, range: 0..<after.count)!
        XCTAssertEqual(moov.upperBound, after.count, "moov size covers the appended tag")
        XCTAssertNotNil(ITunSMPB.box("udta", in: after, range: (moov.lowerBound + 8)..<moov.upperBound))
        XCTAssertNotNil(after.range(of: Data("0000000000001234".utf8)), "valid-sample count rewritten")
    }

    func testAlreadyTaggedIsLeftAlone() throws {
        let src = try m4a(), dst = try mp4(moovChildren: tagUdta())
        let before = try Data(contentsOf: dst)
        try ITunSMPB.copy(from: src, into: dst, validSamples: nil)
        XCTAssertEqual(try Data(contentsOf: dst), before)
    }

    func testMergesIntoExistingUdtaWhenItIsMoovsLastChild() throws {
        let other = box("udta", box("name", Data("x".utf8)))
        let src = try m4a(), dst = try mp4(moovChildren: box("trak", Data(count: 12)) + other)
        try ITunSMPB.copy(from: src, into: dst, validSamples: nil)
        let after = try Data(contentsOf: dst)
        let moov = ITunSMPB.box("moov", in: after, range: 0..<after.count)!
        XCTAssertEqual(moov.upperBound, after.count)
        let udta = ITunSMPB.box("udta", in: after, range: (moov.lowerBound + 8)..<moov.upperBound)!
        XCTAssertEqual(udta.upperBound, moov.upperBound, "existing udta grew to the end of moov")
        let inner = after.subdata(in: udta)
        XCTAssertNotNil(inner.range(of: Data("name".utf8)), "existing child kept")
        XCTAssertNotNil(inner.range(of: Data("iTunSMPB".utf8)), "tag merged in")
    }

    func testFailsWhenExistingUdtaIsNotLastChild() throws {
        let src = try m4a()
        let dst = try mp4(moovChildren: box("udta", box("name", Data("x".utf8))) + box("trak", Data(count: 12)))
        XCTAssertThrowsError(try ITunSMPB.copy(from: src, into: dst, validSamples: nil)) {
            XCTAssertEqual($0 as? ITunSMPB.Failure, .udtaNotLastChild)
        }
    }

    func testFailsWhenMoovIsNotLast() throws {
        let src = try m4a(), dst = try mp4(moovChildren: box("trak", Data(count: 12)), moovLast: false)
        XCTAssertThrowsError(try ITunSMPB.copy(from: src, into: dst, validSamples: nil)) {
            XCTAssertEqual($0 as? ITunSMPB.Failure, .moovNotLast)
        }
    }

    func testFailsWhenSourceHasNoTag() throws {
        let src = try write(box("ftyp", Data("M4A ".utf8)) + box("moov", box("mvhd", Data(count: 20))), "plain.m4a")
        let dst = try mp4(moovChildren: box("trak", Data(count: 12)))
        XCTAssertThrowsError(try ITunSMPB.copy(from: src, into: dst, validSamples: nil)) {
            XCTAssertEqual($0 as? ITunSMPB.Failure, .noTag)
        }
    }
}
