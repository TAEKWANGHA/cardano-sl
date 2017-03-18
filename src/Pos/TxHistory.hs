{-# LANGUAGE CPP                  #-}
{-# LANGUAGE InstanceSigs         #-}
{-# LANGUAGE RankNTypes           #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE UndecidableInstances #-}

module Pos.TxHistory
       ( TxHistoryEntry(..)
       , thTxId
       , thTx
       , thIsOutput
       , thDifficulty

       , TxHistoryAnswer(..)

       , MonadTxHistory(..)

       -- * History derivation
       , getRelatedTxs
       , deriveAddrHistory
       , deriveAddrHistoryPartial
       ) where

import           Universum

import           Control.Lens                (makeLenses, (%=))
import           Control.Monad.Loops         (unfoldrM)
import           Control.Monad.Trans         (MonadTrans)
import           Control.Monad.Trans.Maybe   (MaybeT (..))
import qualified Data.DList                  as DL
import qualified Data.HashMap.Strict         as HM
import           Data.Tagged                 (Tagged (..))
import           System.Wlog                 (WithLogger)

import           Pos.Communication.PeerState (PeerStateHolder)
import           Pos.Constants               (blkSecurityParam)
import qualified Pos.Context                 as PC
import           Pos.Crypto                  (WithHash (..), withHash)
import           Pos.DB                      (MonadDB)
import qualified Pos.DB.Block                as DB
import           Pos.DB.Error                (DBError (..))
import qualified Pos.DB.GState               as GS
import           Pos.Delegation              (DelegationT (..))
import           Pos.DHT.Real                (KademliaDHT (..))
import           Pos.Slotting                (NtpSlotting, SlottingHolder)
import           Pos.Ssc.Class               (SscHelpersClass)
import           Pos.Ssc.Extra               (SscHolder (..))
import           Pos.Txp                     (MonadUtxoRead, Tx (..), TxAux,
                                              TxDistribution, TxId, TxOutAux (..),
                                              TxWitness, TxpHolder (..), Utxo, UtxoStateT,
                                              applyTxToUtxo, evalUtxoStateT,
                                              filterUtxoByAddr, getMemPool, runUtxoStateT,
                                              topsortTxs, txOutAddress,
                                              txProcessTransaction, utxoGet, _mpLocalTxs)
import           Pos.Types                   (Address, Block, ChainDifficulty, HeaderHash,
                                              blockTxas, difficultyL, prevBlockL)
import           Pos.Update                  (USHolder (..))
import           Pos.Util                    (maybeThrow)

data TxHistoryAnswer = TxHistoryAnswer
    { taLastCachedHash :: HeaderHash
    , taCachedNum      :: Int
    , taCachedUtxo     :: Utxo
    , taHistory        :: [TxHistoryEntry]
    } deriving (Show)

----------------------------------------------------------------------
-- Deduction of history
----------------------------------------------------------------------

-- | Check if given 'Address' is one of the receivers of 'Tx'
hasReceiver :: Tx -> Address -> Bool
hasReceiver UnsafeTx {..} addr = any ((== addr) . txOutAddress) _txOutputs

-- | Given some 'Utxo', check if given 'Address' is one of the senders of 'Tx'
hasSender :: MonadUtxoRead m => Tx -> Address -> m Bool
hasSender UnsafeTx {..} addr = anyM hasCorrespondingOutput $ toList _txInputs
  where hasCorrespondingOutput txIn =
            fmap toBool $ fmap ((== addr) . txOutAddress . toaOut) <$> utxoGet txIn
        toBool Nothing  = False
        toBool (Just b) = b

-- | Datatype for returning info about tx history
data TxHistoryEntry = THEntry
    { _thTxId       :: !TxId
    , _thTx         :: !Tx
    , _thIsOutput   :: !Bool
    , _thDifficulty :: !(Maybe ChainDifficulty)
    } deriving (Show, Eq, Generic)

makeLenses ''TxHistoryEntry

-- | Type of monad used to deduce history
type TxSelectorT m = UtxoStateT (MaybeT m)

-- | Select transactions related to given address. `Bool` indicates
-- whether the transaction is outgoing (i. e. is sent from given address)
getRelatedTxs
    :: Monad m
    => Address
    -> [(WithHash Tx, TxWitness, TxDistribution)]
    -> TxSelectorT m [TxHistoryEntry]
getRelatedTxs addr txs = fmap DL.toList $
    lift (MaybeT $ return $ topsortTxs (view _1) txs) >>=
    foldlM step DL.empty
  where
    step ls (WithHash tx txId, _wit, dist) = do
        let isIncoming = tx `hasReceiver` addr
        isOutgoing <- tx `hasSender` addr
        let allToAddr = all ((== addr) . txOutAddress) $ _txOutputs tx
            isToItself = isOutgoing && allToAddr
        if isOutgoing || isIncoming
            then do
            applyTxToUtxo (WithHash tx txId) dist
            identity %= filterUtxoByAddr addr

            -- Workaround to present A to A transactions as a pair of self-canceling
            -- transactions in history
            let resEntry = THEntry txId tx isOutgoing Nothing
                resList = if isToItself
                          then DL.fromList [resEntry & thIsOutput .~ False, resEntry]
                          else DL.singleton resEntry
            return $ ls <> resList
            else return ls

-- | Given a full blockchain, derive address history and Utxo
-- TODO: Such functionality will still be useful for merging
-- blockchains when wallet state is ready, but some metadata for
-- Tx will be required.
deriveAddrHistory
    -- :: (Monad m, Ssc ssc) => Address -> [Block ssc] -> TxSelectorT m [TxHistoryEntry]
    :: (Monad m) => Address -> [Block ssc] -> TxSelectorT m [TxHistoryEntry]
deriveAddrHistory addr chain = identity %= filterUtxoByAddr addr >>
                               deriveAddrHistoryPartial [] addr chain

deriveAddrHistoryPartial
    :: (Monad m)
    => [TxHistoryEntry]
    -> Address
    -> [Block ssc]
    -> TxSelectorT m [TxHistoryEntry]
deriveAddrHistoryPartial hist addr chain =
    DL.toList <$> foldrM updateAll (DL.fromList hist) chain
  where
    updateAll (Left _) hst = pure hst
    updateAll (Right blk) hst = do
        txs <- getRelatedTxs addr $
                   map (over _1 withHash) (blk ^. blockTxas)
        let difficulty = blk ^. difficultyL
            txs' = map (thDifficulty .~ Just difficulty) txs
        return $ DL.fromList txs' <> hst

----------------------------------------------------------------------------
-- MonadTxHistory
----------------------------------------------------------------------------

-- | A class which have methods to get transaction history
class Monad m => MonadTxHistory m where
    getTxHistory
        :: SscHelpersClass ssc
        => Tagged ssc (Address -> Maybe (HeaderHash, Utxo) -> m TxHistoryAnswer)
    saveTx :: (TxId, TxAux) -> m ()

    default getTxHistory
        :: (SscHelpersClass ssc, MonadTrans t, MonadTxHistory m', t m' ~ m)
        => Tagged ssc (Address -> Maybe (HeaderHash, Utxo) -> m TxHistoryAnswer)
    getTxHistory = fmap (fmap lift) <$> getTxHistory

    default saveTx :: (MonadTrans t, MonadTxHistory m', t m' ~ m) => (TxId, TxAux) -> m ()
    saveTx = lift . saveTx

instance MonadTxHistory m => MonadTxHistory (ReaderT r m)
instance MonadTxHistory m => MonadTxHistory (StateT s m)
instance MonadTxHistory m => MonadTxHistory (KademliaDHT m)
instance MonadTxHistory m => MonadTxHistory (PeerStateHolder m)
instance MonadTxHistory m => MonadTxHistory (NtpSlotting m)
instance MonadTxHistory m => MonadTxHistory (SlottingHolder m)

deriving instance MonadTxHistory m => MonadTxHistory (PC.ContextHolder ssc m)
deriving instance MonadTxHistory m => MonadTxHistory (SscHolder ssc m)
deriving instance MonadTxHistory m => MonadTxHistory (DelegationT m)
deriving instance MonadTxHistory m => MonadTxHistory (USHolder m)

instance ( MonadDB m
         , MonadThrow m
         , WithLogger m
#ifdef WITH_EXPLORER
         , MonadSlots m
#endif
         , PC.WithNodeContext s m) =>
         MonadTxHistory (TxpHolder m) where
    getTxHistory :: forall ssc. SscHelpersClass ssc
                 => Tagged ssc (Address -> Maybe (HeaderHash, Utxo) -> TxpHolder m TxHistoryAnswer)
    getTxHistory = Tagged $ \addr mInit -> do
        tip <- GS.getTip

        let getGenUtxo = filterUtxoByAddr addr . PC.ncGenesisUtxo <$> PC.getNodeContext
        (bot, genUtxo) <- maybe ((,) <$> GS.getBot <*> getGenUtxo) pure mInit

        -- Getting list of all hashes in main blockchain (excluding bottom block - it's genesis anyway)
        hashList <- flip unfoldrM tip $ \h ->
            if h == bot
            then return Nothing
            else do
                header <- DB.getBlockHeader @ssc h >>=
                    maybeThrow (DBMalformed "Best blockchain is non-continuous")
                let prev = header ^. prevBlockL
                return $ Just (h, prev)

        -- Determine last block which txs should be cached
        let cachedHashes = drop blkSecurityParam hashList
            nonCachedHashes = take blkSecurityParam hashList

        let blockFetcher h txs = do
                blk <- lift . lift $ DB.getBlock @ssc h >>=
                       maybeThrow (DBMalformed "A block mysteriously disappeared!")
                deriveAddrHistoryPartial txs addr [blk]
            localFetcher blkTxs = do
                let mp (txid, (tx, txw, txd)) = (WithHash tx txid, txw, txd)
                ltxs <- HM.toList . _mpLocalTxs <$> lift (lift getMemPool)
                txs <- getRelatedTxs addr $ map mp ltxs
                return $ txs ++ blkTxs

        mres <- runMaybeT $ do
            (cachedTxs, cachedUtxo) <- runUtxoStateT
                (foldrM blockFetcher [] cachedHashes) genUtxo

            result <- evalUtxoStateT
                (foldrM blockFetcher cachedTxs nonCachedHashes >>= localFetcher)
                cachedUtxo

            let lastCachedHash = maybe bot identity $ head cachedHashes
            return $ TxHistoryAnswer lastCachedHash (length cachedTxs) cachedUtxo result

        maybe (error "deriveAddrHistory: Nothing") pure mres

    saveTx txw = () <$ runExceptT (txProcessTransaction txw)

--deriving instance MonadTxHistory m => MonadTxHistory (Modern.TxpLDHolder m)
