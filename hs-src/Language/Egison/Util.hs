{- |
Module      : Language.Egison.Util
Copyright   : Satoshi Egi
Licence     : MIT

This module provides utility functions.
-}

module Language.Egison.Util (getEgisonExpr, getEgisonExprOrNewLine, completeEgison) where

import Data.List
import Text.Regex.TDFA
import System.Console.Haskeline hiding (handle, catch, throwTo)
import Control.Monad.Except (liftIO)

import Language.Egison.Types
import Language.Egison.Parser as Parser
import Language.Egison.ParserS as ParserS

-- |Get Egison expression from the prompt. We can handle multiline input.
getEgisonExpr :: Bool -> String -> InputT IO (Maybe (String, EgisonTopExpr))
getEgisonExpr isSExpr prompt = getEgisonExpr' isSExpr prompt ""

getEgisonExpr' :: Bool -> String -> String -> InputT IO (Maybe (String, EgisonTopExpr))
getEgisonExpr' isSExpr prompt prev = do
  mLine <- case prev of
             "" -> getInputLine prompt
             _ -> getInputLine $ take (length prompt) (repeat ' ')
  case mLine of
    Nothing -> return Nothing
    Just [] -> do
      if null prev
        then getEgisonExpr isSExpr prompt
        else getEgisonExpr' isSExpr prompt prev
    Just line -> do
      let input = prev ++ line
      case (if isSExpr then ParserS.parseTopExpr else Parser.parseTopExpr) input of
        Left err | show err =~ "unexpected end of input" -> do
          getEgisonExpr' isSExpr prompt $ input ++ "\n"
        Left err -> do
          liftIO $ putStrLn $ show err
          getEgisonExpr isSExpr prompt
        Right topExpr -> return $ Just (input, topExpr)

-- |Get Egison expression from the prompt. We can handle multiline input.
getEgisonExprOrNewLine :: Bool -> String -> InputT IO (Either (Maybe String) (String, EgisonTopExpr))
getEgisonExprOrNewLine isSExpr prompt = getEgisonExprOrNewLine' isSExpr prompt ""

getEgisonExprOrNewLine' :: Bool -> String -> String -> InputT IO (Either (Maybe String) (String, EgisonTopExpr))
getEgisonExprOrNewLine' isSExpr prompt prev = do
  mLine <- case prev of
             "" -> getInputLine prompt
             _ -> getInputLine $ take (length prompt) (repeat ' ')
  case mLine of
    Nothing -> return $ Left Nothing
    Just [] -> return $ Left $ Just ""
    Just line -> do
      let input = prev ++ line
      case (if isSExpr then ParserS.parseTopExpr else Parser.parseTopExpr) input of
        Left err | show err =~ "unexpected end of input" -> do
          getEgisonExprOrNewLine' isSExpr prompt $ input ++ "\n"
        Left err -> do
          liftIO $ putStrLn $ show err
          getEgisonExprOrNewLine isSExpr prompt
        Right topExpr -> return $ Right (input, topExpr)

-- |Complete Egison keywords
completeEgison :: Monad m => CompletionFunc m
completeEgison arg@((')':_), _) = completeParen arg
completeEgison arg@(('>':_), _) = completeParen arg
completeEgison arg@((']':_), _) = completeParen arg
completeEgison arg@(('}':_), _) = completeParen arg
completeEgison arg@(('(':_), _) = (completeWord Nothing " \t<>[]{}$," completeAfterOpenParen) arg
completeEgison arg@(('<':_), _) = (completeWord Nothing " \t()[]{}$," completeAfterOpenCons) arg
completeEgison arg@((' ':_), _) = (completeWord Nothing "" completeNothing) arg
completeEgison arg@(('[':_), _) = (completeWord Nothing "" completeNothing) arg
completeEgison arg@(('{':_), _) = (completeWord Nothing "" completeNothing) arg
completeEgison arg@([], _) = (completeWord Nothing "" completeNothing) arg
completeEgison arg@(_, _) = (completeWord Nothing " \t[]{}$," completeEgisonKeyword) arg

completeAfterOpenParen :: Monad m => String -> m [Completion]
completeAfterOpenParen str = return $ map (\kwd -> Completion kwd kwd False) $ filter (isPrefixOf str) $ egisonPrimitivesAfterOpenParen ++ egisonKeywordsAfterOpenParen

completeAfterOpenCons :: Monad m => String -> m [Completion]
completeAfterOpenCons str = return $ map (\kwd -> Completion kwd kwd False) $ filter (isPrefixOf str) egisonKeywordsAfterOpenCons

completeNothing :: Monad m => String -> m [Completion]
completeNothing _ = return []

