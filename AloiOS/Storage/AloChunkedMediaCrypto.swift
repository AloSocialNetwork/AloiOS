import CryptoKit
import Foundation
import Security

/// Interoperable file envelope for large E2EE attachments.
///
/// The server receives only `ciphertext || tag` chunks. The key material and
/// chunk layout metadata are carried inside the encrypted message payload.
enum AloChunkedMediaCrypto {
    static let scheme = "alo-aes-gcm-chunked-v1"
    static let defaultChunkSize = 1_024 * 1_024
    static let maximumPlaintextSize: Int64 = 2 * 1_024 * 1_024 * 1_024

    private static let noncePrefixSize = 8
    private static let aesKeySize = 32
    private static let tagSize: Int64 = 16
    private static let aadPrefix = "alo-media-stream-v1"

    struct Metadata: Equatable {
        let key: String
        let noncePrefix: String
        let chunkSize: Int
        let plaintextSize: Int64
        let mime: String

        init?(_ encryption: [String: Any]) {
            guard encryption.string("algorithm") == AloChunkedMediaCrypto.scheme else { return nil }
            let key = encryption.string("key")
            let noncePrefix = encryption.string("noncePrefix")
            let chunkSize = Self.integer(encryption["chunkSize"])
            let plaintextSize = Self.int64(encryption["plaintextSize"])
            guard !key.isEmpty,
                  !noncePrefix.isEmpty,
                  (64 * 1_024...AloChunkedMediaCrypto.defaultChunkSize).contains(chunkSize),
                  chunkSize % 16 == 0,
                  (1...AloChunkedMediaCrypto.maximumPlaintextSize).contains(plaintextSize),
                  AloChunkedMediaCrypto.base64URLData(key)?.count == AloChunkedMediaCrypto.aesKeySize,
                  AloChunkedMediaCrypto.base64URLData(noncePrefix)?.count == AloChunkedMediaCrypto.noncePrefixSize else {
                return nil
            }
            self.key = key
            self.noncePrefix = noncePrefix
            self.chunkSize = chunkSize
            self.plaintextSize = plaintextSize
            self.mime = encryption.string("mime").ifBlank("application/octet-stream")
        }

        init(
            key: String,
            noncePrefix: String,
            chunkSize: Int,
            plaintextSize: Int64,
            mime: String
        ) {
            self.key = key
            self.noncePrefix = noncePrefix
            self.chunkSize = chunkSize
            self.plaintextSize = plaintextSize
            self.mime = mime
        }

        var dictionary: [String: Any] {
            [
                "algorithm": AloChunkedMediaCrypto.scheme,
                "key": key,
                "noncePrefix": noncePrefix,
                "chunkSize": String(chunkSize),
                "plaintextSize": String(plaintextSize),
                "mime": mime
            ]
        }

        private static func integer(_ value: Any?) -> Int {
            if let value = value as? Int { return value }
            if let value = value as? NSNumber { return value.intValue }
            if let value = value as? String { return Int(value) ?? 0 }
            return 0
        }

        private static func int64(_ value: Any?) -> Int64 {
            if let value = value as? Int64 { return value }
            if let value = value as? Int { return Int64(value) }
            if let value = value as? NSNumber { return value.int64Value }
            if let value = value as? String { return Int64(value) ?? 0 }
            return 0
        }
    }

    struct EncryptionResult {
        let encryptedURL: URL
        let metadata: Metadata
        let encryptedSize: Int64
        let sha256: String
    }

