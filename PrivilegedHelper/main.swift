//
//  main.swift
//  com.windowsm.helper
//
//  Privileged helper installed by SMJobBless. launchd starts this process as
//  root on demand when the app connects to the Mach service. It exposes
//  HelperProtocol over XPC and accepts connections only from code that
//  satisfies the client requirement (see ConnectionVerifier).
//

import Foundation

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard ConnectionVerifier.connectionIsAuthorized(newConnection) else {
            NSLog("com.windowsm.helper: rejected connection from unauthorized client")
            return false
        }

        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = HelperTool(connection: newConnection)
        newConnection.remoteObjectInterface = NSXPCInterface(with: HelperProgressProtocol.self)
        newConnection.resume()
        return true
    }
}

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()

NSLog("com.windowsm.helper v%@ started", HelperConstants.version)
RunLoop.current.run()
