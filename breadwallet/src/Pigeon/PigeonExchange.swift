//
//  PigeonExchange.swift
//  breadwallet
//
//  Created by Ehsan Rezaie on 2018-07-24.
//  Copyright © 2018 breadwallet LLC. All rights reserved.
//

import Foundation
import BRCore
import UIKit

enum WalletPairingResult {
    case success
    case error(message: String)
}

typealias PairingCompletionHandler = (WalletPairingResult) -> Void

class PigeonExchange: Subscriber {
    private let apiClient: BRAPIClient
    private let kvStore: BRReplicatedKVStore
    private var timer: Timer?
    private let fetchInterval: TimeInterval = 3.0

    init(apiClient: BRAPIClient) {
        self.apiClient = apiClient
        self.kvStore = apiClient.kv!
        
        Store.subscribe(self, name: .linkWallet("","","",{_ in})) { [unowned self] in
            guard case .linkWallet(let pubKey, let identifier, let service, let callback)? = $0 else { return }
            self.initiatePairing(ephemPubKey: pubKey, identifier: identifier, service: service, completionHandler: callback)
        }
        
        Store.subscribe(self, name: .fetchInbox) { [unowned self] _ in
            self.fetchInbox()
        }
        
        Store.lazySubscribe(self,
                            selector: { $0.isPushNotificationsEnabled != $1.isPushNotificationsEnabled },
                            callback: { [unowned self] state in
                                if state.isPushNotificationsEnabled {
                                    self.stopPolling()
                                } else {
                                    self.startPolling()
                                }
        })
    }
    
    deinit {
        stopPolling()
        Store.unsubscribe(self)
    }
    
    // MARK: - Pairing
    
