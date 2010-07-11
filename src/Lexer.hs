-- | Lexer setup for parsec
module Lexer (
  -- * Identifier tokens
  isUpperIdentifier, lid, uid,

  -- * Special, unreserved operators
  sharpLoad, sharpInfo,
  semis, bang, star, slash, plus,
  lolli, arrow, funbraces, funbraceLeft, funbraceRight,
  qualbox, qualboxLeft, qualboxRight,
  qualU, qualA,
  opP,

  -- * Token parsers from Parsec
  identifier, reserved, operator, reservedOp, charLiteral,
  stringLiteral, natural, integer, integerOrFloat, float,
  naturalOrFloat, decimal, hexadecimal, octal, symbol, lexeme,
  whiteSpace, parens, braces, angles, brackets, squares, semi, comma,
  colon, dot, semiSep, semiSep1, commaSep, commaSep1
) where

import Prec

import Data.Char (isUpper)
import Text.ParserCombinators.Parsec
import qualified Text.ParserCombinators.Parsec.Token as T

tok :: T.TokenParser st
tok = T.makeTokenParser T.LanguageDef {
    T.commentStart   = "(*",
    T.commentEnd     = "*)",
    T.commentLine    = "--",
    T.nestedComments = True,
    T.identStart     = upper <|> lower <|> oneOf "_",
    T.identLetter    = alphaNum <|> oneOf "_'",
    T.opStart        = oneOf "!$%&*+-/<=>?@^|~",
    T.opLetter       = oneOf "!$%&*+-/<=>?@^|~.:",
    T.reservedNames  = ["fun", "sigma",
                        "if", "then", "else",
                        "match", "with", "as", "_",
                        "try",
                        "local", "open", "exception",
                        "let", "rec", "and", "in",
                        "Pack",
                        "interface", "abstype", "end",
                        "module", "struct",
                        "sig", "val", "include",
                        "all", "ex", "mu", "of",
                        "type", "qualifier"],
    T.reservedOpNames = ["|", "=", ":", ":>", "->"],
    T.caseSensitive = True
  }

identifier      :: CharParser st String
identifier       = T.identifier tok
reserved        :: String -> CharParser st ()
reserved         = T.reserved tok
operator        :: CharParser st String
operator         = T.operator tok
reservedOp      :: String -> CharParser st ()
reservedOp       = T.reservedOp tok
charLiteral     :: CharParser st Char
charLiteral      = T.charLiteral tok
stringLiteral   :: CharParser st String
stringLiteral    = T.stringLiteral tok
natural         :: CharParser st Integer
natural          = T.natural tok
integer         :: CharParser st Integer
integer          = lexeme $ try $ do
  sign <- choice [
            char '+' >> return id,
            char '-' >> return negate,
            return id
          ]
  nat  <- natural
  return (sign nat)
integerOrFloat  :: CharParser st (Either Integer Double)
integerOrFloat   = lexeme $ try $ do
  sign <- choice [
            char '+' >> return id,
            char '-' >> return (either (Left . negate) (Right . negate)),
            return id
          ]
  nof  <- naturalOrFloat
  return (sign nof)
 
