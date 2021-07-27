//
//  SolanaSDK+Swap.swift
//  SolanaSwift
//
//  Created by Chung Tran on 21/01/2021.
//

import Foundation
import RxSwift

extension SolanaSDK {
    public struct SwapResponse {
        public let transactionId: String
        public let newWalletPubkey: String?
    }
    
    struct AccountInstructions {
        let account: PublicKey
        let instructions: [TransactionInstruction]
        let cleanupInstructions: [TransactionInstruction]
        let signers: [Account]
        
        // additionally return new wallet address
        internal private(set) var newWalletPubkey: String?
        
        // additionally return newAccount's secretkey
        internal private(set) var secretKey: Data?
    }
    
    public func swap(
        account: Account? = nil,
        pool: Pool? = nil,
        source: PublicKey,
        sourceMint: PublicKey,
        destination: PublicKey? = nil,
        destinationMint: PublicKey,
        slippage: Double,
        amount: UInt64,
        isSimulation: Bool = false,
        customProxy: SolanaCustomFeeRelayerProxy? = nil
    ) -> Single<SwapResponse> {
        // verify account
        guard let owner = account ?? accountStorage.account
        else {return .error(Error.unauthorized)}
        
        // reveal proxy (proxy now support only spl token, disable it when source or destination is native sol)
        var proxy = customProxy
        if source == owner.publicKey || destination == owner.publicKey
        {
            proxy = nil // disable proxy
        }
        
        // get payer
        let getFeePayerRequest: Single<PublicKey>
        if let proxy = proxy {
            getFeePayerRequest = proxy.getFeePayer().map {try PublicKey(string: $0)}
        } else {
            getFeePayerRequest = .just(owner.publicKey)
        }
        
        // get pool
        let getPoolRequest: Single<Pool>
        if let pool = pool,
           pool.swapData.mintA == sourceMint,
           pool.swapData.mintB == destinationMint
        {
            getPoolRequest = .just(pool)
        } else {
            getPoolRequest = getMatchedPool(
                sourceMint: sourceMint,
                destinationMint: destinationMint
            )
        }
        
        // request
        return Single.zip(
            getPoolRequest
                // retrieve pool balance if not exists
                .flatMap {self.getPoolWithTokenBalances(pool: $0)},
            getFeePayerRequest
        )
            .observe(on: ConcurrentDispatchQueueScheduler(qos: .userInteractive))
            .flatMap { pool, feePayer in
                Single.zip(
                    .just(pool),
                    
                    self.prepareSourceAccountAndInstructions(
                        pool: pool,
                        source: source,
                        amount: amount,
                        feePayer: feePayer
                    ),
                    
                    self.prepareDestinationAccountAndInstructions(
                        myAccount: owner.publicKey,
                        destination: destination,
                        destinationMint: destinationMint,
                        feePayer: feePayer
                    ),
                    
                    .just(feePayer)
                )
            }
            .observe(on: ConcurrentDispatchQueueScheduler(qos: .userInteractive))
            .flatMap { pool, sourceAccountInstructions, destinationAccountInstructions, feePayer in
                // form instructions
                var instructions = [TransactionInstruction]()
                var cleanupInstructions = [TransactionInstruction]()
                
                // create userTransferAuthority
                let userTransferAuthority = try Account(network: self.endpoint.network)
                
                // source
                instructions.append(contentsOf: sourceAccountInstructions.instructions)
                cleanupInstructions.append(contentsOf: sourceAccountInstructions.cleanupInstructions)
                
                // destination
                instructions.append(contentsOf: destinationAccountInstructions.instructions)
                cleanupInstructions.append(contentsOf: destinationAccountInstructions.cleanupInstructions)
                let newWalletPubkey = destinationAccountInstructions.newWalletPubkey
                
                // approve (if send without proxy)
                if proxy == nil {
                    let approveTransaction = TokenProgram.approveInstruction(
                        tokenProgramId: .tokenProgramId,
                        account: source,
                        delegate: userTransferAuthority.publicKey,
                        owner: owner.publicKey,
                        amount: amount
                    )
                    instructions.append(approveTransaction)
                }
                
                // swap
                let swapInstruction = try self.swapInstruction(
                    pool: pool,
                    source: sourceAccountInstructions.account,
                    destination: destinationAccountInstructions.account,
                    userTransferAuthority: proxy == nil ? userTransferAuthority.publicKey: owner.publicKey,
                    amount: amount,
                    slippage: slippage
                )
                
                instructions.append(swapInstruction)
                
                // prepare send request
                let request: Single<TransactionID>
                
                // send to proxy
                if let proxy = proxy {
                    request = self.swapProxySendTransaction(
                        proxy: proxy,
                        owner: owner.publicKey,
                        feePayer: feePayer,
                        pool: pool,
                        source: source,
                        destination: destination ?? owner.publicKey,
                        amount: amount,
                        destinationAccountInstructions: destinationAccountInstructions,
                        slippage: slippage,
                        instructions: instructions,
                        cleanupInstructions: cleanupInstructions
                    )
                }
                
                // send without proxy
                else {
                    var signers = [owner, userTransferAuthority]
                    signers.append(contentsOf: sourceAccountInstructions.signers)
                    signers.append(contentsOf: destinationAccountInstructions.signers)
                    
                    request = self.serializeAndSendWithFee(
                        instructions: instructions + cleanupInstructions,
                        signers: signers,
                        isSimulation: isSimulation
                    )
                }
                return request
                    .map {.init(transactionId: $0, newWalletPubkey: newWalletPubkey)}
            }
    }
    
