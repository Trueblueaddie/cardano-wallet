{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeSynonymInstances #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Test.Integration.Scenario.API.Shared.Transactions
    ( spec
    ) where

import Prelude

import Cardano.Mnemonic
    ( MkSomeMnemonic (..) )
import Cardano.Wallet.Api.Types
    ( ApiAddress
    , ApiConstructTransaction (..)
    , ApiDecodedTransaction (..)
    , ApiFee (..)
    , ApiSerialisedTransaction (..)
    , ApiSharedWallet (..)
    , ApiT (..)
    , ApiTransaction
    , ApiTxInputGeneral (..)
    , ApiTxMetadata (..)
    , ApiTxOutputGeneral (..)
    , ApiWallet
    , ApiWalletOutput (..)
    , DecodeAddress
    , DecodeStakeAddress
    , EncodeAddress (..)
    , WalletStyle (..)
    )
import Cardano.Wallet.Primitive.AddressDerivation
    ( DerivationIndex (..) )
import Cardano.Wallet.Primitive.Passphrase
    ( Passphrase (..) )
import Cardano.Wallet.Primitive.Types.Tx
    ( TxMetadata (..), TxMetadataValue (..), TxScriptValidity (..) )
import Control.Monad.IO.Unlift
    ( MonadUnliftIO (..), liftIO )
import Control.Monad.Trans.Resource
    ( runResourceT )
import Data.Aeson
    ( toJSON )
import Data.Either.Combinators
    ( swapEither )
import Data.Generics.Internal.VL.Lens
    ( view, (^.) )
import Data.Maybe
    ( isJust )
import Data.Quantity
    ( Quantity (..) )
import Numeric.Natural
    ( Natural )
import Test.Hspec
    ( SpecWith, describe )
import Test.Hspec.Expectations.Lifted
    ( shouldBe, shouldNotContain, shouldSatisfy )
import Test.Hspec.Extra
    ( it )
import Test.Integration.Framework.DSL
    ( Context (..)
    , Headers (..)
    , MnemonicLength (..)
    , Payload (..)
    , accPubKeyFromMnemonics
    , emptyWallet
    , eventually
    , expectErrorMessage
    , expectField
    , expectResponseCode
    , expectSuccess
    , faucetAmt
    , faucetUtxoAmt
    , fixturePassphrase
    , fixtureWallet
    , genMnemonics
    , getFromResponse
    , getSharedWallet
    , json
    , listAddresses
    , minUTxOValue
    , postSharedWallet
    , request
    , signSharedTx
    , submitSharedTxWithWid
    , unsafeRequest
    , verify
    )
import Test.Integration.Framework.TestData
    ( errMsg403EmptyUTxO
    , errMsg403Fee
    , errMsg403InvalidConstructTx
    , errMsg403MinUTxOValue
    , errMsg403SharedWalletPending
    )

import qualified Cardano.Wallet.Api.Link as Link
import qualified Cardano.Wallet.Primitive.Types.TokenMap as TokenMap
import qualified Data.ByteArray as BA
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as Map
import qualified Data.Text.Encoding as T
import qualified Network.HTTP.Types as HTTP


spec :: forall n.
    ( DecodeAddress n
    , DecodeStakeAddress n
    , EncodeAddress n
    ) => SpecWith Context
spec = describe "SHARED_TRANSACTIONS" $ do

    it "SHARED_TRANSACTIONS_CREATE_01 - Cannot create tx for a pending shared wallet" $ \ctx -> runResourceT $ do
        m15txt <- liftIO $ genMnemonics M15
        m12txt <- liftIO $ genMnemonics M12
        let (Right m15) = mkSomeMnemonic @'[ 15 ] m15txt
        let (Right m12) = mkSomeMnemonic @'[ 12 ] m12txt
        let passphrase = Passphrase $ BA.convert $ T.encodeUtf8 fixturePassphrase
        let index = 30
        let accXPubDerived = accPubKeyFromMnemonics m15 (Just m12) index passphrase
        let payload = Json [json| {
                "name": "Shared Wallet",
                "mnemonic_sentence": #{m15txt},
                "mnemonic_second_factor": #{m12txt},
                "passphrase": #{fixturePassphrase},
                "account_index": "30H",
                "payment_script_template":
                    { "cosigners":
                        { "cosigner#0": #{accXPubDerived} },
                      "template":
                          { "all":
                             [ "cosigner#0",
                               "cosigner#1",
                               { "active_from": 120 }
                             ]
                          }
                    }
                } |]
        rPost <- postSharedWallet ctx Default payload
        verify (fmap (swapEither . view #wallet) <$> rPost)
            [ expectResponseCode HTTP.status201
            ]

        let (ApiSharedWallet (Left wal)) =
                getFromResponse Prelude.id rPost

        let metadata = Json [json|{ "metadata": { "1": { "string": "hello" } } }|]

        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shared wal) Default metadata
        verify rTx
            [ expectResponseCode HTTP.status403
            , expectErrorMessage errMsg403SharedWalletPending
            ]

    it "SHARED_TRANSACTIONS_CREATE_01 - Can create tx for an active shared wallet" $ \ctx -> runResourceT $ do
        m15txt <- liftIO $ genMnemonics M15
        m12txt <- liftIO $ genMnemonics M12
        let payload = Json [json| {
                "name": "Shared Wallet",
                "mnemonic_sentence": #{m15txt},
                "mnemonic_second_factor": #{m12txt},
                "passphrase": #{fixturePassphrase},
                "account_index": "30H",
                "payment_script_template":
                    { "cosigners":
                        { "cosigner#0": "self" },
                      "template":
                          { "all":
                             [ "cosigner#0" ]
                          }
                    }
                } |]
        rPost <- postSharedWallet ctx Default payload
        verify (fmap (swapEither . view #wallet) <$> rPost)
            [ expectResponseCode HTTP.status201
            ]

        let walShared@(ApiSharedWallet (Right wal)) =
                getFromResponse Prelude.id rPost

        let metadata = Json [json|{ "metadata": { "1": { "string": "hello" } } }|]

        rTx1 <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shared wal) Default metadata
        verify rTx1
            [ expectResponseCode HTTP.status403
            , expectErrorMessage errMsg403EmptyUTxO
            ]

        let amt = 10 * minUTxOValue (_mainEra ctx)
        fundSharedWallet ctx amt walShared

        rTx2 <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shared wal) Default metadata
        verify rTx2
            [ expectResponseCode HTTP.status202
            , expectField (#coinSelection . #metadata) (`shouldSatisfy` isJust)
            , expectField (#fee . #getQuantity) (`shouldSatisfy` (>0))
            ]

        let txCbor1 = getFromResponse #transaction rTx2
        let decodePayload1 = Json (toJSON txCbor1)
        rDecodedTx1 <- request @(ApiDecodedTransaction n) ctx
            (Link.decodeTransaction @'Shared wal) Default decodePayload1
        let expectedFee = getFromResponse (#fee . #getQuantity) rTx2
        let metadata' = ApiT (TxMetadata (Map.fromList [(1,TxMetaText "hello")]))
        let decodedExpectations =
                [ expectResponseCode HTTP.status202
                , expectField (#fee . #getQuantity) (`shouldBe` expectedFee)
                , expectField #withdrawals (`shouldBe` [])
                , expectField #collateral (`shouldBe` [])
                , expectField #metadata
                  (`shouldBe` (ApiTxMetadata (Just metadata')))
                , expectField #scriptValidity (`shouldBe` (Just $ ApiT TxScriptValid))
                ]
        verify rDecodedTx1 decodedExpectations

        let (ApiSerialisedTransaction apiTx _) =
                getFromResponse #transaction rTx2
        signedTx <-
            signSharedTx ctx wal apiTx [ expectResponseCode HTTP.status202 ]
        let decodePayload2 = Json (toJSON signedTx)
        rDecodedTx2 <- request @(ApiDecodedTransaction n) ctx
            (Link.decodeTransaction @'Shared wal) Default decodePayload2
        verify rDecodedTx2 decodedExpectations

        -- Submit tx
        submittedTx <- submitSharedTxWithWid ctx wal signedTx
        verify submittedTx
            [ expectSuccess
            , expectResponseCode HTTP.status202
            ]

        -- Make sure only fee is deducted from shared Wallet
        eventually "Wallet balance is as expected" $ do
            rWal <- getSharedWallet ctx walShared
            verify (fmap (view #wallet) <$> rWal)
                [ expectResponseCode HTTP.status200
                , expectField
                    (traverse . #balance . #available . #getQuantity)
                    (`shouldBe` (amt - expectedFee))
                ]

    it "SHARED_TRANSACTIONS_CREATE_01a - Empty payload is not allowed" $ \ctx -> runResourceT $ do
        wa <- fixtureSharedWallet ctx
        let emptyPayload = Json [json|{}|]

        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shared wa) Default emptyPayload
        verify rTx
            [ expectResponseCode HTTP.status403
            , expectErrorMessage errMsg403InvalidConstructTx
            ]

    it "SHARED_TRANSACTIONS_CREATE_01b - \
        \Validity interval only is not allowed" $
        \ctx -> runResourceT $ do

        wa <- fixtureSharedWallet ctx
        let validityInterval = Json [json|
                { "validity_interval":
                    { "invalid_before":
                        { "quantity": 10
                        , "unit": "second"
                        }
                    , "invalid_hereafter":
                        { "quantity": 50
                        , "unit": "second"
                        }
                    }
                }|]

        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shared wa) Default validityInterval
        verify rTx
            [ expectResponseCode HTTP.status403
            , expectErrorMessage errMsg403InvalidConstructTx
            ]

    it "SHARED_TRANSACTIONS_CREATE_04a - Single Output Transaction with decode transaction" $ \ctx -> runResourceT $ do

        wa <- fixtureSharedWallet ctx
        wb <- emptyWallet ctx
        let amt = (minUTxOValue (_mainEra ctx) :: Natural)

        payload <- liftIO $ mkTxPayload ctx wb amt

        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shared wa) Default payload
        verify rTx
            [ expectSuccess
            , expectResponseCode HTTP.status202
            , expectField (#coinSelection . #inputs) (`shouldSatisfy` (not . null))
            , expectField (#coinSelection . #outputs) (`shouldSatisfy` (not . null))
            , expectField (#coinSelection . #change) (`shouldSatisfy` (not . null))
            , expectField (#fee . #getQuantity) (`shouldSatisfy` (> 0))
            ]
        let txCbor = getFromResponse #transaction rTx
        let decodePayload = Json (toJSON txCbor)
        rDecodedTxSource <- request @(ApiDecodedTransaction n) ctx
            (Link.decodeTransaction @'Shared wa) Default decodePayload
        rDecodedTxTarget <- request @(ApiDecodedTransaction n) ctx
            (Link.decodeTransaction @'Shelley wb) Default decodePayload

        let expectedFee = getFromResponse (#fee . #getQuantity) rTx
        let sharedExpectationsBetweenWallets =
                [ expectResponseCode HTTP.status202
                , expectField (#fee . #getQuantity) (`shouldBe` expectedFee)
                , expectField #withdrawals (`shouldBe` [])
                , expectField #collateral (`shouldBe` [])
                , expectField #metadata (`shouldBe` (ApiTxMetadata Nothing))
                , expectField #scriptValidity (`shouldBe` (Just $ ApiT TxScriptValid))
                ]

        verify rDecodedTxTarget sharedExpectationsBetweenWallets

        let isInpOurs inp = case inp of
                ExternalInput _ -> False
                WalletInput _ -> True
        let areOurs = all isInpOurs
        addrs <- listAddresses @n ctx wb
        let addrIx = 1
        let addrDest = (addrs !! addrIx) ^. #id
        let expectedTxOutTarget = WalletOutput $ ApiWalletOutput
                { address = addrDest
                , amount = Quantity amt
                , assets = ApiT TokenMap.empty
                , derivationPath = NE.fromList
                    [ ApiT (DerivationIndex 2147485500)
                    , ApiT (DerivationIndex 2147485463)
                    , ApiT (DerivationIndex 2147483648)
                    , ApiT (DerivationIndex 0)
                    , ApiT (DerivationIndex $ fromIntegral addrIx)
                    ]
                }
        let isOutOurs out = case out of
                WalletOutput _ -> False
                ExternalOutput _ -> True

        verify rDecodedTxSource $
            sharedExpectationsBetweenWallets ++
            [ expectField #inputs (`shouldSatisfy` areOurs)
            , expectField #outputs (`shouldNotContain` [expectedTxOutTarget])
            -- Check that the change output is there:
            , expectField (#outputs) ((`shouldBe` 1) . length . filter isOutOurs)
            ]

        let (ApiSerialisedTransaction apiTx _) = getFromResponse #transaction rTx
        signedTx <-
            signSharedTx ctx wa apiTx [ expectResponseCode HTTP.status202 ]
        let decodePayload1 = Json (toJSON signedTx)
        rDecodedTxSource1 <- request @(ApiDecodedTransaction n) ctx
            (Link.decodeTransaction @'Shared wa) Default decodePayload1
        rDecodedTxTarget1 <- request @(ApiDecodedTransaction n) ctx
            (Link.decodeTransaction @'Shelley wb) Default decodePayload1
        verify rDecodedTxTarget1 sharedExpectationsBetweenWallets
        verify rDecodedTxSource1 $
            sharedExpectationsBetweenWallets ++
            [ expectField #inputs (`shouldSatisfy` areOurs)
            , expectField #outputs (`shouldNotContain` [expectedTxOutTarget])
            -- Check that the change output is there:
            , expectField (#outputs) ((`shouldBe` 1) . length . filter isOutOurs)
            ]

        -- Submit tx
        submittedTx <- submitSharedTxWithWid ctx wa signedTx
        verify submittedTx
            [ expectSuccess
            , expectResponseCode HTTP.status202
            ]

        let walShared = ApiSharedWallet (Right wa)

        eventually "Source wallet balance is decreased by amt + fee" $ do
            rWal <- getSharedWallet ctx walShared
            verify (fmap (view #wallet) <$> rWal)
                [ expectResponseCode HTTP.status200
                , expectField
                    (traverse . #balance . #available . #getQuantity)
                    (`shouldBe` (faucetUtxoAmt - expectedFee - amt))
                ]

        eventually "Target wallet balance is increased by amt" $ do
            rWa <- request @ApiWallet ctx
                (Link.getWallet @'Shelley wb) Default Empty
            verify rWa
                [ expectSuccess
                , expectField
                        (#balance . #available . #getQuantity)
                        (`shouldBe` amt)
                ]


    it "SHARED_TRANSACTIONS_CREATE_04b - Cannot spend less than minUTxOValue" $ \ctx -> runResourceT $ do
        wa <- fixtureSharedWallet ctx
        wb <- emptyWallet ctx
        let amt = minUTxOValue (_mainEra ctx) - 1

        payload <- liftIO $ mkTxPayload ctx wb amt

        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shared wa) Default payload
        verify rTx
            [ expectResponseCode HTTP.status403
            , expectErrorMessage errMsg403MinUTxOValue
            ]

    it "SHARED_TRANSACTIONS_CREATE_04c - Can't cover fee" $ \ctx -> runResourceT $ do
        wa <- fixtureSharedWallet ctx
        wb <- emptyWallet ctx

        payload <- liftIO $ mkTxPayload ctx wb faucetUtxoAmt

        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shared wa) Default payload
        verify rTx
            [ expectResponseCode HTTP.status403
            , expectErrorMessage errMsg403Fee
            ]

    it "SHARED_TRANSACTIONS_CREATE_04e- Multiple Output Tx to single wallet" $ \ctx -> runResourceT $ do
        wa <- fixtureSharedWallet ctx
        wb <- emptyWallet ctx
        addrs <- listAddresses @n ctx wb
        let amt = minUTxOValue (_mainEra ctx) :: Natural
        let destination1 = (addrs !! 1) ^. #id
        let destination2 = (addrs !! 2) ^. #id
        let payload = Json [json|{
                "payments": [{
                    "address": #{destination1},
                    "amount": {
                        "quantity": #{amt},
                        "unit": "lovelace"
                    }
                },
                {
                    "address": #{destination2},
                    "amount": {
                        "quantity": #{amt},
                        "unit": "lovelace"
                    }
                }]
            }|]

        rTx <- request @(ApiConstructTransaction n) ctx
            (Link.createUnsignedTransaction @'Shared wa) Default payload
        verify rTx
            [ expectSuccess
            , expectResponseCode HTTP.status202
            , expectField (#coinSelection . #inputs) (`shouldSatisfy` (not . null))
            , expectField (#coinSelection . #outputs) (`shouldSatisfy` (not . null))
            , expectField (#coinSelection . #change) (`shouldSatisfy` (not . null))
            , expectField (#fee . #getQuantity) (`shouldSatisfy` (> 0))
            ]
  where
     fundSharedWallet ctx amt walShared = do
        let wal = case walShared of
                ApiSharedWallet (Right wal') -> wal'
                _ -> error "funding of shared wallet make sense only for active one"

        rAddr <- request @[ApiAddress n] ctx
            (Link.listAddresses @'Shared wal) Default Empty
        expectResponseCode HTTP.status200 rAddr
        let sharedAddrs = getFromResponse Prelude.id rAddr
        let destination = (sharedAddrs !! 1) ^. #id

        wShelley <- fixtureWallet ctx
        let payloadTx = Json [json|{
                "payments": [{
                    "address": #{destination},
                    "amount": {
                        "quantity": #{amt},
                        "unit": "lovelace"
                    }
                }],
                "passphrase": #{fixturePassphrase}
            }|]
        (_, ApiFee (Quantity _) (Quantity feeMax) _ _) <- unsafeRequest ctx
            (Link.getTransactionFeeOld @'Shelley wShelley) payloadTx
        let ep = Link.createTransactionOld @'Shelley
        rTx <- request @(ApiTransaction n) ctx (ep wShelley) Default payloadTx
        expectResponseCode HTTP.status202 rTx
        eventually "wShelley balance is decreased" $ do
            ra <- request @ApiWallet ctx
                (Link.getWallet @'Shelley wShelley) Default Empty
            expectField
                (#balance . #available)
                (`shouldBe` Quantity (faucetAmt - feeMax - amt)) ra

        rWal <- getSharedWallet ctx walShared
        verify (fmap (view #wallet) <$> rWal)
            [ expectResponseCode HTTP.status200
            , expectField (traverse . #balance . #available) (`shouldBe` Quantity amt)
            ]

     fixtureSharedWallet ctx = do
        m15txt <- liftIO $ genMnemonics M15
        m12txt <- liftIO $ genMnemonics M12
        let (Right m15) = mkSomeMnemonic @'[ 15 ] m15txt
        let (Right m12) = mkSomeMnemonic @'[ 12 ] m12txt
        let passphrase = Passphrase $ BA.convert $ T.encodeUtf8 fixturePassphrase
        let index = 30
        let accXPubDerived = accPubKeyFromMnemonics m15 (Just m12) index passphrase
        let payload = Json [json| {
                "name": "Shared Wallet",
                "mnemonic_sentence": #{m15txt},
                "mnemonic_second_factor": #{m12txt},
                "passphrase": #{fixturePassphrase},
                "account_index": "30H",
                "payment_script_template":
                    { "cosigners":
                        { "cosigner#0": #{accXPubDerived} },
                      "template":
                          { "all":
                             [ "cosigner#0" ]
                          }
                    }
                } |]
        rPost <- postSharedWallet ctx Default payload
        verify (fmap (swapEither . view #wallet) <$> rPost)
            [ expectResponseCode HTTP.status201
            ]
        let walShared@(ApiSharedWallet (Right wal)) =
                getFromResponse Prelude.id rPost

        fundSharedWallet ctx faucetUtxoAmt walShared

        return wal

     mkTxPayload
         :: MonadUnliftIO m
         => Context
         -> ApiWallet
         -> Natural
         -> m Payload
     mkTxPayload ctx wDest amt = do
         addrs <- listAddresses @n ctx wDest
         let destination = (addrs !! 1) ^. #id
         return $ Json [json|{
                 "payments": [{
                     "address": #{destination},
                     "amount": {
                         "quantity": #{amt},
                         "unit": "lovelace"
                     }
                 }]
             }|]
