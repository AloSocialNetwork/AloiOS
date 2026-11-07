import Foundation
import LibSignalClient
import XCTest
@testable import AloiOS

/// Interoperability of the app's real libsignal code (AloLibSignalSessionEngine + AloLibSignalStore, libsignal 0.97.1)
/// with the browser build (the same Rust core compiled to WebAssembly). The browser side runs in a Node script
/// (~/alo/tools/native-interop/orchestrator.cjs) that exchanges JSON files with this test through ALO_INTEROP_DIR.
///
///   node ~/alo/tools/native-interop/orchestrator.cjs /tmp/alo-interop &
///   TEST_RUNNER_ALO_INTEROP_DIR=/tmp/alo-interop xcodebuild test -only-testing:AloiOSTests/AloWebInteropTests ...
final class AloWebInteropTests: XCTestCase {
    private func directory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["ALO_INTEROP_DIR"], !path.isEmpty else {
            throw XCTSkip("ALO_INTEROP_DIR is not set: run through ~/alo/tools/native-interop/orchestrator.cjs")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func write(_ object: [String: Any], _ name: String, in directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private func read(_ name: String, in directory: URL, timeout: TimeInterval = 600) throws -> [String: Any] {
        let url = directory.appendingPathComponent(name)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("timed out waiting for \(name)")
        throw CocoaError(.fileReadNoSuchFile)
    }

    // The server stores base64url without padding; the app reads both alphabets (AloAPIClient.libSignalData).
    private func data(_ value: Any?) throws -> Data {
        var normalized = String(describing: value ?? "")
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 { normalized += String(repeating: "=", count: 4 - remainder) }
        return try XCTUnwrap(Data(base64Encoded: normalized))
    }

    private func int(_ value: Any?) -> UInt32 { UInt32((value as? NSNumber)?.uint32Value ?? 0) }

    func testAppEngineInteroperatesWithTheBrowserBuild() throws {
        let dir = try directory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let store = try AloLibSignalStore(namespace: "web-interop-\(UUID().uuidString)")
        let engine = AloLibSignalSessionEngine(store: store, localUserId: 2, localDeviceId: 1)
        let webUserId = 1
        let webDeviceId: UInt32 = 1

        // 1. The app registers a device the way registerLibSignalDeviceIfPossible does.
        let bundle = try engine.generateDeviceBundle(preKeyCount: 3)
        try write([
            "registrationId": Int(bundle.registrationId),
            "protocolDeviceId": Int(bundle.protocolDeviceId),
            "identityKey": bundle.identityKey.base64EncodedString(),
            "signedPreKeyId": Int(bundle.signedPreKeyId),
            "signedPreKey": bundle.signedPreKey.base64EncodedString(),
            "signedPreKeySignature": bundle.signedPreKeySignature.base64EncodedString(),
            "preKeys": bundle.preKeys.map { key in
                [
                    "preKeyId": Int(key.preKeyId),
                    "preKey": key.preKey.base64EncodedString(),
                    "kyberPreKeyId": Int(key.kyberPreKeyId),
                    "kyberPreKey": key.kyberPreKey.base64EncodedString(),
                    "kyberPreKeySignature": key.kyberPreKeySignature.base64EncodedString()
                ] as [String: Any]
            }
        ], "ios-bundle.json", in: dir)

        // 2. The browser starts a session with that bundle (PQXDH + Kyber1024) and sends messages, some out of order.
        let inbound = try read("web-inbound.json", in: dir)
        let messages = try XCTUnwrap(inbound["messages"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(messages.count, 4)
        for (index, message) in messages.enumerated() {
            let opened = try engine.decrypt(
                remoteUserId: webUserId,
                remoteDeviceId: webDeviceId,
                ciphertextType: UInt8(int(message["type"])),
                ciphertext: try data(message["ciphertext"])
            )
            XCTAssertEqual(String(decoding: opened, as: UTF8.self), message["plaintext"] as? String, "browser message \(index)")
        }
        XCTAssertEqual(messages.first.map { int($0["type"]) }, 3, "the first message is a PreKey (PQXDH) message")

        // 3. The app answers (Double Ratchet) and also shares a sender key for a group.
        let reply = try engine.encrypt(remoteUserId: webUserId, remoteDeviceId: webDeviceId, plaintext: Data("ответ из iOS".utf8))
        let distributionId = UUID()
        let distribution = try engine.createSenderKeyDistribution(distributionId: distributionId)
        let groupCiphertext = try engine.groupEncrypt(distributionId: distributionId, plaintext: Data("группа из iOS".utf8))
        try write([
            "type": Int(reply.type),
            "ciphertext": reply.bytes.base64EncodedString(),
            "plaintext": "ответ из iOS",
            "group": [
                "distributionId": distributionId.uuidString.lowercased(),
                "distribution": distribution.base64EncodedString(),
                "ciphertext": groupCiphertext.base64EncodedString(),
                "plaintext": "группа из iOS"
            ] as [String: Any]
        ], "ios-reply.json", in: dir)

        // 4. The app starts a session with the browser's bundle exactly as the server returns it (base64url, no padding).
        let web = try read("web-bundle.json", in: dir)
        let remote = AloLibSignalPreKeyBundle(
            registrationId: int(web["registrationId"]),
            deviceId: int(web["deviceId"]),
            identityKey: try data(web["identityKey"]),
            preKeyId: int(web["preKeyId"]),
            preKey: try data(web["preKey"]),
            signedPreKeyId: int(web["signedPreKeyId"]),
            signedPreKey: try data(web["signedPreKey"]),
            signedPreKeySignature: try data(web["signedPreKeySignature"]),
            kyberPreKeyId: int(web["kyberPreKeyId"]),
            kyberPreKey: try data(web["kyberPreKey"]),
            kyberPreKeySignature: try data(web["kyberPreKeySignature"])
        )
        XCTAssertEqual(remote.identityKey.count, 33)
        try engine.processRemotePreKeyBundle(remoteUserId: webUserId, bundle: remote)
        let initiated = try engine.encrypt(remoteUserId: webUserId, remoteDeviceId: remote.deviceId, plaintext: Data("первое сообщение из iOS".utf8))
        XCTAssertEqual(initiated.type, CiphertextMessage.MessageType.preKey.rawValue)
        try write([
            "type": Int(initiated.type),
            "ciphertext": initiated.bytes.base64EncodedString(),
            "preKeyId": Int(remote.preKeyId),
            "kyberPreKeyId": Int(remote.kyberPreKeyId),
            "plaintext": "первое сообщение из iOS"
        ], "ios-initiated.json", in: dir)

        // 5. The browser's sender key for a group.
        let group = try read("web-group.json", in: dir)
        try engine.processSenderKeyDistribution(remoteUserId: webUserId, remoteDeviceId: webDeviceId, serialized: try data(group["distribution"]))
        let groupPlain = try engine.groupDecrypt(remoteUserId: webUserId, remoteDeviceId: webDeviceId, ciphertext: try data(group["ciphertext"]))
        XCTAssertEqual(String(decoding: groupPlain, as: UTF8.self), group["plaintext"] as? String)

        try write(["ok": true], "ios-done.json", in: dir)
    }
}