    static func encrypt(
        sourceURL: URL,
        destinationURL: URL,
        mime: String,
        chunkSize: Int = defaultChunkSize
    ) throws -> EncryptionResult {
        let source = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let destination = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
        guard source != destination else { throw AloChunkedMediaError.invalidInput }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              let size = values.fileSize.map(Int64.init),
              (1...maximumPlaintextSize).contains(size),
              (64 * 1_024...defaultChunkSize).contains(chunkSize),
              chunkSize % 16 == 0 else {
            throw AloChunkedMediaError.invalidInput
        }

        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        let noncePrefix = try randomData(count: noncePrefixSize)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).upload-\(UUID().uuidString).part"
        )
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: temporary)

        var hasher = SHA256()
        var written: Int64 = 0
        var chunkIndex: UInt32 = 0
        do {
            let input = try FileHandle(forReadingFrom: source)
            FileManager.default.createFile(atPath: temporary.path, contents: nil)
            let output = try FileHandle(forWritingTo: temporary)
            defer {
                try? input.close()
                try? output.close()
            }
            while true {
                let plaintext = try readChunk(from: input, size: chunkSize)
                guard !plaintext.isEmpty else { break }
                let encrypted = try encryptChunk(
                    plaintext: plaintext,
                    key: key,
                    noncePrefix: noncePrefix,
                    plaintextSize: size,
                    chunkSize: chunkSize,
                    chunkIndex: chunkIndex
                )
                try output.write(contentsOf: encrypted)
                hasher.update(data: encrypted)
                written += Int64(encrypted.count)
                guard chunkIndex < UInt32.max else { throw AloChunkedMediaError.invalidInput }
                chunkIndex &+= 1
            }
            try output.synchronize()
            guard written == expectedCiphertextSize(plaintextSize: size, chunkSize: chunkSize) else {
                throw AloChunkedMediaError.invalidCiphertext
            }
            try replaceAtomically(temporary, with: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }

        return EncryptionResult(
            encryptedURL: destination,
            metadata: Metadata(
                key: base64URL(keyData),
                noncePrefix: base64URL(noncePrefix),
                chunkSize: chunkSize,
                plaintextSize: size,
                mime: mime.ifBlank("application/octet-stream")
            ),
            encryptedSize: written,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    static func readRange(
        encryptedURL: URL,
        metadata: Metadata,
        offset: Int64,
        length: Int
    ) throws -> Data {
        guard offset >= 0, length > 0, offset < metadata.plaintextSize else { return Data() }
        try validateCiphertextFile(encryptedURL, metadata: metadata)
        let end = min(metadata.plaintextSize, offset + Int64(length))
        let firstChunk = offset / Int64(metadata.chunkSize)
        let lastChunk = (end - 1) / Int64(metadata.chunkSize)
        let input = try FileHandle(forReadingFrom: encryptedURL)
        defer { try? input.close() }
        var result = Data()
        result.reserveCapacity(Int(end - offset))

        for index in firstChunk...lastChunk {
            let chunkStart = index * Int64(metadata.chunkSize)
            let plainLength = Int(min(Int64(metadata.chunkSize), metadata.plaintextSize - chunkStart))
            let plaintext = try decryptChunk(
                input: input,
                metadata: metadata,
                chunkIndex: UInt32(index),
                plaintextLength: plainLength
            )
            let from = max(offset, chunkStart)
            let to = min(end, chunkStart + Int64(plainLength))
            result.append(plaintext[Int(from - chunkStart)..<Int(to - chunkStart)])
        }
        return result
    }

    static func decrypt(
        encryptedURL: URL,
        metadata: Metadata,
        destinationURL: URL
    ) throws {
        try validateCiphertextFile(encryptedURL, metadata: metadata)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".\(destinationURL.lastPathComponent).decrypt-\(UUID().uuidString).part"
        )
        try? FileManager.default.removeItem(at: temporary)
        do {
            let input = try FileHandle(forReadingFrom: encryptedURL)
            FileManager.default.createFile(atPath: temporary.path, contents: nil)
            let output = try FileHandle(forWritingTo: temporary)
            defer {
                try? input.close()
                try? output.close()
            }
            let chunkCount = chunksFor(plaintextSize: metadata.plaintextSize, chunkSize: metadata.chunkSize)
            for index in 0..<chunkCount {
                let chunkStart = Int64(index) * Int64(metadata.chunkSize)
                let plainLength = Int(min(Int64(metadata.chunkSize), metadata.plaintextSize - chunkStart))
                let plaintext = try decryptChunk(
                    input: input,
                    metadata: metadata,
                    chunkIndex: UInt32(index),
                    plaintextLength: plainLength
                )
                try output.write(contentsOf: plaintext)
            }
            try output.synchronize()
            try replaceAtomically(temporary, with: destinationURL)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    static func expectedCiphertextSize(plaintextSize: Int64, chunkSize: Int) -> Int64 {
        guard plaintextSize > 0 else { return 0 }
        return plaintextSize + chunksFor(plaintextSize: plaintextSize, chunkSize: chunkSize) * tagSize
    }

    private static func encryptChunk(
        plaintext: Data,
        key: SymmetricKey,
        noncePrefix: Data,
        plaintextSize: Int64,
        chunkSize: Int,
        chunkIndex: UInt32
    ) throws -> Data {
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: try nonce(prefix: noncePrefix, index: chunkIndex),
            authenticating: aad(
                plaintextSize: plaintextSize,
                chunkSize: chunkSize,
                chunkIndex: chunkIndex
            )
        )
        var result = Data(sealed.ciphertext)
        result.append(sealed.tag)
        return result
    }

    private static func decryptChunk(
        input: FileHandle,
        metadata: Metadata,
        chunkIndex: UInt32,
        plaintextLength: Int
    ) throws -> Data {
        let storedOffset = UInt64(chunkIndex) * UInt64(metadata.chunkSize + Int(tagSize))
        try input.seek(toOffset: storedOffset)
        let encrypted = try readExactly(from: input, count: plaintextLength + Int(tagSize))
        guard encrypted.count == plaintextLength + Int(tagSize),
              let keyData = base64URLData(metadata.key),
              let prefix = base64URLData(metadata.noncePrefix) else {
            throw AloChunkedMediaError.invalidCiphertext
        }
        let sealed = try AES.GCM.SealedBox(
            nonce: nonce(prefix: prefix, index: chunkIndex),
            ciphertext: Data(encrypted.dropLast(Int(tagSize))),
            tag: Data(encrypted.suffix(Int(tagSize)))
        )
        return try AES.GCM.open(sealed, using: SymmetricKey(data: keyData), authenticating: aad(
            plaintextSize: metadata.plaintextSize,
            chunkSize: metadata.chunkSize,
            chunkIndex: chunkIndex
        ))
    }

    private static func validateCiphertextFile(_ url: URL, metadata: Metadata) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? -1
        guard size == expectedCiphertextSize(
            plaintextSize: metadata.plaintextSize,
            chunkSize: metadata.chunkSize
        ) else {
            throw AloChunkedMediaError.invalidCiphertext
        }
    }

    private static func readChunk(from handle: FileHandle, size: Int) throws -> Data {
        var chunk = Data()
        chunk.reserveCapacity(size)
        while chunk.count < size {
            guard let part = try handle.read(upToCount: size - chunk.count), !part.isEmpty else { break }
            chunk.append(part)
        }
        return chunk
    }

    private static func readExactly(from handle: FileHandle, count: Int) throws -> Data {
        var value = Data()
        value.reserveCapacity(count)
        while value.count < count {
            guard let part = try handle.read(upToCount: count - value.count), !part.isEmpty else { break }
            value.append(part)
        }
        return value
    }

    private static func nonce(prefix: Data, index: UInt32) throws -> AES.GCM.Nonce {
        guard prefix.count == noncePrefixSize else { throw AloChunkedMediaError.invalidMetadata }
        var bytes = prefix
        var bigEndian = index.bigEndian
        withUnsafeBytes(of: &bigEndian) { bytes.append(contentsOf: $0) }
        return try AES.GCM.Nonce(data: bytes)
    }

    private static func aad(plaintextSize: Int64, chunkSize: Int, chunkIndex: UInt32) -> Data {
        Data("\(aadPrefix):\(plaintextSize):\(chunkSize):\(chunkIndex)".utf8)
    }

    private static func chunksFor(plaintextSize: Int64, chunkSize: Int) -> Int64 {
        (plaintextSize + Int64(chunkSize) - 1) / Int64(chunkSize)
    }

    private static func replaceAtomically(_ source: URL, with destination: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        do {
            try manager.moveItem(at: source, to: destination)
        } catch {
            try manager.copyItem(at: source, to: destination)
            try? manager.removeItem(at: source)
        }
    }

    private static func randomData(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw AloChunkedMediaError.randomnessUnavailable
        }
        return Data(bytes)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLData(_ value: String) -> Data? {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: normalized)
    }
}

private enum AloChunkedMediaError: Error {
    case invalidInput
    case invalidMetadata
    case invalidCiphertext
    case randomnessUnavailable
}
