import Foundation

/// Minimal client that exercises the merged `/api/v1` backend end-to-end from
/// the Mac: bearer login → authenticated sync pull. Proves the real macOS app
/// will be able to authenticate and pull the shared dataset.
///
/// This is the SECONDARY leg of the spike (the notification test is the
/// make-or-break). It needs the backend deployed with `/api/v1` and a test
/// account. Point `baseURL` at your Vercel deployment, e.g.
/// `https://<your-app>.vercel.app`.
enum SpikeAPIClient {

    struct LoginResponse: Decodable {
        let token: String?
        let challenge: String?      // "totp" when 2FA is on
        let preAuthToken: String?
    }

    static func testRoundTrip(baseURL: String, email: String, password: String) async {
        guard let base = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            spikeLog("API: invalid base URL")
            return
        }

        // 1. POST /api/v1/auth/login
        let loginURL = base.appendingPathComponent("api/v1/auth/login")
        var req = URLRequest(url: loginURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["email": email, "password": password])

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                spikeLog("API login FAILED: HTTP \(code) \(String(data: data, encoding: .utf8) ?? "")")
                return
            }
            let login = try JSONDecoder().decode(LoginResponse.self, from: data)
            if login.challenge == "totp" {
                spikeLog("API login: account has 2FA on — spike stops here (wire /auth/2fa when needed).")
                return
            }
            guard let token = login.token else {
                spikeLog("API login: 200 but no token in response.")
                return
            }
            spikeLog("API login OK — got bearer token (\(token.prefix(8))…).")

            // 2. GET /api/v1/sync with the bearer token
            let syncURL = base.appendingPathComponent("api/v1/sync")
            var syncReq = URLRequest(url: syncURL)
            syncReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (syncData, syncResp) = try await URLSession.shared.data(for: syncReq)
            let syncCode = (syncResp as? HTTPURLResponse)?.statusCode ?? -1
            guard syncCode == 200 else {
                spikeLog("API sync FAILED: HTTP \(syncCode)")
                return
            }
            let json = try JSONSerialization.jsonObject(with: syncData) as? [String: Any]
            let meds = (json?["medications"] as? [Any])?.count ?? 0
            let doses = (json?["doseLogs"] as? [Any])?.count ?? 0
            let fullResync = json?["fullResync"] as? Bool ?? false
            spikeLog("API sync OK ✅ — fullResync=\(fullResync), medications=\(meds), doseLogs=\(doses).")
        } catch {
            spikeLog("API round-trip ERROR: \(error.localizedDescription)")
        }
    }
}
