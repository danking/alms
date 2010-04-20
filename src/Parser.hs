-- | Parser
module Parser (
  -- * The parsing monad
  P,
  parse,
  -- ** Parsers
  parseProg, parseDecls, parseDecl,
    parseTyDec, parseType, parseExpr, parsePatt,
  -- * Convenience parsers (quick and dirty)
  pp, pds, pd, ptd, pt, pe, px
) where

import Util
import Prec
import Syntax
import Sigma
import Loc
import Lexer

import Text.ParserCombinators.Parsec hiding (parse)
import System.IO.Unsafe (unsafePerformIO)
import System.FilePath ((</>), dropFileName)

data St   = St {
              stSigma :: Bool
            }

-- | A 'Parsec' character parser, with abstract state
type P a  = CharParser St a

state0 :: St
state0 = St {
           stSigma = False
         }

-- | Run a parser, given the source file name, on a given string
parse   :: P a -> SourceName -> String -> Either ParseError a
parse p  = runParser p state0

withSigma :: Bool -> P a -> P a
withSigma = mapSigma . const

mapSigma :: (Bool -> Bool) -> P a -> P a
mapSigma f p = do
  st <- getState
  setState st { stSigma = f (stSigma st) }
  r <- p
  setState st
  return r

getSigma :: P Bool
getSigma  = stSigma `fmap` getState

curLoc :: P Loc
curLoc  = getPosition >>! fromSourcePos

addLoc :: Relocatable a => P a -> P a
addLoc p = do
  loc <- curLoc
  a   <- p
  return (a <<@ loc)

delimList :: P pre -> (P [a] -> P [a]) -> P sep -> P a -> P [a]
delimList before around delim each =
  choice [
    before >> choice [
      around (each `sepBy` delim),
      each >>! \x -> [x]
    ],
    return []
  ]

chainl1last :: P a -> P (a -> a -> a) -> P a -> P a
chainl1last each sep final = start where
    start  = each >>= loop
    loop a = option a $ do
               build <- sep
               choice
                 [ each >>= loop . build a,
                   final >>= return . build a ]

chainr1last :: P a -> P (a -> a -> a) -> P a -> P a
chainr1last each sep final = start where
    start  = do
      a       <- each
      builder <- loop
      return (builder a)
    loop   = option id $ do
               build <- sep
               choice
                 [ do
                     b       <- each
                     builder <- loop
                     return (\a -> a `build` builder b),
                   do
                     b       <- final
                     return (\a -> a `build` b) ]

-- Just uppercase identifiers
uidp :: P Uid
uidp  = uid >>! Uid

-- Just lowercase identifiers
lidp :: P Lid
lidp  = lid >>! Lid

-- Lowercase identifiers or naturals
--  - tycon declarations
lidnatp :: P Lid
lidnatp = choice [ lid, natural >>! show ] >>! Lid

-- Just operators
operatorp :: P Lid
operatorp  = try (parens operator) >>! Lid

-- Add a path before something
pathp :: P ([Uid] -> b) -> P b
pathp p = try $ do
  path <- many $ try $ liftM2 const uidp dot
  make <- p
  return (make path)

-- Qualified uppercase identifiers:
--  - module names occurences
--  - datacons in patterns (though path is ignored)
quidp :: P QUid
quidp  = pathp (uidp >>! flip J)

-- Qualified lowercase identifiers:
-- qlidp :: P QLid
-- qlidp  = pathp (lidp >>! flip J)

-- Qualified lowercase identifiers or naturals:
--  - tycon occurences
qlidnatp :: P QLid
qlidnatp  = pathp (lidnatp >>! flip J)

-- Lowercase identifiers and operators
--  - variable bindings
varp :: P Lid
varp  = lidp <|> operatorp

-- Qualified lowercase identifers and operators
--  - variable occurences
-- qvarp :: P QLid
-- qvarp  = pathp (varp >>! flip J)

-- Identifier expressions
identp :: P (Expr ())
identp  = addLoc $ pathp $ choice
  [ do v <- varp
       return $ \path -> exVar (J path v),
    do c <- uidp
       return $ \path -> exCon (J path c) ]

