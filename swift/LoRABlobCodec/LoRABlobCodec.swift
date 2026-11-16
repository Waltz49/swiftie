import CommonCrypto
import CryptoKit
import Foundation

/// Password-encrypted LoRA defaults blob (version 1).
///
/// Layout: `LORB` magic, UInt16 version (1), 16-byte salt, 12-byte GCM nonce,
/// AES-GCM ciphertext + 16-byte tag.
public enum LoRABlobCodec {
    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidMagic
        case unsupportedVersion(UInt16)
        case invalidBlobSize
        case keyDerivationFailed
        case decryptionFailed
        case invalidUTF8
        case invalidJSON
    }

    private static let magic = Data("LORB".utf8)
    private static let version: UInt16 = 1
    private static let saltLength = 16
    private static let nonceLength = 12
    private static let tagLength = 16
    private static let pbkdf2Iterations: UInt32 = 100_000
    private static let keyLength = 32
    private static let headerLength = 4 + 2 + saltLength + nonceLength

    /// Encrypt JSON UTF-8 bytes with the given password (random salt + nonce).
    public static func encrypt(jsonUTF8: Data, password: String) throws -> Data {
        let salt = randomBytes(count: saltLength)
        let nonceBytes = randomBytes(count: nonceLength)
        let key = try deriveKey(password: password, salt: salt)
        let nonce = try AES.GCM.Nonce(data: nonceBytes)
        let sealed = try AES.GCM.seal(jsonUTF8, using: key, nonce: nonce)
        guard sealed.tag.count == tagLength else {
            throw Error.decryptionFailed
        }

        var out = Data(capacity: headerLength + sealed.ciphertext.count + tagLength)
        out.append(magic)
        out.append(version.bigEndianBytes)
        out.append(salt)
        out.append(nonceBytes)
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    /// Decrypt a blob and return JSON UTF-8 bytes.
    public static func decrypt(blob: Data, password: String) throws -> Data {
        guard blob.count >= headerLength + tagLength else {
            throw Error.invalidBlobSize
        }
        guard blob.prefix(4) == magic else {
            throw Error.invalidMagic
        }
        let versionRead = UInt16(bigEndian: blob.subdata(in: 4 ..< 6))
        guard versionRead == version else {
            throw Error.unsupportedVersion(versionRead)
        }

        let salt = blob.subdata(in: 6 ..< (6 + saltLength))
        let nonceBytes = blob.subdata(in: (6 + saltLength) ..< headerLength)
        let combinedStart = headerLength
        let ciphertextEnd = blob.count - tagLength
        guard ciphertextEnd >= combinedStart else {
            throw Error.invalidBlobSize
        }
        let ciphertext = blob.subdata(in: combinedStart ..< ciphertextEnd)
        let tag = blob.subdata(in: ciphertextEnd ..< blob.count)

        let key = try deriveKey(password: password, salt: salt)
        let nonce = try AES.GCM.Nonce(data: nonceBytes)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        do {
            return try AES.GCM.open(box, using: key)
        } catch {
            throw Error.decryptionFailed
        }
    }

    /// Test helper: encrypt with fixed salt and nonce (version 1 layout).
    public static func encryptForTesting(
        jsonUTF8: Data,
        password: String,
        salt: Data,
        nonce: Data
    ) throws -> Data {
        guard salt.count == saltLength, nonce.count == nonceLength else {
            throw Error.invalidBlobSize
        }
        let key = try deriveKey(password: password, salt: salt)
        let gcmNonce = try AES.GCM.Nonce(data: nonce)
        let sealed = try AES.GCM.seal(jsonUTF8, using: key, nonce: gcmNonce)
        var out = Data(capacity: headerLength + sealed.ciphertext.count + tagLength)
        out.append(magic)
        out.append(version.bigEndianBytes)
        out.append(salt)
        out.append(nonce)
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    private static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess)
        return Data(bytes)
    }

    private static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var derived = [UInt8](repeating: 0, count: keyLength)
        let status = passwordData.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                    passwordData.count,
                    saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    pbkdf2Iterations,
                    &derived,
                    keyLength
                )
            }
        }
        guard status == kCCSuccess else {
            throw Error.keyDerivationFailed
        }
        return SymmetricKey(data: Data(derived))
    }
}

private extension UInt16 {
    var bigEndianBytes: Data {
        var value = self.bigEndian
        return Data(bytes: &value, count: MemoryLayout<UInt16>.size)
    }

    init(bigEndian data: Data) {
        precondition(data.count == 2)
        let value = data.withUnsafeBytes { raw -> UInt16 in
            raw.load(as: UInt16.self)
        }
        self = UInt16(bigEndian: value)
    }
}