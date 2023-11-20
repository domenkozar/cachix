module Cachix.Client.Daemon.Subscription where

import Control.Concurrent.STM.TBMQueue
import Control.Concurrent.STM.TMChan
import Control.Concurrent.STM.TVar
import Data.Aeson as Aeson (ToJSON, encode)
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import qualified Network.Socket as Socket
import qualified Network.Socket.ByteString.Lazy as Socket
import Protolude

data SubscriptionManager k v = SubscriptionManager
  { managerSubscriptions :: TVar (HashMap k [Subscription v]),
    managerGlobalSubscriptions :: TVar [Subscription v],
    managerEvents :: TBMQueue (k, v)
  }

data Subscription v
  = -- | A subscriber that listens on a socket.
    SubSocket Socket.Socket
  | -- | A subscriber that listens on a channel.
    SubChannel (TMChan v)

newSubscriptionManager :: IO (SubscriptionManager k v)
newSubscriptionManager = do
  subscriptions <- newTVarIO HashMap.empty
  globalSubscriptions <- newTVarIO []
  events <- newTBMQueueIO 1000
  pure $ SubscriptionManager subscriptions globalSubscriptions events

-- Subscriptions

subscribeTo :: (Hashable k, MonadIO m) => SubscriptionManager k v -> k -> Subscription v -> m ()
subscribeTo manager key subscription =
  liftIO $ atomically $ subscribeToSTM manager key subscription

subscribeToAll :: (MonadIO m) => SubscriptionManager k v -> Subscription v -> m ()
subscribeToAll manager subscription =
  liftIO $ atomically $ subscribeToAllSTM manager subscription

getSubscriptionsFor :: (Hashable k, MonadIO m) => SubscriptionManager k v -> k -> m [Subscription v]
getSubscriptionsFor manager key =
  liftIO $ atomically $ getSubscriptionsForSTM manager key

subscribeToSTM :: (Hashable k) => SubscriptionManager k v -> k -> Subscription v -> STM ()
subscribeToSTM manager key subscription = do
  subscriptions <- readTVar $ managerSubscriptions manager
  let subscriptions' = HashMap.insertWith (<>) key [subscription] subscriptions
  writeTVar (managerSubscriptions manager) subscriptions'

subscribeToAllSTM :: SubscriptionManager k v -> Subscription v -> STM ()
subscribeToAllSTM manager subscription = do
  subscriptions <- readTVar $ managerGlobalSubscriptions manager
  let subscriptions' = subscription : subscriptions
  writeTVar (managerGlobalSubscriptions manager) subscriptions'

getSubscriptionsForSTM :: (Hashable k) => SubscriptionManager k v -> k -> STM [Subscription v]
getSubscriptionsForSTM manager key = do
  subscriptions <- readTVar $ managerSubscriptions manager
  pure $ HashMap.lookupDefault [] key subscriptions

-- Events

pushEvent :: (MonadIO m) => SubscriptionManager k v -> k -> v -> m ()
pushEvent manager key event = do
  liftIO $ atomically $ pushEventSTM manager key event

pushEventSTM :: SubscriptionManager k v -> k -> v -> STM ()
pushEventSTM manager key event =
  writeTBMQueue (managerEvents manager) (key, event)

sendEvent :: (ToJSON v, MonadIO m) => v -> Subscription v -> m ()
sendEvent event (SubSocket sock) = return ()
-- TODO: should drop the socket if it's closed
-- liftIO $ Socket.sendAll sock (Aeson.encode event)
sendEvent event (SubChannel chan) =
  liftIO $ atomically $ writeTMChan chan event

runSubscriptionManager :: (Show k, Show v, Hashable k, ToJSON v, MonadIO m) => SubscriptionManager k v -> m ()
runSubscriptionManager manager = do
  mevent <- liftIO $ atomically $ readTBMQueue (managerEvents manager)
  case mevent of
    Nothing -> return ()
    Just (key, event) -> do
      subscriptions <- getSubscriptionsFor manager key
      globalSubscriptions <- liftIO $ readTVarIO $ managerGlobalSubscriptions manager
      mapM_ (sendEvent event) (subscriptions <> globalSubscriptions)
      runSubscriptionManager manager

stopSubscriptionManager :: SubscriptionManager k v -> IO ()
stopSubscriptionManager manager = do
  liftIO $ atomically $ closeTBMQueue (managerEvents manager)
  globalSubscriptions <- liftIO $ readTVarIO $ managerGlobalSubscriptions manager
  subscriptions <- liftIO $ readTVarIO $ managerSubscriptions manager

  forM_ (concat subscriptions <> globalSubscriptions) $ \subscription -> do
    case subscription of
      SubSocket sock -> Socket.close sock
      SubChannel channel -> atomically $ closeTMChan channel
