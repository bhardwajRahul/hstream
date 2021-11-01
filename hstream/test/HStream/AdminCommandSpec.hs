{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-incomplete-uni-patterns #-}

module HStream.AdminCommandSpec where

import           Test.Hspec

import           Control.Monad
import qualified Data.Aeson                       as A
import qualified Data.HashMap.Internal            as HM
import qualified Data.Map.Strict                  as Map
import qualified Data.Text                        as Text
import qualified Data.Text.Lazy                   as TL
import qualified Data.Text.Lazy.Encoding          as TL
import qualified Data.Vector                      as V
import           Network.GRPC.HighLevel.Generated

import qualified HStream.Logger                   as Log
import           HStream.Server.HStreamApi
import           HStream.SpecUtils
import           HStream.Store.Logger
import           HStream.Utils

spec :: Spec
spec = describe "HStream.AdminCommnadSpec" $ do
  runIO setupSigsegvHandler
  runIO $ setLogDeviceDbgLevel C_DBG_ERROR

  adminCommandStatsSpec

adminCommandStatsSpec :: Spec
adminCommandStatsSpec = aroundAll provideHstreamApi $ describe "adminCommandStatsSpec" $ do
  aroundWith (withRandomStreams 2) $ do
    it "stats append" $ \(api, streamNames) -> do

      timeStamp <- getProtoTimestamp
      let header = buildRecordHeader HStreamRecordHeader_FlagRAW Map.empty timeStamp TL.empty
      payloads <- V.map (buildRecord header) <$> V.replicateM 10 (newRandomByteString 1024)
      forM_ streamNames $ \name -> replicateM_ 100 $ appendRequest api name payloads

      resp <- adminCommandStatsReq api
      let Just (Just resultObj) =
            A.decode @(Maybe A.Object) . TL.encodeUtf8 . adminCommandResponseResult $ resp
      let Just (A.Array rows) = HM.lookup "rows" resultObj

      forM_ rows $ \(A.Array row) -> do
        let (A.String name) = row V.! 0
        when (TL.fromStrict name `elem` streamNames) $ do
          Log.i $ "Check stream " <> Log.buildText name
          row V.! 1 `shouldSatisfy` (\(A.String x) -> read @Double (Text.unpack x) > 0)
          row V.! 2 `shouldSatisfy` (\(A.String x) -> read @Double (Text.unpack x) > 0)

adminCommandStatsReq :: HStreamApi ClientRequest ClientResult -> IO AdminCommandResponse
adminCommandStatsReq HStreamApi{..} = do
  let requestTimeout = 10
      statReq = AdminCommandRequest "stats appends --intervals 1min --intervals 2min"
      req = ClientNormalRequest statReq requestTimeout $ MetadataMap Map.empty
  getServerResp =<< hstreamApiSendAdminCommand req