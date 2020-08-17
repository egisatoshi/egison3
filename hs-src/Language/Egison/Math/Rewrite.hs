{-# LANGUAGE QuasiQuotes #-}

module Language.Egison.Math.Rewrite
  ( rewriteSymbol
  ) where

import           Control.Egison

import           Language.Egison.Math.Arith
import           Language.Egison.Math.Expr


rewriteSymbol :: ScalarData -> ScalarData
rewriteSymbol = rewritePower . rewriteExp . rewriteSinCos . rewriteLog . rewriteW . rewriteI

mapTerms :: (TermExpr -> TermExpr) -> ScalarData -> ScalarData
mapTerms f (Div (Plus ts1) (Plus ts2)) =
  Div (Plus (map f ts1)) (Plus (map f ts2))

mapPolys :: (PolyExpr -> PolyExpr) -> ScalarData -> ScalarData
mapPolys f (Div p1 p2) = Div (f p1) (f p2)

rewriteI :: ScalarData -> ScalarData
rewriteI = mapTerms f
 where
  f term@(Term a xs) =
    match dfs xs (Multiset (Pair SymbolM Eql))
      [ [mc| (symbol #"i", $k) : $xss ->
              if even k
                then Term (a * (-1) ^ (quot k 2)) xss
                else Term (a * (-1) ^ (quot k 2)) ((Symbol "" "i" [], 1) : xss) |]
      , [mc| _ -> term |]
      ]

rewriteW :: ScalarData -> ScalarData
rewriteW = mapPolys g . mapTerms f
 where
  f term@(Term a xs) =
    match dfs xs (Multiset (Pair SymbolM Eql))
      [ [mc| (symbol #"w", $k & ?(>= 3)) : $xss ->
               Term a ((Symbol "" "w" [], k `mod` 3) : xss) |]
      , [mc| _ -> term |]
      ]
  g poly@(Plus ts) =
    match dfs ts (Multiset TermM)
      [ [mc| term $a ((symbol #"w", #2) : $mr) :
             term $b ((symbol #"w", #1) : #mr) : $pr ->
               g (Plus (Term (-a) mr :
                        Term (b - a) ((Symbol "" "w" [], 1) : mr) : pr)) |]
      , [mc| _ -> poly |]
      ]

rewriteLog :: ScalarData -> ScalarData
rewriteLog = mapTerms f
 where
  f term@(Term a xs) =
    match dfs xs (Multiset (Pair SymbolM Eql))
      [ [mc| (apply #"log" [zero], _) : _ -> Term 0 [] |]
      , [mc| (apply #"log" [singleTerm _ #1 [(symbol #"e", $n)]], _) : $xss ->
              Term (n * a) xss |]
      , [mc| _ -> term |]
      ]

makeApply :: String -> [ScalarData] -> SymbolExpr
makeApply f args =
  Apply (SingleSymbol (Symbol "" f [])) args

rewriteExp :: ScalarData -> ScalarData
rewriteExp = mapTerms f
 where
  f term@(Term a xs) =
    match dfs xs (Multiset (Pair SymbolM Eql))
      [ [mc| (apply #"exp" [zero], _) : $xss ->
               f (Term a xss) |]
      , [mc| (apply #"exp" [singleTerm #1 #1 []], _) : $xss ->
               f (Term a ((Symbol "" "e" [], 1) : xss)) |]
      , [mc| (apply #"exp" [singleTerm $n #1 [(symbol #"i", #1), (symbol #"π", #1)]], _) : $xss ->
               f (Term ((-1) ^ n * a) xss) |]
      , [mc| (apply #"exp" [$x], $n & ?(>= 2)) : $xss ->
               f (Term a ((makeApply "exp" [mathScalarMult n x], 1) : xss)) |]
      , [mc| (apply #"exp" [$x], #1) : (apply #"exp" [$y], #1) : $xss ->
               f (Term a ((makeApply "exp" [mathPlus x y], 1) : xss)) |]
      , [mc| _ -> term |]
      ]

rewritePower :: ScalarData -> ScalarData
rewritePower = mapTerms f
 where
  f term@(Term a xs) =
    match dfs xs (Multiset (Pair SymbolM Eql))
      [ [mc| (apply #"^" [singleTerm #1 #1 [], _], _) : $xss -> f (Term a xss) |]
      , [mc| (apply #"^" [$x, $y], $n & ?(>= 2)) : $xss ->
               f (Term a ((makeApply "^" [x, mathScalarMult n y], 1) : xss)) |]
      , [mc| (apply #"^" [$x, $y], #1) : (apply #"^" [#x, $z], #1) : $xss ->
               f (Term a ((makeApply "^" [x, mathPlus y z], 1) : xss)) |]
      , [mc| _ -> term |]
      ]

rewriteSinCos :: ScalarData -> ScalarData
rewriteSinCos = mapTerms (g . f)
 where
  f term@(Term a xs) =
    match dfs xs (Multiset (Pair SymbolM Eql))
      [ [mc| (apply #"sin" [zero], _) : _ -> Term 0 [] |]
      , [mc| (apply #"sin" [singleTerm _ #1 [(symbol #"π", #1)]], _) : _ ->
               Term 0 [] |]
      , [mc| (apply #"sin" [singleTerm $n #2 [(symbol #"π", #1)]], _) : $xss ->
              Term (a * (-1) ^ (div (abs n - 1) 2)) xss |]
      , [mc| _ -> term |]
      ]
  g term@(Term a xs) =
    match dfs xs (Multiset (Pair SymbolM Eql))
      [ [mc| (apply #"cos" [singleTerm _ #2 [(symbol #"π", #1)]], _) : _ ->
              Term 0 [] |]
      , [mc| (apply #"cos" [zero], _) : $xss -> Term a xss |]
      , [mc| (apply #"cos" [singleTerm $n #1 [(symbol #"π", #1)]], $m) : $xss ->
               Term (a * (-1) ^ (abs n * m)) xss |]
      , [mc| _ -> term |]
      ]