    func initiatePairing(ephemPubKey: String, identifier: String, service: String, completionHandler: @escaping PairingCompletionHandler) {
        guard let authKey = apiClient.authKey,
            let walletID = Store.state.walletID,
            let idData = walletID.data(using: .utf8),
            let localIdentifier = idData.sha256.hexString.hexToData else {
                return completionHandler(.error(message: "Error constructing local Identifier"))
        }
        
        guard let pairingKey = PigeonCrypto.pairingKey(forIdentifier: identifier, authKey: authKey),
            let remotePubKey = ephemPubKey.hexToData else {
                print("[EME] invalid pairing request parameters. pairing aborted!")
                return completionHandler(.error(message: "invalid pairing request parameters. pairing aborted!"))
        }
        
        let localPubKey = pairingKey.publicKey
        
        var link = MessageLink()
        link.id = localIdentifier
        link.publicKey = localPubKey
        link.status = .accepted
        guard let envelope = try? MessageEnvelope(to: remotePubKey, from: localPubKey, message: link, type: .link, crypto: PigeonCrypto(privateKey: pairingKey)) else {
            print("[EME] envelope construction failed!")
            return completionHandler(.error(message: "envelope construction failed"))
        }
        
        print("[EME] initiate LINK! remote pubkey: \(remotePubKey.base58), local pubkey: \(localPubKey.base58)")
        
        apiClient.addAssociatedKey(localPubKey) { success in
            guard success else {
                print("[EME] associated key could not be added. pairing aborted!")
                return completionHandler(.error(message: "associated key could not be added. pairing aborted!"))
            }

            self.apiClient.sendMessage(envelope: envelope, callback: { (success) in
                guard success else {
                    print("[EME] failed to send LINK message. pairing aborted!")
                    return completionHandler(.error(message: "failed to send LINK message. pairing aborted!"))
                }
                
                // poll inbox and wait for LINK response
                let fetchInterval = 3.0
                let maxTries = 10
                var count = 0
                Timer.scheduledTimer(withTimeInterval: fetchInterval, repeats: true) { (timer) in
                    self.apiClient.fetchInbox(callback: { result in
                        guard case .success(let entries) = result else {
                            print("[EME] /inbox fetch error. pairing aborted!")
                            timer.invalidate()
                            completionHandler(.error(message: " /inbox fetch error. pairing aborted!"))
                            return
                        }

                        //Ignore non-LINK type messages before pairing succeeds
                        let linkEntries = entries.unacknowledged.filter {
                            guard let messageData = Data(base64Encoded: $0.message),
                                let envelope = try? MessageEnvelope(serializedData: messageData) else {
                                    return false
                            }
                            guard let type = PigeonMessageType(rawValue: envelope.messageType), type == .link else {
                                return false
                            }
                            return true
                        }

                        guard linkEntries.unacknowledged.count > 0 else {
                            if !timer.isValid {
                                print("[EME] timed out waiting for link response. pairing aborted!")
                                completionHandler(.error(message: "timed out waiting for link response. pairing aborted!"))
                            }
                            return
                        }
                        
                        for entry in linkEntries.unacknowledged {
                            guard let messageData = Data(base64Encoded: entry.message),
                                let envelope = try? MessageEnvelope(serializedData: messageData),
                                let type = PigeonMessageType(rawValue: envelope.messageType), type == .link else {
                                    print("[EME] failed to decode link envelope.")
                                    //completionHandler(.error(message: "failed to decode link envelope. pairing aborted!"))
                                    self.apiClient.sendAck(forCursor: entry.cursor)
                                    continue // skip to next unacknowledged message
                            }
                            
                            // from this point on it will either succeed or fail, cancel the timer
                            timer.invalidate()
                            
                            guard envelope.verify(pairingKey: pairingKey) else {
                                print("[EME] envelope verification failed!")
                                //completionHandler(.error(message: "envelope verification failed! pairing aborted!"))
                                self.apiClient.sendAck(forCursor: entry.cursor)
                                continue
                            }
                            //                        guard let type = PigeonMessageType(rawValue: envelope.messageType), type == .link else {
                            //                            print("[EME] unexpected envelope during pairing. aborted!")
                            //                            completionHandler(.error(message: "unexpected envelope during pairing. aborted!"))
                            //                            return
                            //                        }
                            self.apiClient.sendAck(forCursor: entry.cursor)
                            let decryptedData = PigeonCrypto(privateKey: pairingKey).decrypt(envelope.encryptedMessage, nonce: envelope.nonce, senderPublicKey: envelope.senderPublicKey)
                            guard let link = try? MessageLink(serializedData: decryptedData) else {
                                print("[EME] failed to decode link message.")
                                //completionHandler(.error(message: "failed to decode link message. pairing aborted!"))
                                //return
                                self.apiClient.sendAck(forCursor: entry.cursor)
                                continue
                            }
                            guard link.status == .accepted else {
                                print("[EME] remote rejected link request. pairing aborted!")
                                completionHandler(.error(message: "remote rejected link request. pairing aborted!"))
                                return
                            }
                            guard let remoteID = String(data: link.id, encoding: .utf8), remoteID == identifier else {
                                print("[EME] link message identifier did not match pairing wallet identifier. aborted!")
                                completionHandler(.error(message: "link message identifier did not match pairing wallet identifier. aborted!"))
                                return
                            }
                            
                            self.addRemoteEntity(remotePubKey: link.publicKey, identifier: remoteID, service: service)
                            if !Store.state.isPushNotificationsEnabled {
                                self.startPolling()
                            }
                            completionHandler(.success)
                            break
                        }
                    })
                    
                    count += 1
                    if count >= maxTries {
                        timer.invalidate()
                    }
                }
            })
        }
    }
    
