{
{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE OverloadedStrings #-}
module Cryptol.Parser
  ( parseModule
  , parseProgram, parseProgramWith
  , parseExpr, parseExprWith
  , parseDecl, parseDeclWith
  , parseDecls, parseDeclsWith
  , parseLetDecl, parseLetDeclWith
  , parseRepl, parseReplWith
  , parseSchema, parseSchemaWith
  , parseModName, parseHelpName
  , ParseError(..), ppError
  , Layout(..)
  , Config(..), defaultConfig
  , guessPreProc, PreProc(..)
  ) where

import           Control.Applicative as A
import           Data.Maybe(fromMaybe)
import           Data.Text.Lazy (Text)
import qualified Data.Text.Lazy as T
import           Control.Monad(liftM2,msum)

import Cryptol.Prims.Syntax
import Cryptol.Parser.AST
import Cryptol.Parser.Position
import Cryptol.Parser.LexerUtils
import Cryptol.Parser.ParserUtils
import Cryptol.Parser.Unlit(PreProc(..), guessPreProc)
import Cryptol.Utils.FastString


import Paths_cryptol
}


%token
  NUM         { $$@(Located _ (Token (Num   {}) _))}
  STRLIT      { $$@(Located _ (Token (StrLit {}) _))}
  CHARLIT     { $$@(Located _ (Token (ChrLit {}) _))}

  IDENT       { $$@(Located _ (Token (Ident [] _) _))}
  QIDENT      { $$@(Located _ (Token  Ident{}     _))}

  'include'   { Located $$ (Token (KW KW_include)   _)}
  'import'    { Located $$ (Token (KW KW_import)    _)}
  'as'        { Located $$ (Token (KW KW_as)        _)}
  'hiding'    { Located $$ (Token (KW KW_hiding)    _)}
  'private'   { Located $$ (Token (KW KW_private)   _)}
  'property'  { Located $$ (Token (KW KW_property)  _)}
  'infix'     { Located $$ (Token (KW KW_infix)     _)}
  'infixl'    { Located $$ (Token (KW KW_infixl)    _)}
  'infixr'    { Located $$ (Token (KW KW_infixr)    _)}

  'type'      { Located $$ (Token (KW KW_type   ) _)}
  'newtype'   { Located $$ (Token (KW KW_newtype) _)}
  'module'    { Located $$ (Token (KW KW_module ) _)}
  'where'     { Located $$ (Token (KW KW_where  ) _)}
  'let'       { Located $$ (Token (KW KW_let    ) _)}
  'if'        { Located $$ (Token (KW KW_if     ) _)}
  'then'      { Located $$ (Token (KW KW_then   ) _)}
  'else'      { Located $$ (Token (KW KW_else   ) _)}
  'x'         { Located $$ (Token (KW KW_x)       _)}

  'primitive' { Located $$ (Token (KW KW_primitive) _)}

  '['         { Located $$ (Token (Sym BracketL) _)}
  ']'         { Located $$ (Token (Sym BracketR) _)}
  '<-'        { Located $$ (Token (Sym ArrL    ) _)}
  '..'        { Located $$ (Token (Sym DotDot  ) _)}
  '...'       { Located $$ (Token (Sym DotDotDot) _)}
  '|'         { Located $$ (Token (Sym Bar     ) _)}

  '('         { Located $$ (Token (Sym ParenL  ) _)}
  ')'         { Located $$ (Token (Sym ParenR  ) _)}
  ','         { Located $$ (Token (Sym Comma   ) _)}
  ';'         { Located $$ (Token (Sym Semi    ) _)}
  '.'         { Located $$ (Token (Sym Dot     ) _)}
  '{'         { Located $$ (Token (Sym CurlyL  ) _)}
  '}'         { Located $$ (Token (Sym CurlyR  ) _)}
  '<|'        { Located $$ (Token (Sym TriL    ) _)}
  '|>'        { Located $$ (Token (Sym TriR    ) _)}
  '='         { Located $$ (Token (Sym EqDef   ) _)}
  '`'         { Located $$ (Token (Sym BackTick) _)}
  ':'         { Located $$ (Token (Sym Colon   ) _)}
  '->'        { Located $$ (Token (Sym ArrR    ) _)}
  '=>'        { Located $$ (Token (Sym FatArrR ) _)}
  '\\'        { Located $$ (Token (Sym Lambda  ) _)}
  '_'         { Located $$ (Token (Sym Underscore ) _)}


  'v{'        { Located $$ (Token (Virt VCurlyL)  _)}
  'v}'        { Located $$ (Token (Virt VCurlyR)  _)}
  'v;'        { Located $$ (Token (Virt VSemi)    _)}

  '+'         { Located $$ (Token (Op Plus)  _)}
  '*'         { Located $$ (Token (Op Mul)   _)}
  '^^'        { Located $$ (Token (Op Exp)   _)}

  '-'         { Located $$ (Token (Op Minus) _)}
  '~'         { Located $$ (Token (Op Complement) _)}

  '#'         { Located $$ (Token (Op Hash) _)}

  OP          { $$@(Located _ (Token (Op (Other [] _)) _))}
  QOP         { $$@(Located _ (Token (Op  Other{}   )  _))}

  DOC         { $$@(Located _ (Token (White DocStr) _)) }

%name vmodule vmodule
%name program program
%name programLayout program_layout
%name expr    expr
%name decl    decl
%name decls   decls
%name declsLayout decls_layout
%name letDecl let_decl
%name repl    repl
%name schema  schema
%name modName modName
%name helpName help_name
%tokentype { Located Token }
%monad { ParseM }
%lexer { lexerP } { Located _ (Token EOF _) }

{- If you add additional operators, please update the corresponding
   tables in the pretty printer. -}

%nonassoc '=>'
%right '->'
%left     'where'
%nonassoc 'then' 'else'
%nonassoc ':'
%nonassoc '=='
%nonassoc '<=' '>='
%right '#'
%left  '+' '-'
%left  '*' '/' '%'
%right '^^'
%right NEG '~'
%left OP QOP
%%


vmodule                    :: { Module }
  : 'module' modName 'where' 'v{' vmod_body 'v}'
                              { let (is,ts) = $5 in Module $2 is ts }

  | 'v{' vmod_body 'v}'
    { let { (is,ts) = $2
            -- XXX make a location from is and ts
          ; modName = Located { srcRange = emptyRange
                              , thing    = mkModName ["Main"]
                              }
          } in Module modName is ts }

vmod_body                  :: { ([Located Import], [TopDecl]) }
  : vimports 'v;' vtop_decls  { (reverse $1, reverse $3) }
  | vimports ';'  vtop_decls  { (reverse $1, reverse $3) }
  | vimports                  { (reverse $1, [])         }
  | vtop_decls                { ([], reverse $1)         }
  | {- empty -}               { ([], [])                 }

vimports                   :: { [Located Import] }
  : vimports 'v;' import      { $3 : $1 }
  | vimports ';'  import      { $3 : $1 }
  | import                    { [$1]    }

-- XXX replace rComb with uses of at
import                     :: { Located Import }
  : 'import' modName mbAs mbImportSpec
                              { Located { srcRange = rComb $1
                                                   $ fromMaybe (srcRange $2)
                                                   $ msum [ fmap srcRange $4
                                                          , fmap srcRange $3
                                                          ]
                                        , thing    = Import
                                          { iModule    = thing $2
                                          , iAs        = fmap thing $3
                                          , iSpec      = fmap thing $4
                                          }
                                        } }

mbAs                       :: { Maybe (Located ModName) }
  : 'as' modName              { Just $2 }
  | {- empty -}               { Nothing }

mbImportSpec               :: { Maybe (Located ImportSpec) }
  : mbHiding '(' name_list ')'{ Just Located
                                  { srcRange = case $3 of
                                      { [] -> emptyRange
                                      ; xs -> rCombs (map srcRange xs) }
                                  , thing    = $1 (reverse (map thing $3))
                                  } }
  | {- empty -}               { Nothing }

name_list                  :: { [LName] }
  : name_list ',' name        { $3 : $1 }
  | name                      { [$1]    }
  | {- empty -}               { []      }

mbHiding                   :: { [Name] -> ImportSpec }
  : 'hiding'                  { Hiding }
  | {- empty -}               { Only   }

program                    :: { Program }
  : top_decls                 { Program (reverse $1) }
  | {- empty -}               { Program [] }

program_layout             :: { Program }
  : 'v{' vtop_decls 'v}'      { Program (reverse $2) }
  | 'v{''v}'                  { Program []           }

top_decls                  :: { [TopDecl]  }
  : top_decl ';'              { $1         }
  | top_decls top_decl ';'    { $2 ++ $1   }

vtop_decls                 :: { [TopDecl]  }
  : vtop_decl                 { $1       }
  | vtop_decls 'v;' vtop_decl { $3 ++ $1 }
  | vtop_decls ';'  vtop_decl { $3 ++ $1 }

vtop_decl               :: { [TopDecl] }
  : decl                   { [exportDecl Nothing   Public $1]                 }
  | doc decl               { [exportDecl (Just $1) Public $2]                 }
  | mbDoc 'include' STRLIT {% (return . Include) `fmap` fromStrLit $3         }
  | mbDoc 'property' name apats '=' expr
                           { [exportDecl $1 Public (mkProperty $3 $4 $6)]     }
  | mbDoc 'property' name       '=' expr
                           { [exportDecl $1 Public (mkProperty $3 [] $5)]     }
  | mbDoc newtype          { [exportNewtype Public $2]                        }
  | prim_bind              { $1                                               }
  | private_decls          { $1                                               }

top_decl                :: { [TopDecl] }
  : decl                   { [Decl (TopLevel {tlExport = Public, tlValue = $1 })] }
  | 'include' STRLIT       {% (return . Include) `fmap` fromStrLit $2             }
  | prim_bind              { $1                                                   }

private_decls           :: { [TopDecl] }
  : 'private' 'v{' vtop_decls 'v}'
                           { changeExport Private (reverse $3)                }
  | doc 'private' 'v{' vtop_decls 'v}'
                           { changeExport Private (reverse $4)                }

prim_bind               :: { [TopDecl] }
  : mbDoc 'primitive' name  ':' schema       { mkPrimDecl $1 False $3 $5 }
  | mbDoc 'primitive' '(' op ')' ':' schema  { mkPrimDecl $1 True  $4 $7 }

doc                     :: { Located String }
  : DOC                    { mkDoc (fmap (fastStringText . tokenText) $1) }

mbDoc                   :: { Maybe (Located String) }
  : doc                    { Just $1 }
  | {- empty -}            { Nothing }


decl                    :: { Decl }
  : vars_comma ':' schema  { at (head $1,$3) $ DSignature (map (fmap mkUnqual) (reverse $1)) $3   }
  | apat '=' expr          { at ($1,$3) $ DPatBind $1 $3                    }
  | name apats '=' expr    { at ($1,$4) $
                             DBind $ Bind { bName      = fmap mkUnqual $1
                                          , bParams    = reverse $2
                                          , bDef       = at $4 (Located emptyRange (DExpr $4))
                                          , bSignature = Nothing
                                          , bPragmas   = []
                                          , bMono      = False
                                          , bInfix     = False
                                          , bFixity    = Nothing
                                          , bDoc       = Nothing
                                          } }

  | apat op apat '=' expr  { at ($1,$5) $
                             DBind $ Bind { bName      = fmap mkUnqual $2
                                          , bParams    = [$1,$3]
                                          , bDef       = at $5 (Located emptyRange (DExpr $5))
                                          , bSignature = Nothing
                                          , bPragmas   = []
                                          , bMono      = False
                                          , bInfix     = True
                                          , bFixity    = Nothing
                                          , bDoc       = Nothing
                                          } }

  | 'type' name '=' type   {% at ($1,$4) `fmap` mkTySyn $2 [] $4 }
  | 'type' name tysyn_params '=' type
                           {% at ($1,$5) `fmap` mkTySyn $2 (reverse $3) $5  }

  | 'infixl' NUM ops       {% mkFixity LeftAssoc  $2 (reverse $3) }
  | 'infixr' NUM ops       {% mkFixity RightAssoc $2 (reverse $3) }
  | 'infix'  NUM ops       {% mkFixity NonAssoc   $2 (reverse $3) }

let_decl                :: { Decl }
  : 'let' apat '=' expr          { at ($2,$4) $ DPatBind $2 $4                    }
  | 'let' name apats '=' expr    { at ($2,$5) $
                                   DBind $ Bind { bName      = fmap mkUnqual $2
                                                , bParams    = reverse $3
                                                , bDef       = at $5 (Located emptyRange (DExpr $5))
                                                , bSignature = Nothing
                                                , bPragmas   = []
                                                , bMono      = False
                                                , bInfix     = False
                                                , bFixity    = Nothing
                                                , bDoc       = Nothing
                                                } }

newtype                 :: { Newtype }
  : 'newtype' qname '=' newtype_body
                           { Newtype { nName = $2, nParams = [], nBody = $4 } }
  | 'newtype' qname tysyn_params '=' newtype_body
                           { Newtype { nName = $2, nParams = $3, nBody = $5 } }

newtype_body            :: { [Named Type] }
  : '{' '}'                { [] }
  | '{' field_types '}'    { $2 }

vars_comma                 :: { [ LName ]  }
  : var                       { [ $1]      }
  | vars_comma ',' var        { $3 : $1    }

var                        :: { LName }
  : name                      { $1 }
  | '(' op ')'                { $2 }

apats                   :: { [Pattern]  }
  : apat                   { [$1]       }
  | apats apat             { $2 : $1    }

decls                   :: { [Decl] }
  : decl ';'               { [$1] }
  | decls decl ';'         { $2 : $1 }

vdecls                  :: { [Decl] }
  : decl                   { [$1] }
  | vdecls 'v;' decl       { $3 : $1 }
  | vdecls ';'  decl       { $3 : $1 }

decls_layout            :: { [Decl] }
  : 'v{' vdecls 'v}'       { $2 }
  | 'v{' 'v}'              { [] }

repl                    :: { ReplInput }
  : expr                   { ExprInput $1 }
  | let_decl               { LetInput $1 }

--------------------------------------------------------------------------------
-- if a then b else c : [10]


expr                             :: { Expr }
  : cexpr                           { $1 }
  | expr 'where' '{' '}'            { at ($1,$4) $ EWhere $1 []           }
  | expr 'where' '{' decls '}'      { at ($1,$5) $ EWhere $1 (reverse $4) }
  | expr 'where' 'v{' 'v}'          { at ($1,$2) $ EWhere $1 []           }
  | expr 'where' 'v{' vdecls 'v}'   { at ($1,$4) $ EWhere $1 (reverse $4) }

ifBranches                       :: { [(Expr, Expr)] }
  : ifBranch                        { [$1] }
  | ifBranches '|' ifBranch         { $3 : $1 }

ifBranch                         :: { (Expr, Expr) }
  : expr 'then' expr                { ($1, $3) }

cexpr                            :: { Expr }
  : sig_expr                        { $1 }
  | 'if' ifBranches 'else' cexpr    { at ($1,$4) $ mkIf (reverse $2) $4 }
  | '\\' apats '->' cexpr           { at ($1,$4) $ EFun (reverse $2) $4 }

sig_expr                         :: { Expr }
  : iexpr                           { $1 }
  | iexpr ':' type                  { at ($1,$3) $ ETyped $1 $3 }

iexpr                            :: { Expr }
  : expr10                          { $1 }
  | iexpr qop expr10                { binOp $1 $2 $3 }

expr10                           :: { Expr }
  : aexprs                          { mkEApp $1 }

  | '-' expr10 %prec NEG            { at ($1,$2) $ EApp (at $1 (EVar (mkUnqual (mkName "negate")))) $2 }
  | '~' expr10                      { at ($1,$2) $ EApp (at $1 (EVar (mkUnqual (mkName "complement")))) $2 }

qop                              :: { LQName }
  : op                              { fmap mkUnqual $1 }
  | QOP                             { let Token (Op (Other ns i)) _ = thing $1
                                       in mkQual (mkModName ns) (mkName i) A.<$ $1 }

op                               :: { LName }
  : OP                              { let Token (Op (Other [] str)) _ = thing $1
                                       in mkName str A.<$ $1 }

    -- special cases for operators that are re-used elsewhere
  | '*'                             { Located $1 $ mkName "*" }
  | '+'                             { Located $1 $ mkName "+" }
  | '-'                             { Located $1 $ mkName "-" }
  | '~'                             { Located $1 $ mkName "~" }
  | '^^'                            { Located $1 $ mkName "^^" }
  | '#'                             { Located $1 $ mkName "#" }

ops                     :: { [LName] }
  : op                     { [$1] }
  | ops ',' op             { $3 : $1 }

aexprs                         :: { [Expr]  }
  : aexpr                         { [$1]    }
  | aexprs aexpr                  { $2 : $1 }

aexpr                          :: { Expr                                   }
  : qname                         { at $1 $ EVar (thing $1)                }

  | NUM                           { at $1 $ numLit (tokenType (thing $1))  }
  | STRLIT                        { at $1 $ ELit $ ECString $ getStr $1    }
  | CHARLIT                       { at $1 $ ELit $ ECNum (getNum $1) CharLit }

  | '(' expr ')'                  { at ($1,$3) $ EParens $2                }
  | '(' tuple_exprs ')'           { at ($1,$3) $ ETuple (reverse $2)       }
  | '(' ')'                       { at ($1,$2) $ ETuple []                 }
  | '{' '}'                       { at ($1,$2) $ ERecord []                }
  | '{' field_exprs '}'           { at ($1,$3) $ ERecord (reverse $2)      }
  | '[' ']'                       { at ($1,$2) $ EList []                  }
  | '[' list_expr  ']'            { at ($1,$3) $2                          }
  | '`' tick_ty                   { at ($1,$2) $ ETypeVal $2               }
  | aexpr '.' selector            { at ($1,$3) $ ESel $1 (thing $3)        }

  | '(' qop ')'                   { at ($1,$3) $ EVar $ thing $2           }

  | '<|'            '|>'          {% mkPoly (rComb $1 $2) [] }
  | '<|' poly_terms '|>'          {% mkPoly (rComb $1 $3) $2 }


  -- | error                           {%^ customError "expr" }

poly_terms                     :: { [(Bool, Integer)] }
  : poly_term                     { [$1] }
  | poly_terms '+' poly_term      { $3 : $1 }

poly_term                      :: { (Bool, Integer) }
  : NUM                           {% polyTerm (srcRange $1) (getNum $1) 0 }
  | 'x'                           {% polyTerm $1 1 1 }
  | 'x' '^^' NUM                  {% polyTerm (rComb $1 (srcRange $3))
                                                            1 (getNum $3) }

selector                       :: { Located Selector }
  : name                          { fmap (`RecordSel` Nothing) $1 }
  | NUM                           {% mkTupleSel (srcRange $1) (getNum $1) }

tuple_exprs                    :: { [Expr] }
  : expr ',' expr                 { [ $3, $1] }
  | tuple_exprs ',' expr          { $3 : $1   }

field_expr             :: { Named Expr }
  : name '=' expr         { Named { name = $1, value = $3 } }
  | name apats '=' expr   { Named { name = $1, value = EFun (reverse $2) $4 } }

field_exprs                    :: { [Named Expr] }
  : field_expr                    { [$1]    }
  | field_exprs ',' field_expr    { $3 : $1 }

list_expr                      :: { Expr }
  : expr '|' list_alts            { EComp $1 (reverse $3)    }
  | expr                          { EList [$1]               }
  | tuple_exprs                   { EList (reverse $1)       }

  {- The `expr` in the four productions that follow should be `type`.
     This, however, leads to ambiguity because the syntax for types and
     expressions overlaps and we need more than 1 look-ahead to resolve what
     is being parsed.  For this reason, we use `expr` temporarily and
     then convert it to the corresponding type in the AST. -}

  | expr          '..'            {% eFromTo $2 $1 Nothing   Nothing    }
  | expr          '..' expr       {% eFromTo $2 $1 Nothing   (Just $3)  }
  | expr ',' expr '..'            {% eFromTo $4 $1 (Just $3) Nothing    }
  | expr ',' expr '..' expr       {% eFromTo $4 $1 (Just $3) (Just $5)  }

  | expr '...'                    { EInfFrom $1 Nothing                 }
  | expr ',' expr '...'           { EInfFrom $1 (Just $3)               }


list_alts                      :: { [[Match]] }
  : matches                       { [ reverse $1 ] }
  | list_alts '|' matches         { reverse $3 : $1 }

matches                        :: { [Match] }
  : match                         { [$1] }
  | matches ',' match             { $3 : $1 }

match                          :: { Match }
  : pat '<-' expr                 { Match $1 $3 }


--------------------------------------------------------------------------------
pat                            :: { Pattern  }
  : ipat ':' type                 { at ($1,$3) $ PTyped $1 $3 }
  | ipat                          { $1                        }

ipat
  : ipat '#' ipat                 { at ($1,$3) $ PSplit $1 $3 }
  | apat                          { $1                        }

apat                           :: { Pattern }
  : name                          { PVar $1                           }
  | '_'                           { at $1       $ PWild               }
  | '(' ')'                       { at ($1,$2) $ PTuple []            }
  | '(' pat ')'                   { at ($1,$3)   $2                   }
  | '(' tuple_pats ')'            { at ($1,$3) $ PTuple (reverse $2)  }
  | '[' ']'                       { at ($1,$2) $ PList []             }
  | '[' pat ']'                   { at ($1,$3) $ PList [$2]           }
  | '[' tuple_pats ']'            { at ($1,$3) $ PList (reverse $2)   }
  | '{' '}'                       { at ($1,$2) $ PRecord []           }
  | '{' field_pats '}'            { at ($1,$3) $ PRecord (reverse $2) }

tuple_pats                     :: { [Pattern] }
  : pat ',' pat                   { [$3, $1] }
  | tuple_pats ',' pat            { $3 : $1   }

field_pat                      :: { Named Pattern }
  : name '=' pat                  { Named { name = $1, value = $3 } }

field_pats                     :: { [Named Pattern] }
  : field_pat                     { [$1]    }
  | field_pats ',' field_pat      { $3 : $1 }

--------------------------------------------------------------------------------

schema                         :: { Schema }
  : type                          { at $1 $ mkSchema [] [] $1      }
  | schema_vars type              { at ($1,$2) $ mkSchema (thing $1) [] $2 }
  | schema_quals type             { at ($1,$2) $ mkSchema [] (thing $1) $2 }
  | schema_vars schema_quals type { at ($1,$3) $ mkSchema (thing $1)
                                                          (thing $2) $3 }

schema_vars                    :: { Located [TParam] }
  : '{' '}'                       { Located (rComb $1 $2) [] }
  | '{' schema_params '}'         { Located (rComb $1 $3) (reverse $2) }

schema_quals                   :: { Located [Prop] }
  : type '=>'                     {% fmap (\x -> at (x,$2) x) (mkProp $1) }

kind                             :: { Located Kind      }
  : '#'                             { Located $1 KNum   }
  | '*'                             { Located $1 KType  }

schema_param                   :: { TParam }
  : name                          {% mkTParam $1 Nothing           }
  | name ':' kind                 {% mkTParam (at ($1,$3) $1) (Just (thing $3)) }

schema_params                    :: { [TParam] }
  : schema_param                    { [$1] }
  | schema_params ',' schema_param  { $3 : $1 }

tysyn_param                   :: { TParam }
  : name                         {% mkTParam $1 Nothing }
  | '(' name ':' kind ')'        {% mkTParam (at ($1,$5) $2) (Just (thing $4)) }

tysyn_params                  :: { [TParam]  }
  : tysyn_param                  { [$1]      }
  | tysyn_params tysyn_param     { $2 : $1   }

type                           :: { Type                                                       }
  : app_type '->' type            { at ($1,$3) $ TFun $1 $3                                    }
  | type op app_type              { at ($1,$3) $ TInfix $1 (fmap mkUnqual $2) defaultFixity $3 }
  | app_type                      { $1                                                         }

app_type                       :: { Type }
  -- : 'lg2'   atype                 { at ($1,$2) $ TApp TCLg2   [$2]    }
  -- | 'lengthFromThen' atype atype  { at ($1,$3) $ TApp TCLenFromThen [$2,$3] }
  -- | 'lengthFromThenTo' atype atype
  --                      atype      { at ($1,$4) $ TApp TCLenFromThen [$2,$3,$4] }
  -- | 'min'   atype atype           { at ($1,$3) $ TApp TCMin   [$2,$3] }
  -- | 'max'   atype atype           { at ($1,$3) $ TApp TCMax   [$2,$3] }

  : dimensions atype              { at ($1,$2) $ foldr TSeq $2 (reverse (thing $1)) }
  | qname atypes                  { at ($1,head $2)
                                     $ TUser (thing $1) (reverse $2) }
  | atype                         { $1                    }

atype                          :: { Type }
  : qname                         { at $1 $ TUser (thing $1) []        }
  | NUM                           { at $1 $ TNum  (getNum $1)          }
  | CHARLIT                       { at $1 $ TChar (toEnum $ fromInteger
                                                          $ getNum $1) }
  | '[' type ']'                  { at ($1,$3) $ TSeq $2 TBit          }
  | '(' type ')'                  { at ($1,$3) $ TParens $2            }
  | '(' ')'                       { at ($1,$2) $ TTuple []             }
  | '(' tuple_types ')'           { at ($1,$3) $ TTuple  (reverse $2)  }
  | '{' '}'                       { at ($1,$2) $ TRecord []            }
  | '{' field_types '}'           { at ($1,$3) $ TRecord (reverse $2)  }
  | '_'                           { at $1 TWild                        }

atypes                         :: { [ Type ] }
  : atype                         { [ $1 ]    }
  | atypes atype                  { $2 : $1   }

dimensions                     :: { Located [Type]  }
  : '[' type ']'                  { Located (rComb $1 $3) [ $2 ] }
  | dimensions '[' type ']'       { at ($1,$4) (fmap ($3 :) $1)  }

tuple_types                    :: { [Type] }
  : type ',' type                 { [ $3, $1] }
  | tuple_types ',' type          { $3 : $1   }

field_type                     :: { Named Type }
  : name ':' type                 { Named { name = $1, value = $3 } }

field_types                    :: { [Named Type] }
  : field_type                    { [$1]    }
  | field_types ',' field_type    { $3 : $1 }


name               :: { LName }
  : IDENT             { $1 { thing = getName $1 } }
  | 'x'               { Located { srcRange = $1, thing = mkName "x" }}
  | 'private'         { Located { srcRange = $1, thing = mkName "private" } }
  | 'as'              { Located { srcRange = $1, thing = mkName "as" } }
  | 'hiding'          { Located { srcRange = $1, thing = mkName "hiding" } }


modName                        :: { Located ModName }
  : qname                         { mkLModName $1 }

qname                          :: { Located QName }
  : name                          { fmap mkUnqual $1 }
  | QIDENT                        { let Token (Ident ns i) _ = thing $1
                                     in mkQual (mkModName ns) (mkName i) A.<$ $1 }

help_name                      :: { Located QName    }
  : qname                         { $1               }
  | qop                           { $1               }
  | '(' qop ')'                   { $2               }

{- The types that can come after a back-tick: either a type demotion,
or an explicit type application.  Explicit type applications are converted
to records, which cannot be demoted. -}
tick_ty                        :: { Type }
  : qname                         { at $1 $ TUser (thing $1) []      }
  | NUM                           { at $1 $ TNum  (getNum $1)          }
  | '(' type ')'                  {% validDemotedType (rComb $1 $3) $2 }
  | '{' '}'                       { at ($1,$2) (TRecord [])            }
  | '{' field_ty_vals '}'         { at ($1,$3) (TRecord (reverse $2))  }
  | '{' type '}'                  { anonRecord (getLoc ($1,$3)) [$2]   }
  | '{' tuple_types '}'           { anonRecord (getLoc ($1,$3)) (reverse $2) }

-- This for explicit type applications (e.g., f ` { front = 3 })
field_ty_val                   :: { Named Type                    }
  : name '=' type                 { Named { name = $1, value = $3 } }

field_ty_vals                  :: { [Named Type] }
  : field_ty_val                    { [$1]       }
  | field_ty_vals ',' field_ty_val  { $3 : $1    }




{

parseModName :: String -> Maybe ModName
parseModName txt =
  case parseString defaultConfig { cfgModuleScope = False } modName txt of
    Right a -> Just (thing a)
    Left _  -> Nothing

parseHelpName :: String -> Maybe QName
parseHelpName txt =
  case parseString defaultConfig { cfgModuleScope = False } helpName txt of
    Right a -> Just (thing a)
    Left _  -> Nothing

addImplicitIncludes :: Config -> Program -> Program
addImplicitIncludes cfg (Program ds) =
  Program $ map path (cfgAutoInclude cfg) ++ ds
  where path p = Include Located { srcRange = rng, thing = p }
        rng    = Range { source = cfgSource cfg, from = start, to = start }


parseProgramWith :: Config -> Text -> Either ParseError Program
parseProgramWith cfg s = case res s of
                          Left err -> Left err
                          Right a  -> Right (addImplicitIncludes cfg a)
  where
  res = parse cfg $ case cfgLayout cfg of
                      Layout   -> programLayout
                      NoLayout -> program

parseModule :: Config -> Text -> Either ParseError Module
parseModule cfg = parse cfg { cfgModuleScope = True } vmodule

parseProgram :: Layout -> Text -> Either ParseError Program
parseProgram l = parseProgramWith defaultConfig { cfgLayout = l }

parseExprWith :: Config -> Text -> Either ParseError Expr
parseExprWith cfg = parse cfg { cfgModuleScope = False } expr

parseExpr :: Text -> Either ParseError Expr
parseExpr = parseExprWith defaultConfig

parseDeclWith :: Config -> Text -> Either ParseError Decl
parseDeclWith cfg = parse cfg { cfgModuleScope = False } decl

parseDecl :: Text -> Either ParseError Decl
parseDecl = parseDeclWith defaultConfig

parseDeclsWith :: Config -> Text -> Either ParseError [Decl]
parseDeclsWith cfg = parse cfg { cfgModuleScope = ms } decls'
  where (ms, decls') = case cfgLayout cfg of
                         Layout   -> (True, declsLayout)
                         NoLayout -> (False, decls)

parseDecls :: Text -> Either ParseError [Decl]
parseDecls = parseDeclsWith defaultConfig

parseLetDeclWith :: Config -> Text -> Either ParseError Decl
parseLetDeclWith cfg = parse cfg { cfgModuleScope = False } letDecl

parseLetDecl :: Text -> Either ParseError Decl
parseLetDecl = parseLetDeclWith defaultConfig

parseReplWith :: Config -> Text -> Either ParseError ReplInput
parseReplWith cfg = parse cfg { cfgModuleScope = False } repl

parseRepl :: Text -> Either ParseError ReplInput
parseRepl = parseReplWith defaultConfig

parseSchemaWith :: Config -> Text -> Either ParseError Schema
parseSchemaWith cfg = parse cfg { cfgModuleScope = False } schema

parseSchema :: Text -> Either ParseError Schema
parseSchema = parseSchemaWith defaultConfig

-- vim: ft=haskell
}
