{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.Wallet.Shelley.Network.Blockfrost.Conversion where

import Prelude

import Cardano.Pool.Metadata.Types
    ( StakePoolMetadataHash )
import Cardano.Wallet.Primitive.Types
    ( BlockHeader (..), EpochNo, SlotNo (SlotNo) )
import Cardano.Wallet.Primitive.Types.Address
    ( Address )
import Cardano.Wallet.Primitive.Types.Coin
    ( Coin (Coin) )
import Cardano.Wallet.Primitive.Types.Hash
    ( Hash )
import Cardano.Wallet.Primitive.Types.RewardAccount
    ( RewardAccount )
import Cardano.Wallet.Shelley.Compatibility
    ( shelleyDecodeAddress, shelleyDecodeStakeAddress )
import Cardano.Wallet.Shelley.Network.Blockfrost.Error
    ( BlockfrostError (..), (<?#>) )
import Control.Monad.Error.Class
    ( MonadError (throwError) )
import Data.Bifunctor
    ( first )
import Data.IntCast
    ( intCast )
import Data.Maybe
    ( fromMaybe )
import Data.Quantity
    ( Percentage, Quantity (Quantity), mkPercentage )
import Data.Text
    ( Text )
import Data.Text.Class
    ( fromText )
import Data.Traversable
    ( for )

import qualified Blockfrost.Client as BF
import qualified Cardano.Ledger.BaseTypes as Ledger
import Cardano.Pool.Types
    ( PoolId, decodePoolIdBech32 )

fromBfLovelaces :: MonadError BlockfrostError m => BF.Lovelaces -> m Coin
fromBfLovelaces lovs = Coin <$> (intCast @_ @Integer lovs <?#> "Lovelaces")

fromBfAddress
    :: MonadError BlockfrostError m => Ledger.Network -> BF.Address -> m Address
fromBfAddress network (BF.Address addr) =
    case shelleyDecodeAddress network addr of
        Left e -> throwError (InvalidAddress addr e)
        Right a -> pure a

fromBfStakeAddress
    :: MonadError BlockfrostError m
    => Ledger.Network -> BF.Address -> m RewardAccount
fromBfStakeAddress network (BF.Address addr) =
    case shelleyDecodeStakeAddress network addr of
        Left e -> throwError (InvalidStakeAddress addr e)
        Right a -> pure a

percentageFromDouble :: MonadError BlockfrostError m => Double -> m Percentage
percentageFromDouble d =
    case mkPercentage (toRational d) of
        Left e -> throwError (InvalidPercentage d e)
        Right a -> pure a

stakePoolMetadataHashFromText
    :: MonadError BlockfrostError m => Text -> m StakePoolMetadataHash
stakePoolMetadataHashFromText text =
    case fromText text of
        Left e -> throwError (InvalidStakePoolMetadataHash text e)
        Right a -> pure a

bfBlockHeader :: BF.Block -> Either BlockfrostError BlockHeader
bfBlockHeader BF.Block{..} = do
    slotNo <- fromMaybe 0 <$> for _blockSlot fromBfSlot
    blockHeight <- Quantity <$> fromMaybe 0 _blockHeight <?#> "BlockHeight"
    headerHash <- parseBlockHeader _blockHash
    parentHeaderHash <- for _blockPreviousBlock parseBlockHeader
    pure BlockHeader{slotNo, blockHeight, headerHash, parentHeaderHash}
  where
    parseBlockHeader blockHash =
        case fromText (BF.unBlockHash blockHash) of
            Right hash -> pure hash
            Left tde -> throwError $ InvalidBlockHash blockHash tde

fromBfTxHash :: BF.TxHash -> Either BlockfrostError (Hash "Tx")
fromBfTxHash txHash = first (InvalidTxHash hash) $ fromText hash
  where hash = BF.unTxHash txHash

fromBfSlot :: BF.Slot -> Either BlockfrostError SlotNo
fromBfSlot = fmap SlotNo . (<?#> "SlotNo") . BF.unSlot

fromBfPoolId :: BF.PoolId -> Either BlockfrostError PoolId
fromBfPoolId poolId = first (InvalidPoolId addr) (decodePoolIdBech32 addr)
  where addr = BF.unPoolId poolId

fromBfEpoch :: BF.Epoch -> EpochNo
fromBfEpoch = fromIntegral
