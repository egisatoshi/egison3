{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TupleSections    #-}

{- |
Module      : Language.Egison.ParserNonS
Copyright   : Satoshi Egi
Licence     : MIT

This module provide Egison parser.
-}

module Language.Egison.ParserNonS2
       (
       -- * Parse a string
         readTopExprs
       , readTopExpr
       , readExprs
       , readExpr
       , parseTopExprs
       , parseTopExpr
       , parseExprs
       , parseExpr
       -- * Parse a file
       , loadLibraryFile
       , loadFile
       ) where

import           Control.Applicative            (pure, (*>), (<$>), (<$), (<*), (<*>))
import           Control.Monad.Except           (liftIO, throwError)
import           Control.Monad.State            (unless)
import           Prelude                        hiding (mapM)

import           System.Directory               (doesFileExist, getHomeDirectory)

import           Data.Functor                   (($>))
import           Data.Maybe                     (fromMaybe)
import           Data.Traversable               (mapM)

import           Control.Monad.Combinators.Expr
import           Data.Void
import           Text.Megaparsec
import           Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer     as L
import           Text.Megaparsec.Debug
import           Text.Megaparsec.Pos            (Pos)

import           Data.Text                      (pack)

import           Language.Egison.Desugar
import           Language.Egison.Types
import           Paths_egison                   (getDataFileName)

readTopExprs :: String -> EgisonM [EgisonTopExpr]
readTopExprs = either throwError (mapM desugarTopExpr) . parseTopExprs

readTopExpr :: String -> EgisonM EgisonTopExpr
readTopExpr = either throwError desugarTopExpr . parseTopExpr

readExprs :: String -> EgisonM [EgisonExpr]
readExprs = liftEgisonM . runDesugarM . either throwError (mapM desugar) . parseExprs

readExpr :: String -> EgisonM EgisonExpr
readExpr = liftEgisonM . runDesugarM . either throwError desugar . parseExpr

parseTopExprs :: String -> Either EgisonError [EgisonTopExpr]
parseTopExprs = doParse $ many (L.nonIndented sc topExpr) <* eof

parseTopExpr :: String -> Either EgisonError EgisonTopExpr
parseTopExpr = doParse $ sc >> topExpr

parseExprs :: String -> Either EgisonError [EgisonExpr]
parseExprs = doParse $ many (L.nonIndented sc expr) <* eof

parseExpr :: String -> Either EgisonError EgisonExpr
parseExpr = doParse $ sc >> expr

-- |Load a libary file
loadLibraryFile :: FilePath -> EgisonM [EgisonTopExpr]
loadLibraryFile file = do
  homeDir <- liftIO getHomeDirectory
  doesExist <- liftIO $ doesFileExist $ homeDir ++ "/.egison/" ++ file
  if doesExist
    then loadFile $ homeDir ++ "/.egison/" ++ file
    else liftIO (getDataFileName file) >>= loadFile

-- |Load a file
loadFile :: FilePath -> EgisonM [EgisonTopExpr]
loadFile file = do
  doesExist <- liftIO $ doesFileExist file
  unless doesExist $ throwError $ Default ("file does not exist: " ++ file)
  input <- liftIO $ readUTF8File file
  exprs <- readTopExprs $ shebang input
  concat <$> mapM  recursiveLoad exprs
 where
  recursiveLoad (Load file)     = loadLibraryFile file
  recursiveLoad (LoadFile file) = loadFile file
  recursiveLoad expr            = return [expr]
  shebang :: String -> String
  shebang ('#':'!':cs) = ';':'#':'!':cs
  shebang cs           = cs

--
-- Parser
--

type Parser = Parsec Void String

doParse :: Parser a -> String -> Either EgisonError a
doParse p input = either (throwError . fromParsecError) return $ parse p "egison" input
  where
    fromParsecError :: ParseErrorBundle String Void -> EgisonError
    fromParsecError = Parser . errorBundlePretty

--
-- Expressions
--

topExpr :: Parser EgisonTopExpr
topExpr = Load     <$> (keywordLoad >> stringLiteral)
      <|> LoadFile <$> (keywordLoadFile >> stringLiteral)
      <|> defineOrTestExpr

defineOrTestExpr :: Parser EgisonTopExpr
defineOrTestExpr = do
  e <- expr
  (do symbol "="
      body <- expr
      return (convertToDefine e body))
      <|> return (Test e)
  where
    convertToDefine :: EgisonExpr -> EgisonExpr -> EgisonTopExpr
    convertToDefine (VarExpr var) body = Define var body
    convertToDefine (ApplyExpr (VarExpr var) (TupleExpr args)) body =
      Define var (LambdaExpr (map exprToArg args) body)

    -- TODO(momohatt): Handle other types of arg
    exprToArg :: EgisonExpr -> Arg
    exprToArg (VarExpr (Var [x] [])) = ScalarArg x

expr :: Parser EgisonExpr
expr = ifExpr
   <|> patternMatchExpr
   <|> lambdaExpr
   <|> letExpr
   <|> matcherExpr
   <|> algebraicDataMatcherExpr
   <|> dbg "opExpr" opExpr
   <?> "expressions"

-- Also parses atomExpr
opExpr :: Parser EgisonExpr
opExpr = do
  pos <- L.indentLevel
  makeExprParser atomOrAppExpr (makeTable pos)
  where
    -- TODO(momohatt): Parse function application here (this would require
    -- currying of functions)
    makeTable :: Pos -> [[Operator Parser EgisonExpr]]
    makeTable pos =
      let unary  internalName parseSym =
            makeUnaryApply  internalName <$ parseSym
          binary internalName parseSym =
            makeBinaryApply internalName <$ (L.indentGuard sc GT pos >> parseSym)
       in
          [ [ Prefix (unary  "-"         $ symbol "-" ) ]
          -- 8
          , [ InfixL (binary "**"        $ symbol "^" ) ]
          -- 7
          , [ InfixL (binary "*"         $ symbol "*" )
            , InfixL (binary "/"         $ symbol "/" )
            , InfixL (binary "remainder" $ symbol "%" ) ]
          -- 6
          , [ InfixL (binary "+"         $ try $ symbol "+" <* notFollowedBy (char '+'))
            , InfixL (binary "-"         $ symbol "-" ) ]
          -- 5
          , [ InfixR (binary "cons"      $ symbol ":" )
            , InfixR (binary "append"    $ symbol "++") ]
          -- 4
          , [ InfixL (binary "eq?"       $ symbol "==")
            , InfixL (binary "lte?"      $ symbol "<=")
            , InfixL (binary "lt?"       $ symbol "<" )
            , InfixL (binary "gte?"      $ symbol ">=")
            , InfixL (binary "gt?"       $ symbol ">" ) ]
          -- 3
          , [ InfixR (binary "and"       $ symbol "&&") ]
          -- 2
          , [ InfixR (binary "or"        $ symbol "||") ]
          ]


ifExpr :: Parser EgisonExpr
ifExpr = keywordIf >> IfExpr <$> expr <* keywordThen <*> expr <* keywordElse <*> expr

patternMatchExpr :: Parser EgisonExpr
patternMatchExpr = makeMatchExpr keywordMatch       MatchExpr
               <|> makeMatchExpr keywordMatchDFS    MatchDFSExpr
               <|> makeMatchExpr keywordMatchAll    MatchAllExpr
               <|> makeMatchExpr keywordMatchAllDFS MatchAllDFSExpr
  where
    makeMatchExpr keyword ctor = do
      pos     <- L.indentLevel
      tgt     <- keyword >> expr
      matcher <- keywordAs >> expr
      clauses <- keywordWith >> matchClauses1 pos
      return $ ctor tgt matcher clauses

matchClauses1 :: Pos -> Parser [MatchClause]
matchClauses1 pos = (:) <$> (optional (symbol "|") >> matchClause pos) <*> matchClauses pos
  where
    matchClauses :: Pos -> Parser [MatchClause]
    matchClauses pos = try ((:) <$> (symbol "|" >> matchClause pos) <*> matchClauses pos)
                   <|> (return [])
    matchClause :: Pos -> Parser MatchClause
    matchClause pos = (,) <$> (L.indentGuard sc GT pos *> pattern) <*> (symbol "->" >> expr)

lambdaExpr :: Parser EgisonExpr
lambdaExpr = symbol "\\" >> (
      makeMatchLambdaExpr keywordMatch    MatchLambdaExpr
  <|> makeMatchLambdaExpr keywordMatchAll MatchAllLambdaExpr
  <|> LambdaExpr <$> some arg <*> (symbol "->" >> expr))
  where
    makeMatchLambdaExpr keyword ctor = do
      pos     <- L.indentLevel
      matcher <- keyword >> keywordAs >> expr
      clauses <- keywordWith >> matchClauses1 pos
      return $ ctor matcher clauses

arg :: Parser Arg
arg = ScalarArg         <$> (symbol "$"  >> identifier)
  <|> InvertedScalarArg <$> (symbol "*$" >> identifier)
  <|> TensorArg         <$> (symbol "%"  >> identifier)
  <|> ScalarArg         <$> identifier

letExpr :: Parser EgisonExpr
letExpr = do
  pos   <- keywordLet >> L.indentLevel
  binds <- some (L.indentGuard sc EQ pos *> binding)
  body  <- keywordIn >> expr
  return $ LetStarExpr binds body

binding :: Parser BindingExpr
binding = do
  vars <- ((:[]) <$> varLiteral) <|> (parens $ sepBy varLiteral comma)
  body <- symbol "=" >> expr
  return (vars, body)

applyExpr :: Parser EgisonExpr
applyExpr = do
  pos <- L.indentLevel
  func <- atomExpr
  args <- some (L.indentGuard sc GT pos *> atomExpr)
  return $ makeApply func args

matcherExpr :: Parser EgisonExpr
matcherExpr = do
  keywordMatcher
  pos <- L.indentLevel
  -- In matcher expression, the first '|' (bar) is indispensable
  info <- some (L.indentGuard sc EQ pos >> symbol "|" >> patternDef)
  return $ MatcherExpr info
  where
    patternDef :: Parser (PrimitivePatPattern, EgisonExpr, [(PrimitiveDataPattern, EgisonExpr)])
    patternDef = do
      pp <- ppPattern
      returnMatcher <- keywordAs >> expr <* keywordWith
      pos <- L.indentLevel
      datapat <- some (L.indentGuard sc EQ pos >> symbol "|" >> dataCases)
      return (pp, returnMatcher, datapat)

    dataCases :: Parser (PrimitiveDataPattern, EgisonExpr)
    dataCases = (,) <$> pdPattern <*> (symbol "->" >> expr)

algebraicDataMatcherExpr :: Parser EgisonExpr
algebraicDataMatcherExpr = do
  keywordAlgebraicDataMatcher
  pos <- L.indentLevel
  defs <- some (L.indentGuard sc EQ pos >> symbol "|" >> patternDef)
  return $ AlgebraicDataMatcherExpr defs
  where
    patternDef :: Parser (String, [EgisonExpr])
    patternDef = do
      pos <- L.indentLevel
      patternCtor <- lowerId
      args <- many (L.indentGuard sc GT pos >> atomExpr)
      return (patternCtor, args)

collectionExpr :: Parser EgisonExpr
collectionExpr = symbol "[" >> (try betweenOrFromExpr <|> elementsExpr)
  where
    betweenOrFromExpr = do
      start <- expr <* symbol ".."
      end   <- optional expr <* symbol "]"
      case end of
        Just end' -> return $ makeBinaryApply "between" start end'
        Nothing   -> return $ makeUnaryApply "from" start

    elementsExpr = CollectionExpr <$> (sepBy (ElementExpr <$> expr) comma <* symbol "]")

tupleOrParenExpr :: Parser EgisonExpr
tupleOrParenExpr = do
  elems <- parens $ try pointFreeExpr <|> sepBy expr comma
  case elems of
    [x] -> return x
    _   -> return $ TupleExpr elems
  where
    makeLambda name Nothing Nothing =
      LambdaExpr [ScalarArg ":x", ScalarArg ":y"]
                 (ApplyExpr (stringToVarExpr name)
                            (TupleExpr [stringToVarExpr ":x", stringToVarExpr ":y"]))
    makeLambda name Nothing (Just rarg) =
      LambdaExpr [ScalarArg ":x"]
                 (ApplyExpr (stringToVarExpr name)
                            (TupleExpr [stringToVarExpr ":x", rarg]))
    makeLambda name (Just larg) Nothing =
      LambdaExpr [ScalarArg ":y"]
                 (ApplyExpr (stringToVarExpr name)
                            (TupleExpr [larg, stringToVarExpr ":y"]))

    -- TODO(momohatt): Handle point-free expressions starting with expr, such as (1 +)
    -- TODO(momohatt): Reject ill-formed point-free expressions like (* 1 + 2)
    pointFreeExpr :: Parser [EgisonExpr]
    pointFreeExpr = do
      op   <- parseOneOf $ map (\(sym, sem) -> symbol sym $> sem) reservedBinops
      rarg <- optional $ expr
      return [makeLambda op Nothing rarg]

hashExpr :: Parser EgisonExpr
hashExpr = HashExpr <$> hashBraces (sepEndBy hashElem comma)
  where
    hashBraces = between (symbol "{|") (symbol "|}")
    hashElem = brackets $ (,) <$> expr <*> (comma >> expr)

atomOrAppExpr :: Parser EgisonExpr
atomOrAppExpr = try (dbg "applyExpr" applyExpr)
            <|> atomExpr

atomExpr :: Parser EgisonExpr
atomExpr = IntegerExpr <$> positiveIntegerLiteral
       <|> BoolExpr <$> boolLiteral
       <|> CharExpr <$> charLiteral
       <|> StringExpr . pack <$> stringLiteral
       <|> VarExpr <$> varLiteral
       <|> SomethingExpr <$ keywordSomething
       <|> UndefinedExpr <$ keywordUndefined
       <|> (\x -> InductiveDataExpr x []) <$> upperId
       <|> collectionExpr
       <|> tupleOrParenExpr
       <|> hashExpr
       <?> "atomic expressions"

--
-- Pattern
--

pattern :: Parser EgisonPattern
pattern = letPattern
      <|> loopPattern
      <|> try applyPattern
      <|> opPattern

letPattern :: Parser EgisonPattern
letPattern = do
  pos   <- keywordLet >> L.indentLevel
  binds <- some (L.indentGuard sc EQ pos *> binding)
  body  <- keywordIn >> pattern
  return $ LetPat binds body

loopPattern :: Parser EgisonPattern
loopPattern = do
  keywordLoop
  iter <- patVarLiteral
  range <- parseRange
  loopBody <- optional (symbol "|") >> pattern
  loopEnd <- symbol "|" >> pattern
  return $ LoopPat iter range loopBody loopEnd
  where
    parseRange :: Parser LoopRange
    parseRange =
      try (parens $ LoopRange <$> expr <*> (comma >> expr) <*> (comma >> pattern))
      <|> (do start <- keywordFrom >> expr
              ends  <- fromMaybe (defaultEnds start) <$> optional (keywordTo >> expr)
              as    <- fromMaybe WildCard <$> optional (keywordAs >> pattern)
              keywordOf
              return $ LoopRange start ends as)

    defaultEnds s =
      ApplyExpr
        (stringToVarExpr "from")
        (ApplyExpr (stringToVarExpr "-'") (TupleExpr [s, IntegerExpr 1]))

applyPattern :: Parser EgisonPattern
applyPattern = do
  pos <- L.indentLevel
  func <- atomPattern
  args <- some (L.indentGuard sc GT pos *> atomPattern)
  case func of
    InductivePat x [] -> return $ InductivePat x args

opPattern :: Parser EgisonPattern
opPattern = makeExprParser atomPattern table
  where
    table :: [[Operator Parser EgisonPattern]]
    table =
      [ [ Prefix (NotPat <$ symbol "!") ]
      -- 5
      , [ InfixR (inductive2 "cons" ":" )
        , InfixR (inductive2 "join" "++") ]
      -- 3
      , [ InfixR (binary AndPat "&&") ]
      -- 2
      , [ InfixR (binary OrPat  "||") ]
      ]
    inductive2 name sym = (\x y -> InductivePat name [x, y]) <$ symbol sym
    binary name sym     = (\x y -> name [x, y]) <$ symbol sym

atomPattern :: Parser EgisonPattern
atomPattern = WildCard <$   symbol "_"
          <|> PatVar   <$> patVarLiteral
          <|> ValuePat <$> (char '#' >> atomExpr)
          <|> InductivePat "nil" [] <$ (symbol "[" >> symbol "]")
          <|> InductivePat <$> identifier <*> pure []
          <|> VarPat   <$> (char '~' >> identifier)
          <|> PredPat  <$> (symbol "?" >> atomExpr)
          <|> ContPat  <$ symbol "..."
          <|> makeTupleOrParen pattern TuplePat

patVarLiteral :: Parser Var
patVarLiteral = stringToVar <$> (char '$' >> identifier)

ppPattern :: Parser PrimitivePatPattern
ppPattern = PPInductivePat <$> lowerId <*> many ppAtom
        <|> makeExprParser ppAtom table
  where
    table :: [[Operator Parser PrimitivePatPattern]]
    table =
      [ [ InfixR (inductive2 "cons" ":" )
        , InfixR (inductive2 "join" "++") ]
      ]
    inductive2 name sym = (\x y -> PPInductivePat name [x, y]) <$ symbol sym

    ppAtom :: Parser PrimitivePatPattern
    ppAtom = PPWildCard <$ symbol "_"
         <|> PPPatVar   <$ symbol "$"
         <|> PPValuePat <$> (symbol "#$" >> identifier)
         <|> PPInductivePat "nil" [] <$ brackets sc
         <|> makeTupleOrParen ppPattern PPTuplePat

-- TODO(momohatt): cons pat, snoc pat, empty pat, constant pat
pdPattern :: Parser PrimitiveDataPattern
pdPattern = PDInductivePat <$> upperId <*> many pdAtom
        <|> pdAtom
  where
    pdAtom :: Parser PrimitiveDataPattern
    pdAtom = PDWildCard <$ symbol "_"
         <|> PDPatVar   <$> (symbol "$" >> identifier)
         <|> makeTupleOrParen pdPattern PDTuplePat

--
-- Tokens
--

-- space comsumer
sc :: Parser ()
sc = L.space space1 lineCmnt blockCmnt
  where
    lineCmnt  = L.skipLineComment "--"
    blockCmnt = L.skipBlockCommentNested "{-" "-}"

lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

parens    = between (symbol "(") (symbol ")")
braces    = between (symbol "{") (symbol "}")
brackets  = between (symbol "[") (symbol "]")
comma     = symbol ","
dot       = symbol "."

positiveIntegerLiteral :: Parser Integer
positiveIntegerLiteral = lexeme L.decimal

charLiteral :: Parser Char
charLiteral = between (char '\'') (char '\'') L.charLiteral

stringLiteral :: Parser String
stringLiteral = char '\"' *> manyTill L.charLiteral (char '\"')

boolLiteral :: Parser Bool
boolLiteral = reserved "True"  $> True
          <|> reserved "False" $> False

varLiteral :: Parser Var
varLiteral = stringToVar <$> lowerId

reserved :: String -> Parser ()
reserved w = (lexeme . try) (string w *> notFollowedBy alphaNumChar)

symbol :: String -> Parser String
symbol sym = try (L.symbol sc sym)

lowerId :: Parser String
lowerId = (lexeme . try) (p >>= check)
  where
    p       = (:) <$> lowerChar <*> many (alphaNumChar <|> oneOf ['?', '\''])
    check x = if x `elem` lowerReservedWords
                then fail $ "keyword " ++ show x ++ " cannot be an identifier"
                else return x

-- TODO: Deprecate BoolExpr and merge it with InductiveDataExpr
upperId :: Parser String
upperId = (lexeme . try) (p >>= check)
  where
    p       = (:) <$> upperChar <*> many alphaNumChar
    check x = if x `elem` upperReservedWords
                then fail $ "keyword " ++ show x ++ " cannot be an identifier"
                else return x

-- TODO: Replace identifier with lowerId?
identifier :: Parser String
identifier = lowerId <|> upperId

keywordLoadFile             = reserved "loadFile"
keywordLoad                 = reserved "load"
keywordIf                   = reserved "if"
keywordThen                 = reserved "then"
keywordElse                 = reserved "else"
keywordSeq                  = reserved "seq"
keywordApply                = reserved "apply"
keywordCApply               = reserved "capply"
keywordMemoizedLambda       = reserved "memoizedLambda"
keywordCambda               = reserved "cambda"
keywordProcedure            = reserved "procedure"
keywordMacro                = reserved "macro"
keywordLetRec               = reserved "letrec"
keywordLet                  = reserved "let"
keywordIn                   = reserved "in"
keywordWithSymbols          = reserved "withSymbols"
keywordLoop                 = reserved "loop"
keywordFrom                 = reserved "from"
keywordTo                   = reserved "to"
keywordOf                   = reserved "of"
keywordMatch                = reserved "match"
keywordMatchDFS             = reserved "matchDFS"
keywordMatchAll             = reserved "matchAll"
keywordMatchAllDFS          = reserved "matchAllDFS"
keywordAs                   = reserved "as"
keywordWith                 = reserved "with"
keywordMatcher              = reserved "matcher"
keywordDo                   = reserved "do"
keywordIo                   = reserved "io"
keywordSomething            = reserved "something"
keywordUndefined            = reserved "undefined"
keywordAlgebraicDataMatcher = reserved "algebraicDataMatcher"
keywordGenerateTensor       = reserved "generateTensor"
keywordTensor               = reserved "tensor"
keywordTensorContract       = reserved "contract"
keywordSubrefs              = reserved "subrefs"
keywordSubrefsNew           = reserved "subrefs!"
keywordSuprefs              = reserved "suprefs"
keywordSuprefsNew           = reserved "suprefs!"
keywordUserrefs             = reserved "userRefs"
keywordUserrefsNew          = reserved "userRefs!"
keywordFunction             = reserved "function"

upperReservedWords =
  [ "True"
  , "False"
  ]

lowerReservedWords =
  [ "loadFile"
  , "load"
  , "if"
  , "then"
  , "else"
  , "seq"
  , "apply"
  , "capply"
  , "memoizedLambda"
  , "cambda"
  , "procedure"
  , "macro"
  , "letrec"
  , "let"
  , "in"
  , "withSymbols"
  , "loop"
  , "from"
  , "to"
  , "of"
  , "match"
  , "matchDFS"
  , "matchAll"
  , "matchAllDFS"
  , "as"
  , "with"
  , "matcher"
  , "do"
  , "io"
  , "something"
  , "undefined"
  , "algebraicDataMatcher"
  , "generateTensor"
  , "tensor"
  , "contract"
  , "subrefs"
  , "subrefs!"
  , "suprefs"
  , "suprefs!"
  , "userRefs"
  , "userRefs!"
  , "function"
  ]

-- Reserved binary operators, aligned from the longest one
reservedBinops :: [(String, String)]
reservedBinops =
  [ ("++", "append"   )
  , ("==", "eq?"      )
  , ("<=", "lte?"     )
  , (">=", "gte?"     )
  , ("&&", "and"      )
  , ("||", "or"       )
  , ("^",  "**"       )
  , ("*",  "*"        )
  , ("/",  "/"        )
  , ("%",  "remainder")
  , ("+",  "+"        )
  , ("-",  "-"        )
  , (":",  "cons"     )
  , ("<",  "lt?"      )
  , (">",  "gt?"      )
  ]

--
-- Utils
--

parseOneOf :: [Parser a] -> Parser a
parseOneOf = foldl1 (\acc p -> acc <|> p)

makeTupleOrParen :: Parser a -> ([a] -> a) -> Parser a
makeTupleOrParen parser tupleCtor = do
  elems <- parens $ sepBy parser comma
  case elems of
    [elem] -> return elem
    _      -> return $ tupleCtor elems

makeBinaryApply :: String -> EgisonExpr -> EgisonExpr -> EgisonExpr
makeBinaryApply func x y = ApplyExpr (stringToVarExpr func) (TupleExpr [x, y])

makeUnaryApply :: String -> EgisonExpr -> EgisonExpr
makeUnaryApply "-" x  = makeBinaryApply "*" (IntegerExpr (-1)) x
makeUnaryApply func x = ApplyExpr (stringToVarExpr func) (TupleExpr [x])

makeApply :: EgisonExpr -> [EgisonExpr] -> EgisonExpr
makeApply (InductiveDataExpr x []) xs = InductiveDataExpr x xs
makeApply func xs = ApplyExpr func (TupleExpr xs)