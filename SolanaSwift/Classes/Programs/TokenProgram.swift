//
//  SPLTokenProgram.swift
//  SolanaSwift
//
//  Created by Chung Tran on 11/6/20.
//

import Foundation

public extension SolanaSDK {
    struct TokenProgram {
        // MARK: - Nested type
        private struct Index {
            static let initalizeMint: UInt8 = 0
            static let initializeAccount: UInt8 = 1
            static let transfer: UInt8 = 3
            static let approve: UInt8 = 4
            static let mintTo: UInt8 = 7
            static let closeAccount: UInt8 = 9
        }
        
        // MARK: - Instructions
        public static func initializeMintInstruction(
            tokenProgramId: PublicKey,
            mint: PublicKey,
            decimals: UInt8,
            authority: PublicKey,
            freezeAuthority: PublicKey?
        ) -> TransactionInstruction {
            
            TransactionInstruction(
                keys: [
                    Account.Meta(publicKey: mint, isSigner: false, isWritable: true),
                    Account.Meta(publicKey: PublicKey.sysvarRent, isSigner: false, isWritable: false)
                ],
                programId: tokenProgramId,
                data: [
                    Index.initalizeMint,
                    decimals,
                    authority,
                    freezeAuthority != nil,
                    freezeAuthority?.bytes ?? Data(capacity: PublicKey.LENGTH).bytes
                ]
            )
        }
        
        public static func initializeAccountInstruction(
            programId: PublicKey = PublicKey.tokenProgramId,
            account: PublicKey,
            mint: PublicKey,
            owner: PublicKey
        ) -> TransactionInstruction {
            
            TransactionInstruction(
                keys: [
                    Account.Meta(publicKey: account, isSigner: false, isWritable: true),
                    Account.Meta(publicKey: mint, isSigner: false, isWritable: false),
                    Account.Meta(publicKey: owner, isSigner: false, isWritable: false),
                    Account.Meta(publicKey: PublicKey.sysvarRent, isSigner: false, isWritable: false)
                ],
                programId: programId,
                data: [Index.initializeAccount]
            )
        }
        
        public static func transferInstruction(
            tokenProgramId: PublicKey,
            source: PublicKey,
            destination: PublicKey,
            owner: PublicKey,
            amount: UInt64
        ) -> TransactionInstruction {
            TransactionInstruction(
                keys: [
                    Account.Meta(publicKey: source, isSigner: false, isWritable: true),
                    Account.Meta(publicKey: destination, isSigner: false, isWritable: true),
                    Account.Meta(publicKey: owner, isSigner: true, isWritable: true)
                ],
                programId: tokenProgramId,
                data: [Index.transfer, amount]
            )
        }
        
        public static func approveInstruction(
            tokenProgramId: PublicKey,
            account: PublicKey,
            delegate: PublicKey,
            owner: PublicKey,
            amount: UInt64
        ) -> TransactionInstruction {
            
            TransactionInstruction(
                keys: [
                    Account.Meta(publicKey: account, isSigner: false, isWritable: true),
                    Account.Meta(publicKey: delegate, isSigner: false, isWritable: false),
                    Account.Meta(publicKey: owner, isSigner: true, isWritable: true)
                ],
                programId: tokenProgramId,
                data: [Index.approve, amount]
            )
        }
        
        public static func mintToInstruction(
            tokenProgramId: PublicKey,
            mint: PublicKey,
            destination: PublicKey,
            authority: PublicKey,
            amount: UInt64
        ) -> TransactionInstruction {
            
            TransactionInstruction(
                keys: [
                    Account.Meta(publicKey: mint, isSigner: false, isWritable: true),
                    Account.Meta(publicKey: destination, isSigner: false, isWritable: true),
                    Account.Meta(publicKey: authority, isSigner: true, isWritable: true)
                ],
                programId: tokenProgramId,
                data: [Index.mintTo, amount]
            )
        }
        
        public static func closeAccountInstruction(
            tokenProgramId: PublicKey,
            account: PublicKey,
            destination: PublicKey,
            owner: PublicKey
        ) -> TransactionInstruction {
            
            TransactionInstruction(
                keys: [
                    Account.Meta(publicKey: account, isSigner: false, isWritable: true),
                    Account.Meta(publicKey: destination, isSigner: false, isWritable: true),
                    Account.Meta(publicKey: owner, isSigner: false, isWritable: false)
                ],
                programId: tokenProgramId,
                data: [Index.closeAccount]
            )
        }
    }
}
