{- PiForall language -}

{-# LANGUAGE ViewPatterns, TypeSynonymInstances, 
             ExistentialQuantification, NamedFieldPuns, 
             ParallelListComp, FlexibleContexts, ScopedTypeVariables, 
             TupleSections, FlexibleInstances, CPP #-}
{-# OPTIONS_GHC -Wall -fno-warn-unused-matches #-}

-- | The main routines for type-checking 
module TypeCheck(tcModules, inferType, checkType) where

import Syntax
import Environment
import PrettyPrint
import Equal

import Unbound.Generics.LocallyNameless
import Unbound.Generics.LocallyNameless.Internal.Fold (toListOf)


#ifdef MIN_VERSION_GLASGOW_HASKELL
#if MIN_VERSION_GLASGOW_HASKELL(7,10,3,0)
-- ghc >= 7.10.3
#else
-- older ghc versions, but MIN_VERSION_GLASGOW_HASKELL defined
#endif
#else
-- MIN_VERSION_GLASGOW_HASKELL not even defined yet (ghc <= 7.8.x)
import Control.Applicative 
#endif




import Control.Monad.Except
import Text.PrettyPrint.HughesPJ
import Data.Maybe



-- | Infer the type of a term, producing an annotated version of the 
-- term (whose type can *always* be inferred).
inferType :: Term -> TcMonad (Term,Type)
inferType t = tcTerm t Nothing

-- | Check that the given term has the expected type.  
-- The provided type does not necessarily need to be in whnf, but it should be
-- elaborated (i.e. already checked to be a good type).
checkType :: Term -> Type -> TcMonad (Term, Type)
checkType tm expectedTy = do
  nf <- whnf expectedTy
  tcTerm tm (Just nf)

-- | check a term, producing an elaborated term
-- where all of the type annotations have been filled in
-- The second argument is 'Nothing' in inference mode and 
-- an expected type (must be in whnf) in checking mode
tcTerm :: Term -> Maybe Type -> TcMonad (Term,Type)

tcTerm t@(Var x) Nothing = do
  ty  <- lookupTy x
  return (t,ty)
  
tcTerm t@(Type) Nothing = return (t,Type)  
  
tcTerm (Pi bnd) Nothing = do 
  ((x, unembed -> tyA), tyB) <- unbind bnd
  atyA <- tcType tyA 
  atyB <- extendCtx (Sig x atyA) $ tcType tyB
  return (Pi (bind (x, embed atyA) atyB), Type) 
      
-- Check the type of a function    
tcTerm (Lam bnd) (Just (Pi bnd2)) = do
  -- unbind the variables in the lambda expression and pi type
  ((x,unembed -> Annot ma), body, 
   (_, unembed -> tyA), tyB) <- unbind2Plus bnd bnd2
  -- check tyA matches type annotation on binder, if present
  maybe (return ()) (equate tyA) ma
  -- check the type of the body of the lambda expression
  (ebody, etyB) <- extendCtx (Sig x tyA) (checkType body tyB)
  return (Lam (bind (x, embed (Annot (Just tyA))) ebody), 
          Pi bnd2)  
tcTerm (Lam _) (Just nf) = 
  err [DS "Lambda expression has a function type, not", DD nf]

-- infer the type of a lambda expression, when an annotation
-- on the binder is present
tcTerm (Lam bnd) Nothing = do
  ((x,(unembed -> Annot annot)), body) <- unbind bnd 
  tyA  <- maybe (err [DS "Must annotate lambda"]) (return) annot
  -- check that the type annotation is well-formed
  atyA <- tcType tyA
  -- infer the type of the body of the lambda expression
  (ebody, atyB) <- extendCtx (Sig x atyA) (inferType body)
  return (Lam (bind (x, embed (Annot (Just atyA))) ebody), 
          Pi  (bind (x, embed atyA) atyB))  

tcTerm (App t1 t2) Nothing = do  
  (at1, ty1)    <- inferType t1  
  (x, tyA, tyB) <- ensurePi ty1 
  (at2, ty2)    <- checkType t2 tyA
  let result = (App at1 at2, subst x at2 tyB)
  return result
                     


tcTerm (Ann tm ty) Nothing = do
  ty'         <- tcType ty
  (tm', ty'') <- checkType tm ty'
  
  return (tm', ty'')   
  
tcTerm (Pos p tm) mTy = 
  extendSourceLocation p tm $ tcTerm tm mTy
  
tcTerm (Paren tm) mTy = tcTerm tm mTy
  
tcTerm t@(TrustMe ann1) ann2 = do  
  expectedTy <- matchAnnots t ann1 ann2
  return (TrustMe (Annot (Just expectedTy)), expectedTy)

tcTerm (TyUnit) Nothing = return (TyUnit, Type)

tcTerm (LitUnit) Nothing = return (LitUnit, TyUnit)

tcTerm (TyBool) Nothing = return (TyBool,Type)
  
  
tcTerm (LitBool b) Nothing = do
  return (LitBool b, TyBool)
  
  
tcTerm t@(If t1 t2 t3 ann1) ann2 = do
  ty <- matchAnnots t ann1 ann2   
  (at1,_) <- checkType t1 TyBool
  nf <- whnf at1 
  let ctx b = case nf of 
        Var x -> [Def x (LitBool b)]
        _     -> []
  (at2, _) <- extendCtxs (ctx True) $ checkType t2 ty
  (at3, _) <- extendCtxs (ctx False) $ checkType t3 ty
  return (If at1 at2 at3 (Annot (Just ty)), ty)
        
  
tcTerm (Let bnd) ann = do       
  ((x,unembed->rhs),body) <- unbind bnd
  (arhs,aty) <- inferType rhs    
  (abody,ty) <- extendCtxs [Sig x aty, Def x arhs] $ 
                tcTerm body ann
  when (x `elem` toListOf fv ty) $
    err [DS "Let bound variable", DD x, DS "escapes in type", DD ty]  
  return (Let (bind (x,embed arhs) abody), ty)
          
  
             
           
  
  
tcTerm (TyEq a b) Nothing =  do
  (aa,aTy) <- inferType a 
  (ab,bTy) <- checkType b aTy
  return (TyEq aa ab, Type) 


tcTerm t@(Refl ann1) ann2 =  do
  ty <- matchAnnots t ann1 ann2
  case ty of 
    (TyEq a b) -> do
      equate a b
      return (Refl (Annot (Just ty)), ty)  
    _ -> err [DS "refl annotated with", DD ty]
  
tcTerm t@(Subst tm p ann1) ann2 =  do
  ty <- matchAnnots t ann1 ann2
  -- infer the type of the proof p
  (apf, tp) <- inferType p 
  -- make sure that it is an equality between m and n
  (m,n)     <- ensureTyEq tp
  -- if either side is a variable, add a definition to the context 
  edecl <- do 
    m'        <- whnf m
    n'        <- whnf n
    case (m',n') of 
        (Var x, _) -> return [Def x n']
        (_, Var y) -> return [Def y m']
        (_,_) -> return [] 
        
  pdecl <- do
    p'        <- whnf apf
    case p' of 
      (Var x) -> return [Def x (Refl (Annot (Just tp)))]
      _       -> return []
  let refined = extendCtxs (edecl ++ pdecl)
  (atm, _) <- refined $ checkType tm ty
  return (Subst atm apf (Annot (Just ty)), ty)
    
tcTerm t@(Contra p ann1) ann2 = do
  ty <- matchAnnots t ann1 ann2
  (apf, ty') <- inferType p 
  (a,b) <- ensureTyEq ty'
  a' <- whnf a
  b' <- whnf b
  case (a',b') of 
    
      
    (LitBool b1, LitBool b2) | b1 /= b2 ->
      return (Contra apf (Annot (Just ty)), ty)
    (_,_) -> err [DS "I can't tell that", DD a, DS "and", DD b,
                  DS "are contradictory"]

    
tcTerm t@(Sigma bnd) Nothing = do        
  ((x,unembed->tyA),tyB) <- unbind bnd
  aa <- tcType tyA
  ba <- extendCtx (Sig x aa) $ tcType tyB
  return (Sigma (bind (x,embed aa) ba), Type)
  
  
tcTerm t@(Prod a b ann1) ann2 = do
  ty <- matchAnnots t ann1 ann2
  case ty of
     (Sigma bnd) -> do
      ((x, unembed-> tyA), tyB) <- unbind bnd
      (aa,_) <- checkType a tyA
      (ba,_) <- extendCtxs [Sig x tyA, Def x aa] $ checkType b tyB
      return (Prod aa ba (Annot (Just ty)), ty)
     _ -> err [DS "Products must have Sigma Type", DD ty, 
                   DS "found instead"]
    
        
tcTerm t@(Pcase p bnd ann1) ann2 = do   
  ty <- matchAnnots t ann1 ann2
  (apr, pty) <- inferType p
  pty' <- whnf pty
  case pty' of 
    Sigma bnd' -> do
      ((x,unembed->tyA),tyB) <- unbind bnd'
      ((x',y'),body) <- unbind bnd
      let tyB' = subst x (Var x') tyB
      nfp  <- whnf apr
      let ctx = case nfp of 
            Var x0 -> [Def x0 (Prod (Var x') (Var y') 
                              (Annot (Just pty')))]
            _     -> []              
      (abody, bTy) <- extendCtxs ([Sig x' tyA, Sig y' tyB'] ++ ctx) $
        checkType body ty
      return (Pcase apr (bind (x',y') abody) (Annot (Just ty)), bTy)
    _ -> err [DS "Scrutinee of pcase must have Sigma type"]

      
tcTerm tm (Just ty) = do
  (atm, ty') <- inferType tm 
  equate ty' ty

  return (atm, ty)                     
  



---------------------------------------------------------------------
-- helper functions for type checking 
      
-- | Merge together two sources of type information
-- The first annotation is assumed to come from an annotation on 
-- the syntax of the term itself, the second as an argument to 
-- 'checkType'.  
matchAnnots :: Term -> Annot -> Maybe Type -> TcMonad Type
matchAnnots e (Annot Nothing) Nothing     = err 
 [DD e, DS "requires annotation"]
matchAnnots e (Annot Nothing) (Just t)    = return t
matchAnnots e (Annot (Just t)) Nothing    = do
  at <- tcType t                                          
  return at
matchAnnots e (Annot (Just t1)) (Just t2) = do
  at1 <- tcType t1                                          
  equate at1 t2
  return at1
  
-- | Make sure that the term is a type (i.e. has type 'Type') 
tcType :: Term -> TcMonad Term
tcType tm = do
  (atm, _) <- checkType tm Type
  return atm
                      
                    

  
--------------------------------------------------------
-- Using the typechecker for decls and modules and stuff
--------------------------------------------------------

-- | Typecheck a collection of modules. Assumes that each module
-- appears after its dependencies. Returns the same list of modules
-- with each definition typechecked 
tcModules :: [Module] -> TcMonad [Module]
tcModules mods = foldM tcM [] mods
  -- Check module m against modules in defs, then add m to the list.
  where defs `tcM` m = do -- "M" is for "Module" not "monad"
          let name = moduleName m
          liftIO $ putStrLn $ "Checking module " ++ show name
          m' <- defs `tcModule` m
          return $ defs++[m']

-- | Typecheck an entire module.
tcModule :: [Module]        -- ^ List of already checked modules (including their Decls).
         -> Module          -- ^ Module to check.
         -> TcMonad Module  -- ^ The same module with all Decls checked and elaborated.
tcModule defs m' = do checkedEntries <- extendCtxMods importedModules $
                                          foldr tcE (return [])
                                                  (moduleEntries m')
                      return $ m' { moduleEntries = checkedEntries }
  where d `tcE` m = do
          -- Extend the Env per the current Decl before checking
          -- subsequent Decls.
          x <- tcEntry d
          case x of
            AddHint  hint  -> extendHints hint m
                           -- Add decls to the Decls to be returned
            AddCtx decls -> (decls++) <$> (extendCtxsGlobal decls m)
        -- Get all of the defs from imported modules (this is the env to check current module in)
        importedModules = filter (\x -> (ModuleImport (moduleName x)) `elem` moduleImports m') defs

-- | The Env-delta returned when type-checking a top-level Decl.
data HintOrCtx = AddHint Hint
               | AddCtx [Decl]

-- | Check each sort of declaration in a module
tcEntry :: Decl -> TcMonad HintOrCtx
tcEntry (Def n term) = do
  oldDef <- lookupDef n
  case oldDef of
    Nothing -> tc
    Just term' -> die term'
  where
    tc = do
      lkup <- lookupHint n
      case lkup of
        Nothing -> do (aterm, ty) <- inferType term 
                      return $ AddCtx [Sig n ty, Def n aterm]
        Just ty ->
          let handler (Err ps msg) = throwError $ Err (ps) (msg $$ msg')
              msg' = disp [DS "When checking the term ", DD term,
                           DS "against the signature", DD ty]
          in do
            (eterm, ety) <- extendCtx (Sig n ty) $
                               checkType term ty `catchError` handler
            -- Put the elaborated version of term into the context.
            if (n `elem` toListOf fv eterm) then
                 return $ AddCtx [Sig n ety, RecDef n eterm]
              else
                 return $ AddCtx [Sig n ety, Def n eterm]
    die term' =
      extendSourceLocation (unPosFlaky term) term $
         err [DS "Multiple definitions of", DD n,
              DS "Previous definition was", DD term']

tcEntry (Sig n ty) = do
  duplicateTypeBindingCheck n ty
  ety <- tcType ty
  return $ AddHint (Hint n ety)

tcEntry _ = error "unimplemented"
     
-- | Make sure that we don't have the same name twice in the      
-- environment. (We don't rename top-level module definitions.)
duplicateTypeBindingCheck :: TName -> Term -> TcMonad ()
duplicateTypeBindingCheck n ty = do
  -- Look for existing type bindings ...
  l  <- lookupTyMaybe n
  l' <- lookupHint    n
  -- ... we don't care which, if either are Just.
  case catMaybes [l,l'] of
    [] ->  return ()
    -- We already have a type in the environment so fail.
    ty':_ ->
      let (Pos p  _) = ty
          msg = [DS "Duplicate type signature ", DD ty,
                 DS "for name ", DD n,
                 DS "Previous typing was", DD ty']
       in
         extendSourceLocation p ty $ err msg