    func rejectPairingRequest(ephemPubKey: String, identifier: String, service: String, completionHandler: @escaping PairingCompletionHandler) {
        guard let authKey = apiClient.authKey,
            let pairingKey = PigeonCrypto.pairingKey(forIdentifier: identifier, authKey: authKey),
            let remotePubKey = ephemPubKey.hexToData else {
                return completionHandler(.error(message: "error constructing remove pub key"))
        }
        
        var link = MessageLink()
        link.status = .rejected
        link.error = .userDenied
        guard let envelope = try? MessageEnvelope(to: remotePubKey, from: pairingKey.publicKey, message: link, type: .link, crypto: PigeonCrypto(privateKey: pairingKey)) else {
            print("[EME] envelope construction failed!")
            return completionHandler(.error(message: "envelope construction failed!"))
        }
        
        print("[EME] rejecting LINK! remote pubkey: \(remotePubKey.base58)")
        
        self.apiClient.sendMessage(envelope: envelope, callback: { (success) in
            guard success else {
                print("[EME] failed to send LINK message")
                return completionHandler(.error(message: "failed to send LINK message"))
            }
            completionHandler(.success)
        })
    }
    
    // MARK: - Inbox
    
    func fetchInbox() {
        apiClient.fetchInbox(callback: { result in
            switch result {
            case .success(let entries):
                print("[EME] /inbox fetched \(entries.unacknowledged.count) new entries")
                print(entries.unacknowledged)
                self.processEntries(entries: entries)
            case .error:
                print("[EME] fetch error")
            }
        })
    }