-- Type variables
tyvarp :: P TyVar
tyvarp  = do
  char '\''
  q <- choice
       [ do char '<'; return Qa,
         return Qu ]
  x <- lidp
  return (TV x q)

oplevelp :: Prec -> P Lid
oplevelp  = liftM Lid . opP

typep  :: P (Type ())
typep   = typepP precStart

typepP :: Int -> P (Type ())
typepP p | p == precStart
         = choice
  [ do tc <- choice
         [ reserved "all" >> return tyAll,
           reserved "ex"  >> return tyEx,
           reserved "mu"  >> return TyMu ]
       tvs <- many tyvarp
       dot
       t   <- typepP p
       return (foldr tc t tvs),
    typepP (p + 1) ]
typepP p | p == precArr
         = chainr1last (typepP (p + 1)) tyop (typepP precStart) where
             tyop = choice [ arrow, lolli ] >>! tyBinOp
typepP p | p == precPlus
         = chainl1last (typepP (p + 1)) tyop (typepP precStart) where
             tyop = plus >>! tyBinOp
typepP p | p == precStar
         = chainl1last (typepP (p + 1)) tyop (typepP precStart) where
             tyop = choice [ star, slash ] >>! tyBinOp
typepP p | p == precSemi
         = chainr1last (typepP (p + 1)) tyop (typepP precStart) where
             tyop = semi >>! tyBinOp
typepP p | p == precApp -- this case ensures termination
         = tyarg >>= tyapp'
  where
  tyarg :: P [Type ()]
  tyarg  = choice
           [ do args <- parens $ commaSep1 (typepP precStart)
                return args,
             do tv   <- tyvarp
                return [TyVar tv],
             do tc   <- qlidnatp
                return [TyCon tc [] ()] ]

  tyapp' :: [Type ()] -> P (Type ())
  tyapp' [t] = option t $ do
                 tc <- qlidnatp
                 tyapp' [TyCon tc [t] ()]
  tyapp' ts  = do
                 tc <- qlidnatp
                 tyapp' [TyCon tc ts ()]
typepP p | p <= precMax
         = typepP (p + 1)
typepP _ = typepP precStart

progp :: P (Prog ())
progp  = choice [
           do ds <- declsp
              when (null ds) pzero
              e  <- optionMaybe (reserved "in" >> exprp)
              return (Prog ds e),
           exprp >>! (Prog [] . Just)
         ]