    // MARK: - Get pools
    func getMatchedPool(
        sourceMint: PublicKey,
        destinationMint: PublicKey
    ) -> Single<Pool> {
        getSwapPools()
            .map {pools -> Pool in
                // filter pool that match requirement
                if let matchPool = pools.matchedPool(
                    sourceMint: sourceMint.base58EncodedString,
                    destinationMint: destinationMint.base58EncodedString
                ) {
                    return matchPool
                }
                throw Error.other("Unsupported swapping tokens")
            }
    }
    
    // MARK: - Account and instructions
    func prepareSourceAccountAndInstructions(
        pool: Pool,
        source: PublicKey,
        amount: Lamports,
        feePayer: PublicKey
    ) -> Single<AccountInstructions> {
        getAccountInfo(
            account: pool.swapData.tokenAccountA.base58EncodedString,
            decodedTo: AccountInfo.self
        )
            .observe(on: ConcurrentDispatchQueueScheduler(qos: .userInteractive))
            // check if source token is native
            .map { info -> Bool in
                guard info.owner == PublicKey.tokenProgramId.base58EncodedString,
                      let isNative = info.data.value?.isNative
                else {
                    throw Error.other("Source account is not valid")
                }
                
                return isNative
            }
            // create token if source token is native
            .flatMap {isNative in
                // if token is non-native
                if !isNative {
                    return .just(.init(
                        account: source,
                        instructions: [],
                        cleanupInstructions: [],
                        signers: []
                    ))
                }
                
                // if token is native
                return self.prepareForCreatingTempAccountAndClose(
                    from: source,
                    amount: amount,
                    payer: feePayer
                )
            }
    }
    
    func prepareDestinationAccountAndInstructions(
        myAccount: PublicKey,
        destination: PublicKey?,
        destinationMint: PublicKey,
        feePayer: PublicKey
    ) -> Single<AccountInstructions> {
        // if destination is a registered non-native token account
        if let destination = destination, destination != myAccount
        {
            return .just(
                .init(
                    account: destination,
                    instructions: [],
                    cleanupInstructions: [],
                    signers: []
                )
            )
        }
        
        // if destination is a native account or is nil
        return prepareForCreatingAssociatedTokenAccountAndCloseIfNative(
            owner: myAccount,
            mint: destinationMint,
            feePayer: feePayer
        )
    }
    
    // MARK: - Helpers
    private func prepareForCreatingTempAccountAndClose(
        from source: PublicKey,
        amount: Lamports,
        payer: PublicKey
    ) -> Single<AccountInstructions> {
        getMinimumBalanceForRentExemption(
            dataLength: UInt64(AccountInfo.BUFFER_LENGTH)
        )
            .observe(on: ConcurrentDispatchQueueScheduler(qos: .userInteractive))
            .map { minimumBalanceForRentExemption in
                // create new account
                let newAccount = try Account(network: self.endpoint.network)
                
                return .init(
                    account: newAccount.publicKey,
                    instructions: [
                        SystemProgram.createAccountInstruction(
                            from: source,
                            toNewPubkey: newAccount.publicKey,
                            lamports: amount + minimumBalanceForRentExemption
                        ),
                        TokenProgram.initializeAccountInstruction(
                            account: newAccount.publicKey,
                            mint: .wrappedSOLMint,
                            owner: payer
                        )
                    ],
                    cleanupInstructions: [
                        TokenProgram.closeAccountInstruction(
                            account: newAccount.publicKey,
                            destination: payer,
                            owner: payer
                        )
                    ],
                    signers: [
                        newAccount
                    ],
                    secretKey: newAccount.secretKey
                )
            }
    }
    