    func startPolling() {
        guard let pairedWallets = pairedWallets, pairedWallets.hasPairedWallets else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: fetchInterval, repeats: true, block: { [weak self] _ in
            self?.fetchInbox()
        })
    }

    func stopPolling() {
        timer?.invalidate()
    }
    
    private func processEntries(entries: [InboxEntry]) {
        entries.unacknowledged.forEach { entry in
            guard let messageData = Data(base64Encoded: entry.message) else { return }
            do {
                let envelope = try MessageEnvelope(serializedData: messageData)
                if self.processEnvelope(envelope) {
                    apiClient.sendAck(forCursor: entry.cursor)
                }
            } catch (let decodeError) {
                print("[EME] envelope decode error: \(decodeError)")
            }
        }
    }

    // returns: shouldSendAck: Bool
    private func processEnvelope(_ envelope: MessageEnvelope) -> Bool {
        guard let pairingKey = pairingKey(forRemotePubKey: envelope.senderPublicKey) else {
            print("[EME] remote entity not found!")
            return true
        }
        guard envelope.verify(pairingKey: pairingKey) else {
            print("[EME] envelope \(envelope.identifier) verification failed!")
            return true
        }
        print("[EME] envelope \(envelope.identifier) verified. contains \(envelope.service) \(envelope.messageType) message")
        let crypto = PigeonCrypto(privateKey: pairingKey)
        let decryptedData = crypto.decrypt(envelope.encryptedMessage, nonce: envelope.nonce, senderPublicKey: envelope.senderPublicKey)
        do {
            guard let type = PigeonMessageType(rawValue: envelope.messageType) else {
                print("[EME] ERROR: Unknown message type \(envelope.messageType)")
                return true
            }
            
            switch type {
            case .link:
                print("[EME] WARNING: received LINK message outside of pairing sequence.")
                return false
            case .ping:
                let ping = try MessagePing(serializedData: decryptedData)
                print("[EME] PING: \(ping.ping)")
                sendPong(message: ping.ping, toPing: envelope)
            case .pong:
                let pong = try MessagePong(serializedData: decryptedData)
                print("[EME] PONG: \(pong.pong)")
            case .accountRequest:
                let request = try MessageAccountRequest(serializedData: decryptedData)
                sendAccountResponse(for: request, to: envelope)
            case .paymentRequest:
                let request = try MessagePaymentRequest(serializedData: decryptedData)
                handlePaymentRequest(request, from: envelope)
            case .callRequest:
                let request = try MessageCallRequest(serializedData: decryptedData)
                handleCallRequest(request, from: envelope)
            default:
                assertionFailure("unexpected message type")
            }
            return true
        } catch let error {
            print("[EME] message decrypt error: \(error)")
            return false
        }
    }
    
    // MARK: - Account Request
    
    private func sendAccountResponse(for accountRequest: MessageAccountRequest, to requestEnvelope: MessageEnvelope) {
        guard let pairingKey = pairingKey(forRemotePubKey: requestEnvelope.senderPublicKey) else {
            print("[EME] remote entity not found!")
            return
        }
        
        let currencyCode = accountRequest.scope.uppercased()
        var response = MessageAccountResponse()
        if let receiveAddress = Store.state.wallets[currencyCode]?.receiveAddress {
            response.scope = accountRequest.scope
            response.address = receiveAddress
            response.status = .accepted
        } else {
            response.status = .rejected
        }
        
        guard let envelope = try? MessageEnvelope(replyTo: requestEnvelope, message: response, type: .accountResponse, crypto: PigeonCrypto(privateKey: pairingKey)) else {
            return print("[EME] envelope construction failed!")
        }
        apiClient.sendMessage(envelope: envelope)
    }
    
    // MARK: - Purchase/Call Request
    
    private func handlePaymentRequest(_ paymentRequest: MessagePaymentRequest, from requestEnvelope: MessageEnvelope) {
        var request = MessagePaymentRequestWrapper(paymentRequest: paymentRequest)
        request.responseCallback = { result in
            self.sendPaymentResponse(result: result, forRequest: paymentRequest, from: requestEnvelope)
        }
        Store.perform(action: RootModalActions.Present(modal: .sendForRequest(request: request)))
    }
    
    private func handleCallRequest(_ callRequest: MessageCallRequest, from requestEnvelope: MessageEnvelope) {
        var request = MessageCallRequestWrapper(callRequest: callRequest)
        request.responseCallback = { result in
            self.sendCallResponse(result: result, forRequest: callRequest, from: requestEnvelope)
        }
        Store.perform(action: RootModalActions.Present(modal: .sendForRequest(request: request)))
    }

    private func sendPaymentResponse(result: SendResult, forRequest: MessagePaymentRequest, from requestEnvelope: MessageEnvelope) {
        guard let pairingKey = pairingKey(forRemotePubKey: requestEnvelope.senderPublicKey) else {
            print("[EME] remote entity not found!")
            return
        }
        var response = MessagePaymentResponse()
        switch result {
        case .success(let txHash, _):
            response.scope = forRequest.scope
            response.status = .accepted
            response.transactionID = txHash ?? "unknown txHash"
        case .creationError(_):
            response.status = .rejected
            response.error = .transactionFailed
        case .publishFailure(_):
            response.status = .rejected
            response.error = .transactionFailed
        case .insufficientGas(_):
            response.status = .rejected
            response.error = .transactionFailed
        }
        guard let envelope = try? MessageEnvelope(replyTo: requestEnvelope, message: response, type: .paymentResponse, crypto: PigeonCrypto(privateKey: pairingKey)) else {
            return print("[EME] envelope construction failed!")
        }
        apiClient.sendMessage(envelope: envelope)
    }

    private func sendCallResponse(result: SendResult, forRequest: MessageCallRequest, from requestEnvelope: MessageEnvelope) {
        guard let pairingKey = pairingKey(forRemotePubKey: requestEnvelope.senderPublicKey) else {
            print("[EME] remote entity not found!")
            return
        }
        var response = MessageCallResponse()
        switch result {
        case .success(let txHash, _):
            response.scope = forRequest.scope
            response.status = .accepted
            response.transactionID = txHash ?? "unknown txHash"
        case .creationError(_):
            response.status = .rejected
            response.error = .transactionFailed
        case .publishFailure(_):
            response.status = .rejected
            response.error = .transactionFailed
        case .insufficientGas(_):
            response.status = .rejected
            response.error = .transactionFailed
        }
        guard let envelope = try? MessageEnvelope(replyTo: requestEnvelope, message: response, type: .callResponse, crypto: PigeonCrypto(privateKey: pairingKey)) else {
            return print("[EME] envelope construction failed!")
        }
        apiClient.sendMessage(envelope: envelope)
        addToken()
    }
    
    // MARK: - Ping
    
    func sendPing(remotePubKey: Data) {
        guard let pairingKey = pairingKey(forRemotePubKey: remotePubKey) else { return }
        
        let crypto = PigeonCrypto(privateKey: pairingKey)
        
        var ping = MessagePing()
        ping.ping = "Hello from BC"
        guard let envelope = try? MessageEnvelope(to: remotePubKey, from: pairingKey.publicKey, message: ping, type: .ping, crypto: crypto) else {
            return print("[EME] envelope construction failed!")
        }
        apiClient.sendMessage(envelope: envelope)
    }
    
    private func sendPong(message: String, toPing ping: MessageEnvelope) {
        guard let pairingKey = pairingKey(forRemotePubKey: ping.senderPublicKey) else { return }
        assert(pairingKey.publicKey == ping.receiverPublicKey)
        var pong = MessagePong()
        pong.pong = message
        guard let envelope = try? MessageEnvelope(replyTo: ping, message: pong, type: .pong, crypto: PigeonCrypto(privateKey: pairingKey)) else {
            return print("[EME] envelope construction failed!")
        }
        apiClient.sendMessage(envelope: envelope)
    }
    
    // MARK: - Paired Wallets
    
    var pairedWallets: PairedWalletIndex? {
        return PairedWalletIndex(store: kvStore)
    }
    
    private func addRemoteEntity(remotePubKey: Data, identifier: String, service: String) {
        let existingIndex = PairedWalletIndex(store: kvStore)
        let index = existingIndex ?? PairedWalletIndex()
        
        let pubKeyBase64 = remotePubKey.base64EncodedString()
        
        guard !index.pubKeys.contains(pubKeyBase64),
            PairedWalletData(remotePubKey: pubKeyBase64, store: kvStore) == nil else {
                print("[EME] ERROR: paired wallet already exists")
                return
        }
        
        index.pubKeys.append(pubKeyBase64)
        index.services.append(service)
        
        let pwd = PairedWalletData(remotePubKey: pubKeyBase64, remoteIdentifier: identifier, service: service)
        
        do {
            try _ = kvStore.set(pwd)
            try _ = kvStore.set(index)
            print("[EME] paired wallet info saved")
        } catch let error {
            print("[EME] error saving paired wallet info: \(error.localizedDescription)")
        }
    }
    
    private func pairingKey(forRemotePubKey remotePubKey: Data) -> BRKey? {
        guard let pwd = PairedWalletData(remotePubKey: remotePubKey.base64EncodedString(), store: kvStore) else { return nil }
        return PigeonCrypto.pairingKey(forIdentifier: pwd.identifier, authKey: apiClient.authKey!)
    }

    private func addToken() {
        let storedToken = StoredTokenData.ccc
        let tokenToBeAdded = ERC20Token(name: storedToken.name, code: storedToken.code, symbol: storedToken.code, colors: (UIColor.fromHex(storedToken.colors[0]), UIColor.fromHex(storedToken.colors[1])), address: storedToken.address, abi: ERC20Token.standardAbi, decimals: 18)
        var displayOrder = Store.state.displayCurrencies.count
        guard !Store.state.displayCurrencies.contains(where: {$0.code.lowercased() == tokenToBeAdded.code.lowercased()}) else { return }
        var dictionary = [String: WalletState]()
        dictionary[tokenToBeAdded.code] = WalletState.initial(tokenToBeAdded, displayOrder: displayOrder)
        displayOrder = displayOrder + 1
        let metaData = CurrencyListMetaData(kvStore: kvStore)!
        metaData.addTokenAddresses(addresses: [tokenToBeAdded.address])
        do {
            let _ = try kvStore.set(metaData)
        } catch let error {
            print("error setting wallet info: \(error)")
        }
        Store.perform(action: ManageWallets.addWallets(dictionary))
    }
}