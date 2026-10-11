import Testing
@testable import UltstatCore

@Suite struct SMCValueTests {
    @Test func keyPacking() {
        #expect(SMCKey("CHTE").raw == 0x4348_5445)
        #expect(SMCKey("ui8").description == "ui8 ")
        #expect(SMCKey(raw: 0x4348_5445).description == "CHTE")
    }

    @Test func decodesLittleEndianFloat() {
        let v = SMCValue(info: info(.flt, 4), bytes: [0x00, 0x00, 0x48, 0x42]) // 50.0
        #expect(v.double == 50.0)
    }

    @Test func decodesSignedFixedPoint() {
        #expect(SMCValue(info: info(.sp78, 2), bytes: [0x32, 0x80]).double == 50.5)
        #expect(SMCValue(info: info(.sp78, 2), bytes: [0xFF, 0x00]).double == -1.0)
        #expect(SMCValue(info: info(.fpe2, 2), bytes: [0x17, 0x70]).double == 1500.0)
    }

    /// Byte patterns captured from a real M5 (Mac17,4) on macOS 27.0.1.
    @Test func decodesLittleEndianIntegersFromRealM5() {
        #expect(SMCValue(info: info(.ui16, 2), bytes: [0x0B, 0x00]).double == 11)      // B0CT cycle count
        #expect(SMCValue(info: info(.ui16, 2), bytes: [0x80, 0x16]).double == 5760)    // B0DC design mAh
        #expect(SMCValue(info: info(.si16, 2), bytes: [0x89, 0xFD]).double == -631)    // B0AC current mA
        #expect(SMCValue(info: info(.ui32, 4), bytes: [0x88, 0x13, 0x00, 0x00]).double == 5000)
        #expect(SMCValue(info: info(.si8, 1), bytes: [0xFE]).double == -2)
    }

    @Test func opaqueTypesAreNotNumeric() {
        #expect(SMCValue(info: info(.hex, 1), bytes: [0x08]).double == nil)
        #expect(SMCValue(info: info(.flt, 2), bytes: [0, 0]).double == nil) // wrong size
    }

    private func info(_ t: SMCDataType, _ size: Int) -> SMCKeyInfo {
        SMCKeyInfo(size: size, type: t, attributes: 0)
    }
}