    private func prepareForCreatingAssociatedTokenAccountAndCloseIfNative(
        owner: PublicKey,
        mint: PublicKey,
        feePayer: PublicKey
    ) -> Single<AccountInstructions> {
        do {
            let associatedAddress = try PublicKey.associatedTokenAddress(
                walletAddress: owner,
                tokenMintAddress: mint
            )
            
            return getAccountInfo(
                account: associatedAddress.base58EncodedString,
                decodedTo: AccountInfo.self
            )
                .observe(on: ConcurrentDispatchQueueScheduler(qos: .userInteractive))
                // check if associated address is registered
                .map { info -> Bool in
                    if info.owner == PublicKey.tokenProgramId.base58EncodedString,
                       info.data.value?.owner == owner
                    {
                        return true
                    }
                    throw Error.other("Associated token account is belong to another user")
                }
                .catch { error in
                    // associated address is not available
                    if let error = error as? Error,
                       error == Error.other("Could not retrieve account info")
                    {
                        return .just(false)
                    }
                    throw error
                }
                .map {isRegistered -> AccountInstructions in
                    // cleanup intructions
                    var cleanupInstructions = [TransactionInstruction]()
                    if mint == .wrappedSOLMint {
                        cleanupInstructions = [
                            TokenProgram.closeAccountInstruction(
                                account: associatedAddress,
                                destination: owner,
                                owner: owner
                            )
                        ]
                    }
                    
                    // if associated address is registered, there is no need to creating it again
                    if isRegistered {
                        return .init(
                            account: associatedAddress,
                            instructions: [],
                            cleanupInstructions: cleanupInstructions,
                            signers: []
                        )
                    }
                    
                    // create associated address
                    return .init(
                        account: associatedAddress,
                        instructions: [
                            AssociatedTokenProgram
                                .createAssociatedTokenAccountInstruction(
                                    mint: mint,
                                    associatedAccount: associatedAddress,
                                    owner: owner,
                                    payer: feePayer
                                )
                        ],
                        cleanupInstructions: cleanupInstructions,
                        signers: [],
                        newWalletPubkey: associatedAddress.base58EncodedString
                    )
                }
        } catch {
            return .error(error)
        }
    }
    
    private func swapInstruction(
        pool: Pool,
        source: PublicKey,
        destination: PublicKey,
        userTransferAuthority: PublicKey,
        amount: Lamports,
        slippage: Double
    ) throws -> TransactionInstruction {
        // pool validation
        guard let poolAuthority = pool.authority,
              let minAmountOut = pool.minimumReceiveAmount(fromInputAmount: amount, slippage: slippage, includesFees: true)
        else { throw Error.other("Swap pool is not valid") }
        
        return TokenSwapProgram.swapInstruction(
            tokenSwap: pool.address,
            authority: poolAuthority,
            userTransferAuthority: userTransferAuthority,
            userSource: source,
            poolSource: pool.swapData.tokenAccountA,
            poolDestination: pool.swapData.tokenAccountB,
            userDestination: destination,
            poolMint: pool.swapData.tokenPool,
            feeAccount: pool.swapData.feeAccount,
            hostFeeAccount: nil,
            swapProgramId: self.endpoint.network.swapProgramId,
            tokenProgramId: .tokenProgramId,
            amountIn: amount,
            minimumAmountOut: minAmountOut
        )
    }
    
