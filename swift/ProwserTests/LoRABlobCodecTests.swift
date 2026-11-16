import Foundation
import LoRABlobCodec
import XCTest

final class LoRABlobCodecTests: XCTestCase {
    func testRoundTrip() throws {
        let json = Data(#"{"user_entries":{"user_test":{"lora_id":"user_test"}}}"#.utf8)
        let password = "test-password"
        let blob = try LoRABlobCodec.encrypt(jsonUTF8: json, password: password)
        let opened = try LoRABlobCodec.decrypt(blob: blob, password: password)
        XCTAssertEqual(opened, json)
    }

    func testDeterministicTestVectors() throws {
        let json = Data(#"{"hello":"world"}"#.utf8)
        let salt = Data(repeating: 0x11, count: 16)
        let nonce = Data(repeating: 0x22, count: 12)
        let blob = try LoRABlobCodec.encryptForTesting(
            jsonUTF8: json,
            password: "pw",
            salt: salt,
            nonce: nonce
        )
        let opened = try LoRABlobCodec.decrypt(blob: blob, password: "pw")
        XCTAssertEqual(opened, json)
    }

    func testWrongPasswordFails() throws {
        let json = Data("{}".utf8)
        let blob = try LoRABlobCodec.encrypt(jsonUTF8: json, password: "right")
        XCTAssertThrowsError(try LoRABlobCodec.decrypt(blob: blob, password: "wrong")) { error in
            XCTAssertEqual(error as? LoRABlobCodec.Error, .decryptionFailed)
        }
    }
}