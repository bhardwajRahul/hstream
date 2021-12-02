module HStream.Store.Admin.Command.Status
  ( runStatus
  ) where

import           Control.Monad
import           Data.Int                  (Int64)
import           Data.List                 (elemIndex, sortBy)
import           Data.Maybe                (fromJust)
import qualified Data.Text                 as Text
import qualified Data.Text.Encoding        as Text
import           Data.Time.Clock.POSIX     (POSIXTime, getPOSIXTime)
import qualified Text.Layout.Table         as Table

import qualified HStream.Store.Admin.API   as AA
import           HStream.Store.Admin.Types
import           HStream.Utils             (approxNaturalTime, simpleShowTable)

data NodeState' = NodeState'
  { stateState      :: AA.NodeState
  , stateVersion    :: Text.Text
  , stateAliveSince :: Int64
  }

showID :: NodeState' -> String
showID = show . AA.nodeConfig_node_index . AA.nodeState_config . stateState

showName :: NodeState' -> String
showName = Text.unpack . AA.nodeConfig_name . AA.nodeState_config . stateState

showDaemonState :: NodeState' -> String
showDaemonState = cutLast' "_" . show . AA.nodeState_daemon_state . stateState

showHealthState :: NodeState' -> String
showHealthState = cutLast' "_" . show . AA.nodeState_daemon_health_status . stateState

showVersion :: NodeState' -> String
showVersion = Text.unpack . stateVersion

showUptime :: POSIXTime -> NodeState' -> String
showUptime time state =
  approxNaturalTime (time - fromIntegral (stateAliveSince state)) ++ " ago"

showSeqState :: NodeState' -> String
showSeqState = cutLast' "_" . maybe " " (show . AA.sequencerState_state) . AA.nodeState_sequencer_state . stateState

-- | Gets the state object for all nodes that matches the supplied NodesFilter.
--
-- If NodesFilter is empty we will return all nodes. If the filter does not
-- match any nodes, an empty list of nodes is returned in the
-- NodesStateResponse object. `force` will force this method to return all the
-- available state even if the node is not fully ready. In this case we will
-- not throw NodeNotReady exception but we will return partial data.
runStatus :: AA.HeaderConfig AA.AdminAPI -> StatusOpts -> IO String
runStatus conf StatusOpts{..} = do
  states <- AA.sendAdminApiRequest conf $ do
    case fromSimpleNodesFilter statusFilter of
      [] -> AA.nodesStateResponse_states <$> AA.getNodesState (AA.NodesStateRequest Nothing (Just statusForce))
      xs -> do
        rs <- forM xs $ \x -> AA.nodesStateResponse_states <$> AA.getNodesState (AA.NodesStateRequest (Just x) (Just statusForce))
        return $ concat rs

  let getNodeHeaderConfig sa =
        AA.HeaderConfig
          { AA.headerHost = Text.encodeUtf8 . fromJust $ AA.socketAddress_address sa
          , AA.headerPort = fromIntegral . fromJust $ AA.socketAddress_port sa
          , AA.headerProtocolId  = AA.binaryProtocolId
          , AA.headerConnTimeout = 5000
          , AA.headerSendTimeout = 5000
          , AA.headerRecvTimeout = 5000
          }
  additionStates <- forM states $ \state -> do
    let hc = getNodeHeaderConfig . AA.getNodeAdminAddr $ AA.nodeState_config state
    AA.sendAdminApiRequest hc $ do
      version <- AA.getVersion
      aliveSince <- AA.aliveSince
      return (version, aliveSince)
  let allStates = zipWith (\state (version, alive) -> NodeState' state version alive) states additionStates
  currentTime <- getPOSIXTime

  let cons = [ ("ID", showID)
             , ("NAME", showName)
             , ("PACKAGE", showVersion)
             , ("STATE", showDaemonState)
             , ("UPTIME", showUptime currentTime)
             , ("SEQ.", showSeqState)
             , ("HEALTH STATUS", showHealthState)
             ]
  let titles = map fst cons
      collectedState = map (\s -> map (($ s) . snd) cons) allStates

  let m_sortIdx = elemIndex (Text.unpack . Text.toUpper $ statusSortField) titles
  case m_sortIdx of
    Just sortIdx -> do
      let stats = sortBy (\xs ys -> compare (xs!!sortIdx) (ys!!sortIdx)) collectedState
      case statusFormat of
        TabularFormat -> return $ simpleShowTable (map (, 20, Table.left) titles) stats
        JSONFormat    -> errorWithoutStackTrace "NotImplemented"
    Nothing -> errorWithoutStackTrace $ "No such sort key: " <> Text.unpack statusSortField

-------------------------------------------------------------------------------

cutLast :: Text.Text -> Text.Text -> Text.Text
cutLast splitor = last . Text.splitOn splitor

cutLast' :: Text.Text -> String -> String
cutLast' splitor = Text.unpack . cutLast splitor . Text.pack
