{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      :  $Header$
-- Copyright   :  (c) 2013-2015 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable
--
-- Utility functions that are also useful for translating programs
-- from previous Cryptol versions.

module Cryptol.Parser.Utils
  ( translateExprToNumT
  ) where

import Cryptol.Parser.AST
import Cryptol.Prims.Syntax


translateExprToNumT :: Expr -> Maybe Type
translateExprToNumT expr =
  case expr of
    ELocated e r -> (`TLocated` r) `fmap` translateExprToNumT e
    EVar (QName Nothing n) | n == mkName "width" -> mkFun TCWidth
    EVar x       -> return (TUser x [])
    ELit x       -> cvtLit x
    EApp e1 e2   -> do t1 <- translateExprToNumT e1
                       t2 <- translateExprToNumT e2
                       tApp t1 t2

    EInfix a o f b -> do e1 <- translateExprToNumT a
                         e2 <- translateExprToNumT b
                         return (TInfix e1 o f e2)

    EParens e    -> translateExprToNumT e

    _            -> Nothing

  where
  tApp ty t =
    case ty of
      TLocated t1 r -> (`TLocated` r) `fmap` tApp t1 t
      TApp f ts     -> return (TApp f (ts ++ [t]))
      TUser f ts    -> return (TUser f (ts ++ [t]))
      _             -> Nothing

  mkFun f = return (TApp f [])

  cvtLit (ECNum n CharLit)  = return (TChar $ toEnum $ fromInteger n)
  cvtLit (ECNum n _)        = return (TNum n)
  cvtLit (ECString _)       = Nothing
