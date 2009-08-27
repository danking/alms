{-# LANGUAGE PatternGuards #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Ppr (
  Ppr(..), module Text.PrettyPrint, parensIf,
  module Prec
) where

import Prec
import Syntax

import Text.PrettyPrint
import Data.List (intersperse)

class Ppr p where
  pprPrec :: Int -> p -> Doc
  ppr     :: p -> Doc

  ppr       = pprPrec precDot
  pprPrec _ = ppr

parensIf :: Bool -> Doc -> Doc
parensIf True  doc = parens doc
parensIf False doc = doc

class Separator a where
  separator :: a -> Doc

instance Separator (Type i w) where
  separator _ = comma

instance (Ppr a, Separator a) => Ppr [a] where
  ppr xs = hcat (intersperse (separator (head xs))
                             (map (pprPrec precCom) xs))

instance Ppr (Type i w) where
  -- Print sugar for arrow types:
  pprPrec p (TyCon (Lid "->") [t1, t2] _)
                  = parensIf (p > precArr) $
                      sep [ pprPrec (precArr + 1) t1,
                        text "->" <+> pprPrec precArr t2 ]
  pprPrec p (TyCon (Lid "-o") [t1, t2] _)
                  = parensIf (p > precArr) $
                      sep [ pprPrec (precArr + 1) t1,
                        text "-o" <+> pprPrec precArr t2 ]
  pprPrec p (TyCon (Lid "*") [t1, t2] _)
                  = parensIf (p > precStar) $
                      sep [ pprPrec precStar t1,
                        text "*" <+> pprPrec (precStar + 1) t2 ]
  pprPrec _ (TyCon n [] _)  = ppr n
  pprPrec p (TyCon n [t] _) = parensIf (p > precApp) $
                                sep [ pprPrec precApp t,
                                      ppr n ]
  pprPrec p (TyCon n ts _)  = parensIf (p > precApp) $
                                sep [ parens (pprPrec p ts),
                                      ppr n ]
  pprPrec p (TyVar x)     = pprPrec p x
  pprPrec p (TyQu u x t)  = parensIf (p > precDot) $
                              ppr u <+>
                              fsep (map (pprPrec (precDot + 1))
                                        tvs) <>
                              char '.'
                                >+> pprPrec precDot body
      where (tvs, body) = unfoldTyQu u (TyQu u x t)
  pprPrec p (TyMu x t)    = parensIf (p > precDot) $
                              text "mu" <+>
                              pprPrec (precDot + 1) x <>
                              char '.'
                                >+> pprPrec precDot t
  pprPrec _ (TyA t)       = braces (ppr t)
  pprPrec _ (TyC t)       = braces (ppr t)

instance Ppr (Prog i) where
  ppr (Prog ms Nothing)  = vcat (map ppr ms)
  ppr (Prog [] (Just e)) = ppr e
  ppr (Prog ms (Just e)) = vcat (map (ppr) ms) $+$
                           (text "in" >+> ppr e)

instance Ppr (Decl i) where
  pprPrec p (DcMod _ m)     = pprPrec p m
  pprPrec p (DcTyp _ td)    = pprPrec p td
  pprPrec p (DcAbs _ at ds) =
    vcat [
      text "abstype" <> pprPrec p at <+> text "with",
      nest 2 $ vcat (map (pprPrec p) ds),
      text "end"
    ]

instance Ppr (Mod i) where
  ppr (MdC x Nothing e) = sep
    [ text "module[C]" <+> ppr x,
      nest 2 $ equals <+> ppr e ]
  ppr (MdA x Nothing e) = sep
    [ text "module[A]" <+> ppr x,
      nest 2 $ equals <+> ppr e ]
  ppr (MdC x (Just t) e) = sep
    [ text "module[C]" <+>
        ppr x,
      nest 2 $ colon <+> ppr t,
      nest 4 $ equals <+> ppr e ]
  ppr (MdA x (Just t) e) = sep
    [ text "module[A]" <+>
        ppr x,
      nest 2 $ colon <+> ppr t,
      nest 4 $ equals <+> ppr e ]
  ppr (MdInt x t y)      = sep
    [ text "interface" <+> ppr x,
      nest 2 $ text ":>" <+> ppr t,
      nest 4 $ equals <+> ppr y ]

instance Ppr TyDec where
  ppr (TdAbsA n ps vs qs) =
    text "type[A]" <?> pprParamsV vs ps <?> ppr n
      >?> pprQuals qs
  ppr (TdAbsC n ps) =
    text "type[C]" <?> pprParams ps <?> ppr n
  ppr (TdSynA n ps rhs) =
    text "type[A]" <?> pprParams ps <?> ppr n
      >?> equals <+> ppr rhs
  ppr (TdSynC n ps rhs) =
    text "type[C]" <?> pprParams ps <?> ppr n
      >?> equals <+> ppr rhs
  ppr (TdDatC n ps alts) =
    text "type[C]" <?> pprParams ps <?> ppr n
      >?> pprAlternatives alts
  ppr (TdDatA n ps alts) =
    text "type[A]" <?> pprParams ps <?> ppr n
      >?> pprAlternatives alts