float           :: CharParser st Double
float            = T.float tok
naturalOrFloat  :: CharParser st (Either Integer Double)
naturalOrFloat   = T.naturalOrFloat tok
decimal         :: CharParser st Integer
decimal          = T.decimal tok
hexadecimal     :: CharParser st Integer
hexadecimal      = T.hexadecimal tok
octal           :: CharParser st Integer
octal            = T.octal tok
symbol          :: String -> CharParser st String
symbol           = T.symbol tok
lexeme          :: CharParser st a -> CharParser st a
lexeme           = T.lexeme tok
whiteSpace      :: CharParser st ()
whiteSpace       = T.whiteSpace tok
parens          :: CharParser st a -> CharParser st a
parens           = T.parens tok
braces          :: CharParser st a -> CharParser st a
braces           = T.braces tok
angles          :: CharParser st a -> CharParser st a
angles           = T.angles tok
brackets        :: CharParser st a -> CharParser st a
brackets         = T.brackets tok
squares         :: CharParser st a -> CharParser st a
squares          = T.squares tok
semi            :: CharParser st String
semi             = T.semi tok
comma           :: CharParser st String
comma            = T.comma tok
colon           :: CharParser st String
colon            = T.reservedOp tok ":" >> return ":"
dot             :: CharParser st String
dot              = T.dot tok
semiSep         :: CharParser st a -> CharParser st [a]
semiSep          = T.semiSep tok
semiSep1        :: CharParser st a -> CharParser st [a]
semiSep1         = T.semiSep1 tok
commaSep        :: CharParser st a -> CharParser st [a]
commaSep         = T.commaSep tok
commaSep1       :: CharParser st a -> CharParser st [a]
commaSep1        = T.commaSep1 tok

-- | The @#load@ pragma
sharpLoad       :: CharParser st ()
sharpLoad        = reserved "#l" <|> reserved "#load"

-- | The @#info@ pragma
sharpInfo       :: CharParser st ()
sharpInfo        = reserved "#i" <|> reserved "#info"

-- | @!@, which has special meaning in let patterns
bang            :: CharParser st String
bang             = symbol "!"

-- | The @-o@ type operator, which violates our other lexer rules
lolli           :: CharParser st ()
lolli            = reserved "-o"

-- | The @->@ type operator
arrow           :: CharParser st ()
arrow            = reservedOp "->"

-- | The left part of the $-[_]>$ operator
funbraceLeft    :: CharParser st ()
funbraceLeft     = try (symbol "-[") >> return ()

-- | The right part of the $-[_]>$ operator
funbraceRight   :: CharParser st ()
funbraceRight    = try (symbol "]>") >> return ()

funbraces       :: CharParser st a -> CharParser st a
funbraces        = between funbraceLeft funbraceRight

-- | The left part of the $|[_]$ annotation
qualboxLeft     :: CharParser st ()
qualboxLeft      = try (symbol "|[") >> return ()

-- | The right part of the $|[_]$ annotation
qualboxRight    :: CharParser st ()
qualboxRight     = try (symbol "]") >> return ()

qualbox         :: CharParser st a -> CharParser st a
qualbox          = between qualboxLeft qualboxRight

-- | @;@, @;;@, ...
semis           :: CharParser st String
semis            = lexeme (many1 (char ';'))

-- | @*@, which is reserved in types but not in expressions
star            :: CharParser st String
star             = symbol "*"

-- | @/@, which is reserved in types but not in expressions
slash           :: CharParser st String
slash            = symbol "/"

-- | @+@, which is reserved in types but not in expressions
plus            :: CharParser st String
plus             = symbol "+"

-- | Qualifier @U@ (not reserved)
qualU    :: CharParser st ()
qualU     = reserved "U"
-- | Qualifier @A@ (not reserved)
qualA    :: CharParser st ()
qualA     = reserved "A"

-- | Is the string an uppercase identifier?  (Special case: @true@ and
--   @false@ are consider uppercase.)
isUpperIdentifier :: String -> Bool
isUpperIdentifier "true"  = True
isUpperIdentifier "false" = True
isUpperIdentifier "()"    = True
isUpperIdentifier (c:_)   = isUpper c
isUpperIdentifier _       = False

-- | Lex a lowercase identifer
lid        :: CharParser st String
lid              = try $ do
  s <- identifier
  if isUpperIdentifier s
    then pzero <?> "lowercase identifier"
    else return s
-- | Lex an uppercase identifer
uid        :: CharParser st String
uid              = try $ do
  s <- identifier <|> symbol "()"
  if isUpperIdentifier s
    then return s
    else pzero <?> "uppercase identifier"

-- | Accept an operator having the specified precedence
opP :: Prec -> CharParser st String
opP p = try $ do
  op <- operator
  if precOp op == p
    then return op
    else pzero

