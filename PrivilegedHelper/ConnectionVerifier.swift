//
//  ConnectionVerifier.swift
//  com.windowsm.helper
//
//  A root helper must not trust arbitrary local processes: anything on the
//  system can open our Mach service. Before accepting a connection we verify
//  the *code signature* of the connecting process against a requirement that
//  pins it to the WindowsM app.
//

import Foundation
import Security

enum ConnectionVerifier {

    /// Code-signing requirement the connecting client must satisfy.
    /// Debug builds are ad-hoc signed, so the requirement is identifier-only;
    /// release builds must also chain to Apple's anchor (Developer ID).
    private static var clientRequirementString: String {
        #if DEBUG
        return "identifier \"com.windowsm.app\""
        #else
        return "identifier \"com.windowsm.app\" and anchor apple generic"
        #endif
    }

    static func connectionIsAuthorized(_ connection: NSXPCConnection) -> Bool {
        guard let tokenData = auditTokenData(for: connection) else {
            NSLog("com.windowsm.helper: could not read audit token")
            return false
        }

        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: tokenData] as NSDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let clientCode = code else {
            return false
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(clientRequirementString as CFString, [], &requirement) == errSecSuccess,
              let clientRequirement = requirement else {
            return false
        }

        return SecCodeCheckValidity(clientCode, [], clientRequirement) == errSecSuccess
    }

    /// NSXPCConnection's audit token is not public API, but it has been a
    /// stable property since 10.8 and is the standard way for blessed helpers
    /// to identify their peer (used via KVC by virtually every open-source
    /// SMJobBless implementation). The alternative, trusting the peer's PID -
    /// is racy and insecure.
    private static func auditTokenData(for connection: NSXPCConnection) -> Data? {
        guard let value = connection.value(forKey: "auditToken") else { return nil }
        if let data = value as? Data {
            return data
        }
        if let nsValue = value as? NSValue {
            var token = audit_token_t()
            nsValue.getValue(&token)
            return withUnsafeBytes(of: &token) { Data($0) }
        }
        return nil
    }
}