instance Ppr AbsTy where
  ppr (AbsTyC name params alts) =
    text "[C]" <?> pprParams params <?> ppr name <?> pprAlternatives alts
  ppr (AbsTyA name params variances qual alts) =
    text "[A]" <?>
      (pprParamsV variances params <?> ppr name
         >?> pprQuals qual
         >?> pprAlternatives alts)

pprParams    :: [TyVar] -> Doc
pprParams tvs = delimList parens comma (map ppr tvs)

pprParamsV       :: [Variance] -> [TyVar] -> Doc
pprParamsV vs tvs = delimList parens comma (zipWith pprParam vs tvs)
  where
    pprParam v tv = ppr v <> ppr tv

pprQuals :: (Ppr a, Ppr b) => [Either a b] -> Doc
pprQuals [] = empty
pprQuals qs = text "qualifier" <+>
              delimList parens (text " \\/") (map (either ppr ppr) qs)

pprAlternatives :: [(Uid, Maybe (Type i w))] -> Doc
pprAlternatives [] = equals
pprAlternatives (a:as) = sep $
  equals <+> alt a : [ char '|' <+> alt a' | a' <- as ]
  where
    alt (Uid s, Nothing) = text s
    alt (Uid s, Just t)  = text s <+> text "of" <+> pprPrec precDot t

