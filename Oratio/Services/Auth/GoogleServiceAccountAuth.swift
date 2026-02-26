import Foundation
import Security

/// Google Service Account 인증 관리
/// JWT 생성 → access token 교환 → 자동 갱신
class GoogleServiceAccountAuth {
    struct ServiceAccountCredentials {
        let clientEmail: String
        let privateKey: String
        let tokenURI: String
    }

    private var credentials: ServiceAccountCredentials?
    private var accessToken: String?
    private var tokenExpiry: Date?

    /// Service Account JSON 파일 경로에서 인증 정보를 로드한다.
    func loadCredentials(from filePath: String) throws {
        let url = URL(fileURLWithPath: filePath)
        let data = try Data(contentsOf: url)
        try loadCredentials(from: data)
    }

    /// Service Account JSON 데이터에서 인증 정보를 로드한다.
    func loadCredentials(from jsonData: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let clientEmail = json["client_email"] as? String,
              let privateKey = json["private_key"] as? String,
              let tokenURI = json["token_uri"] as? String else {
            throw AuthError.invalidServiceAccountJSON
        }

        self.credentials = ServiceAccountCredentials(
            clientEmail: clientEmail,
            privateKey: privateKey,
            tokenURI: tokenURI
        )

        // 기존 토큰 무효화
        accessToken = nil
        tokenExpiry = nil
    }

    /// 유효한 access token을 반환한다. 필요시 자동 갱신.
    func getAccessToken() async throws -> String {
        // 캐시된 토큰이 유효하면 재사용
        if let token = accessToken, let expiry = tokenExpiry, Date() < expiry {
            return token
        }

        guard let creds = credentials else {
            throw AuthError.credentialsNotLoaded
        }

        let jwt = try createJWT(credentials: creds)
        let token = try await exchangeJWTForToken(jwt: jwt, tokenURI: creds.tokenURI)

        self.accessToken = token.accessToken
        self.tokenExpiry = Date().addingTimeInterval(TimeInterval(token.expiresIn - 60))

        return token.accessToken
    }

    // MARK: - JWT 생성

    private func createJWT(credentials: ServiceAccountCredentials) throws -> String {
        let now = Int(Date().timeIntervalSince1970)
        let expiry = now + 3600

        // Header
        let header = ["alg": "RS256", "typ": "JWT"]
        let headerData = try JSONSerialization.data(withJSONObject: header)
        let headerB64 = headerData.base64URLEncoded()

        // Payload
        let payload: [String: Any] = [
            "iss": credentials.clientEmail,
            "scope": "https://www.googleapis.com/auth/cloud-platform",
            "aud": credentials.tokenURI,
            "iat": now,
            "exp": expiry
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let payloadB64 = payloadData.base64URLEncoded()

        // Sign
        let signingInput = "\(headerB64).\(payloadB64)"
        guard let signingData = signingInput.data(using: .utf8) else {
            throw AuthError.jwtCreationFailed
        }

        let privateKey = try loadPrivateKey(pem: credentials.privateKey)
        let signature = try sign(data: signingData, with: privateKey)
        let signatureB64 = signature.base64URLEncoded()

        return "\(headerB64).\(payloadB64).\(signatureB64)"
    }

    // MARK: - RSA 서명

    private func loadPrivateKey(pem: String) throws -> SecKey {
        // PEM 데이터를 SecItemImport로 직접 임포트 (PKCS#8 PEM 지원)
        guard let pemData = pem.data(using: .utf8) else {
            throw AuthError.invalidPrivateKey
        }

        var items: CFArray?
        var inputFormat = SecExternalFormat.formatPEMSequence
        var itemType = SecExternalItemType.itemTypePrivateKey

        let status = SecItemImport(
            pemData as CFData,
            nil,
            &inputFormat,
            &itemType,
            [],
            nil,
            nil,
            &items
        )

        guard status == errSecSuccess,
              let itemArray = items as? [Any],
              let firstItem = itemArray.first else {
            // 폴백: PEM 헤더 제거 후 PKCS#8 → PKCS#1 변환 시도
            return try loadPrivateKeyManual(pem: pem)
        }

        return firstItem as! SecKey
    }

    /// SecItemImport 실패 시 수동으로 PKCS#8 헤더를 제거하고 PKCS#1으로 변환한다.
    private func loadPrivateKeyManual(pem: String) throws -> SecKey {
        let stripped = pem
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()

        guard var keyData = Data(base64Encoded: stripped) else {
            throw AuthError.invalidPrivateKey
        }

        // PKCS#8 형식이면 헤더를 제거하여 PKCS#1 데이터 추출
        if pem.contains("BEGIN PRIVATE KEY") {
            keyData = stripPKCS8Header(keyData)
        }

        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &error) else {
            if let err = error {
                print("[Auth] SecKeyCreateWithData 실패: \(err.takeRetainedValue())")
            }
            throw AuthError.invalidPrivateKey
        }

        return key
    }

