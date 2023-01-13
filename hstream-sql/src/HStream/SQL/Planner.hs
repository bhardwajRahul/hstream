{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies      #-}

module HStream.SQL.Planner where

import           Data.Kind       (Type)
import qualified Data.List       as L
import qualified Data.Map        as Map
import           Data.Text       (Text)
import qualified Data.Text       as T

import           HStream.SQL.AST

data RelationExpr
  = StreamScan   Text
  | StreamRename RelationExpr Text
  | CrossJoin RelationExpr RelationExpr
  | LoopJoinOn RelationExpr RelationExpr ScalarExpr RJoinType
  | LoopJoinUsing RelationExpr RelationExpr [Text] RJoinType
  | LoopJoinNatural RelationExpr RelationExpr RJoinType
  | Filter RelationExpr ScalarExpr
  | Project RelationExpr [(ColumnCatalog, ColumnCatalog)] [Text] -- project [(column AS alias)] or [stream.*]
  | Affiliate RelationExpr [(ColumnCatalog,ScalarExpr)]
  | Reduce RelationExpr [(ColumnCatalog,ScalarExpr)] [(ColumnCatalog,AggregateExpr)]
  | Distinct RelationExpr
  | TimeWindow RelationExpr WindowType
  | Union RelationExpr RelationExpr
  deriving (Eq)

data ScalarExpr
  = ColumnRef  Text (Maybe Text) -- fieldName, streamName_m
  | Literal    Constant
  | CallUnary  UnaryOp  ScalarExpr
  | CallBinary BinaryOp ScalarExpr ScalarExpr
  | CallCast   ScalarExpr RDataType
  | CallJson   JsonOp ScalarExpr ScalarExpr
  | ValueArray [ScalarExpr]
  | ValueMap   (Map.Map ScalarExpr ScalarExpr)
  | AccessArray ScalarExpr RArrayAccessRhs
  | AccessMap ScalarExpr ScalarExpr
  deriving (Eq, Ord)

type AggregateExpr = Aggregate ScalarExpr

-------------------
type family DecoupledType a :: Type
class Decouple a where
  decouple :: a -> DecoupledType a

type instance DecoupledType RValueExpr = ScalarExpr
instance Decouple RValueExpr where
  decouple expr = case expr of
    RExprCol _ stream_m field  -> ColumnRef field stream_m
    RExprConst _ constant      -> Literal constant
    RExprBinOp _ op e1 e2      -> CallBinary op (decouple e1) (decouple e2)
    RExprUnaryOp _ op e        -> CallUnary op (decouple e)
    RExprCast _ e typ          -> CallCast (decouple e) typ
    RExprAccessJson _ op e1 e2 -> CallJson op (decouple e1) (decouple e2)
    RExprAggregate name _      -> ColumnRef (T.pack name) Nothing
    RExprArray _ es            -> ValueArray (L.map decouple es)
    RExprMap _ m               -> ValueMap (Map.mapKeys decouple $ Map.map decouple m)
    RExprAccessArray _ e rhs   -> AccessArray (decouple e) rhs
    RExprAccessMap _ em ek     -> AccessMap (decouple em) (decouple ek)
    RExprSubquery _ _          -> error "subquery is not supported"

rSelToAffiliateItems :: RSel -> [(ColumnCatalog,ScalarExpr)]
rSelToAffiliateItems (RSel items) =
  L.concatMap (\item ->
                 case item of
                   RSelectItemProject expr _ ->
                     case expr of
                       RExprCol _ _ _     -> []
                       RExprAggregate _ _ -> []
                       _ -> let cata = ColumnCatalog
                                     { columnName = T.pack (getName expr)
                                     , columnStream = Nothing
                                     }
                                scalar = decouple expr
                             in [(cata,scalar)]
                   RSelectProjectQualifiedAll _ -> []
                   RSelectProjectAll            -> []
              ) items

-- FIXME: should not use alias. Project [ColumnCatalog] should be Project [(ColumnCatalog, ColumnCatalog)]
rSelToProjectItems :: RSel -> [(ColumnCatalog, ColumnCatalog)]
rSelToProjectItems (RSel items) =
  L.concatMap (\item ->
                 case item of
                   RSelectItemProject expr alias_m ->
                     case expr of
                       RExprCol name stream_m field ->
                         let cata_get = ColumnCatalog
                                        { columnName = field
                                        , columnStream = stream_m
                                        }
                             cata_alias = case alias_m of
                                            Nothing    -> cata_get
                                            Just alias -> ColumnCatalog
                                                        { columnName = alias
                                                        , columnStream = Nothing
                                                        }
                          in [(cata_get,cata_alias)]
                       _ -> let cata_get = ColumnCatalog
                                       { columnName = T.pack (getName expr)
                                       , columnStream = Nothing
                                       }
                                cata_alias = case alias_m of
                                               Nothing    -> cata_get
                                               Just alias -> ColumnCatalog
                                                           { columnName = alias
                                                           , columnStream = Nothing
                                                           }
                             in [(cata_get,cata_alias)]
                   RSelectProjectAll               -> []
                   RSelectProjectQualifiedAll _    -> []
              ) items

rSelToProjectStreams :: RSel -> [Text]
rSelToProjectStreams (RSel items) =
  L.concatMap (\item -> case item of
                          RSelectProjectQualifiedAll s -> [s]
                          RSelectItemProject _ _       -> []
                          RSelectProjectAll            -> []
              ) items

type instance DecoupledType (Aggregate RValueExpr) = Aggregate ScalarExpr
instance Decouple (Aggregate RValueExpr) where
  decouple agg = case agg of
    Nullary AggCountAll -> Nullary AggCountAll
    Unary agg expr      -> Unary agg (decouple expr)
    Binary agg e1 e2    -> Binary agg (decouple e1) (decouple e2)

type instance DecoupledType RGroupBy = [(ColumnCatalog,ScalarExpr)]
instance Decouple RGroupBy where
  decouple RGroupByEmpty = []
  decouple (RGroupBy tups) =
    L.map (\(stream_m,field) ->
              let cata = ColumnCatalog
                       { columnName = field
                       , columnStream = stream_m
                       }
                  scalar = ColumnRef field stream_m
               in (cata, scalar)
          ) tups

type instance DecoupledType RTableRef = RelationExpr
instance Decouple RTableRef where
  decouple (RTableRefSimple s alias_m) =
    let base = StreamScan s
     in case alias_m of
          Nothing    -> base
          Just alias -> StreamRename base alias
  decouple (RTableRefCrossJoin ref1 ref2 alias_m) =
    let base_1 = decouple ref1
        base_2 = decouple ref2
        joined = CrossJoin base_1 base_2
     in case alias_m of
          Nothing    -> joined
          Just alias -> StreamRename joined alias
  decouple (RTableRefNaturalJoin ref1 typ ref2 alias_m) =
    let base_1 = decouple ref1
        base_2 = decouple ref2
        joined = LoopJoinNatural base_1 base_2 typ
     in case alias_m of
          Nothing    -> joined
          Just alias -> StreamRename joined alias
  decouple (RTableRefJoinOn ref1 typ ref2 expr alias_m) =
    let base_1 = decouple ref1
        base_2 = decouple ref2
        scalar = decouple expr
        joined = LoopJoinOn base_1 base_2 scalar typ
     in case alias_m of
          Nothing    -> joined
          Just alias -> StreamRename joined alias
  decouple (RTableRefJoinUsing ref1 typ ref2 cols alias_m) =
    let base_1 = decouple ref1
        base_2 = decouple ref2
        joined = LoopJoinUsing base_1 base_2 cols typ
     in case alias_m of
          Nothing    -> joined
          Just alias -> StreamRename joined alias
  decouple (RTableRefWindowed ref win alias_m) =
    let base = decouple ref
        windowed = TimeWindow base win
     in case alias_m of
          Nothing    -> windowed
          Just alias -> StreamRename windowed alias
  decouple (RTableRefSubquery select alias_m) =
    let base = decouple select
     in case alias_m of
          Nothing    -> base
          Just alias -> StreamRename base alias

type instance DecoupledType RFrom = RelationExpr
instance Decouple RFrom where
  decouple (RFrom refs) =
    L.foldl1 (\x acc -> CrossJoin acc x) (L.map decouple refs)

type instance DecoupledType RSelect = RelationExpr
instance Decouple RSelect where
  decouple (RSelect sel frm whr grp hav) =
    let base = decouple frm
        -- WHERE
        filtered_1 = case whr of
                       RWhereEmpty -> base
                       RWhere expr -> Filter base (decouple expr)
        -- SELECT(affiliate items)
        affiliateItems = rSelToAffiliateItems sel
        affiliated = case affiliateItems of
                       [] -> filtered_1
                       _  -> Affiliate filtered_1 affiliateItems
        -- GROUP BY
        aggs = getAggregates sel ++ getAggregates hav
        grped = case grp of
                  RGroupByEmpty -> affiliated
                  RGroupBy _    -> Reduce affiliated (decouple grp) aggs
        -- HAVING
        filtered_2 = case hav of
                       RHavingEmpty -> grped
                       RHaving expr -> Filter grped (decouple expr)
        -- SELECT(project items)
        projectItems   = rSelToProjectItems sel
        projectStreams = rSelToProjectStreams sel
        projected = if L.null projectItems && L.null projectStreams then
                      filtered_2 else
                      Project filtered_2 projectItems projectStreams
     in projected

--------------------------------------------------------------------------------
class HasAggregates a where
  getAggregates :: a -> [(ColumnCatalog,AggregateExpr)]

instance HasAggregates RValueExpr where
  getAggregates expr = case expr of
    RExprAggregate name agg   ->
      let cata = ColumnCatalog
               { columnName = T.pack name
               , columnStream = Nothing
               }
       in [(cata, decouple agg)]
    RExprCol _ _ _            -> []
    RExprConst _ _            -> []
    RExprCast _ e _           -> getAggregates e
    RExprArray _ es           -> L.concatMap getAggregates es
    RExprMap _ m              -> L.concatMap (\(ek,ev) -> getAggregates ek ++ getAggregates ev) (Map.toList m)
    RExprAccessMap _ em ek    -> getAggregates em ++ getAggregates ek
    RExprAccessArray _ e _    -> getAggregates e
    RExprAccessJson _ _ e1 e2 -> getAggregates e1 ++ getAggregates e2
    RExprBinOp _ _ e1 e2      -> getAggregates e1 ++ getAggregates e2
    RExprUnaryOp _ _ e        -> getAggregates e
    RExprSubquery _ _         -> [] -- do not support subquery in SELECT/HAVING now

instance HasAggregates RSelectItem where
  getAggregates item = case item of
    RSelectItemProject e _ -> getAggregates e
    _                      -> []

instance HasAggregates RSel where
  getAggregates (RSel items) = L.concatMap getAggregates items

instance HasAggregates RHaving where
  getAggregates RHavingEmpty = []
  getAggregates (RHaving e)  = getAggregates e