    private func swapProxySendTransaction(
        proxy: SolanaCustomFeeRelayerProxy,
        owner: PublicKey,
        feePayer: PublicKey,
        pool: Pool,
        source: PublicKey,
        destination: PublicKey,
        amount: Lamports,
        destinationAccountInstructions: AccountInstructions,
        slippage: Double,
        instructions: [TransactionInstruction],
        cleanupInstructions: [TransactionInstruction]
    ) -> Single<TransactionID> {
        // create feepayer wsol account
        let getFeePayerWsolAccount = prepareForCreatingTempAccountAndClose(
            from: feePayer,
            amount: 0,
            payer: feePayer
        )
        
        // get compensation pool
        let getCompensationPool = getMatchedPool(
            sourceMint: .wrappedSOLMint,
            destinationMint: pool.swapData.mintA
        )
            .flatMap {self.getPoolWithTokenBalances(pool: $0)}
        
        // get fee payer and compensation pool
        return Single.zip(
            getFeePayerWsolAccount,
            getCompensationPool
        )
            .observe(on: ConcurrentDispatchQueueScheduler(qos: .userInteractive))
            .flatMap { feePayerWsolAccountAndInstructions, feeCompensationPool -> Single<([Account], AccountInstructions, Pool, Lamports, String)> in
                // form signer
                let signers = feePayerWsolAccountAndInstructions.signers
                
                // fee per signature
                let signatureFeesRequest: Single<Lamports>
                if signers.isEmpty {
                    signatureFeesRequest = .just(0)
                } else {
                    signatureFeesRequest = self.getFees(commitment: nil)
                        .map {$0.feeCalculator?.lamportsPerSignature ?? 0}
                        .map {$0 * Lamports(signers.count + 2)} // +1 for fee relayer, +1 for userAuthority
                }
                
                // fee per account creation
                let creationFeeRequest: Single<Lamports>
                if destinationAccountInstructions.instructions.isEmpty {
                    creationFeeRequest = .just(0)
                } else {
                    creationFeeRequest = self.getMinimumBalanceForRentExemption(
                        dataLength: UInt64(AccountInfo.BUFFER_LENGTH)
                    )
                }
                
                // total fee
                return Single.zip(
                    signatureFeesRequest,
                    creationFeeRequest,
                    self.getRecentBlockhash()
                )
                    .map {($0 + $1, $2)}
                    .map {(signers, feePayerWsolAccountAndInstructions, feeCompensationPool, $0, $1)}
            }
            .observe(on: ConcurrentDispatchQueueScheduler(qos: .userInteractive))
            .flatMap {(signers, feePayerWsolAccountAndInstructions, feeCompensationPool, feeAmount, recentBlockhash) -> Single<TransactionID> in
                // instructions
                var instructions = instructions
                instructions.append(contentsOf: feePayerWsolAccountAndInstructions.instructions)
                
                instructions.append(
                    try self.swapInstruction(
                        pool: feeCompensationPool,
                        source: source,
                        destination: destinationAccountInstructions.account,
                        userTransferAuthority: owner,
                        amount: feeAmount,
                        slippage: 1
                    )
                )
                
                // clean up instructions
                var cleanupInstructions = cleanupInstructions
                cleanupInstructions.append(contentsOf: feePayerWsolAccountAndInstructions.cleanupInstructions)
                
                let signature = try self.getSignatureForProxy(
                    feePayer: feePayer.base58EncodedString,
                    instructions: instructions + cleanupInstructions,
                    recentBlockhash: recentBlockhash
                )
                
                guard let feePayerSecretKey = feePayerWsolAccountAndInstructions.secretKey?.bytes
                else {
                    throw Error.other("Could not create fee payer account")
                }
                
                guard let minAmountOut = pool.minimumReceiveAmount(fromInputAmount: amount, slippage: slippage, includesFees: true),
                      let minFeeAmountOut = feeCompensationPool.minimumReceiveAmount(fromInputAmount: feeAmount, slippage: 0.01, includesFees: true)
                else {
                    throw Error.other("Swap pool is not valid")
                }
                
                return proxy.swapToken(
                    sourceToken: source.base58EncodedString,
                    destinationToken: destination.base58EncodedString,
                    sourceTokenMint: pool.swapData.mintA.base58EncodedString,
                    destinationTokenMint: pool.swapData.mintB.base58EncodedString,
                    userAuthority: owner.base58EncodedString,
                    pool: pool,
                    amount: amount,
                    minAmountOut: minAmountOut,
                    feeCompensationPool: feeCompensationPool,
                    feeAmount: feeAmount,
                    feeMinAmountOut: minFeeAmountOut,
                    feePayerWSOLAccountKeypair: Base58.encode(feePayerSecretKey),
                    signature: signature,
                    blockhash: recentBlockhash
                )
            }
        
    }
    
//    private func createAccountByMint(
//        owner: PublicKey,
//        mint: PublicKey,
//        instructions: inout [TransactionInstruction],
//        cleanupInstructions: inout [TransactionInstruction],
//        signers: inout [Account],
//        minimumBalanceForRentExemption: UInt64
//    ) throws -> Account {
//        let newAccount = try Account(network: endpoint.network)
//
//        instructions.append(
//            SystemProgram.createAccountInstruction(
//                from: owner,
//                toNewPubkey: newAccount.publicKey,
//                lamports: minimumBalanceForRentExemption
//            )
//        )
//
//        instructions.append(
//            TokenProgram.initializeAccountInstruction(
//                account: newAccount.publicKey,
//                mint: mint,
//                owner: owner
//            )
//        )
//
//        if mint == .wrappedSOLMint {
//            cleanupInstructions.append(
//                TokenProgram.closeAccountInstruction(
//                    account: newAccount.publicKey,
//                    destination: owner,
//                    owner: owner
//                )
//            )
//        }
//
//        signers.append(newAccount)
//        return newAccount
//    }
}
