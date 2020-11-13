//
//  SocketServer.swift
//  MessageProxy
//
//  Created by Salman Husain on 5/5/17.
//  Copyright © 2017 Salman Husain. All rights reserved.
//

import Foundation
import Network
import Starscream
import Dispatch


/*
 
 SOCKET SERVER API DOCUMENTATION::::
 I've never written a socket API before so I send my condolences

 You can test the API by connecting just using raw netcat
 
 Connection flow:
 1. User connects. The application sends the user socket to addNewSocket()
 2. The server sends an 'ACK' letting the client know it is ready for a login password
 3. The client has exactly two seconds to response with their password and a new line.
 4. If the login passes, the server responds with 'READY' but if the password auth fails then the server responds with 'FAIL'
 
 */


/// A socket server to provide live updates on messaging, sort of.
@available(OSX 10.15, *)
public class SocketServer {
    
    public var onEvent: ((ServerEvent) -> Void)?
    private var listener: NWListener!
    private var connections: [Int: ServerConnection] = [:]
    private let messageQueue = DispatchQueue(label: "com.TalenFisher.MessageProxy.SocketServerQueue", attributes: [])
    
    deinit {
        self.listener?.stateUpdateHandler = nil
        self.listener?.newConnectionHandler = nil
        self.listener?.cancel()
        
        for connection in self.connections.values {
            connection.didStopCallback = nil
            connection.stop()
        }
    }
    
    public init() {
        let parameters = NWParameters(tls: nil)
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        
        listener = try! NWListener(using: parameters, on: 8736)
        listener.stateUpdateHandler = self.stateChanged(to:)
        listener.newConnectionHandler = self.accept(connection:)
        listener.start(queue: .main)
    }
    
    func stateChanged(to state: NWListener.State) {
        switch state {
            case .failed(let error):
                print("Server failure, error: \(error.localizedDescription)")
                exit(EXIT_FAILURE)
            default:
                break
        }
    }
    
    private func accept(connection: NWConnection) {
        let connection = ServerConnection(nwConnection: connection)
        connections[connection.id] = connection
        
        connection.start()
        
        connection.didStopCallback = { err in
            if let err = err {
                print(err)
            }
            self.connectionEnded(connection)
        }
    }
    
    private func connectionEnded(_ connection: ServerConnection) {
        self.connections.removeValue(forKey: connection.id)
    }
    
    public func broadcast(message: String) {
        let messageData = message.data(using: .utf8)
        
        if messageData == nil {
            return
        }
        
        self.messageQueue.sync { [unowned self] in
            for connection in self.connections.values {
                connection.send(data: messageData!)
            }
        }
    }
}

class ServerConnection {
    private static var nextID: Int = 0
    let connection: NWConnection
    let id: Int

    init(nwConnection: NWConnection) {
        connection = nwConnection
        id = ServerConnection.nextID
        ServerConnection.nextID += 1
    }
    
    deinit {
        print("deinit")
    }

    var didStopCallback: ((Error?) -> Void)? = nil
    var didReceive: ((Data) -> ())? = nil

    func start() {
        print("connection \(id) will start")
        connection.stateUpdateHandler = self.stateDidChange(to:)
        connection.start(queue: .main)
    }

    private func stateDidChange(to state: NWConnection.State) {
        switch state {
        case .waiting(let error):
            connectionDidFail(error: error)
        case .failed(let error):
            connectionDidFail(error: error)
        default:
            break
        }
    }


    func send(data: Data, opcode: NWProtocolWebSocket.Opcode = .text) {
        let metaData = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext (identifier: "context", metadata: [metaData])
        self.connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed( { error in
            if let error = error {
                self.connectionDidFail(error: error)
                return
            }
        }))
    }

    func stop() {
        print("connection \(id) stopped")
    }

    private func connectionDidFail(error: Error) {
        print("connection \(id) error: \(error)")
        stop(error: error)
    }

    private func connectionDidEnd() {
        print("connection \(id) ending")
        stop(error: nil)
    }

    private func stop(error: Error?) {
        connection.stateUpdateHandler = nil
        connection.cancel()
        if let didStopCallback = didStopCallback {
            self.didStopCallback = nil
            didStopCallback(error)
        }
    }
}
