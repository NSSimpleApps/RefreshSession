//
//  ViewController.swift
//  RefreshSession
//
//  Created by NSSimpleApps on 14/10/2018.
//  Copyright © 2018 NSSimpleApps. All rights reserved.
//

import UIKit

public class Server {
    public enum Status: Int {
        case ok = 200
        case authRequred = 401
    }
    private var count = 0
    private var sessionId: String?
    private let accessQueue = DispatchQueue(label: "ns.simpleapps.Server")
    
    public func handleRequest(sessionId: String, completion: @escaping (Status) -> Void) {
        self.accessQueue.async {
            if let currentSessionId = self.sessionId, currentSessionId == sessionId, self.count < 10 {
                self.count += 1
                let random = arc4random_uniform(100)
                let delay = 3 * TimeInterval(random)/100
                DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: {
                    completion(.ok)
                })
            } else {
                DispatchQueue.global().async {
                    completion(.authRequred)
                }
            }
        }
    }
    public func auth(tag: Int, completion: @escaping (String) -> Void) {
        self.accessQueue.async {
            print("@@@@@@@@ AUTH", tag)
            self.count = 0
            let new = UUID().uuidString
            self.sessionId = new
            DispatchQueue.global().async {
                completion(new)
            }
        }
    }
}

public class SimpleOperation: Operation {
    public unowned let server: Server
    public let tag: Int
    public var sessionId: String
    
    public enum Status {
        case response(Server.Status)
        case timeOut
    }
    public var status: Status?
    private var semaphore: DispatchSemaphore?
    
    override final public func cancel() {
        self.completionBlock = nil
        super.cancel()
        self.semaphore?.signal()
        self.semaphore = nil
    }
    
    init(server: Server, tag: Int, sessionId: String) {
        self.server = server
        self.tag = tag
        self.sessionId = sessionId
        
        super.init()
    }
    
    override public func main() {
        let semaphore = DispatchSemaphore(value: 0)
        self.semaphore = semaphore
        self.server.handleRequest(sessionId: self.sessionId,
                                  completion: { [weak self] (status) in
                                    guard let sSelf = self, sSelf.isCancelled == false else { return }
                                    
                                    sSelf.status = .response(status)
                                    sSelf.semaphore?.signal()
                                    
        })
        
        switch semaphore.wait(timeout: .now() + 20) {
        case .success:
            break
        case .timedOut:
            self.status = .timeOut
        }
        self.semaphore = nil
    }
}

public class RefreshOperation: Operation {
    public unowned let server: Server
    public let tag: Int
    
    public var completion: ((RefreshOperation, String?) -> Void)?
    private var semaphore: DispatchSemaphore?
    
    override final public func cancel() {
        self.completion = nil
        super.cancel()
        self.semaphore?.signal()
        self.semaphore = nil
    }
    
    public init(server: Server, tag: Int) {
        self.server = server
        self.tag = tag
        
        super.init()
    }
    override public func main() {
        var result: String?
        let semaphore = DispatchSemaphore(value: 0)
        self.semaphore = semaphore
        self.server.auth(tag: self.tag, completion: { [weak self] newSessionId in
            guard let sSelf = self, sSelf.isCancelled == false else { return }
            result = newSessionId
            sSelf.semaphore?.signal()
        })
        _ = semaphore.wait(timeout: .now() + 20)
        self.semaphore = nil
        self.completion?(self, result)
    }
}


public class Client {
    public let server = Server()
    private let operationQueue = OperationQueue()
    private let refreshQueue = OperationQueue()
    private let accessQueue = DispatchQueue(label: "ns.simpleapps.Client")
    
    public var sessionId = ""
    
    public init() {
        self.refreshQueue.maxConcurrentOperationCount = 1
    }
    public struct DelayedTask {
        public let tag: Int
        public let completion: (String) -> Void
        public let errorBlock: (Error) -> Void
    }
    private var pool: [DelayedTask] = []
    
