// Checks the appcast's EdDSA signature and length for the DMG against the public key INSIDE the built app
// (docs/install-and-update.md 4). A wrong or rotated key is the one mistake that silently strands every user, so the
// release never skips this.
//   swift scripts/mac/verify-update.swift <appcast.xml> <update.dmg> <Info.plist | base64 public key>
//   swift scripts/mac/verify-update.swift --throwaway-key <file>   writes a new private key (generate_appcast's
//                                                                   --ed-key-file format), prints its public key
//   swift scripts/mac/verify-update.swift --self-test
import CryptoKit
import Foundation

func fail(_ why: String) -> Never { FileHandle.standardError.write(Data("verify-update: \(why)\n".utf8)); exit(1) }

/// nil when the signature, the length or the key does not hold.
func problem(appcast: String, dmg: Data, publicKey: String) -> String? {
    let name = #"sparkle:edSignature="([^"]+)""#, len = #"length="(\d+)""#
    guard let sig = appcast.firstMatch(of: try! Regex(name))?.output[1].substring.map(String.init),
          let length = appcast.firstMatch(of: try! Regex(len))?.output[1].substring.flatMap({ Int($0) })
    else { return "the appcast has no sparkle:edSignature or length" }
    guard length == dmg.count else { return "length \(length) in the appcast, the DMG has \(dmg.count) bytes" }
    guard let raw = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    else { return "SUPublicEDKey is not a base64 EdDSA public key" }
    guard let s = Data(base64Encoded: sig), key.isValidSignature(s, for: dmg)
    else { return "the signature does not match the DMG under the app's SUPublicEDKey" }
    return nil
}

func publicKey(_ arg: String) -> String {
    guard arg.hasSuffix(".plist") else { return arg }
    let plist = NSDictionary(contentsOfFile: arg) ?? [:]
    guard let k = plist["SUPublicEDKey"] as? String else { fail("\(arg) has no SUPublicEDKey (built without UPDATES=1?)") }
    return k
}

func item(_ sig: Data, _ length: Int) -> String {
    #"<enclosure url="https://example.invalid/a.dmg" sparkle:edSignature="\#(sig.base64EncodedString())" length="\#(length)"/>"#
}

func selfTest() {
    let key = Curve25519.Signing.PrivateKey(), other = Curve25519.Signing.PrivateKey()
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    let dmg = Data((0..<4096).map { UInt8($0 % 251) })
    let sig = try! key.signature(for: dmg)
    var flipped = dmg; flipped[100] ^= 1
    var bad: [String] = []
    if let p = problem(appcast: item(sig, dmg.count), dmg: dmg, publicKey: pub) { bad.append("a good signature was refused: \(p)") }
    let refused = [("a flipped byte", problem(appcast: item(sig, dmg.count), dmg: flipped, publicKey: pub)),
                   ("another key", problem(appcast: item(try! other.signature(for: dmg), dmg.count), dmg: dmg, publicKey: pub)),
                   ("a wrong length", problem(appcast: item(sig, dmg.count + 1), dmg: dmg, publicKey: pub)),
                   ("no signature", problem(appcast: "<enclosure length=\"4096\"/>", dmg: dmg, publicKey: pub))]
    for (label, p) in refused where p == nil { bad.append("\(label) was accepted") }
    guard bad.isEmpty else { fail("self-test FAILED: " + bad.joined(separator: "; ")) }
    print("verify-update self-test ok")
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "--self-test": selfTest()
case "--throwaway-key":
    guard args.count == 2 else { fail("--throwaway-key <file>") }
    let key = Curve25519.Signing.PrivateKey()
    FileManager.default.createFile(atPath: args[1], contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                   attributes: [.posixPermissions: 0o600])
    print(key.publicKey.rawRepresentation.base64EncodedString())
default:
    guard args.count == 3, let appcast = try? String(contentsOfFile: args[0], encoding: .utf8),
          let dmg = FileManager.default.contents(atPath: args[1]) else {
        fail("usage: verify-update.swift <appcast.xml> <update.dmg> <Info.plist | public key>")
    }
    if let p = problem(appcast: appcast, dmg: dmg, publicKey: publicKey(args[2])) { fail(p) }
    print("verify-update: the appcast's signature and length match \(args[1]) under the app's key")
}