completeEgisonKeyword :: Monad m => String -> m [Completion]
completeEgisonKeyword str = return $ map (\kwd -> Completion kwd kwd False) $ filter (isPrefixOf str) egisonKeywords

egisonPrimitivesAfterOpenParen = map ((:) '(') $ ["+", "-", "*", "/", "numerator", "denominator", "modulo", "quotient", "remainder", "neg", "abs", "eq?", "lt?", "lte?", "gt?", "gte?", "round", "floor", "ceiling", "truncate", "sqrt", "exp", "log", "sin", "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh", "asinh", "acosh", "atanh", "itof", "rtof", "stoi", "read", "show", "empty?", "uncons", "unsnoc", "assert", "assert-equal"]
egisonKeywordsAfterOpenParen = map ((:) '(') $ ["define", "let", "letrec", "lambda", "match", "match-all", "match-lambda", "matcher", "algebraic-data-matcher", "pattern-function", "if", "loop", "io", "do"]
                            ++ ["id", "or", "and", "not", "char", "eq?/m", "compose", "compose3", "list", "map", "between", "repeat1", "repeat", "filter", "separate", "concat", "foldr", "foldl", "map2", "zip", "member?", "member?/m", "include?", "include?/m", "any", "all", "length", "count", "count/m", "car", "cdr", "rac", "rdc", "nth", "take", "drop", "while", "reverse", "multiset", "add", "add/m", "delete-first", "delete-first/m", "delete", "delete/m", "difference", "difference/m", "union", "union/m", "intersect", "intersect/m", "set", "unique", "unique/m", "print", "print-to-port", "each", "pure-rand", "fib", "fact", "divisor?", "gcd", "primes", "find-factor", "prime-factorization", "p-f", "min", "max", "min-and-max", "power", "mod", "sort", "intersperse", "intercalate", "split", "split/m"]
egisonKeywordsAfterOpenCons = map ((:) '<') ["nil", "cons", "join", "snoc", "nioj"]
egisonKeywordsInNeutral = ["something"]
                       ++ ["bool", "string", "integer", "nats", "primes"]
egisonKeywords = egisonPrimitivesAfterOpenParen ++ egisonKeywordsAfterOpenParen ++ egisonKeywordsAfterOpenCons ++ egisonKeywordsInNeutral

completeParen :: Monad m => CompletionFunc m
completeParen (lstr, _) = case (closeParen lstr) of
  Nothing -> return (lstr, [])
  Just paren -> return (lstr, [(Completion paren paren False)])

closeParen :: String -> Maybe String
closeParen str = closeParen' 0 $ removeCharAndStringLiteral str

removeCharAndStringLiteral :: String -> String
removeCharAndStringLiteral [] = []
removeCharAndStringLiteral ('"':'\\':str) = '"':'\\':(removeCharAndStringLiteral str)
removeCharAndStringLiteral ('"':str) = removeCharAndStringLiteral' str
removeCharAndStringLiteral ('\'':'\\':str) = '\'':'\\':(removeCharAndStringLiteral str)
removeCharAndStringLiteral ('\'':str) = removeCharAndStringLiteral' str
removeCharAndStringLiteral (c:str) = c:(removeCharAndStringLiteral str)

removeCharAndStringLiteral' :: String -> String
removeCharAndStringLiteral' [] = []
removeCharAndStringLiteral' ('"':'\\':str) = removeCharAndStringLiteral' str
removeCharAndStringLiteral' ('"':str) = removeCharAndStringLiteral str
removeCharAndStringLiteral' ('\'':'\\':str) = removeCharAndStringLiteral' str
removeCharAndStringLiteral' ('\'':str) = removeCharAndStringLiteral str
removeCharAndStringLiteral' (_:str) = removeCharAndStringLiteral' str

closeParen' :: Integer -> String -> Maybe String
closeParen' _ [] = Nothing
closeParen' 0 ('(':_) = Just ")"
closeParen' 0 ('<':_) = Just ">"
closeParen' 0 ('[':_) = Just "]"
closeParen' 0 ('{':_) = Just "}"
closeParen' n ('(':str) = closeParen' (n - 1) str
closeParen' n ('<':str) = closeParen' (n - 1) str
closeParen' n ('[':str) = closeParen' (n - 1) str
closeParen' n ('{':str) = closeParen' (n - 1) str
closeParen' n (')':str) = closeParen' (n + 1) str
closeParen' n ('>':str) = closeParen' (n + 1) str
closeParen' n (']':str) = closeParen' (n + 1) str
closeParen' n ('}':str) = closeParen' (n + 1) str
closeParen' n (_:str) = closeParen' n str