    private func createSimpleOperation(tag: Int,
                                       completion: @escaping (String) -> Void,
                                       errorBlock: @escaping (Error) -> Void) -> SimpleOperation {
        let simpleOperation = SimpleOperation(server: self.server, tag: tag, sessionId: self.sessionId)
        simpleOperation.completionBlock = { [unowned simpleOperation] in
            let tag = simpleOperation.tag
            let sessionId = simpleOperation.sessionId
            switch simpleOperation.status {
            case .response(let status)?:
                switch status {
                case .authRequred:
                    let server = simpleOperation.server
                    self.accessQueue.async {
                        if let refreshingOperation = self.refreshQueue.operations.first {
                            if refreshingOperation.isExecuting {
                                self.pool.append(DelayedTask(tag: tag, completion: completion, errorBlock: errorBlock))
                            } else {
                                let retrySimpleOperation = self.createSimpleOperation(tag: tag, completion: completion, errorBlock: errorBlock)
                                self.operationQueue.addOperation(retrySimpleOperation)
                            }
                        } else if sessionId != self.sessionId {
                            let retrySimpleOperation = self.createSimpleOperation(tag: tag, completion: completion, errorBlock: errorBlock)
                            self.operationQueue.addOperation(retrySimpleOperation)
                            
                        } else {
                            let refreshOperation = RefreshOperation(server: server, tag: tag)
                            refreshOperation.completion = { refresh, newSessionId in
                                if let newSessionId = newSessionId {
                                    self.accessQueue.sync {
                                        self.sessionId = newSessionId
                                        let pool = self.pool
                                        self.pool.removeAll()
                                        let operations = pool.map({ (item) -> SimpleOperation in
                                            return self.createSimpleOperation(tag: item.tag,
                                                                              completion: item.completion,
                                                                              errorBlock: item.errorBlock)
                                        })
                                        self.operationQueue.addOperations(operations, waitUntilFinished: false)
                                    }
                                } else {
                                    self.pool.removeAll()
                                    self.operationQueue.cancelAllOperations()
                                    self.refreshQueue.cancelAllOperations()
                                }
                            }
                            self.pool.append(DelayedTask(tag: tag, completion: completion, errorBlock: errorBlock))
                            self.operationQueue.operations.forEach({ (op) in
                                op.addDependency(refreshOperation)
                            })
                            self.refreshQueue.addOperation(refreshOperation)
                        }
                    }
                case .ok:
                    completion("OK \(tag) " + sessionId)
                }
            case .timeOut?:
                errorBlock(NSError(domain: "AAA", code: -1, userInfo: [NSLocalizedDescriptionKey: "Timeout."]))
            case .none:
                break
            }
        }
        return simpleOperation
    }
    
    public func sendRequest(tag: Int, completion: @escaping (String) -> Void, errorBlock: @escaping (Error) -> Void) {
        self.accessQueue.async {
            let simpleOperation = self.createSimpleOperation(tag: tag, completion: completion, errorBlock: errorBlock)
            
            if let refreshingOperation = self.refreshQueue.operations.first {
                simpleOperation.addDependency(refreshingOperation)
            }
            self.operationQueue.addOperation(simpleOperation)
        }
    }
    public func refreshToken(completion: @escaping (String?) -> Void) {
        self.accessQueue.async {
            let refreshOperation = RefreshOperation(server: self.server, tag: -1)
            if let refreshingOperation = self.refreshQueue.operations.first(where: { $0.isExecuting }) {
                refreshOperation.addDependency(refreshingOperation)
            }
            refreshOperation.completion = { refresh, newSessionId in
                if let token = newSessionId {
                    self.sessionId = token
                }
                completion(newSessionId)
            }
            self.refreshQueue.addOperation(refreshOperation)
        }
    }
}

class ViewController: UIViewController {
    let client = Client()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .white
        
        let runButton = UIButton(type: .system)
        runButton.setTitle("RUN", for: .normal)
        runButton.addTarget(self, action: #selector(self.sendRequestAction(_:)), for: .touchUpInside)
        runButton.translatesAutoresizingMaskIntoConstraints = false
        
        self.view.addSubview(runButton)
        
        runButton.centerXAnchor.constraint(equalTo: self.view.centerXAnchor).isActive = true
        runButton.centerYAnchor.constraint(equalTo: self.view.centerYAnchor).isActive = true
        
        let refreshButton = UIButton(type: .system)
        refreshButton.setTitle("REFRESH", for: .normal)
        refreshButton.addTarget(self, action: #selector(self.refreshTokenAction(_:)), for: .touchUpInside)
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        
        self.view.addSubview(refreshButton)
        
        refreshButton.centerXAnchor.constraint(equalTo: runButton.centerXAnchor).isActive = true
        refreshButton.topAnchor.constraint(equalTo: runButton.bottomAnchor, constant: 10).isActive = true
    }
    
    @objc func refreshTokenAction(_ sender: UIButton) {
        self.client.refreshToken(completion: { (token) in
            print("%%%%%%%%%", token)
        })
    }
    
    @objc func sendRequestAction(_ sender: UIButton) {
        for i in 0..<15 {
            self.client.sendRequest(tag: i,
                                    completion: { (result) in
                                        print(#function, result, i)
            },
                                    errorBlock: { error in
                                        print(#function, i, error)
            })
        }
    }
}