    /// PKCS#8 DER에서 RSA OID 뒤의 OCTET STRING 내 PKCS#1 키 데이터를 추출한다.
    private func stripPKCS8Header(_ data: Data) -> Data {
        let bytes = [UInt8](data)

        // RSA OID: 2a 86 48 86 f7 0d 01 01 01
        let rsaOID: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]

        // OID 위치 찾기
        guard let oidIndex = findSequence(rsaOID, in: bytes) else {
            return data
        }

        var index = oidIndex + rsaOID.count

        // NULL (05 00) 건너뛰기
        guard index + 2 <= bytes.count,
              bytes[index] == 0x05, bytes[index + 1] == 0x00 else {
            return data
        }
        index += 2

        // OCTET STRING 태그 (04)
        guard index < bytes.count, bytes[index] == 0x04 else {
            return data
        }
        index += 1

        // 길이 읽기
        if bytes[index] & 0x80 != 0 {
            let numBytes = Int(bytes[index] & 0x7f)
            index += 1 + numBytes
        } else {
            index += 1
        }

        guard index < bytes.count else { return data }
        return Data(bytes[index...])
    }

    private func findSequence(_ seq: [UInt8], in bytes: [UInt8]) -> Int? {
        guard seq.count <= bytes.count else { return nil }
        for i in 0...(bytes.count - seq.count) {
            if Array(bytes[i..<(i + seq.count)]) == seq {
                return i
            }
        }
        return nil
    }

    private func sign(data: Data, with key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            data as CFData,
            &error
        ) as Data? else {
            throw AuthError.signingFailed
        }

        return signature
    }

    // MARK: - 토큰 교환

    private struct TokenResponse {
        let accessToken: String
        let expiresIn: Int
    }

    private func exchangeJWTForToken(jwt: String, tokenURI: String) async throws -> TokenResponse {
        guard let url = URL(string: tokenURI) else {
            throw AuthError.invalidTokenURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=\(jwt)"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AuthError.tokenExchangeFailed(errorText)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Int else {
            throw AuthError.invalidTokenResponse
        }

        return TokenResponse(accessToken: accessToken, expiresIn: expiresIn)
    }
}

// MARK: - Error Types

enum AuthError: LocalizedError {
    case invalidServiceAccountJSON
    case credentialsNotLoaded
    case invalidPrivateKey
    case jwtCreationFailed
    case signingFailed
    case invalidTokenURI
    case tokenExchangeFailed(String)
    case invalidTokenResponse

    var errorDescription: String? {
        switch self {
        case .invalidServiceAccountJSON:
            return "Service Account JSON 파일이 올바르지 않습니다."
        case .credentialsNotLoaded:
            return "Service Account 인증 정보가 로드되지 않았습니다."
        case .invalidPrivateKey:
            return "Private key를 파싱할 수 없습니다."
        case .jwtCreationFailed:
            return "JWT 생성에 실패했습니다."
        case .signingFailed:
            return "JWT 서명에 실패했습니다."
        case .invalidTokenURI:
            return "Token URI가 올바르지 않습니다."
        case .tokenExchangeFailed(let message):
            return "토큰 교환 실패: \(message)"
        case .invalidTokenResponse:
            return "토큰 응답을 파싱할 수 없습니다."
        }
    }
}

// MARK: - Base64URL 인코딩

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