declsp :: P [Decl ()]
declsp  = choice [
            do
              d  <- declp
              ds <- declsp
              return (d : ds),
            do
              sharpLoad
              base <- sourceName `liftM` getPosition
              path <- inDirectoryOf base `liftM` stringLiteral
              let contents = unsafePerformIO $ readFile path
              ds <- case parse parseProg path contents of
                Left e   -> fail (show e)
                Right p  -> return (prog2decls p)
              ds' <- declsp
              return (ds ++ ds'),
            return []
          ]
  where inDirectoryOf "-"  path = path
        inDirectoryOf base path = dropFileName base </> path

declp :: P (Decl ())
declp  = addLoc $ choice [
           do
             reserved "type"
             sepBy1 tyDecp (reserved "and") >>! dcTyp,
           letp,
           do
             reserved "open"
             modexpp >>! dcOpn,
           do
             reserved "module"
             n <- uidp
             reservedOp "="
             b <- modexpp
             return (dcMod n b),
           do
             reserved "local"
             ds0 <- declsp
             reserved "with"
             ds1 <- declsp
             reserved "end"
             return (dcLoc ds0 ds1),
           do
             reserved "abstype"
             at <- abstyp
             reserved "with"
             ds <- declsp
             reserved "end"
             return (dcAbs at ds),
           do
             reserved "exception"
             n  <- uidp
             t  <- optionMaybe $ do
               reserved "of"
               typep
             return (dcExn n t)
         ]

modexpp :: P (ModExp ())
modexpp  = choice [
             do
               reserved "struct"
               ds <- declsp
               reserved "end"
               return (MeStr ds),
             quidp >>! MeName
           ]

tyDecp :: P TyDec
tyDecp = do
  (arity, tvs, name) <- tyProtp
  choice [
    do
      unless (all (== Invariant) arity) pzero
      reservedOp "="
      choice [
        typep >>! TdSyn name tvs,
        altsp >>! TdDat name tvs ],
    do
      quals <- qualsp
      return (TdAbs name tvs arity quals) ]

tyProtp :: P ([Variance], [TyVar], Lid)
tyProtp  = choice [
  try $ do
    (v1, tv1) <- paramVp
    con <- choice [ arrow, lolli, semi, star, slash, plus ] >>! Lid
    (v2, tv2) <- paramVp
    return ([v1, v2], [tv1, tv2], con),
  do
    (arity, tvs) <- paramsVp
    name         <- lidnatp
    return (arity, tvs, name)
  ]

letp :: P (Decl ())
letp  = do
  reserved "let"
  choice [
    do
      bindings <- flip sepBy1 (reserved "and") $ do
        f <- varp
        (sigma, fixt, fixe) <- afargsp
        colon
        t <- typep
        reservedOp "="
        e <- withSigma sigma exprp
        return (Binding f (fixt t) (fixe e))
      let names    = map bnvar bindings
          namesExp = foldl1 exPair (map exBVar names)
          namesPat = foldl1 PaPair (map PaVar names)
          tempVar  = Lid "#letrec"
          decls0   = [ dcLet tempVar Nothing $
                         exLetRec bindings namesExp ]
          decls1   = [ dcLet (bnvar binding) Nothing $
                         exLet namesPat (exBVar tempVar) $
                            exBVar (bnvar binding)
                     | binding <- bindings ]
      return $ dcLoc decls0 decls1,
    do
      f <- varp
      (sigma, fixt, fixe) <- afargsp
      t <- optionMaybe $ colon >> typep
      reservedOp "="
      e <- withSigma sigma exprp
      return (dcLet f (fmap fixt t) (fixe e))
    ]

abstyp :: P [AbsTy]
abstyp = flip sepBy (reserved "and") $ do
  (arity, tvs, name) <- tyProtp
  quals        <- qualsp
  reservedOp "="
  alts         <- altsp
  return (arity, quals, TdDat name tvs alts)

paramsVp :: P ([Variance], [TyVar])
paramsVp  = delimList (return ()) parens comma paramVp >>! unzip

qualsp   :: P [Either TyVar Q]
qualsp    = delimList (reserved "qualifier") parens (symbol "\\/") qualp

paramVp :: P (Variance, TyVar)
paramVp = do
  v  <- variancep
  tv <- tyvarp
  return (v, tv)

variancep :: P Variance
variancep =
  choice
    [ char '+' >> return Covariant,
      char '-' >> return Contravariant,
      char '0' >> return Omnivariant,
      char '1' >> return Invariant,
      return Invariant ]

qualp :: P (Either TyVar Q)
qualp = choice
  [ litqualp >>! Right,
    tyvarp   >>! Left ]

litqualp :: P Q
litqualp = choice
  [ qualU    >> return Qu,
    qualA    >> return Qa ]

altsp :: P [(Uid, Maybe (Type ()))]
altsp  = sepBy1 altp (reservedOp "|")

altp  :: P (Uid, Maybe (Type ()))
altp   = do
  k <- uidp
  t <- optionMaybe $ do
    reserved "of"
    typep
  return (k, t)

exprp :: P (Expr ())
exprp = expr0 where
  onlyOne [x] = [x True]
  onlyOne xs  = map ($ False) xs
  expr0 = addLoc $ choice
    [ do reserved "let"
         choice
           [ do reserved "rec"
                bs <- flip sepBy1 (reserved "and") $ do
                  x    <- varp
                  (sigma, ft, fe) <- afargsp
                  colon
                  t    <- typep
                  reservedOp "="
                  e    <- withSigma sigma expr0
                  return (Binding x (ft t) (fe e))
                reserved "in"
                e2 <- expr0
                return (exLetRec bs e2),
             do (x, sigma, lift) <- pattbangp
                if sigma
                  then do
                    reservedOp "="
                    e1 <- expr0
                    reserved "in"
                    e2 <- withSigma True expr0
                    return (lift True (flip exLet e1) x e2)
                  else do
                    (sigma', args) <- argsp
                    reservedOp "="
                    e1 <- withSigma sigma' expr0
                    reserved "in"
                    e2 <- expr0
                    return (exLet x (args e1) e2),
             do reserved "let"
                unexpected "let",
             do d    <- withSigma False declp
                reserved "in"
                e2   <- expr0
                return (exLetDecl d e2) ],
      do reserved "if"
         ec <- expr0
         reserved "then"
         et <- expr0
         reserved "else"
         ef <- expr0
         return (exCase ec [(PaCon (Uid "true")  Nothing Nothing, et),
                            (PaCon (Uid "false") Nothing Nothing, ef)]),
      do reserved "match"
         e1 <- expr0
         reserved "with"
         optional (reservedOp "|")
         clauses <- flip sepBy1 (reservedOp "|") $ do
           (xi, sigma, lift) <- pattbangp
           reservedOp "->"
           ei <- mapSigma (sigma ||) expr0
           return (\b -> lift b (,) xi ei)
         return (exCase e1 (onlyOne clauses)),
      do reserved "try"
         e1 <- expr0
         reserved "with"
         optional (reservedOp "|")
         clauses <- flip sepBy1 (reservedOp "|") $ do
           (xi, sigma, lift) <- pattbangp
           reservedOp "->"
           ei <- mapSigma (sigma ||) expr0
           return $ \b ->
             lift b (\xi' ei' ->
                     (PaCon (Uid "Left") (Just xi') Nothing, ei'))
                  xi ei
         let tryQ = qlid $
                      "INTERNALS.Exn.try"
         return (exCase (exApp (exVar tryQ)
                               (exAbs PaWild (tyNulOp "unit") e1)) $
                  (PaCon (Uid "Right") (Just (PaVar (Lid "x"))) Nothing,
                   exVar (qlid "x")) :
                  onlyOne clauses ++
                  [(PaCon (Uid "Left") (Just (PaVar (Lid "e"))) Nothing,
                    exApp (exVar (qlid "INTERNALS.Exn.raise"))
                          (exVar (qlid "e")))]),
      do reserved "fun"
         (sigma, build) <- choice
           [
             argsp1,
             do
               (x, sigma, lift) <- pattbangp
               colon
               t <- typepP (precArr + 1)
               return (sigma, lift True (flip exAbs t) x)
           ]
         arrow
         withSigma sigma expr0 >>! build,
      expr1 ]
  expr1 = addLoc $ do
            e1 <- expr3
            choice
              [ do semi
                   e2 <- expr0
                   return (exSeq e1 e2),
                return e1 ]
  expr3 = chainl1last expr4 (opappp (Left 3))  expr0
  expr4 = chainr1last expr5 (opappp (Right 4)) expr0
  expr5 = chainl1last expr6 (opappp (Left 5))  expr0
  expr6 = chainl1last expr7 (opappp (Left 6))  expr0
  expr7 = expr8
  expr8 = chainr1last expr9 (opappp (Right 8)) expr0
  expr9 = choice
            [ chainl1 expr10 (addLoc (return exApp)),
              do
                reserved "Pack"
                t1 <- optionMaybe (brackets typep)
                parens $ do
                  t2 <- typep
                  comma
                  e  <- exprN1
                  return (exPack t1 t2 e)
                ]
  expr10 = do
    ops <- many $ addLoc $ oplevelp (Right 10) >>! exBVar
    arg <- expr11
    return (foldr exApp arg ops)
  expr11 = do
             e  <- exprA
             ts <- many . brackets $ commaSep1 typep
             return (foldl exTApp e (concat ts))
  exprA = addLoc $ choice
    [ identp,
      integerOrFloat >>! either exInt exFloat,
      charLiteral    >>! (exInt . fromIntegral . fromEnum),
      stringLiteral  >>! exStr,
      parens (exprN1 <|> return (exBCon (Uid "()")))
    ]
  exprN1 = addLoc $ do
    e1 <- expr0
    choice
      [ do t1 <- optionMaybe $ do reservedOp ":"; typep
           reservedOp ":>"
           t2 <- typep
           return (exCast e1 t1 t2),
        do comma
           es <- commaSep1 expr0
           return (foldl exPair e1 es),
        return e1 ]

-- Parse an infix operator at given precedence
opappp :: Prec -> P (Expr () -> Expr () -> Expr ())
opappp p = do
  loc <- curLoc
  op  <- oplevelp p
  return (\e1 e2 -> (exBVar op <<@ loc `exApp` e1) `exApp` e2)

-- Zero or more of (pat:typ, ...), (), or tyvar, recognizing '|'
-- to introduce affine arrows
afargsp :: P (Bool, Type () -> Type (), Expr () -> Expr ())
afargsp = loop tyArr where
  loop arrcon0 = do
    arrcon <- option arrcon0 $ do
      reservedOp "|"
      return tyLol
    choice
      [ do (tvt, tve) <- tyargp
           (b, ft, fe) <- loop arrcon
           return (b, tvt . ft, tve . fe),
        do (b, ft, fe) <- vargp arrcon
           if b
              then return (b, ft, fe)
              else do
                (b', fts, fes) <- loop arrcon
                return (b', ft . fts, fe . fes),
        return (False, id, id) ]

-- One or more of (pat:typ, ...), (), tyvar
argsp1 :: P (Bool, Expr () -> Expr ())
argsp1  = do
           (b, fe) <- argp
           if b
             then return (b, fe)
             else second (fe .) `fmap` option (False, id) argsp1

-- Zero or more of (pat:typ, ...), (), tyvar
argsp :: P (Bool, Expr () -> Expr ())
argsp  = option (False, id) $ do
           (b, fe) <- argp
           if b
             then return (b, fe)
             else second (fe .) `fmap` argsp

-- Parse a (pat:typ, ...), (), or tyvar
argp :: P (Bool, Expr () -> Expr ())
argp  = choice [
          do
            (_, fe)    <- tyargp
            return (False, fe),
          do
            (b, _, fe) <- vargp const
            return (b, fe)
        ]

-- Parse a (pat:typ, ...) or () argument
vargp :: (Type () -> Type () -> Type ()) ->
         P (Bool, Type () -> Type (), Expr () -> Expr ())
vargp arrcon = do
  loc    <- curLoc
  inBang <- bangp
  (p, t) <- paty
  return (inBang, arrcon t, condSigma inBang True (flip exAbs t) p <<@ loc)

-- Parse a (pat:typ, ...) or () argument
paty :: P (Patt, Type ())
paty  = do
  (p, mt) <- pamty
  case (p, mt) of
    (_, Just t) -> return (p, t)
    (PaCon (Uid "()") Nothing Nothing, Nothing)
                -> return (p, tyNulOp "unit")
    _           -> pzero <?> ":"

-- Parse a (), (pat:typ, ...) or (pat) argument
pamty :: P (Patt, Maybe (Type ()))
pamty  = parens $ choice
           [
             do
               (p, mt) <- pamty
               maybe (maybecolon p) (morepts p) mt,
             do
               p <- pattp
               maybecolon p,
             return (PaCon (Uid "()") Nothing Nothing, Nothing)
           ]
  where
    maybecolon p = choice
      [
        do
          colon
          t <- typep
          morepts p t,
        moreps p
      ]
    moreps p = do
      ps <- many (comma >> pattp)
      return (foldl PaPair p ps, Nothing)
    morepts p0 t0 = do
      (ps, ts) <- liftM unzip . many $ do
        comma
        choice
          [
            do
              (p, mt) <- pamty
              case mt of
                Just t  -> return (p, t)
                Nothing -> colonType p,
            do
              p <- pattp
              colonType p
          ]
      return (foldl PaPair p0 ps, Just (foldl tyTuple t0 ts))
    colonType p = do
      colon
      t <- typep
      return (p, t)

-- Parse a sequence of one or more tyvar arguments
tyargp :: P (Type () -> Type (), Expr () -> Expr ())
tyargp  = do
  tvs <- liftM return loctv <|> brackets (commaSep1 loctv)
  return (\t -> foldr (\(_,   tv) -> tyAll tv) t tvs,
          \e -> foldr (\(loc, tv) -> exTAbs tv <<@ loc) e tvs)
    where
  loctv = liftM2 (,) curLoc tyvarp

pattbangp :: P (Patt, Bool,
                Bool -> (Patt -> Expr () -> b) -> Patt -> Expr () -> b)
pattbangp = do
  inSigma <- getSigma
  inBang  <- bangp
  x       <- pattp
  let trans = inBang && not inSigma
      wrap  = inBang && inSigma
  return (condMakeBang wrap x, inBang, condSigma trans)

condSigma :: Bool -> Bool ->
             (Patt -> Expr () -> a) ->
             Patt -> Expr () -> a
condSigma True  = exSigma
condSigma False = const id

condMakeBang :: Bool -> Patt -> Patt
condMakeBang True  = makeBangPatt
condMakeBang False = id

bangp :: P Bool
bangp  = (bang >> return True) <|> return False

pattp :: P Patt
pattp  = patt0 where
  patt0 = do
    x <- patt9
    choice
      [ do
          reserved "as"
          y <- varp
          return (PaAs x y),
        return x
      ]
  patt9 = choice
    [ do
        reserved "Pack"
        parens $ do
          tv <- tyvarp
          comma
          x  <- pattN1
          return (PaPack tv x),
      do
        J _ u <- quidp
        x     <- optionMaybe (try pattA)
        return (PaCon u x Nothing),
      pattA ]
  pattA = choice
    [ reserved "_"  >>  return PaWild,
      varp          >>! PaVar,
      integer       >>! PaInt,
      charLiteral   >>! (PaInt . fromIntegral . fromEnum),
      stringLiteral >>! PaStr,
      parens pattN1
    ]
  pattN1 = do
    xs <- commaSep patt0
    case xs of
      []    -> return (PaCon (Uid "()") Nothing Nothing)
      x:xs' -> return (foldl PaPair x xs')

finish :: CharParser st a -> CharParser st a
finish p = do
  optional (whiteSpace)
  r <- p
  eof
  return r

-- | Parse a program
parseProg     :: P (Prog ())
-- | Parse a sequence of declarations
parseDecls    :: P [Decl ()]
-- | Parse a declaration
parseDecl     :: P (Decl ())
-- | Parse a type declaration
parseTyDec    :: P TyDec
-- | Parse a type
parseType     :: P (Type ())
-- | Parse an expression
parseExpr     :: P (Expr ())
-- | Parse a pattern
parsePatt     :: P Patt
parseProg      = finish progp
parseDecls     = finish declsp
parseDecl      = finish declp
parseTyDec     = finish tyDecp
parseType      = finish typep
parseExpr      = finish exprp
parsePatt      = finish pattp

-- Convenience functions for quick-and-dirty parsing:

-- | Parse a program
pp  :: String -> Prog ()
pp   = makeQaD parseProg

-- | Parse a sequence of declarations
pds :: String -> [Decl ()]
pds  = makeQaD parseDecls

-- | Parse a declaration
pd  :: String -> Decl ()
pd   = makeQaD parseDecl

-- | Parse a type declaration
ptd :: String -> TyDec
ptd  = makeQaD parseTyDec

-- | Parse a type
pt  :: String -> Type ()
pt   = makeQaD parseType

-- | Parse an expression
pe  :: String -> Expr ()
pe   = makeQaD parseExpr

-- | Parse a pattern
px  :: String -> Patt
px   = makeQaD parsePatt

makeQaD :: P a -> String -> a
makeQaD parser =
  either (error . show) id . runParser parser state0 "<string>"