instance Ppr (Expr i w) where
  pprPrec p e0 = case view e0 of
    ExId x    -> ppr x
    ExInt i   -> integer i
    ExFloat f -> double f
    ExStr s   -> text (show s)
    ExCase e1 clauses ->
      case clauses of
        [ (PaCon (Uid "true")  Nothing, et),
          (PaCon (Uid "false") Nothing, ef) ] ->
            parensIf (p > precDot) $
              sep [ text "if" <+> ppr e1,
                    nest 2 $ text "then" <+> ppr et,
                    nest 2 $ text "else" <+> pprPrec precDot ef ]
        [ (PaWild, e2) ] ->
            parensIf (p > precSemi) $
              sep [ pprPrec (precSemi + 1) e1 <> semi,
                    ppr e2 ]
        [ (x, e2) ] ->
            pprLet p (ppr x) e1 e2
        _ ->
            parensIf (p > precDot) $
              vcat (sep [ text "match",
                          nest 2 $ ppr e1,
                          text "with" ] : map alt clauses)
            where
              alt (xi, ei) =
                hang (char '|' <+> pprPrec precDot xi <+> text "->")
                      4
                      (pprPrec precDot ei)
    ExLetRec bs e2 ->
      text "let" <+>
      vcat (zipWith each ("rec" : repeat "and") bs) $$
      text "in" <+> pprPrec precDot e2
        where
          each kw (Binding x t e) =
            -- This could be better by pulling some args out.
            hang (hang (text kw <+> ppr x)
                       6
                       (colon <+> ppr t <+> equals))
                 2
                 (ppr e)
    ExPair e1 e2 ->
      parensIf (p > precCom) $
        sep [ pprPrec precCom e1 <> comma,
              pprPrec (precCom + 1) e2 ]
    ExAbs _ _ _ -> pprAbs p e0
    ExApp e1 e2
      | ExId (Var (Lid x)) <- view e1,
        Right p'           <- precOp x,
        p' == 10
          -> parensIf (p > p') $
               text x <+> pprPrec p' e2
      | ExApp e11 e12      <- view e1,
        ExId (Var (Lid x)) <- view e11,
        (pl, pr, p')       <- either ((,,) 0 1) ((,,) 1 0) (precOp x),
        p' < 9
          -> parensIf (p > p') $
               sep [ pprPrec (p' + pl) e12,
                     text x,
                     pprPrec (p' + pr) e2 ]
      | otherwise
          -> parensIf (p > precApp) $
               sep [ pprPrec precApp e1,
                     pprPrec (precApp + 1) e2 ]
    ExTAbs _ _  -> pprAbs p e0
    ExTApp _ _  ->
      parensIf (p > precTApp) $
        cat [ pprPrec precTApp op,
              brackets . fsep . punctuate comma $
                map (pprPrec precCom) args ]
      where 
        (args, op) = unfoldExTApp e0
    ExPack t1 t2 e ->
      parensIf (p > precApp) $
        text "Pack" <> brackets (ppr t1) <+>
        parens (sep [ pprPrec (precCom + 1) t2 <> comma,
                      pprPrec (precCom + 1) e ])
    ExCast e t1 t2 ->
      parensIf (p > precCast) $
        sep [ pprPrec (precCast + 2) e,
              colon,
              pprPrec (precCast + 2) t1,
              text ":>",
              pprPrec (precCast + 2) t2 ]

pprLet :: Int -> Doc -> Expr i w -> Expr i w -> Doc
pprLet p pat e1 e2 = parensIf (p > precDot) $
  hang (text "let" <+> pat <+> pprArgList args <+> equals
          >+> ppr body <+> text "in")
       (if isLet (view e2)
          then 0
          else 2)
       (pprPrec precDot e2)
  where
    (args, body) = unfoldExAbs e1
    isLet (ExCase _ [_]) = True
    isLet _              = False

pprAbs :: Int -> Expr i w -> Doc
pprAbs p e = parensIf (p > precDot) $
    text "fun" <+> argsDoc <+> text "->"
      >+> pprPrec precDot body
  where (args, body)   = unfoldExAbs e
        argsDoc = case args of
          [Left (PaWild, TyCon (Lid "unit") [] _)]
                        -> parens empty
          [Left (x, t)] -> ppr x <+> char ':' <+> pprPrec (precArr + 1) t
          _             -> pprArgList args

pprArgList :: [Either (Patt, Type i w) TyVar] -> Doc
pprArgList = fsep . map eachArg . combine where
  eachArg (Left (PaWild, TyCon (Lid "unit") [] _))
                          = parens empty
  eachArg (Left (x, t))   = parens $
                              ppr x
                                >+> colon <+> ppr t
  eachArg (Right tvs)     = brackets .
                              sep .
                                punctuate comma $
                                  map ppr tvs

  combine :: [Either a b] -> [Either a [b]]
  combine  = foldr each [] where
    each (Right b) (Right bs : es) = Right (b : bs) : es
    each (Right b) es              = Right [b] : es
    each (Left a)  es              = Left a : es

instance Ppr Patt where
  pprPrec _ PaWild               = text "_"
  pprPrec _ (PaVar lid)          = ppr lid
  pprPrec _ (PaCon uid Nothing)  = ppr uid
  pprPrec p (PaCon uid (Just x)) = parensIf (p > precApp) $
                                     pprPrec precApp uid <+>
                                     pprPrec (precApp + 1) x
  pprPrec p (PaPair x y)         = parensIf (p > precCom) $
                                     pprPrec precCom x <> comma <+>
                                     pprPrec (precCom + 1) y
  pprPrec _ (PaStr s)            = text (show s)
  pprPrec _ (PaInt z)            = text (show z)
  pprPrec p (PaAs x lid)         = parensIf (p > precDot) $
                                     pprPrec (precDot + 1) x <+>
                                     text "as" <+> ppr lid
  pprPrec p (PaPack tv x)        = parensIf (p > precApp) $
                                     text "Pack" <+> parens (sep pair)
    where pair = [ pprPrec (precCom + 1) tv <> comma,
                   pprPrec (precCom + 1) x ]

instance Show (Prog i)   where showsPrec = showFromPpr
instance Show (Decl i)   where showsPrec = showFromPpr
instance Show (Mod i)    where showsPrec = showFromPpr
instance Show TyDec      where showsPrec = showFromPpr
instance Show AbsTy      where showsPrec = showFromPpr
instance Show (Expr i w) where showsPrec = showFromPpr
instance Show Patt       where showsPrec = showFromPpr
instance Show (Type i w) where showsPrec = showFromPpr

instance Ppr Q         where pprPrec = pprFromShow
instance Ppr Variance  where pprPrec = pprFromShow
instance Ppr Quant     where pprPrec = pprFromShow
instance Ppr Lid       where pprPrec = pprFromShow
instance Ppr Uid       where pprPrec = pprFromShow
instance Ppr Ident     where pprPrec = pprFromShow
instance Ppr TyVar     where pprPrec = pprFromShow

instance Show TypeTW where
  showsPrec p (TypeTA t) = showsPrec p t
  showsPrec p (TypeTC t) = showsPrec p t

showFromPpr :: Ppr a => Int -> a -> ShowS
showFromPpr p t = shows (pprPrec p t)

pprFromShow :: Show a => Int -> a -> Doc
pprFromShow p t = text (showsPrec p t "")

delimList :: (Doc -> Doc) -> Doc -> [Doc] -> Doc
delimList around delim ds = case ds of
  []  -> empty
  [d] -> d
  _   -> around . fsep . punctuate delim $ ds

liftEmpty :: (Doc -> Doc -> Doc) -> Doc -> Doc -> Doc
liftEmpty joiner d1 d2
  | isEmpty d1 = d2
  | isEmpty d2 = d1
  | otherwise  = joiner d1 d2

(<?>) :: Doc -> Doc -> Doc
(<?>)  = liftEmpty (<+>)

(>+>) :: Doc -> Doc -> Doc
(>+>) = flip hang 2

(>?>) :: Doc -> Doc -> Doc
(>?>)  = liftEmpty (>+>)

infixr 6 <?>
infixr 5 >+>, >?>

