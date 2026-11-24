// Generates / verifies a CryptoKit test vector for the projector's BleCrypto (android unit test).
// swift ble-vector.swift gen > vector.json   |   swift ble-vector.swift open <keyHex> <sealedHex>
import CryptoKit
import Foundation

func hex(_ d: some DataProtocol) -> String { d.map { String(format: "%02x", $0) }.joined() }
func data(_ h: String) -> Data { Data(stride(from: 0, to: h.count, by: 2).map { UInt8(h.dropFirst($0).prefix(2), radix: 16)! }) }
let info = Data("BeamDeck BLE v1".utf8)
let args = CommandLine.arguments
if args[1] == "gen" {
    let client = P256.KeyAgreement.PrivateKey(), server = P256.KeyAgreement.PrivateKey()
    let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    let key = try client.sharedSecretFromKeyAgreement(with: server.publicKey)
        .hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32)
    let plain = #"{"id":1,"op":"key","key":"up"}"#
    let sealed = try AES.GCM.seal(Data(plain.utf8), using: key).combined!
    let out: [String: String] = ["serverPrivate": hex(server.rawRepresentation), "clientPublic": hex(client.publicKey.x963Representation),
        "salt": hex(salt), "key": key.withUnsafeBytes { hex($0) }, "sealed": hex(sealed), "plain": plain]
    print(String(data: try JSONSerialization.data(withJSONObject: out, options: .sortedKeys), encoding: .utf8)!)
} else {
    let box = try AES.GCM.SealedBox(combined: data(args[3]))
    print(String(data: try AES.GCM.open(box, using: SymmetricKey(data: data(args[2]))), encoding: .utf8)!)
}
