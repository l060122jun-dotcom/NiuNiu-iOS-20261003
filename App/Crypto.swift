import Foundation
import CommonCrypto
import zlib

/// Protocol compatibility only: AES/3DES/MD5 are not used for new credential storage.
enum Crypto {
    enum Failure: LocalizedError {
        case invalidKey, invalidIV, invalidBase64, invalidUTF8, invalidGzip, operation(Int32)
        var errorDescription: String? {
            switch self {
            case .invalidKey: return "加密配置的密钥长度无效"
            case .invalidIV: return "加密配置的 IV 长度无效"
            case .invalidBase64: return "服务器返回的加密内容不是有效 Base64"
            case .invalidUTF8: return "解密后的内容不是 UTF-8 文本"
            case .invalidGzip: return "远端压缩内容无效或超过大小限制"
            case .operation(let code): return "协议解密失败（\(code)）"
            }
        }
    }

    static func androidURIEncode(_ value: String, additionallyAllowed: String = "") -> String {
        // Android Uri.encode always permits these characters, in addition to `allow`.
        let allowed = Set(("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-!.~'()*" + additionallyAllowed).utf8)
        return value.utf8.map { allowed.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
    }

    static func responseKey(for url: URL, encodedQuery: Bool = false) -> Data {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var seed = components?.path ?? url.path
        if let query = components?.percentEncodedQuery, !query.isEmpty {
            let decoded = query.removingPercentEncoding ?? query
            seed += "?" + (encodedQuery ? query : androidURIEncode(decoded, additionallyAllowed: "-![.:/,%?&=]"))
        }
        return paddedSeed(seed)
    }

    static func paddedSeed(_ seed: String) -> Data {
        let prefix = String(seed.prefix(16))
        return Data((prefix + String(repeating: "0", count: max(0, 16 - prefix.count))).utf8)
    }

    static func aesECBDecrypt(_ data: Data, key: Data) throws -> Data {
        try crypt(data, key: key, iv: nil, algorithm: CCAlgorithm(kCCAlgorithmAES), operation: CCOperation(kCCDecrypt), ecb: true)
    }
    static func aesECBEncrypt(_ data: Data, key: Data) throws -> Data {
        try crypt(data, key: key, iv: nil, algorithm: CCAlgorithm(kCCAlgorithmAES), operation: CCOperation(kCCEncrypt), ecb: true)
    }
    static func aesCBCDecrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        try crypt(data, key: key, iv: iv, algorithm: CCAlgorithm(kCCAlgorithmAES), operation: CCOperation(kCCDecrypt), ecb: false)
    }
    static func aesCBCEncrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        try crypt(data, key: key, iv: iv, algorithm: CCAlgorithm(kCCAlgorithmAES), operation: CCOperation(kCCEncrypt), ecb: false)
    }
    static func tripleDESDecrypt(_ data: Data, key: Data, iv: Data? = nil) throws -> Data {
        try crypt(data, key: key, iv: iv, algorithm: CCAlgorithm(kCCAlgorithm3DES), operation: CCOperation(kCCDecrypt), ecb: iv == nil)
    }
    static func tripleDESEncrypt(_ data: Data, key: Data, iv: Data? = nil) throws -> Data {
        try crypt(data, key: key, iv: iv, algorithm: CCAlgorithm(kCCAlgorithm3DES), operation: CCOperation(kCCEncrypt), ecb: iv == nil)
    }
    static func decryptBase64(_ text: String, key: Data) throws -> Data {
        let compact = text.components(separatedBy: .whitespacesAndNewlines).joined()
        guard let data = Data(base64Encoded: compact) else { throw Failure.invalidBase64 }
        return try aesECBDecrypt(data, key: key)
    }
    static func md5(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_MD5($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    static func md5(_ text: String, uppercase: Bool = false) -> String {
        let digest = md5(Data(text.utf8))
        return uppercase ? digest.uppercased() : digest
    }

    /// g3.g decompresses gzip by magic bytes even when Content-Encoding is absent.
    static func gunzipIfNeeded(_ data: Data) throws -> Data {
        guard data.count >= 2, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else { return data }
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure.invalidGzip }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { input -> Data in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var result = Data()
            let chunkSize = 32 * 1024
            while true {
                var chunk = Data(count: chunkSize)
                let status = chunk.withUnsafeMutableBytes { output -> Int32 in
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                guard result.count + produced <= 16 * 1024 * 1024 else { throw Failure.invalidGzip }
                result.append(chunk.prefix(produced))
                if status == Z_STREAM_END { return result }
                guard status == Z_OK, produced > 0 else { throw Failure.invalidGzip }
            }
        }
    }

    private static func crypt(_ data: Data, key: Data, iv: Data?, algorithm: CCAlgorithm, operation: CCOperation, ecb: Bool) throws -> Data {
        let aes = algorithm == CCAlgorithm(kCCAlgorithmAES)
        guard (aes && [16, 24, 32].contains(key.count)) || (!aes && key.count == kCCKeySize3DES) else { throw Failure.invalidKey }
        let blockSize = aes ? kCCBlockSizeAES128 : kCCBlockSize3DES
        guard ecb || iv?.count == blockSize else { throw Failure.invalidIV }
        var output = Data(count: data.count + blockSize)
        let capacity = output.count
        var moved = 0
        let options = CCOptions(kCCOptionPKCS7Padding | (ecb ? kCCOptionECBMode : 0))
        let status = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                key.withUnsafeBytes { keyBytes in
                    if let iv = iv {
                        return iv.withUnsafeBytes { ivBytes in
                            CCCrypt(operation, algorithm, options, keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                    source.baseAddress, data.count, destination.baseAddress, capacity, &moved)
                        }
                    }
                    return CCCrypt(operation, algorithm, options, keyBytes.baseAddress, key.count, nil,
                                   source.baseAddress, data.count, destination.baseAddress, capacity, &moved)
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.operation(status) }
        output.count = moved
        return output
    }
}
