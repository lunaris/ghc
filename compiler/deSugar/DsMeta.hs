-----------------------------------------------------------------------------
--
-- (c) The University of Glasgow 2006
--
-- The purpose of this module is to transform an HsExpr into a CoreExpr which
-- when evaluated, returns a (Meta.Q Meta.Exp) computation analogous to the
-- input HsExpr. We do this in the DsM monad, which supplies access to
-- CoreExpr's of the "smart constructors" of the Meta.Exp datatype.
--
-- It also defines a bunch of knownKeyNames, in the same way as is done
-- in prelude/PrelNames.  It's much more convenient to do it here, becuase
-- otherwise we have to recompile PrelNames whenever we add a Name, which is
-- a Royal Pain (triggers other recompilation).
-----------------------------------------------------------------------------

{-# OPTIONS -fno-warn-tabs #-}
-- The above warning supression flag is a temporary kludge.
-- While working on this module you are encouraged to remove it and
-- detab the module (please do the detabbing in a separate patch). See
--     http://hackage.haskell.org/trac/ghc/wiki/Commentary/CodingStyle#TabsvsSpaces
-- for details

module DsMeta( dsBracket, 
	       templateHaskellNames, qTyConName, nameTyConName,
	       liftName, liftStringName, expQTyConName, patQTyConName, 
               decQTyConName, decsQTyConName, typeQTyConName,
	       decTyConName, typeTyConName, mkNameG_dName, mkNameG_vName, mkNameG_tcName,
	       quoteExpName, quotePatName, quoteDecName, quoteTypeName
	        ) where

#include "HsVersions.h"

import {-# SOURCE #-}	DsExpr ( dsExpr )

import MatchLit
import DsMonad

import qualified Language.Haskell.TH as TH

import HsSyn
import Class
import PrelNames
-- To avoid clashes with DsMeta.varName we must make a local alias for
-- OccName.varName we do this by removing varName from the import of
-- OccName above, making a qualified instance of OccName and using
-- OccNameAlias.varName where varName ws previously used in this file.
import qualified OccName( isDataOcc, isVarOcc, isTcOcc, varName, tcName ) 

import Module
import Id
import Name hiding( isVarOcc, isTcOcc, varName, tcName ) 
import NameEnv
import TcType
import TyCon
import TysWiredIn
import TysPrim ( liftedTypeKindTyConName )
import CoreSyn
import MkCore
import CoreUtils
import SrcLoc
import Unique
import BasicTypes
import Outputable
import Bag
import FastString
import ForeignCall
import MonadUtils
import Util( equalLength, filterOut )

import Data.Maybe
import Control.Monad
import Data.List

-----------------------------------------------------------------------------
dsBracket :: HsBracket Name -> [PendingSplice] -> DsM CoreExpr
-- Returns a CoreExpr of type TH.ExpQ
-- The quoted thing is parameterised over Name, even though it has
-- been type checked.  We don't want all those type decorations!

dsBracket brack splices
  = dsExtendMetaEnv new_bit (do_brack brack)
  where
    new_bit = mkNameEnv [(n, Splice (unLoc e)) | (n,e) <- splices]

    do_brack (VarBr _ n) = do { MkC e1  <- lookupOcc n ; return e1 }
    do_brack (ExpBr e)   = do { MkC e1  <- repLE e     ; return e1 }
    do_brack (PatBr p)   = do { MkC p1  <- repTopP p   ; return p1 }
    do_brack (TypBr t)   = do { MkC t1  <- repLTy t    ; return t1 }
    do_brack (DecBrG gp) = do { MkC ds1 <- repTopDs gp ; return ds1 }
    do_brack (DecBrL _)  = panic "dsBracket: unexpected DecBrL"

{- -------------- Examples --------------------

  [| \x -> x |]
====>
  gensym (unpackString "x"#) `bindQ` \ x1::String ->
  lam (pvar x1) (var x1)


  [| \x -> $(f [| x |]) |]
====>
  gensym (unpackString "x"#) `bindQ` \ x1::String ->
  lam (pvar x1) (f (var x1))
-}


-------------------------------------------------------
-- 			Declarations
-------------------------------------------------------

repTopP :: LPat Name -> DsM (Core TH.PatQ)
repTopP pat = do { ss <- mkGenSyms (collectPatBinders pat) 
                 ; pat' <- addBinds ss (repLP pat)
                 ; wrapGenSyms ss pat' }

repTopDs :: HsGroup Name -> DsM (Core (TH.Q [TH.Dec]))
repTopDs group
 = do { let { tv_bndrs = hsSigTvBinders (hs_valds group)
            ; bndrs = tv_bndrs ++ hsGroupBinders group } ;
	ss <- pprTrace "reptop" (ppr bndrs $$ ppr tv_bndrs) $ mkGenSyms bndrs ;

	-- Bind all the names mainly to avoid repeated use of explicit strings.
	-- Thus	we get
	--	do { t :: String <- genSym "T" ;
	--	     return (Data t [] ...more t's... }
	-- The other important reason is that the output must mention
	-- only "T", not "Foo:T" where Foo is the current module
	
	decls <- addBinds ss (do {
                        fix_ds  <- mapM repFixD (hs_fixds group) ;
			val_ds  <- rep_val_binds (hs_valds group) ;
			tycl_ds <- mapM repTyClD (concat (hs_tyclds group)) ;
			inst_ds <- mapM repInstD (hs_instds group) ;
			for_ds <- mapM repForD (hs_fords group) ;
			-- more needed
			return (de_loc $ sort_by_loc $ 
                                val_ds ++ catMaybes tycl_ds ++ fix_ds
                                       ++ inst_ds ++ for_ds) }) ;

	decl_ty <- lookupType decQTyConName ;
	let { core_list = coreList' decl_ty decls } ;

	dec_ty <- lookupType decTyConName ;
	q_decs  <- repSequenceQ dec_ty core_list ;

	wrapGenSyms ss q_decs
      }


hsSigTvBinders :: HsValBinds Name -> [Name]
-- See Note [Scoped type variables in bindings]
hsSigTvBinders binds
  = [hsLTyVarName tv | L _ (TypeSig _ (L _ (HsForAllTy Explicit tvs _ _))) <- sigs, tv <- tvs]
  where
    sigs = case binds of
     	     ValBindsIn  _ sigs -> sigs
     	     ValBindsOut _ sigs -> sigs


{- Notes

Note [Scoped type variables in bindings]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider
   f :: forall a. a -> a
   f x = x::a
Here the 'forall a' brings 'a' into scope over the binding group.
To achieve this we 

  a) Gensym a binding for 'a' at the same time as we do one for 'f'
     collecting the relevant binders with hsSigTvBinders

  b) When processing the 'forall', don't gensym

The relevant places are signposted with references to this Note

Note [Binders and occurrences]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
When we desugar [d| data T = MkT |]
we want to get
	Data "T" [] [Con "MkT" []] []
and *not*
	Data "Foo:T" [] [Con "Foo:MkT" []] []
That is, the new data decl should fit into whatever new module it is
asked to fit in.   We do *not* clone, though; no need for this:
	Data "T79" ....

But if we see this:
	data T = MkT 
	foo = reifyDecl T

then we must desugar to
	foo = Data "Foo:T" [] [Con "Foo:MkT" []] []

So in repTopDs we bring the binders into scope with mkGenSyms and addBinds.
And we use lookupOcc, rather than lookupBinder
in repTyClD and repC.

-}

-- represent associated family instances
--
repTyClDs :: [LTyClDecl Name] -> DsM [Core TH.DecQ]
repTyClDs ds = liftM de_loc (mapMaybeM repTyClD ds)


repTyClD :: LTyClDecl Name -> DsM (Maybe (SrcSpan, Core TH.DecQ))

repTyClD (L loc (TyFamily { tcdFlavour = flavour,
		            tcdLName   = tc, tcdTyVars = tvs, 
		            tcdKindSig = opt_kind }))
  = do { tc1 <- lookupLOcc tc 		-- See note [Binders and occurrences] 
       ; dec <- addTyClTyVarBinds tvs $ \bndrs ->
           do { flav   <- repFamilyFlavour flavour
	      ; case opt_kind of 
                  Nothing -> repFamilyNoKind flav tc1 bndrs
                  Just (HsBSig ki _) 
                    -> do { ki1 <- repKind ki 
                          ; repFamilyKind flav tc1 bndrs ki1 }
              }
       ; return $ Just (loc, dec)
       }

repTyClD (L loc (TyDecl { tcdLName = tc, tcdTyVars = tvs, tcdTyDefn = defn }))
  = do { tc1 <- lookupLOcc tc 		-- See note [Binders and occurrences]  
       ; tc_tvs <- mk_extra_tvs tc tvs defn
       ; dec <- addTyClTyVarBinds tc_tvs $ \bndrs -> 
	        repTyDefn tc1 bndrs Nothing (hsLTyVarNames tc_tvs) defn
       ; return (Just (loc, dec)) }

repTyClD (L loc (ClassDecl { tcdCtxt = cxt, tcdLName = cls, 
		             tcdTyVars = tvs, tcdFDs = fds,
		             tcdSigs = sigs, tcdMeths = meth_binds, 
                             tcdATs = ats, tcdATDefs = [] }))
  = do { cls1 <- lookupLOcc cls 	-- See note [Binders and occurrences] 
       ; dec  <- addTyVarBinds tvs $ \bndrs -> 
           do { cxt1   <- repLContext cxt
 	      ; sigs1  <- rep_sigs sigs
 	      ; binds1 <- rep_binds meth_binds
	      ; fds1   <- repLFunDeps fds
              ; ats1   <- repTyClDs ats
 	      ; decls1 <- coreList decQTyConName (ats1 ++ sigs1 ++ binds1)
 	      ; repClass cxt1 cls1 bndrs fds1 decls1 
              }
       ; return $ Just (loc, dec) 
       }

-- Un-handled cases
repTyClD (L loc d) = putSrcSpanDs loc $
		     do { warnDs (hang ds_msg 4 (ppr d))
			; return Nothing }

-------------------------
repTyDefn :: Core TH.Name -> Core [TH.TyVarBndr] 
          -> Maybe (Core [TH.TypeQ])
          -> [Name] -> HsTyDefn Name
          -> DsM (Core TH.DecQ)
repTyDefn tc bndrs opt_tys tv_names
          (TyData { td_ND = new_or_data, td_ctxt = cxt
		  , td_cons = cons, td_derivs = mb_derivs })
  = do { cxt1     <- repLContext cxt
       ; derivs1  <- repDerivs mb_derivs
       ; case new_or_data of
           NewType  -> do { con1 <- repC tv_names (head cons)
                          ; repNewtype cxt1 tc bndrs opt_tys con1 derivs1 }
           DataType -> do { cons1 <- mapM (repC tv_names) cons
                          ; cons2 <- coreList conQTyConName cons1
                          ; repData cxt1 tc bndrs opt_tys cons2 derivs1 } }

repTyDefn tc bndrs opt_tys _ (TySynonym { td_synRhs = ty })
  = do { ty1 <- repLTy ty
       ; repTySyn tc bndrs opt_tys ty1 }

-------------------------
mk_extra_tvs :: Located Name -> [LHsTyVarBndr Name] 
             -> HsTyDefn Name -> DsM [LHsTyVarBndr Name]
-- If there is a kind signature it must be of form
--    k1 -> .. -> kn -> *
-- Return type variables [tv1:k1, tv2:k2, .., tvn:kn]
mk_extra_tvs tc tvs defn
  | TyData { td_kindSig = Just (HsBSig hs_kind _) } <- defn
  = do { extra_tvs <- go hs_kind
       ; return (tvs ++ extra_tvs) }
  | otherwise
  = return tvs
  where
    go :: LHsKind Name -> DsM [LHsTyVarBndr Name]
    go (L loc (HsFunTy kind rest))
      = do { uniq <- newUnique
           ; let { occ = mkTyVarOccFS (fsLit "t")
                 ; nm = mkInternalName uniq occ loc
                 ; hs_tv = L loc (KindedTyVar nm (mkHsBSig kind)) }
           ; hs_tvs <- go rest
           ; return (hs_tv : hs_tvs) }

    go (L _ (HsTyVar n))
      | n == liftedTypeKindTyConName
      = return []
   
    go _ = failWithDs (ptext (sLit "Malformed kind signature for") <+> ppr tc)

-------------------------
-- represent fundeps
--
repLFunDeps :: [Located (FunDep Name)] -> DsM (Core [TH.FunDep])
repLFunDeps fds = do fds' <- mapM repLFunDep fds
                     fdList <- coreList funDepTyConName fds'
                     return fdList

repLFunDep :: Located (FunDep Name) -> DsM (Core TH.FunDep)
repLFunDep (L _ (xs, ys)) = do xs' <- mapM lookupBinder xs
                               ys' <- mapM lookupBinder ys
                               xs_list <- coreList nameTyConName xs'
                               ys_list <- coreList nameTyConName ys'
                               repFunDep xs_list ys_list

-- represent family declaration flavours
--
repFamilyFlavour :: FamilyFlavour -> DsM (Core TH.FamFlavour)
repFamilyFlavour TypeFamily = rep2 typeFamName []
repFamilyFlavour DataFamily = rep2 dataFamName []

-- Represent instance declarations
--
repInstD :: LInstDecl Name -> DsM (SrcSpan, Core TH.DecQ)
repInstD (L loc (FamInstD fi_decl))
  = do { dec <- repFamInstD fi_decl
       ; return (loc, dec) }

repInstD (L loc (ClsInstD ty binds prags ats))
  = do { dec <- addTyVarBinds tvs $ \_ ->
	    -- We must bring the type variables into scope, so their
	    -- occurrences don't fail, even though the binders don't 
            -- appear in the resulting data structure
	    --
	    -- But we do NOT bring the binders of 'binds' into scope
	    -- becuase they are properly regarded as occurrences
	    -- For example, the method names should be bound to
	    -- the selector Ids, not to fresh names (Trac #5410)
	    --
            do { cxt1 <- repContext cxt
               ; cls_tcon <- repTy (HsTyVar cls)
               ; cls_tys <- repLTys tys
               ; inst_ty1 <- repTapps cls_tcon cls_tys
               ; binds1 <- rep_binds binds
               ; prags1 <- rep_sigs prags
               ; ats1 <- mapM (repFamInstD . unLoc) ats
               ; decls <- coreList decQTyConName (ats1 ++ binds1 ++ prags1)
               ; repInst cxt1 inst_ty1 decls }
       ; return (loc, dec) }
 where
   Just (tvs, cxt, cls, tys) = splitHsInstDeclTy_maybe (unLoc ty)

repFamInstD :: FamInstDecl Name -> DsM (Core TH.DecQ)
repFamInstD (FamInstDecl { fid_tycon = tc_name, fid_pats = HsBSig tys tv_names, fid_defn = defn })
  = do { tc <- lookupLOcc tc_name 		-- See note [Binders and occurrences]  
       ; let loc = getLoc tc_name
             hs_tvs = [ L loc (UserTyVar n) | n <- tv_names]   -- Yuk
       ; addTyClTyVarBinds hs_tvs $ \ bndrs ->
         do { tys1 <- repLTys tys
            ; tys2 <- coreList typeQTyConName tys1
            ; repTyDefn tc bndrs (Just tys2) tv_names defn } }

repForD :: Located (ForeignDecl Name) -> DsM (SrcSpan, Core TH.DecQ)
repForD (L loc (ForeignImport name typ _ (CImport cc s mch cis)))
 = do MkC name' <- lookupLOcc name
      MkC typ' <- repLTy typ
      MkC cc' <- repCCallConv cc
      MkC s' <- repSafety s
      cis' <- conv_cimportspec cis
      MkC str <- coreStringLit (static ++ chStr ++ cis')
      dec <- rep2 forImpDName [cc', s', str, name', typ']
      return (loc, dec)
 where
    conv_cimportspec (CLabel cls) = notHandled "Foreign label" (doubleQuotes (ppr cls))
    conv_cimportspec (CFunction DynamicTarget) = return "dynamic"
    conv_cimportspec (CFunction (StaticTarget fs _ True)) = return (unpackFS fs)
    conv_cimportspec (CFunction (StaticTarget _  _ False)) = panic "conv_cimportspec: values not supported yet"
    conv_cimportspec CWrapper = return "wrapper"
    static = case cis of
                 CFunction (StaticTarget _ _ _) -> "static "
                 _ -> ""
    chStr = case mch of
            Nothing -> ""
            Just (Header h) -> unpackFS h ++ " "
repForD decl = notHandled "Foreign declaration" (ppr decl)

repCCallConv :: CCallConv -> DsM (Core TH.Callconv)
repCCallConv CCallConv = rep2 cCallName []
repCCallConv StdCallConv = rep2 stdCallName []
repCCallConv callConv    = notHandled "repCCallConv" (ppr callConv)

repSafety :: Safety -> DsM (Core TH.Safety)
repSafety PlayRisky = rep2 unsafeName []
repSafety PlayInterruptible = rep2 interruptibleName []
repSafety PlaySafe = rep2 safeName []

repFixD :: LFixitySig Name -> DsM (SrcSpan, Core TH.DecQ)
repFixD (L loc (FixitySig name (Fixity prec dir)))
  = do { MkC name' <- lookupLOcc name
       ; MkC prec' <- coreIntLit prec
       ; let rep_fn = case dir of 
                        InfixL -> infixLDName
                        InfixR -> infixRDName
                        InfixN -> infixNDName
       ; dec <- rep2 rep_fn [prec', name']
       ; return (loc, dec) }

ds_msg :: SDoc
ds_msg = ptext (sLit "Cannot desugar this Template Haskell declaration:")

-------------------------------------------------------
-- 			Constructors
-------------------------------------------------------

repC :: [Name] -> LConDecl Name -> DsM (Core TH.ConQ)
repC _ (L _ (ConDecl { con_name = con, con_qvars = [], con_cxt = L _ []
                       , con_details = details, con_res = ResTyH98 }))
  = do { con1 <- lookupLOcc con 	-- See note [Binders and occurrences] 
       ; repConstr con1 details  }
repC tvs (L _ (ConDecl { con_name = con
                       , con_qvars = con_tvs, con_cxt = L _ ctxt
                       , con_details = details
                       , con_res = res_ty }))
  = do { (eq_ctxt, con_tv_subst) <- mkGadtCtxt tvs res_ty
       ; let ex_tvs = [ tv | tv <- con_tvs, not (hsLTyVarName tv `in_subst` con_tv_subst)]
       ; binds <- mapM dupBinder con_tv_subst 
       ; dsExtendMetaEnv (mkNameEnv binds) $     -- Binds some of the con_tvs
         addTyVarBinds ex_tvs $ \ ex_bndrs ->   -- Binds the remaining con_tvs
    do { con1      <- lookupLOcc con 	-- See note [Binders and occurrences] 
       ; c'        <- repConstr con1 details
       ; ctxt'     <- repContext (eq_ctxt ++ ctxt)
       ; rep2 forallCName [unC ex_bndrs, unC ctxt', unC c'] } }

in_subst :: Name -> [(Name,Name)] -> Bool
in_subst _ []          = False
in_subst n ((n',_):ns) = n==n' || in_subst n ns

mkGadtCtxt :: [Name]		-- Tyvars of the data type
           -> ResType (LHsType Name)
	   -> DsM (HsContext Name, [(Name,Name)])
-- Given a data type in GADT syntax, figure out the equality 
-- context, so that we can represent it with an explicit 
-- equality context, because that is the only way to express
-- the GADT in TH syntax
--
-- Example:   
-- data T a b c where { MkT :: forall d e. d -> e -> T d [e] e
--     mkGadtCtxt [a,b,c] [d,e] (T d [e] e)
--   returns 
--     (b~[e], c~e), [d->a] 
-- 
-- This function is fiddly, but not really hard
mkGadtCtxt _ ResTyH98
  = return ([], [])
mkGadtCtxt data_tvs (ResTyGADT res_ty)
  | let (head_ty, tys) = splitHsAppTys res_ty []
  , Just _ <- is_hs_tyvar head_ty
  , data_tvs `equalLength` tys
  = return (go [] [] (data_tvs `zip` tys))

  | otherwise 
  = failWithDs (ptext (sLit "Malformed constructor result type:") <+> ppr res_ty)
  where
    go cxt subst [] = (cxt, subst)
    go cxt subst ((data_tv, ty) : rest)
       | Just con_tv <- is_hs_tyvar ty
       , isTyVarName con_tv
       , not (in_subst con_tv subst)
       = go cxt ((con_tv, data_tv) : subst) rest
       | otherwise
       = go (eq_pred : cxt) subst rest
       where
         loc = getLoc ty
         eq_pred = L loc (HsEqTy (L loc (HsTyVar data_tv)) ty)

    is_hs_tyvar (L _ (HsTyVar n))  = Just n   -- Type variables *and* tycons
    is_hs_tyvar (L _ (HsParTy ty)) = is_hs_tyvar ty
    is_hs_tyvar _                  = Nothing

    
repBangTy :: LBangType Name -> DsM (Core (TH.StrictTypeQ))
repBangTy ty= do 
  MkC s <- rep2 str []
  MkC t <- repLTy ty'
  rep2 strictTypeName [s, t]
  where 
    (str, ty') = case ty of
		   L _ (HsBangTy HsUnpack ty) -> (unpackedName,  ty)
		   L _ (HsBangTy _ ty)        -> (isStrictName,  ty)
		   _                          -> (notStrictName, ty)

-------------------------------------------------------
-- 			Deriving clause
-------------------------------------------------------

repDerivs :: Maybe [LHsType Name] -> DsM (Core [TH.Name])
repDerivs Nothing = coreList nameTyConName []
repDerivs (Just ctxt)
  = do { strs <- mapM rep_deriv ctxt ; 
	 coreList nameTyConName strs }
  where
    rep_deriv :: LHsType Name -> DsM (Core TH.Name)
	-- Deriving clauses must have the simple H98 form
    rep_deriv ty
      | Just (cls, []) <- splitHsClassTy_maybe (unLoc ty)
      = lookupOcc cls
      | otherwise
      = notHandled "Non-H98 deriving clause" (ppr ty)


-------------------------------------------------------
--   Signatures in a class decl, or a group of bindings
-------------------------------------------------------

rep_sigs :: [LSig Name] -> DsM [Core TH.DecQ]
rep_sigs sigs = do locs_cores <- rep_sigs' sigs
                   return $ de_loc $ sort_by_loc locs_cores

rep_sigs' :: [LSig Name] -> DsM [(SrcSpan, Core TH.DecQ)]
	-- We silently ignore ones we don't recognise
rep_sigs' sigs = do { sigs1 <- mapM rep_sig sigs ;
		     return (concat sigs1) }

rep_sig :: LSig Name -> DsM [(SrcSpan, Core TH.DecQ)]
	-- Singleton => Ok
	-- Empty     => Too hard, signature ignored
rep_sig (L loc (TypeSig nms ty))      = mapM (rep_ty_sig loc ty) nms
rep_sig (L _   (GenericSig nm _))     = failWithDs msg
  where msg = vcat  [ ptext (sLit "Illegal default signature for") <+> quotes (ppr nm)
                    , ptext (sLit "Default signatures are not supported by Template Haskell") ]

rep_sig (L loc (InlineSig nm ispec))  = rep_inline nm ispec loc
rep_sig (L loc (SpecSig nm ty ispec)) = rep_specialise nm ty ispec loc
rep_sig _                             = return []

rep_ty_sig :: SrcSpan -> LHsType Name -> Located Name
           -> DsM (SrcSpan, Core TH.DecQ)
rep_ty_sig loc (L _ ty) nm 
  = do { nm1 <- lookupLOcc nm
       ; ty1 <- rep_ty ty
       ; sig <- repProto nm1 ty1
       ; return (loc, sig) }
  where
    -- We must special-case the top-level explicit for-all of a TypeSig
    -- See Note [Scoped type variables in bindings]
    rep_ty (HsForAllTy Explicit tvs ctxt ty)
      = do { let rep_in_scope_tv tv = do { name <- lookupBinder (hsLTyVarName tv)
                                         ; repTyVarBndrWithKind tv name }
           ; bndrs1 <- mapM rep_in_scope_tv tvs
           ; bndrs2 <- coreList tyVarBndrTyConName bndrs1
           ; ctxt1  <- repLContext ctxt
           ; ty1    <- repLTy ty
           ; repTForall bndrs2 ctxt1 ty1 }

    rep_ty ty = repTy ty  


rep_inline :: Located Name 
           -> InlinePragma	-- Never defaultInlinePragma
           -> SrcSpan 
           -> DsM [(SrcSpan, Core TH.DecQ)]
rep_inline nm ispec loc
  = do { nm1 <- lookupLOcc nm
       ; ispec1 <- rep_InlinePrag ispec
       ; pragma <- repPragInl nm1 ispec1
       ; return [(loc, pragma)]
       }

rep_specialise :: Located Name -> LHsType Name -> InlinePragma -> SrcSpan 
               -> DsM [(SrcSpan, Core TH.DecQ)]
rep_specialise nm ty ispec loc
  = do { nm1 <- lookupLOcc nm
       ; ty1 <- repLTy ty
       ; pragma <- if isDefaultInlinePragma ispec
                   then repPragSpec nm1 ty1                  -- SPECIALISE
                   else do { ispec1 <- rep_InlinePrag ispec  -- SPECIALISE INLINE
                           ; repPragSpecInl nm1 ty1 ispec1 } 
       ; return [(loc, pragma)]
       }

-- Extract all the information needed to build a TH.InlinePrag
--
rep_InlinePrag :: InlinePragma	-- Never defaultInlinePragma
               -> DsM (Core TH.InlineSpecQ)
rep_InlinePrag (InlinePragma { inl_act = activation, inl_rule = match, inl_inline = inline })
  | Just (flag, phase) <- activation1 
  = repInlineSpecPhase inline1 match1 flag phase
  | otherwise
  = repInlineSpecNoPhase inline1 match1
  where
      match1      = coreBool (rep_RuleMatchInfo match)
      activation1 = rep_Activation activation
      inline1     = case inline of 
                       Inline -> coreBool True
 		       _other -> coreBool False
		       -- We have no representation for Inlinable

      rep_RuleMatchInfo FunLike = False
      rep_RuleMatchInfo ConLike = True

      rep_Activation NeverActive          = Nothing	-- We never have NOINLINE/AlwaysActive
      rep_Activation AlwaysActive         = Nothing	-- or            INLINE/NeverActive
      rep_Activation (ActiveBefore phase) = Just (coreBool False, 
                                                  MkC $ mkIntExprInt phase)
      rep_Activation (ActiveAfter phase)  = Just (coreBool True, 
                                                  MkC $ mkIntExprInt phase)


-------------------------------------------------------
-- 			Types
-------------------------------------------------------

addTyVarBinds :: [LHsTyVarBndr Name]	                       -- the binders to be added
              -> (Core [TH.TyVarBndr] -> DsM (Core (TH.Q a)))  -- action in the ext env
              -> DsM (Core (TH.Q a))
-- gensym a list of type variables and enter them into the meta environment;
-- the computations passed as the second argument is executed in that extended
-- meta environment and gets the *new* names on Core-level as an argument

addTyVarBinds tvs m
  = do { freshNames <- mkGenSyms (hsLTyVarNames tvs)
       ; term <- addBinds freshNames $ 
	    	 do { kbs1 <- mapM mk_tv_bndr (tvs `zip` freshNames)
                    ; kbs2 <- coreList tyVarBndrTyConName kbs1
	    	    ; m kbs2 }
       ; wrapGenSyms freshNames term }
  where
    mk_tv_bndr (tv, (_,v)) = repTyVarBndrWithKind tv (coreVar v)

addTyClTyVarBinds :: [LHsTyVarBndr Name]
                  -> (Core [TH.TyVarBndr] -> DsM (Core (TH.Q a)))
                  -> DsM (Core (TH.Q a))

-- Used for data/newtype declarations, and family instances,
-- so that the nested type variables work right
--    instance C (T a) where
--      type W (T a) = blah
-- The 'a' in the type instance is the one bound by the instance decl
addTyClTyVarBinds tvs m
  = do { let tv_names = hsLTyVarNames tvs
       ; env <- dsGetMetaEnv
       ; freshNames <- mkGenSyms (filterOut (`elemNameEnv` env) tv_names)
       	    -- Make fresh names for the ones that are not already in scope
            -- This makes things work for family declarations

       ; term <- addBinds freshNames $ 
	    	 do { kbs1 <- mapM mk_tv_bndr tvs
                    ; kbs2 <- coreList tyVarBndrTyConName kbs1
	    	    ; m kbs2 }

       ; wrapGenSyms freshNames term }
  where
    mk_tv_bndr tv = do { v <- lookupOcc (hsLTyVarName tv)
                       ; repTyVarBndrWithKind tv v }

-- Produce kinded binder constructors from the Haskell tyvar binders
--
repTyVarBndrWithKind :: LHsTyVarBndr Name 
                     -> Core TH.Name -> DsM (Core TH.TyVarBndr)
repTyVarBndrWithKind (L _ (UserTyVar {})) nm
  = repPlainTV nm
repTyVarBndrWithKind (L _ (KindedTyVar _ (HsBSig ki _))) nm
  = repKind ki >>= repKindedTV nm

-- represent a type context
--
repLContext :: LHsContext Name -> DsM (Core TH.CxtQ)
repLContext (L _ ctxt) = repContext ctxt

repContext :: HsContext Name -> DsM (Core TH.CxtQ)
repContext ctxt = do 
	            preds    <- mapM repLPred ctxt
		    predList <- coreList predQTyConName preds
		    repCtxt predList

-- represent a type predicate
--
repLPred :: LHsType Name -> DsM (Core TH.PredQ)
repLPred (L _ p) = repPred p

repPred :: HsType Name -> DsM (Core TH.PredQ)
repPred ty
  | Just (cls, tys) <- splitHsClassTy_maybe ty
  = do
      cls1 <- lookupOcc cls
      tys1 <- repLTys tys
      tys2 <- coreList typeQTyConName tys1
      repClassP cls1 tys2
repPred (HsEqTy tyleft tyright) 
  = do
      tyleft1  <- repLTy tyleft
      tyright1 <- repLTy tyright
      repEqualP tyleft1 tyright1
repPred ty
  = notHandled "Exotic predicate type" (ppr ty)

-- yield the representation of a list of types
--
repLTys :: [LHsType Name] -> DsM [Core TH.TypeQ]
repLTys tys = mapM repLTy tys

-- represent a type
--
repLTy :: LHsType Name -> DsM (Core TH.TypeQ)
repLTy (L _ ty) = repTy ty

repTy :: HsType Name -> DsM (Core TH.TypeQ)
repTy (HsForAllTy _ tvs ctxt ty)  = 
  addTyVarBinds tvs $ \bndrs -> do
    ctxt1  <- repLContext ctxt
    ty1    <- repLTy ty
    repTForall bndrs ctxt1 ty1

repTy (HsTyVar n)
  | isTvOcc (nameOccName n) = do 
			        tv1 <- lookupOcc n
			        repTvar tv1
  | otherwise		    = do 
			        tc1 <- lookupOcc n
			        repNamedTyCon tc1
repTy (HsAppTy f a)         = do 
			        f1 <- repLTy f
			        a1 <- repLTy a
			        repTapp f1 a1
repTy (HsFunTy f a)         = do 
			        f1   <- repLTy f
			        a1   <- repLTy a
			        tcon <- repArrowTyCon
			        repTapps tcon [f1, a1]
repTy (HsListTy t)	    = do
			        t1   <- repLTy t
			        tcon <- repListTyCon
			        repTapp tcon t1
repTy (HsPArrTy t)          = do
			        t1   <- repLTy t
			        tcon <- repTy (HsTyVar (tyConName parrTyCon))
			        repTapp tcon t1
repTy (HsTupleTy HsUnboxedTuple tys) = do
			        tys1 <- repLTys tys
			        tcon <- repUnboxedTupleTyCon (length tys)
			        repTapps tcon tys1
repTy (HsTupleTy _ tys)     = do tys1 <- repLTys tys 
                                 tcon <- repTupleTyCon (length tys)
                                 repTapps tcon tys1
repTy (HsOpTy ty1 (_, n) ty2) = repLTy ((nlHsTyVar (unLoc n) `nlHsAppTy` ty1)
			    	   `nlHsAppTy` ty2)
repTy (HsParTy t)  	    = repLTy t
repTy (HsKindSig t k)       = do
                                t1 <- repLTy t
                                k1 <- repKind k
                                repTSig t1 k1
repTy (HsSpliceTy splice _ _) = repSplice splice
repTy ty		      = notHandled "Exotic form of type" (ppr ty)

-- represent a kind
--
repKind :: LHsKind Name -> DsM (Core TH.Kind)
repKind ki
  = do { let (kis, ki') = splitHsFunType ki
       ; kis_rep <- mapM repKind kis
       ; ki'_rep <- repNonArrowKind ki'
       ; foldrM repArrowK ki'_rep kis_rep
       }
  where
    repNonArrowKind (L _ (HsTyVar name)) | name == liftedTypeKindTyConName = repStarK
    repNonArrowKind k = notHandled "Exotic form of kind" (ppr k)

-----------------------------------------------------------------------------
-- 		Splices
-----------------------------------------------------------------------------

repSplice :: HsSplice Name -> DsM (Core a)
-- See Note [How brackets and nested splices are handled] in TcSplice
-- We return a CoreExpr of any old type; the context should know
repSplice (HsSplice n _) 
 = do { mb_val <- dsLookupMetaEnv n
       ; case mb_val of
	   Just (Splice e) -> do { e' <- dsExpr e
				 ; return (MkC e') }
	   _ -> pprPanic "HsSplice" (ppr n) }
			-- Should not happen; statically checked

-----------------------------------------------------------------------------
-- 		Expressions
-----------------------------------------------------------------------------

repLEs :: [LHsExpr Name] -> DsM (Core [TH.ExpQ])
repLEs es = do { es'  <- mapM repLE es ;
		 coreList expQTyConName es' }

-- FIXME: some of these panics should be converted into proper error messages
--	  unless we can make sure that constructs, which are plainly not
--	  supported in TH already lead to error messages at an earlier stage
repLE :: LHsExpr Name -> DsM (Core TH.ExpQ)
repLE (L loc e) = putSrcSpanDs loc (repE e)

repE :: HsExpr Name -> DsM (Core TH.ExpQ)
repE (HsVar x)            =
  do { mb_val <- dsLookupMetaEnv x 
     ; case mb_val of
	Nothing	         -> do { str <- globalVar x
			       ; repVarOrCon x str }
	Just (Bound y)   -> repVarOrCon x (coreVar y)
	Just (Splice e)  -> do { e' <- dsExpr e
			       ; return (MkC e') } }
repE e@(HsIPVar _) = notHandled "Implicit parameters" (ppr e)

	-- Remember, we're desugaring renamer output here, so
	-- HsOverlit can definitely occur
repE (HsOverLit l) = do { a <- repOverloadedLiteral l; repLit a }
repE (HsLit l)     = do { a <- repLiteral l;           repLit a }
repE (HsLam (MatchGroup [m] _)) = repLambda m
repE (HsApp x y)   = do {a <- repLE x; b <- repLE y; repApp a b}

repE (OpApp e1 op _ e2) =
  do { arg1 <- repLE e1; 
       arg2 <- repLE e2; 
       the_op <- repLE op ;
       repInfixApp arg1 the_op arg2 } 
repE (NegApp x _)        = do
			      a         <- repLE x
			      negateVar <- lookupOcc negateName >>= repVar
			      negateVar `repApp` a
repE (HsPar x)            = repLE x
repE (SectionL x y)       = do { a <- repLE x; b <- repLE y; repSectionL a b } 
repE (SectionR x y)       = do { a <- repLE x; b <- repLE y; repSectionR a b } 
repE (HsCase e (MatchGroup ms _)) = do { arg <- repLE e
				       ; ms2 <- mapM repMatchTup ms
				       ; repCaseE arg (nonEmptyCoreList ms2) }
repE (HsIf _ x y z)         = do
			      a <- repLE x
			      b <- repLE y
			      c <- repLE z
			      repCond a b c
repE (HsLet bs e)         = do { (ss,ds) <- repBinds bs
			       ; e2 <- addBinds ss (repLE e)
			       ; z <- repLetE ds e2
			       ; wrapGenSyms ss z }

-- FIXME: I haven't got the types here right yet
repE e@(HsDo ctxt sts _) 
 | case ctxt of { DoExpr -> True; GhciStmt -> True; _ -> False }
 = do { (ss,zs) <- repLSts sts; 
        e'      <- repDoE (nonEmptyCoreList zs);
        wrapGenSyms ss e' }

 | ListComp <- ctxt
 = do { (ss,zs) <- repLSts sts; 
        e'      <- repComp (nonEmptyCoreList zs);
        wrapGenSyms ss e' }

  | otherwise
  = notHandled "mdo, monad comprehension and [: :]" (ppr e)

repE (ExplicitList _ es) = do { xs <- repLEs es; repListExp xs }
repE e@(ExplicitPArr _ _) = notHandled "Parallel arrays" (ppr e)
repE e@(ExplicitTuple es boxed) 
  | not (all tupArgPresent es) = notHandled "Tuple sections" (ppr e)
  | isBoxed boxed              = do { xs <- repLEs [e | Present e <- es]; repTup xs }
  | otherwise                  = do { xs <- repLEs [e | Present e <- es]; repUnboxedTup xs }

repE (RecordCon c _ flds)
 = do { x <- lookupLOcc c;
        fs <- repFields flds;
        repRecCon x fs }
repE (RecordUpd e flds _ _ _)
 = do { x <- repLE e;
        fs <- repFields flds;
        repRecUpd x fs }

repE (ExprWithTySig e ty) = do { e1 <- repLE e; t1 <- repLTy ty; repSigExp e1 t1 }
repE (ArithSeq _ aseq) =
  case aseq of
    From e              -> do { ds1 <- repLE e; repFrom ds1 }
    FromThen e1 e2      -> do 
		             ds1 <- repLE e1
			     ds2 <- repLE e2
			     repFromThen ds1 ds2
    FromTo   e1 e2      -> do 
			     ds1 <- repLE e1
			     ds2 <- repLE e2
			     repFromTo ds1 ds2
    FromThenTo e1 e2 e3 -> do 
			     ds1 <- repLE e1
			     ds2 <- repLE e2
			     ds3 <- repLE e3
			     repFromThenTo ds1 ds2 ds3

repE (HsSpliceE splice)  = repSplice splice
repE e@(PArrSeq {})      = notHandled "Parallel arrays" (ppr e)
repE e@(HsCoreAnn {})    = notHandled "Core annotations" (ppr e)
repE e@(HsSCC {})        = notHandled "Cost centres" (ppr e)
repE e@(HsTickPragma {}) = notHandled "Tick Pragma" (ppr e)
repE e@(HsBracketOut {}) = notHandled "TH brackets" (ppr e)
repE e 			 = notHandled "Expression form" (ppr e)

-----------------------------------------------------------------------------
-- Building representations of auxillary structures like Match, Clause, Stmt, 

repMatchTup ::  LMatch Name -> DsM (Core TH.MatchQ) 
repMatchTup (L _ (Match [p] _ (GRHSs guards wheres))) =
  do { ss1 <- mkGenSyms (collectPatBinders p) 
     ; addBinds ss1 $ do {
     ; p1 <- repLP p
     ; (ss2,ds) <- repBinds wheres
     ; addBinds ss2 $ do {
     ; gs    <- repGuards guards
     ; match <- repMatch p1 gs ds
     ; wrapGenSyms (ss1++ss2) match }}}
repMatchTup _ = panic "repMatchTup: case alt with more than one arg"

repClauseTup ::  LMatch Name -> DsM (Core TH.ClauseQ)
repClauseTup (L _ (Match ps _ (GRHSs guards wheres))) =
  do { ss1 <- mkGenSyms (collectPatsBinders ps) 
     ; addBinds ss1 $ do {
       ps1 <- repLPs ps
     ; (ss2,ds) <- repBinds wheres
     ; addBinds ss2 $ do {
       gs <- repGuards guards
     ; clause <- repClause ps1 gs ds
     ; wrapGenSyms (ss1++ss2) clause }}}

repGuards ::  [LGRHS Name] ->  DsM (Core TH.BodyQ)
repGuards [L _ (GRHS [] e)]
  = do {a <- repLE e; repNormal a }
repGuards other 
  = do { zs <- mapM process other;
     let {(xs, ys) = unzip zs};
	 gd <- repGuarded (nonEmptyCoreList ys);
     wrapGenSyms (concat xs) gd }
  where 
    process :: LGRHS Name -> DsM ([GenSymBind], (Core (TH.Q (TH.Guard, TH.Exp))))
    process (L _ (GRHS [L _ (ExprStmt e1 _ _ _)] e2))
           = do { x <- repLNormalGE e1 e2;
                  return ([], x) }
    process (L _ (GRHS ss rhs))
           = do (gs, ss') <- repLSts ss
		rhs' <- addBinds gs $ repLE rhs
                g <- repPatGE (nonEmptyCoreList ss') rhs'
                return (gs, g)

repFields :: HsRecordBinds Name -> DsM (Core [TH.Q TH.FieldExp])
repFields (HsRecFields { rec_flds = flds })
  = do	{ fnames <- mapM lookupLOcc (map hsRecFieldId flds)
	; es <- mapM repLE (map hsRecFieldArg flds)
	; fs <- zipWithM repFieldExp fnames es
	; coreList fieldExpQTyConName fs }


-----------------------------------------------------------------------------
-- Representing Stmt's is tricky, especially if bound variables
-- shadow each other. Consider:  [| do { x <- f 1; x <- f x; g x } |]
-- First gensym new names for every variable in any of the patterns.
-- both static (x'1 and x'2), and dynamic ((gensym "x") and (gensym "y"))
-- if variables didn't shaddow, the static gensym wouldn't be necessary
-- and we could reuse the original names (x and x).
--
-- do { x'1 <- gensym "x"
--    ; x'2 <- gensym "x"   
--    ; doE [ BindSt (pvar x'1) [| f 1 |]
--          , BindSt (pvar x'2) [| f x |] 
--          , NoBindSt [| g x |] 
--          ]
--    }

-- The strategy is to translate a whole list of do-bindings by building a
-- bigger environment, and a bigger set of meta bindings 
-- (like:  x'1 <- gensym "x" ) and then combining these with the translations
-- of the expressions within the Do
      
-----------------------------------------------------------------------------
-- The helper function repSts computes the translation of each sub expression
-- and a bunch of prefix bindings denoting the dynamic renaming.

repLSts :: [LStmt Name] -> DsM ([GenSymBind], [Core TH.StmtQ])
repLSts stmts = repSts (map unLoc stmts)

repSts :: [Stmt Name] -> DsM ([GenSymBind], [Core TH.StmtQ])
repSts (BindStmt p e _ _ : ss) =
   do { e2 <- repLE e 
      ; ss1 <- mkGenSyms (collectPatBinders p) 
      ; addBinds ss1 $ do {
      ; p1 <- repLP p; 
      ; (ss2,zs) <- repSts ss
      ; z <- repBindSt p1 e2
      ; return (ss1++ss2, z : zs) }}
repSts (LetStmt bs : ss) =
   do { (ss1,ds) <- repBinds bs
      ; z <- repLetSt ds
      ; (ss2,zs) <- addBinds ss1 (repSts ss)
      ; return (ss1++ss2, z : zs) } 
repSts (ExprStmt e _ _ _ : ss) =       
   do { e2 <- repLE e
      ; z <- repNoBindSt e2 
      ; (ss2,zs) <- repSts ss
      ; return (ss2, z : zs) }
repSts [LastStmt e _] 
  = do { e2 <- repLE e
       ; z <- repNoBindSt e2
       ; return ([], [z]) }
repSts []    = return ([],[])
repSts other = notHandled "Exotic statement" (ppr other)


-----------------------------------------------------------
--			Bindings
-----------------------------------------------------------

repBinds :: HsLocalBinds Name -> DsM ([GenSymBind], Core [TH.DecQ]) 
repBinds EmptyLocalBinds
  = do	{ core_list <- coreList decQTyConName []
	; return ([], core_list) }

repBinds b@(HsIPBinds _) = notHandled "Implicit parameters" (ppr b)

repBinds (HsValBinds decs)
 = do	{ let { bndrs = hsSigTvBinders decs ++ collectHsValBinders decs }
		-- No need to worrry about detailed scopes within
		-- the binding group, because we are talking Names
		-- here, so we can safely treat it as a mutually 
		-- recursive group
                -- For hsSigTvBinders see Note [Scoped type variables in bindings]
	; ss        <- mkGenSyms bndrs
	; prs       <- addBinds ss (rep_val_binds decs)
	; core_list <- coreList decQTyConName 
				(de_loc (sort_by_loc prs))
	; return (ss, core_list) }

rep_val_binds :: HsValBinds Name -> DsM [(SrcSpan, Core TH.DecQ)]
-- Assumes: all the binders of the binding are alrady in the meta-env
rep_val_binds (ValBindsOut binds sigs)
 = do { core1 <- rep_binds' (unionManyBags (map snd binds))
      ;	core2 <- rep_sigs' sigs
      ;	return (core1 ++ core2) }
rep_val_binds (ValBindsIn _ _)
 = panic "rep_val_binds: ValBindsIn"

rep_binds :: LHsBinds Name -> DsM [Core TH.DecQ]
rep_binds binds = do { binds_w_locs <- rep_binds' binds
		     ; return (de_loc (sort_by_loc binds_w_locs)) }

rep_binds' :: LHsBinds Name -> DsM [(SrcSpan, Core TH.DecQ)]
rep_binds' binds = mapM rep_bind (bagToList binds)

rep_bind :: LHsBind Name -> DsM (SrcSpan, Core TH.DecQ)
-- Assumes: all the binders of the binding are alrady in the meta-env

-- Note GHC treats declarations of a variable (not a pattern) 
-- e.g.  x = g 5 as a Fun MonoBinds. This is indicated by a single match 
-- with an empty list of patterns
rep_bind (L loc (FunBind { fun_id = fn, 
			   fun_matches = MatchGroup [L _ (Match [] _ (GRHSs guards wheres))] _ }))
 = do { (ss,wherecore) <- repBinds wheres
	; guardcore <- addBinds ss (repGuards guards)
	; fn'  <- lookupLBinder fn
	; p    <- repPvar fn'
	; ans  <- repVal p guardcore wherecore
	; ans' <- wrapGenSyms ss ans
	; return (loc, ans') }

rep_bind (L loc (FunBind { fun_id = fn, fun_matches = MatchGroup ms _ }))
 =   do { ms1 <- mapM repClauseTup ms
	; fn' <- lookupLBinder fn
        ; ans <- repFun fn' (nonEmptyCoreList ms1)
        ; return (loc, ans) }

rep_bind (L loc (PatBind { pat_lhs = pat, pat_rhs = GRHSs guards wheres }))
 =   do { patcore <- repLP pat 
        ; (ss,wherecore) <- repBinds wheres
	; guardcore <- addBinds ss (repGuards guards)
        ; ans  <- repVal patcore guardcore wherecore
	; ans' <- wrapGenSyms ss ans
        ; return (loc, ans') }

rep_bind (L _ (VarBind { var_id = v, var_rhs = e}))
 =   do { v' <- lookupBinder v 
	; e2 <- repLE e
        ; x <- repNormal e2
        ; patcore <- repPvar v'
	; empty_decls <- coreList decQTyConName [] 
        ; ans <- repVal patcore x empty_decls
        ; return (srcLocSpan (getSrcLoc v), ans) }

rep_bind (L _ (AbsBinds {}))  = panic "rep_bind: AbsBinds"

-----------------------------------------------------------------------------
-- Since everything in a Bind is mutually recursive we need rename all
-- all the variables simultaneously. For example: 
-- [| AndMonoBinds (f x = x + g 2) (g x = f 1 + 2) |] would translate to
-- do { f'1 <- gensym "f"
--    ; g'2 <- gensym "g"
--    ; [ do { x'3 <- gensym "x"; fun f'1 [pvar x'3] [| x + g2 |]},
--        do { x'4 <- gensym "x"; fun g'2 [pvar x'4] [| f 1 + 2 |]}
--      ]}
-- This requires collecting the bindings (f'1 <- gensym "f"), and the 
-- environment ( f |-> f'1 ) from each binding, and then unioning them 
-- together. As we do this we collect GenSymBinds's which represent the renamed 
-- variables bound by the Bindings. In order not to lose track of these 
-- representations we build a shadow datatype MB with the same structure as 
-- MonoBinds, but which has slots for the representations


-----------------------------------------------------------------------------
-- GHC allows a more general form of lambda abstraction than specified
-- by Haskell 98. In particular it allows guarded lambda's like : 
-- (\  x | even x -> 0 | odd x -> 1) at the moment we can't represent this in
-- Haskell Template's Meta.Exp type so we punt if it isn't a simple thing like
-- (\ p1 .. pn -> exp) by causing an error.  

repLambda :: LMatch Name -> DsM (Core TH.ExpQ)
repLambda (L _ (Match ps _ (GRHSs [L _ (GRHS [] e)] EmptyLocalBinds)))
 = do { let bndrs = collectPatsBinders ps ;
      ; ss  <- mkGenSyms bndrs
      ; lam <- addBinds ss (
		do { xs <- repLPs ps; body <- repLE e; repLam xs body })
      ; wrapGenSyms ss lam }

repLambda (L _ m) = notHandled "Guarded labmdas" (pprMatch (LambdaExpr :: HsMatchContext Name) m)

  
-----------------------------------------------------------------------------
--			Patterns
-- repP deals with patterns.  It assumes that we have already
-- walked over the pattern(s) once to collect the binders, and 
-- have extended the environment.  So every pattern-bound 
-- variable should already appear in the environment.

-- Process a list of patterns
repLPs :: [LPat Name] -> DsM (Core [TH.PatQ])
repLPs ps = do { ps' <- mapM repLP ps ;
		 coreList patQTyConName ps' }

repLP :: LPat Name -> DsM (Core TH.PatQ)
repLP (L _ p) = repP p

repP :: Pat Name -> DsM (Core TH.PatQ)
repP (WildPat _)       = repPwild 
repP (LitPat l)        = do { l2 <- repLiteral l; repPlit l2 }
repP (VarPat x)        = do { x' <- lookupBinder x; repPvar x' }
repP (LazyPat p)       = do { p1 <- repLP p; repPtilde p1 }
repP (BangPat p)       = do { p1 <- repLP p; repPbang p1 }
repP (AsPat x p)       = do { x' <- lookupLBinder x; p1 <- repLP p; repPaspat x' p1 }
repP (ParPat p)        = repLP p 
repP (ListPat ps _)    = do { qs <- repLPs ps; repPlist qs }
repP (TuplePat ps boxed _)
  | isBoxed boxed       = do { qs <- repLPs ps; repPtup qs }
  | otherwise           = do { qs <- repLPs ps; repPunboxedTup qs }
repP (ConPatIn dc details)
 = do { con_str <- lookupLOcc dc
      ; case details of
         PrefixCon ps -> do { qs <- repLPs ps; repPcon con_str qs }
         RecCon rec   -> do { let flds = rec_flds rec
			    ; vs <- sequence $ map lookupLOcc (map hsRecFieldId flds)
                            ; ps <- sequence $ map repLP (map hsRecFieldArg flds)
                            ; fps <- zipWithM (\x y -> rep2 fieldPatName [unC x,unC y]) vs ps
                            ; fps' <- coreList fieldPatQTyConName fps
                            ; repPrec con_str fps' }
         InfixCon p1 p2 -> do { p1' <- repLP p1;
                                p2' <- repLP p2;
                                repPinfix p1' con_str p2' }
   }
repP (NPat l Nothing _)  = do { a <- repOverloadedLiteral l; repPlit a }
repP (ViewPat e p _) = do { e' <- repLE e; p' <- repLP p; repPview e' p' }
repP p@(NPat _ (Just _) _) = notHandled "Negative overloaded patterns" (ppr p)
repP p@(SigPatIn {})  = notHandled "Type signatures in patterns" (ppr p)
	-- The problem is to do with scoped type variables.
	-- To implement them, we have to implement the scoping rules
	-- here in DsMeta, and I don't want to do that today!
	--	 do { p' <- repLP p; t' <- repLTy t; repPsig p' t' }
	--	repPsig :: Core TH.PatQ -> Core TH.TypeQ -> DsM (Core TH.PatQ)
	--	repPsig (MkC p) (MkC t) = rep2 sigPName [p, t]

repP other = notHandled "Exotic pattern" (ppr other)

----------------------------------------------------------
-- Declaration ordering helpers

sort_by_loc :: [(SrcSpan, a)] -> [(SrcSpan, a)]
sort_by_loc xs = sortBy comp xs
    where comp x y = compare (fst x) (fst y)

de_loc :: [(a, b)] -> [b]
de_loc = map snd

----------------------------------------------------------
--	The meta-environment

-- A name/identifier association for fresh names of locally bound entities
type GenSymBind = (Name, Id)	-- Gensym the string and bind it to the Id
				-- I.e.		(x, x_id) means
				--	let x_id = gensym "x" in ...

-- Generate a fresh name for a locally bound entity

mkGenSyms :: [Name] -> DsM [GenSymBind]
-- We can use the existing name.  For example:
--	[| \x_77 -> x_77 + x_77 |]
-- desugars to
--	do { x_77 <- genSym "x"; .... }
-- We use the same x_77 in the desugared program, but with the type Bndr
-- instead of Int
--
-- We do make it an Internal name, though (hence localiseName)
--
-- Nevertheless, it's monadic because we have to generate nameTy
mkGenSyms ns = do { var_ty <- lookupType nameTyConName
		  ; return [(nm, mkLocalId (localiseName nm) var_ty) | nm <- ns] }

	     
addBinds :: [GenSymBind] -> DsM a -> DsM a
-- Add a list of fresh names for locally bound entities to the 
-- meta environment (which is part of the state carried around 
-- by the desugarer monad) 
addBinds bs m = dsExtendMetaEnv (mkNameEnv [(n,Bound id) | (n,id) <- bs]) m

dupBinder :: (Name, Name) -> DsM (Name, DsMetaVal)
dupBinder (new, old) 
  = do { mb_val <- dsLookupMetaEnv old
       ; case mb_val of
           Just val -> return (new, val)
           Nothing  -> pprPanic "dupBinder" (ppr old) }

-- Look up a locally bound name
--
lookupLBinder :: Located Name -> DsM (Core TH.Name)
lookupLBinder (L _ n) = lookupBinder n

lookupBinder :: Name -> DsM (Core TH.Name)
lookupBinder = lookupOcc
  -- Binders are brought into scope before the pattern or what-not is
  -- desugared.  Moreover, in instance declaration the binder of a method
  -- will be the selector Id and hence a global; so we need the 
  -- globalVar case of lookupOcc

-- Look up a name that is either locally bound or a global name
--
--  * If it is a global name, generate the "original name" representation (ie,
--   the <module>:<name> form) for the associated entity
--
lookupLOcc :: Located Name -> DsM (Core TH.Name)
-- Lookup an occurrence; it can't be a splice.
-- Use the in-scope bindings if they exist
lookupLOcc (L _ n) = lookupOcc n

lookupOcc :: Name -> DsM (Core TH.Name)
lookupOcc n
  = do {  mb_val <- dsLookupMetaEnv n ;
          case mb_val of
		Nothing         -> globalVar n
		Just (Bound x)  -> return (coreVar x)
		Just (Splice _) -> pprPanic "repE:lookupOcc" (ppr n) 
    }

globalVar :: Name -> DsM (Core TH.Name)
-- Not bound by the meta-env
-- Could be top-level; or could be local
--	f x = $(g [| x |])
-- Here the x will be local
globalVar name
  | isExternalName name
  = do	{ MkC mod <- coreStringLit name_mod
        ; MkC pkg <- coreStringLit name_pkg
	; MkC occ <- occNameLit name
	; rep2 mk_varg [pkg,mod,occ] }
  | otherwise
  = do 	{ MkC occ <- occNameLit name
	; MkC uni <- coreIntLit (getKey (getUnique name))
	; rep2 mkNameLName [occ,uni] }
  where
      mod = ASSERT( isExternalName name) nameModule name
      name_mod = moduleNameString (moduleName mod)
      name_pkg = packageIdString (modulePackageId mod)
      name_occ = nameOccName name
      mk_varg | OccName.isDataOcc name_occ = mkNameG_dName
	      | OccName.isVarOcc  name_occ = mkNameG_vName
	      | OccName.isTcOcc   name_occ = mkNameG_tcName
	      | otherwise 	           = pprPanic "DsMeta.globalVar" (ppr name)

lookupType :: Name 	-- Name of type constructor (e.g. TH.ExpQ)
	   -> DsM Type	-- The type
lookupType tc_name = do { tc <- dsLookupTyCon tc_name ;
		          return (mkTyConApp tc []) }

wrapGenSyms :: [GenSymBind] 
	    -> Core (TH.Q a) -> DsM (Core (TH.Q a))
-- wrapGenSyms [(nm1,id1), (nm2,id2)] y 
--	--> bindQ (gensym nm1) (\ id1 -> 
--	    bindQ (gensym nm2 (\ id2 -> 
--	    y))

wrapGenSyms binds body@(MkC b)
  = do  { var_ty <- lookupType nameTyConName
	; go var_ty binds }
  where
    [elt_ty] = tcTyConAppArgs (exprType b) 
	-- b :: Q a, so we can get the type 'a' by looking at the
	-- argument type. NB: this relies on Q being a data/newtype,
	-- not a type synonym

    go _ [] = return body
    go var_ty ((name,id) : binds)
      = do { MkC body'  <- go var_ty binds
	   ; lit_str    <- occNameLit name
	   ; gensym_app <- repGensym lit_str
	   ; repBindQ var_ty elt_ty 
		      gensym_app (MkC (Lam id body')) }

occNameLit :: Name -> DsM (Core String)
occNameLit n = coreStringLit (occNameString (nameOccName n))


-- %*********************************************************************
-- %*									*
--		Constructing code
-- %*									*
-- %*********************************************************************

-----------------------------------------------------------------------------
-- PHANTOM TYPES for consistency. In order to make sure we do this correct 
-- we invent a new datatype which uses phantom types.

newtype Core a = MkC CoreExpr
unC :: Core a -> CoreExpr
unC (MkC x) = x

rep2 :: Name -> [ CoreExpr ] -> DsM (Core a)
rep2 n xs = do { id <- dsLookupGlobalId n
               ; return (MkC (foldl App (Var id) xs)) }

-- Then we make "repConstructors" which use the phantom types for each of the
-- smart constructors of the Meta.Meta datatypes.


-- %*********************************************************************
-- %*									*
--		The 'smart constructors'
-- %*									*
-- %*********************************************************************

--------------- Patterns -----------------
repPlit   :: Core TH.Lit -> DsM (Core TH.PatQ) 
repPlit (MkC l) = rep2 litPName [l]

repPvar :: Core TH.Name -> DsM (Core TH.PatQ)
repPvar (MkC s) = rep2 varPName [s]

repPtup :: Core [TH.PatQ] -> DsM (Core TH.PatQ)
repPtup (MkC ps) = rep2 tupPName [ps]

repPunboxedTup :: Core [TH.PatQ] -> DsM (Core TH.PatQ)
repPunboxedTup (MkC ps) = rep2 unboxedTupPName [ps]

repPcon   :: Core TH.Name -> Core [TH.PatQ] -> DsM (Core TH.PatQ)
repPcon (MkC s) (MkC ps) = rep2 conPName [s, ps]

repPrec   :: Core TH.Name -> Core [(TH.Name,TH.PatQ)] -> DsM (Core TH.PatQ)
repPrec (MkC c) (MkC rps) = rep2 recPName [c,rps]

repPinfix :: Core TH.PatQ -> Core TH.Name -> Core TH.PatQ -> DsM (Core TH.PatQ)
repPinfix (MkC p1) (MkC n) (MkC p2) = rep2 infixPName [p1, n, p2]

repPtilde :: Core TH.PatQ -> DsM (Core TH.PatQ)
repPtilde (MkC p) = rep2 tildePName [p]

repPbang :: Core TH.PatQ -> DsM (Core TH.PatQ)
repPbang (MkC p) = rep2 bangPName [p]

repPaspat :: Core TH.Name -> Core TH.PatQ -> DsM (Core TH.PatQ)
repPaspat (MkC s) (MkC p) = rep2 asPName [s, p]

repPwild  :: DsM (Core TH.PatQ)
repPwild = rep2 wildPName []

repPlist :: Core [TH.PatQ] -> DsM (Core TH.PatQ)
repPlist (MkC ps) = rep2 listPName [ps]

repPview :: Core TH.ExpQ -> Core TH.PatQ -> DsM (Core TH.PatQ)
repPview (MkC e) (MkC p) = rep2 viewPName [e,p]

--------------- Expressions -----------------
repVarOrCon :: Name -> Core TH.Name -> DsM (Core TH.ExpQ)
repVarOrCon vc str | isDataOcc (nameOccName vc) = repCon str
	           | otherwise 		        = repVar str

repVar :: Core TH.Name -> DsM (Core TH.ExpQ)
repVar (MkC s) = rep2 varEName [s] 

repCon :: Core TH.Name -> DsM (Core TH.ExpQ)
repCon (MkC s) = rep2 conEName [s] 

repLit :: Core TH.Lit -> DsM (Core TH.ExpQ)
repLit (MkC c) = rep2 litEName [c] 

repApp :: Core TH.ExpQ -> Core TH.ExpQ -> DsM (Core TH.ExpQ)
repApp (MkC x) (MkC y) = rep2 appEName [x,y] 

repLam :: Core [TH.PatQ] -> Core TH.ExpQ -> DsM (Core TH.ExpQ)
repLam (MkC ps) (MkC e) = rep2 lamEName [ps, e]

repTup :: Core [TH.ExpQ] -> DsM (Core TH.ExpQ)
repTup (MkC es) = rep2 tupEName [es]

repUnboxedTup :: Core [TH.ExpQ] -> DsM (Core TH.ExpQ)
repUnboxedTup (MkC es) = rep2 unboxedTupEName [es]

repCond :: Core TH.ExpQ -> Core TH.ExpQ -> Core TH.ExpQ -> DsM (Core TH.ExpQ)
repCond (MkC x) (MkC y) (MkC z) = rep2 condEName [x,y,z] 

repLetE :: Core [TH.DecQ] -> Core TH.ExpQ -> DsM (Core TH.ExpQ)
repLetE (MkC ds) (MkC e) = rep2 letEName [ds, e] 

repCaseE :: Core TH.ExpQ -> Core [TH.MatchQ] -> DsM( Core TH.ExpQ)
repCaseE (MkC e) (MkC ms) = rep2 caseEName [e, ms]

repDoE :: Core [TH.StmtQ] -> DsM (Core TH.ExpQ)
repDoE (MkC ss) = rep2 doEName [ss]

repComp :: Core [TH.StmtQ] -> DsM (Core TH.ExpQ)
repComp (MkC ss) = rep2 compEName [ss]

repListExp :: Core [TH.ExpQ] -> DsM (Core TH.ExpQ)
repListExp (MkC es) = rep2 listEName [es]

repSigExp :: Core TH.ExpQ -> Core TH.TypeQ -> DsM (Core TH.ExpQ)
repSigExp (MkC e) (MkC t) = rep2 sigEName [e,t]

repRecCon :: Core TH.Name -> Core [TH.Q TH.FieldExp]-> DsM (Core TH.ExpQ)
repRecCon (MkC c) (MkC fs) = rep2 recConEName [c,fs]

repRecUpd :: Core TH.ExpQ -> Core [TH.Q TH.FieldExp] -> DsM (Core TH.ExpQ)
repRecUpd (MkC e) (MkC fs) = rep2 recUpdEName [e,fs]

repFieldExp :: Core TH.Name -> Core TH.ExpQ -> DsM (Core (TH.Q TH.FieldExp))
repFieldExp (MkC n) (MkC x) = rep2 fieldExpName [n,x]

repInfixApp :: Core TH.ExpQ -> Core TH.ExpQ -> Core TH.ExpQ -> DsM (Core TH.ExpQ)
repInfixApp (MkC x) (MkC y) (MkC z) = rep2 infixAppName [x,y,z]

repSectionL :: Core TH.ExpQ -> Core TH.ExpQ -> DsM (Core TH.ExpQ)
repSectionL (MkC x) (MkC y) = rep2 sectionLName [x,y]

repSectionR :: Core TH.ExpQ -> Core TH.ExpQ -> DsM (Core TH.ExpQ)
repSectionR (MkC x) (MkC y) = rep2 sectionRName [x,y]

------------ Right hand sides (guarded expressions) ----
repGuarded :: Core [TH.Q (TH.Guard, TH.Exp)] -> DsM (Core TH.BodyQ)
repGuarded (MkC pairs) = rep2 guardedBName [pairs]

repNormal :: Core TH.ExpQ -> DsM (Core TH.BodyQ)
repNormal (MkC e) = rep2 normalBName [e]

------------ Guards ----
repLNormalGE :: LHsExpr Name -> LHsExpr Name -> DsM (Core (TH.Q (TH.Guard, TH.Exp)))
repLNormalGE g e = do g' <- repLE g
                      e' <- repLE e
                      repNormalGE g' e'

repNormalGE :: Core TH.ExpQ -> Core TH.ExpQ -> DsM (Core (TH.Q (TH.Guard, TH.Exp)))
repNormalGE (MkC g) (MkC e) = rep2 normalGEName [g, e]

repPatGE :: Core [TH.StmtQ] -> Core TH.ExpQ -> DsM (Core (TH.Q (TH.Guard, TH.Exp)))
repPatGE (MkC ss) (MkC e) = rep2 patGEName [ss, e]

------------- Stmts -------------------
repBindSt :: Core TH.PatQ -> Core TH.ExpQ -> DsM (Core TH.StmtQ)
repBindSt (MkC p) (MkC e) = rep2 bindSName [p,e]

repLetSt :: Core [TH.DecQ] -> DsM (Core TH.StmtQ)
repLetSt (MkC ds) = rep2 letSName [ds]

repNoBindSt :: Core TH.ExpQ -> DsM (Core TH.StmtQ)
repNoBindSt (MkC e) = rep2 noBindSName [e]

-------------- Range (Arithmetic sequences) -----------
repFrom :: Core TH.ExpQ -> DsM (Core TH.ExpQ)
repFrom (MkC x) = rep2 fromEName [x]

repFromThen :: Core TH.ExpQ -> Core TH.ExpQ -> DsM (Core TH.ExpQ)
repFromThen (MkC x) (MkC y) = rep2 fromThenEName [x,y]

repFromTo :: Core TH.ExpQ -> Core TH.ExpQ -> DsM (Core TH.ExpQ)
repFromTo (MkC x) (MkC y) = rep2 fromToEName [x,y]

repFromThenTo :: Core TH.ExpQ -> Core TH.ExpQ -> Core TH.ExpQ -> DsM (Core TH.ExpQ)
repFromThenTo (MkC x) (MkC y) (MkC z) = rep2 fromThenToEName [x,y,z]

------------ Match and Clause Tuples -----------
repMatch :: Core TH.PatQ -> Core TH.BodyQ -> Core [TH.DecQ] -> DsM (Core TH.MatchQ)
repMatch (MkC p) (MkC bod) (MkC ds) = rep2 matchName [p, bod, ds]

repClause :: Core [TH.PatQ] -> Core TH.BodyQ -> Core [TH.DecQ] -> DsM (Core TH.ClauseQ)
repClause (MkC ps) (MkC bod) (MkC ds) = rep2 clauseName [ps, bod, ds]

-------------- Dec -----------------------------
repVal :: Core TH.PatQ -> Core TH.BodyQ -> Core [TH.DecQ] -> DsM (Core TH.DecQ)
repVal (MkC p) (MkC b) (MkC ds) = rep2 valDName [p, b, ds]

repFun :: Core TH.Name -> Core [TH.ClauseQ] -> DsM (Core TH.DecQ)  
repFun (MkC nm) (MkC b) = rep2 funDName [nm, b]

repData :: Core TH.CxtQ -> Core TH.Name -> Core [TH.TyVarBndr] 
        -> Maybe (Core [TH.TypeQ])
        -> Core [TH.ConQ] -> Core [TH.Name] -> DsM (Core TH.DecQ)
repData (MkC cxt) (MkC nm) (MkC tvs) Nothing (MkC cons) (MkC derivs)
  = rep2 dataDName [cxt, nm, tvs, cons, derivs]
repData (MkC cxt) (MkC nm) (MkC _) (Just (MkC tys)) (MkC cons) (MkC derivs)
  = rep2 dataInstDName [cxt, nm, tys, cons, derivs]

repNewtype :: Core TH.CxtQ -> Core TH.Name -> Core [TH.TyVarBndr] 
           -> Maybe (Core [TH.TypeQ])
           -> Core TH.ConQ -> Core [TH.Name] -> DsM (Core TH.DecQ)
repNewtype (MkC cxt) (MkC nm) (MkC tvs) Nothing (MkC con) (MkC derivs)
  = rep2 newtypeDName [cxt, nm, tvs, con, derivs]
repNewtype (MkC cxt) (MkC nm) (MkC _) (Just (MkC tys)) (MkC con) (MkC derivs)
  = rep2 newtypeInstDName [cxt, nm, tys, con, derivs]

repTySyn :: Core TH.Name -> Core [TH.TyVarBndr] 
         -> Maybe (Core [TH.TypeQ])
         -> Core TH.TypeQ -> DsM (Core TH.DecQ)
repTySyn (MkC nm) (MkC tvs) Nothing (MkC rhs) 
  = rep2 tySynDName [nm, tvs, rhs]
repTySyn (MkC nm) (MkC _) (Just (MkC tys)) (MkC rhs) 
  = rep2 tySynInstDName [nm, tys, rhs]

repInst :: Core TH.CxtQ -> Core TH.TypeQ -> Core [TH.DecQ] -> DsM (Core TH.DecQ)
repInst (MkC cxt) (MkC ty) (MkC ds) = rep2 instanceDName [cxt, ty, ds]

repClass :: Core TH.CxtQ -> Core TH.Name -> Core [TH.TyVarBndr] 
         -> Core [TH.FunDep] -> Core [TH.DecQ] 
         -> DsM (Core TH.DecQ)
repClass (MkC cxt) (MkC cls) (MkC tvs) (MkC fds) (MkC ds) 
  = rep2 classDName [cxt, cls, tvs, fds, ds]

repPragInl :: Core TH.Name -> Core TH.InlineSpecQ -> DsM (Core TH.DecQ)
repPragInl (MkC nm) (MkC ispec) = rep2 pragInlDName [nm, ispec]

repPragSpec :: Core TH.Name -> Core TH.TypeQ -> DsM (Core TH.DecQ)
repPragSpec (MkC nm) (MkC ty) = rep2 pragSpecDName [nm, ty]

repPragSpecInl :: Core TH.Name -> Core TH.TypeQ -> Core TH.InlineSpecQ 
               -> DsM (Core TH.DecQ)
repPragSpecInl (MkC nm) (MkC ty) (MkC ispec) 
  = rep2 pragSpecInlDName [nm, ty, ispec]

repFamilyNoKind :: Core TH.FamFlavour -> Core TH.Name -> Core [TH.TyVarBndr] 
                -> DsM (Core TH.DecQ)
repFamilyNoKind (MkC flav) (MkC nm) (MkC tvs)
    = rep2 familyNoKindDName [flav, nm, tvs]

repFamilyKind :: Core TH.FamFlavour -> Core TH.Name -> Core [TH.TyVarBndr] 
              -> Core TH.Kind
              -> DsM (Core TH.DecQ)
repFamilyKind (MkC flav) (MkC nm) (MkC tvs) (MkC ki)
    = rep2 familyKindDName [flav, nm, tvs, ki]

repInlineSpecNoPhase :: Core Bool -> Core Bool -> DsM (Core TH.InlineSpecQ)
repInlineSpecNoPhase (MkC inline) (MkC conlike) 
  = rep2 inlineSpecNoPhaseName [inline, conlike]

repInlineSpecPhase :: Core Bool -> Core Bool -> Core Bool -> Core Int
                   -> DsM (Core TH.InlineSpecQ)
repInlineSpecPhase (MkC inline) (MkC conlike) (MkC beforeFrom) (MkC phase)
  = rep2 inlineSpecPhaseName [inline, conlike, beforeFrom, phase]

repFunDep :: Core [TH.Name] -> Core [TH.Name] -> DsM (Core TH.FunDep)
repFunDep (MkC xs) (MkC ys) = rep2 funDepName [xs, ys]

repProto :: Core TH.Name -> Core TH.TypeQ -> DsM (Core TH.DecQ)
repProto (MkC s) (MkC ty) = rep2 sigDName [s, ty]

repCtxt :: Core [TH.PredQ] -> DsM (Core TH.CxtQ)
repCtxt (MkC tys) = rep2 cxtName [tys]

repClassP :: Core TH.Name -> Core [TH.TypeQ] -> DsM (Core TH.PredQ)
repClassP (MkC cla) (MkC tys) = rep2 classPName [cla, tys]

repEqualP :: Core TH.TypeQ -> Core TH.TypeQ -> DsM (Core TH.PredQ)
repEqualP (MkC ty1) (MkC ty2) = rep2 equalPName [ty1, ty2]

repConstr :: Core TH.Name -> HsConDeclDetails Name
          -> DsM (Core TH.ConQ)
repConstr con (PrefixCon ps)
    = do arg_tys  <- mapM repBangTy ps
         arg_tys1 <- coreList strictTypeQTyConName arg_tys
         rep2 normalCName [unC con, unC arg_tys1]
repConstr con (RecCon ips)
    = do arg_vs   <- mapM lookupLOcc (map cd_fld_name ips)
         arg_tys  <- mapM repBangTy (map cd_fld_type ips)
         arg_vtys <- zipWithM (\x y -> rep2 varStrictTypeName [unC x, unC y])
                              arg_vs arg_tys
         arg_vtys' <- coreList varStrictTypeQTyConName arg_vtys
         rep2 recCName [unC con, unC arg_vtys']
repConstr con (InfixCon st1 st2)
    = do arg1 <- repBangTy st1
         arg2 <- repBangTy st2
         rep2 infixCName [unC arg1, unC con, unC arg2]

------------ Types -------------------

repTForall :: Core [TH.TyVarBndr] -> Core TH.CxtQ -> Core TH.TypeQ 
           -> DsM (Core TH.TypeQ)
repTForall (MkC tvars) (MkC ctxt) (MkC ty)
    = rep2 forallTName [tvars, ctxt, ty]

repTvar :: Core TH.Name -> DsM (Core TH.TypeQ)
repTvar (MkC s) = rep2 varTName [s]

repTapp :: Core TH.TypeQ -> Core TH.TypeQ -> DsM (Core TH.TypeQ)
repTapp (MkC t1) (MkC t2) = rep2 appTName [t1, t2]

repTapps :: Core TH.TypeQ -> [Core TH.TypeQ] -> DsM (Core TH.TypeQ)
repTapps f []     = return f
repTapps f (t:ts) = do { f1 <- repTapp f t; repTapps f1 ts }

repTSig :: Core TH.TypeQ -> Core TH.Kind -> DsM (Core TH.TypeQ)
repTSig (MkC ty) (MkC ki) = rep2 sigTName [ty, ki]

--------- Type constructors --------------

repNamedTyCon :: Core TH.Name -> DsM (Core TH.TypeQ)
repNamedTyCon (MkC s) = rep2 conTName [s]

repTupleTyCon :: Int -> DsM (Core TH.TypeQ)
-- Note: not Core Int; it's easier to be direct here
repTupleTyCon i = rep2 tupleTName [mkIntExprInt i]

repUnboxedTupleTyCon :: Int -> DsM (Core TH.TypeQ)
-- Note: not Core Int; it's easier to be direct here
repUnboxedTupleTyCon i = rep2 unboxedTupleTName [mkIntExprInt i]

repArrowTyCon :: DsM (Core TH.TypeQ)
repArrowTyCon = rep2 arrowTName []

repListTyCon :: DsM (Core TH.TypeQ)
repListTyCon = rep2 listTName []

------------ Kinds -------------------

repPlainTV :: Core TH.Name -> DsM (Core TH.TyVarBndr)
repPlainTV (MkC nm) = rep2 plainTVName [nm]

repKindedTV :: Core TH.Name -> Core TH.Kind -> DsM (Core TH.TyVarBndr)
repKindedTV (MkC nm) (MkC ki) = rep2 kindedTVName [nm, ki]

repStarK :: DsM (Core TH.Kind)
repStarK = rep2 starKName []

repArrowK :: Core TH.Kind -> Core TH.Kind -> DsM (Core TH.Kind)
repArrowK (MkC ki1) (MkC ki2) = rep2 arrowKName [ki1, ki2]

----------------------------------------------------------
--		Literals

repLiteral :: HsLit -> DsM (Core TH.Lit)
repLiteral lit 
  = do lit' <- case lit of
                   HsIntPrim i    -> mk_integer i
                   HsWordPrim w   -> mk_integer w
                   HsInt i        -> mk_integer i
                   HsFloatPrim r  -> mk_rational r
                   HsDoublePrim r -> mk_rational r
                   _ -> return lit
       lit_expr <- dsLit lit'
       case mb_lit_name of
	  Just lit_name -> rep2 lit_name [lit_expr]
	  Nothing -> notHandled "Exotic literal" (ppr lit)
  where
    mb_lit_name = case lit of
		 HsInteger _ _  -> Just integerLName
		 HsInt     _    -> Just integerLName
		 HsIntPrim _    -> Just intPrimLName
		 HsWordPrim _   -> Just wordPrimLName
		 HsFloatPrim _  -> Just floatPrimLName
		 HsDoublePrim _ -> Just doublePrimLName
		 HsChar _       -> Just charLName
		 HsString _     -> Just stringLName
		 HsRat _ _      -> Just rationalLName
		 _              -> Nothing

mk_integer :: Integer -> DsM HsLit
mk_integer  i = do integer_ty <- lookupType integerTyConName
                   return $ HsInteger i integer_ty
mk_rational :: FractionalLit -> DsM HsLit
mk_rational r = do rat_ty <- lookupType rationalTyConName
                   return $ HsRat r rat_ty
mk_string :: FastString -> DsM HsLit
mk_string s = return $ HsString s

repOverloadedLiteral :: HsOverLit Name -> DsM (Core TH.Lit)
repOverloadedLiteral (OverLit { ol_val = val})
  = do { lit <- mk_lit val; repLiteral lit }
	-- The type Rational will be in the environment, becuase 
	-- the smart constructor 'TH.Syntax.rationalL' uses it in its type,
	-- and rationalL is sucked in when any TH stuff is used

mk_lit :: OverLitVal -> DsM HsLit
mk_lit (HsIntegral i)   = mk_integer  i
mk_lit (HsFractional f) = mk_rational f
mk_lit (HsIsString s)   = mk_string   s
              
--------------- Miscellaneous -------------------

repGensym :: Core String -> DsM (Core (TH.Q TH.Name))
repGensym (MkC lit_str) = rep2 newNameName [lit_str]

repBindQ :: Type -> Type	-- a and b
	 -> Core (TH.Q a) -> Core (a -> TH.Q b) -> DsM (Core (TH.Q b))
repBindQ ty_a ty_b (MkC x) (MkC y) 
  = rep2 bindQName [Type ty_a, Type ty_b, x, y] 

repSequenceQ :: Type -> Core [TH.Q a] -> DsM (Core (TH.Q [a]))
repSequenceQ ty_a (MkC list)
  = rep2 sequenceQName [Type ty_a, list]

------------ Lists and Tuples -------------------
-- turn a list of patterns into a single pattern matching a list

coreList :: Name	-- Of the TyCon of the element type
	 -> [Core a] -> DsM (Core [a])
coreList tc_name es 
  = do { elt_ty <- lookupType tc_name; return (coreList' elt_ty es) }

coreList' :: Type 	-- The element type
	  -> [Core a] -> Core [a]
coreList' elt_ty es = MkC (mkListExpr elt_ty (map unC es ))

nonEmptyCoreList :: [Core a] -> Core [a]
  -- The list must be non-empty so we can get the element type
  -- Otherwise use coreList
nonEmptyCoreList [] 	      = panic "coreList: empty argument"
nonEmptyCoreList xs@(MkC x:_) = MkC (mkListExpr (exprType x) (map unC xs))

coreStringLit :: String -> DsM (Core String)
coreStringLit s = do { z <- mkStringExpr s; return(MkC z) }

------------ Bool, Literals & Variables -------------------

coreBool :: Bool -> Core Bool
coreBool False = MkC $ mkConApp falseDataCon []
coreBool True  = MkC $ mkConApp trueDataCon  []

coreIntLit :: Int -> DsM (Core Int)
coreIntLit i = return (MkC (mkIntExprInt i))

coreVar :: Id -> Core TH.Name	-- The Id has type Name
coreVar id = MkC (Var id)

----------------- Failure -----------------------
notHandled :: String -> SDoc -> DsM a
notHandled what doc = failWithDs msg
  where
    msg = hang (text what <+> ptext (sLit "not (yet) handled by Template Haskell")) 
	     2 doc


-- %************************************************************************
-- %*									*
--		The known-key names for Template Haskell
-- %*									*
-- %************************************************************************

-- To add a name, do three things
-- 
--  1) Allocate a key
--  2) Make a "Name"
--  3) Add the name to knownKeyNames

templateHaskellNames :: [Name]
-- The names that are implicitly mentioned by ``bracket''
-- Should stay in sync with the import list of DsMeta

templateHaskellNames = [
    returnQName, bindQName, sequenceQName, newNameName, liftName,
    mkNameName, mkNameG_vName, mkNameG_dName, mkNameG_tcName, mkNameLName, 
    liftStringName,
 
    -- Lit
    charLName, stringLName, integerLName, intPrimLName, wordPrimLName,
    floatPrimLName, doublePrimLName, rationalLName, 
    -- Pat
    litPName, varPName, tupPName, unboxedTupPName,
    conPName, tildePName, bangPName, infixPName,
    asPName, wildPName, recPName, listPName, sigPName, viewPName,
    -- FieldPat
    fieldPatName,
    -- Match
    matchName,
    -- Clause
    clauseName,
    -- Exp
    varEName, conEName, litEName, appEName, infixEName,
    infixAppName, sectionLName, sectionRName, lamEName,
    tupEName, unboxedTupEName,
    condEName, letEName, caseEName, doEName, compEName,
    fromEName, fromThenEName, fromToEName, fromThenToEName,
    listEName, sigEName, recConEName, recUpdEName,
    -- FieldExp
    fieldExpName,
    -- Body
    guardedBName, normalBName,
    -- Guard
    normalGEName, patGEName,
    -- Stmt
    bindSName, letSName, noBindSName, parSName,
    -- Dec
    funDName, valDName, dataDName, newtypeDName, tySynDName,
    classDName, instanceDName, sigDName, forImpDName, 
    pragInlDName, pragSpecDName, pragSpecInlDName,
    familyNoKindDName, familyKindDName, dataInstDName, newtypeInstDName,
    tySynInstDName, infixLDName, infixRDName, infixNDName,
    -- Cxt
    cxtName,
    -- Pred
    classPName, equalPName,
    -- Strict
    isStrictName, notStrictName, unpackedName,
    -- Con
    normalCName, recCName, infixCName, forallCName,
    -- StrictType
    strictTypeName,
    -- VarStrictType
    varStrictTypeName,
    -- Type
    forallTName, varTName, conTName, appTName,
    tupleTName, unboxedTupleTName, arrowTName, listTName, sigTName,
    -- TyVarBndr
    plainTVName, kindedTVName,
    -- Kind
    starKName, arrowKName,
    -- Callconv
    cCallName, stdCallName,
    -- Safety
    unsafeName,
    safeName,
    interruptibleName,
    -- InlineSpec
    inlineSpecNoPhaseName, inlineSpecPhaseName,
    -- FunDep
    funDepName,
    -- FamFlavour
    typeFamName, dataFamName,

    -- And the tycons
    qTyConName, nameTyConName, patTyConName, fieldPatTyConName, matchQTyConName,
    clauseQTyConName, expQTyConName, fieldExpTyConName, predTyConName,
    stmtQTyConName, decQTyConName, conQTyConName, strictTypeQTyConName,
    varStrictTypeQTyConName, typeQTyConName, expTyConName, decTyConName,
    typeTyConName, tyVarBndrTyConName, matchTyConName, clauseTyConName,
    patQTyConName, fieldPatQTyConName, fieldExpQTyConName, funDepTyConName,
    predQTyConName, decsQTyConName, 

    -- Quasiquoting
    quoteDecName, quoteTypeName, quoteExpName, quotePatName]

thSyn, thLib, qqLib :: Module
thSyn = mkTHModule (fsLit "Language.Haskell.TH.Syntax")
thLib = mkTHModule (fsLit "Language.Haskell.TH.Lib")
qqLib = mkTHModule (fsLit "Language.Haskell.TH.Quote")

mkTHModule :: FastString -> Module
mkTHModule m = mkModule thPackageId (mkModuleNameFS m)

libFun, libTc, thFun, thTc, qqFun :: FastString -> Unique -> Name
libFun = mk_known_key_name OccName.varName thLib
libTc  = mk_known_key_name OccName.tcName  thLib
thFun  = mk_known_key_name OccName.varName thSyn
thTc   = mk_known_key_name OccName.tcName  thSyn
qqFun  = mk_known_key_name OccName.varName qqLib

-------------------- TH.Syntax -----------------------
qTyConName, nameTyConName, fieldExpTyConName, patTyConName,
    fieldPatTyConName, expTyConName, decTyConName, typeTyConName,
    tyVarBndrTyConName, matchTyConName, clauseTyConName, funDepTyConName,
    predTyConName :: Name 
qTyConName        = thTc (fsLit "Q")            qTyConKey
nameTyConName     = thTc (fsLit "Name")         nameTyConKey
fieldExpTyConName = thTc (fsLit "FieldExp")     fieldExpTyConKey
patTyConName      = thTc (fsLit "Pat")          patTyConKey
fieldPatTyConName = thTc (fsLit "FieldPat")     fieldPatTyConKey
expTyConName      = thTc (fsLit "Exp")          expTyConKey
decTyConName      = thTc (fsLit "Dec")          decTyConKey
typeTyConName     = thTc (fsLit "Type")         typeTyConKey
tyVarBndrTyConName= thTc (fsLit "TyVarBndr")    tyVarBndrTyConKey
matchTyConName    = thTc (fsLit "Match")        matchTyConKey
clauseTyConName   = thTc (fsLit "Clause")       clauseTyConKey
funDepTyConName   = thTc (fsLit "FunDep")       funDepTyConKey
predTyConName     = thTc (fsLit "Pred")         predTyConKey

returnQName, bindQName, sequenceQName, newNameName, liftName,
    mkNameName, mkNameG_vName, mkNameG_dName, mkNameG_tcName,
    mkNameLName, liftStringName :: Name
returnQName    = thFun (fsLit "returnQ")   returnQIdKey
bindQName      = thFun (fsLit "bindQ")     bindQIdKey
sequenceQName  = thFun (fsLit "sequenceQ") sequenceQIdKey
newNameName    = thFun (fsLit "newName")   newNameIdKey
liftName       = thFun (fsLit "lift")      liftIdKey
liftStringName = thFun (fsLit "liftString")  liftStringIdKey
mkNameName     = thFun (fsLit "mkName")     mkNameIdKey
mkNameG_vName  = thFun (fsLit "mkNameG_v")  mkNameG_vIdKey
mkNameG_dName  = thFun (fsLit "mkNameG_d")  mkNameG_dIdKey
mkNameG_tcName = thFun (fsLit "mkNameG_tc") mkNameG_tcIdKey
mkNameLName    = thFun (fsLit "mkNameL")    mkNameLIdKey


-------------------- TH.Lib -----------------------
-- data Lit = ...
charLName, stringLName, integerLName, intPrimLName, wordPrimLName,
    floatPrimLName, doublePrimLName, rationalLName :: Name
charLName       = libFun (fsLit "charL")       charLIdKey
stringLName     = libFun (fsLit "stringL")     stringLIdKey
integerLName    = libFun (fsLit "integerL")    integerLIdKey
intPrimLName    = libFun (fsLit "intPrimL")    intPrimLIdKey
wordPrimLName   = libFun (fsLit "wordPrimL")   wordPrimLIdKey
floatPrimLName  = libFun (fsLit "floatPrimL")  floatPrimLIdKey
doublePrimLName = libFun (fsLit "doublePrimL") doublePrimLIdKey
rationalLName   = libFun (fsLit "rationalL")     rationalLIdKey

-- data Pat = ...
litPName, varPName, tupPName, unboxedTupPName, conPName, infixPName, tildePName, bangPName,
    asPName, wildPName, recPName, listPName, sigPName, viewPName :: Name
litPName   = libFun (fsLit "litP")   litPIdKey
varPName   = libFun (fsLit "varP")   varPIdKey
tupPName   = libFun (fsLit "tupP")   tupPIdKey
unboxedTupPName = libFun (fsLit "unboxedTupP") unboxedTupPIdKey
conPName   = libFun (fsLit "conP")   conPIdKey
infixPName = libFun (fsLit "infixP") infixPIdKey
tildePName = libFun (fsLit "tildeP") tildePIdKey
bangPName  = libFun (fsLit "bangP")  bangPIdKey
asPName    = libFun (fsLit "asP")    asPIdKey
wildPName  = libFun (fsLit "wildP")  wildPIdKey
recPName   = libFun (fsLit "recP")   recPIdKey
listPName  = libFun (fsLit "listP")  listPIdKey
sigPName   = libFun (fsLit "sigP")   sigPIdKey
viewPName  = libFun (fsLit "viewP")  viewPIdKey

-- type FieldPat = ...
fieldPatName :: Name
fieldPatName = libFun (fsLit "fieldPat") fieldPatIdKey

-- data Match = ...
matchName :: Name
matchName = libFun (fsLit "match") matchIdKey

-- data Clause = ...
clauseName :: Name
clauseName = libFun (fsLit "clause") clauseIdKey

-- data Exp = ...
varEName, conEName, litEName, appEName, infixEName, infixAppName,
    sectionLName, sectionRName, lamEName, tupEName, unboxedTupEName, condEName,
    letEName, caseEName, doEName, compEName :: Name
varEName        = libFun (fsLit "varE")        varEIdKey
conEName        = libFun (fsLit "conE")        conEIdKey
litEName        = libFun (fsLit "litE")        litEIdKey
appEName        = libFun (fsLit "appE")        appEIdKey
infixEName      = libFun (fsLit "infixE")      infixEIdKey
infixAppName    = libFun (fsLit "infixApp")    infixAppIdKey
sectionLName    = libFun (fsLit "sectionL")    sectionLIdKey
sectionRName    = libFun (fsLit "sectionR")    sectionRIdKey
lamEName        = libFun (fsLit "lamE")        lamEIdKey
tupEName        = libFun (fsLit "tupE")        tupEIdKey
unboxedTupEName = libFun (fsLit "unboxedTupE") unboxedTupEIdKey
condEName       = libFun (fsLit "condE")       condEIdKey
letEName        = libFun (fsLit "letE")        letEIdKey
caseEName       = libFun (fsLit "caseE")       caseEIdKey
doEName         = libFun (fsLit "doE")         doEIdKey
compEName       = libFun (fsLit "compE")       compEIdKey
-- ArithSeq skips a level
fromEName, fromThenEName, fromToEName, fromThenToEName :: Name
fromEName       = libFun (fsLit "fromE")       fromEIdKey
fromThenEName   = libFun (fsLit "fromThenE")   fromThenEIdKey
fromToEName     = libFun (fsLit "fromToE")     fromToEIdKey
fromThenToEName = libFun (fsLit "fromThenToE") fromThenToEIdKey
-- end ArithSeq
listEName, sigEName, recConEName, recUpdEName :: Name
listEName       = libFun (fsLit "listE")       listEIdKey
sigEName        = libFun (fsLit "sigE")        sigEIdKey
recConEName     = libFun (fsLit "recConE")     recConEIdKey
recUpdEName     = libFun (fsLit "recUpdE")     recUpdEIdKey

-- type FieldExp = ...
fieldExpName :: Name
fieldExpName = libFun (fsLit "fieldExp") fieldExpIdKey

-- data Body = ...
guardedBName, normalBName :: Name
guardedBName = libFun (fsLit "guardedB") guardedBIdKey
normalBName  = libFun (fsLit "normalB")  normalBIdKey

-- data Guard = ...
normalGEName, patGEName :: Name
normalGEName = libFun (fsLit "normalGE") normalGEIdKey
patGEName    = libFun (fsLit "patGE")    patGEIdKey

-- data Stmt = ...
bindSName, letSName, noBindSName, parSName :: Name
bindSName   = libFun (fsLit "bindS")   bindSIdKey
letSName    = libFun (fsLit "letS")    letSIdKey
noBindSName = libFun (fsLit "noBindS") noBindSIdKey
parSName    = libFun (fsLit "parS")    parSIdKey

-- data Dec = ...
funDName, valDName, dataDName, newtypeDName, tySynDName, classDName,
    instanceDName, sigDName, forImpDName, pragInlDName, pragSpecDName,
    pragSpecInlDName, familyNoKindDName, familyKindDName, dataInstDName,
    newtypeInstDName, tySynInstDName, 
    infixLDName, infixRDName, infixNDName :: Name
funDName         = libFun (fsLit "funD")         funDIdKey
valDName         = libFun (fsLit "valD")         valDIdKey
dataDName        = libFun (fsLit "dataD")        dataDIdKey
newtypeDName     = libFun (fsLit "newtypeD")     newtypeDIdKey
tySynDName       = libFun (fsLit "tySynD")       tySynDIdKey
classDName       = libFun (fsLit "classD")       classDIdKey
instanceDName    = libFun (fsLit "instanceD")    instanceDIdKey
sigDName         = libFun (fsLit "sigD")         sigDIdKey
forImpDName      = libFun (fsLit "forImpD")      forImpDIdKey
pragInlDName     = libFun (fsLit "pragInlD")     pragInlDIdKey
pragSpecDName    = libFun (fsLit "pragSpecD")    pragSpecDIdKey
pragSpecInlDName = libFun (fsLit "pragSpecInlD") pragSpecInlDIdKey
familyNoKindDName= libFun (fsLit "familyNoKindD")familyNoKindDIdKey
familyKindDName  = libFun (fsLit "familyKindD")  familyKindDIdKey
dataInstDName    = libFun (fsLit "dataInstD")    dataInstDIdKey
newtypeInstDName = libFun (fsLit "newtypeInstD") newtypeInstDIdKey
tySynInstDName   = libFun (fsLit "tySynInstD")   tySynInstDIdKey
infixLDName      = libFun (fsLit "infixLD")      infixLDIdKey
infixRDName      = libFun (fsLit "infixRD")      infixRDIdKey
infixNDName      = libFun (fsLit "infixND")      infixNDIdKey

-- type Ctxt = ...
cxtName :: Name
cxtName = libFun (fsLit "cxt") cxtIdKey

-- data Pred = ...
classPName, equalPName :: Name
classPName = libFun (fsLit "classP") classPIdKey
equalPName = libFun (fsLit "equalP") equalPIdKey

-- data Strict = ...
isStrictName, notStrictName, unpackedName :: Name
isStrictName      = libFun  (fsLit "isStrict")      isStrictKey
notStrictName     = libFun  (fsLit "notStrict")     notStrictKey
unpackedName      = libFun  (fsLit "unpacked")      unpackedKey

-- data Con = ...
normalCName, recCName, infixCName, forallCName :: Name
normalCName = libFun (fsLit "normalC") normalCIdKey
recCName    = libFun (fsLit "recC")    recCIdKey
infixCName  = libFun (fsLit "infixC")  infixCIdKey
forallCName  = libFun (fsLit "forallC")  forallCIdKey

-- type StrictType = ...
strictTypeName :: Name
strictTypeName    = libFun  (fsLit "strictType")    strictTKey

-- type VarStrictType = ...
varStrictTypeName :: Name
varStrictTypeName = libFun  (fsLit "varStrictType") varStrictTKey

-- data Type = ...
forallTName, varTName, conTName, tupleTName, unboxedTupleTName, arrowTName,
    listTName, appTName, sigTName :: Name
forallTName = libFun (fsLit "forallT") forallTIdKey
varTName    = libFun (fsLit "varT")    varTIdKey
conTName    = libFun (fsLit "conT")    conTIdKey
tupleTName  = libFun (fsLit "tupleT")  tupleTIdKey
unboxedTupleTName = libFun (fsLit "unboxedTupleT")  unboxedTupleTIdKey
arrowTName  = libFun (fsLit "arrowT")  arrowTIdKey
listTName   = libFun (fsLit "listT")   listTIdKey
appTName    = libFun (fsLit "appT")    appTIdKey
sigTName    = libFun (fsLit "sigT")    sigTIdKey

-- data TyVarBndr = ...
plainTVName, kindedTVName :: Name
plainTVName  = libFun (fsLit "plainTV")  plainTVIdKey
kindedTVName = libFun (fsLit "kindedTV") kindedTVIdKey

-- data Kind = ...
starKName, arrowKName :: Name
starKName  = libFun (fsLit "starK")   starKIdKey
arrowKName = libFun (fsLit "arrowK")  arrowKIdKey

-- data Callconv = ...
cCallName, stdCallName :: Name
cCallName = libFun (fsLit "cCall") cCallIdKey
stdCallName = libFun (fsLit "stdCall") stdCallIdKey

-- data Safety = ...
unsafeName, safeName, interruptibleName :: Name
unsafeName     = libFun (fsLit "unsafe") unsafeIdKey
safeName       = libFun (fsLit "safe") safeIdKey
interruptibleName = libFun (fsLit "interruptible") interruptibleIdKey

-- data InlineSpec = ...
inlineSpecNoPhaseName, inlineSpecPhaseName :: Name
inlineSpecNoPhaseName = libFun (fsLit "inlineSpecNoPhase") inlineSpecNoPhaseIdKey
inlineSpecPhaseName   = libFun (fsLit "inlineSpecPhase")   inlineSpecPhaseIdKey

-- data FunDep = ...
funDepName :: Name
funDepName     = libFun (fsLit "funDep") funDepIdKey

-- data FamFlavour = ...
typeFamName, dataFamName :: Name
typeFamName = libFun (fsLit "typeFam") typeFamIdKey
dataFamName = libFun (fsLit "dataFam") dataFamIdKey

matchQTyConName, clauseQTyConName, expQTyConName, stmtQTyConName,
    decQTyConName, conQTyConName, strictTypeQTyConName,
    varStrictTypeQTyConName, typeQTyConName, fieldExpQTyConName,
    patQTyConName, fieldPatQTyConName, predQTyConName, decsQTyConName :: Name
matchQTyConName         = libTc (fsLit "MatchQ")        matchQTyConKey
clauseQTyConName        = libTc (fsLit "ClauseQ")       clauseQTyConKey
expQTyConName           = libTc (fsLit "ExpQ")          expQTyConKey
stmtQTyConName          = libTc (fsLit "StmtQ")         stmtQTyConKey
decQTyConName           = libTc (fsLit "DecQ")          decQTyConKey
decsQTyConName          = libTc (fsLit "DecsQ")          decsQTyConKey  -- Q [Dec]
conQTyConName           = libTc (fsLit "ConQ")           conQTyConKey
strictTypeQTyConName    = libTc (fsLit "StrictTypeQ")    strictTypeQTyConKey
varStrictTypeQTyConName = libTc (fsLit "VarStrictTypeQ") varStrictTypeQTyConKey
typeQTyConName          = libTc (fsLit "TypeQ")          typeQTyConKey
fieldExpQTyConName      = libTc (fsLit "FieldExpQ")      fieldExpQTyConKey
patQTyConName           = libTc (fsLit "PatQ")           patQTyConKey
fieldPatQTyConName      = libTc (fsLit "FieldPatQ")      fieldPatQTyConKey
predQTyConName          = libTc (fsLit "PredQ")          predQTyConKey

-- quasiquoting
quoteExpName, quotePatName, quoteDecName, quoteTypeName :: Name
quoteExpName	    = qqFun (fsLit "quoteExp")  quoteExpKey
quotePatName	    = qqFun (fsLit "quotePat")  quotePatKey
quoteDecName	    = qqFun (fsLit "quoteDec")  quoteDecKey
quoteTypeName	    = qqFun (fsLit "quoteType") quoteTypeKey

-- TyConUniques available: 200-299
-- Check in PrelNames if you want to change this

expTyConKey, matchTyConKey, clauseTyConKey, qTyConKey, expQTyConKey,
    decQTyConKey, patTyConKey, matchQTyConKey, clauseQTyConKey,
    stmtQTyConKey, conQTyConKey, typeQTyConKey, typeTyConKey, tyVarBndrTyConKey,
    decTyConKey, varStrictTypeQTyConKey, strictTypeQTyConKey,
    fieldExpTyConKey, fieldPatTyConKey, nameTyConKey, patQTyConKey,
    fieldPatQTyConKey, fieldExpQTyConKey, funDepTyConKey, predTyConKey,
    predQTyConKey, decsQTyConKey :: Unique
expTyConKey             = mkPreludeTyConUnique 200
matchTyConKey           = mkPreludeTyConUnique 201
clauseTyConKey          = mkPreludeTyConUnique 202
qTyConKey               = mkPreludeTyConUnique 203
expQTyConKey            = mkPreludeTyConUnique 204
decQTyConKey            = mkPreludeTyConUnique 205
patTyConKey             = mkPreludeTyConUnique 206
matchQTyConKey          = mkPreludeTyConUnique 207
clauseQTyConKey         = mkPreludeTyConUnique 208
stmtQTyConKey           = mkPreludeTyConUnique 209
conQTyConKey            = mkPreludeTyConUnique 210
typeQTyConKey           = mkPreludeTyConUnique 211
typeTyConKey            = mkPreludeTyConUnique 212
decTyConKey             = mkPreludeTyConUnique 213
varStrictTypeQTyConKey  = mkPreludeTyConUnique 214
strictTypeQTyConKey     = mkPreludeTyConUnique 215
fieldExpTyConKey        = mkPreludeTyConUnique 216
fieldPatTyConKey        = mkPreludeTyConUnique 217
nameTyConKey            = mkPreludeTyConUnique 218
patQTyConKey            = mkPreludeTyConUnique 219
fieldPatQTyConKey       = mkPreludeTyConUnique 220
fieldExpQTyConKey       = mkPreludeTyConUnique 221
funDepTyConKey          = mkPreludeTyConUnique 222
predTyConKey            = mkPreludeTyConUnique 223
predQTyConKey           = mkPreludeTyConUnique 224
tyVarBndrTyConKey       = mkPreludeTyConUnique 225
decsQTyConKey           = mkPreludeTyConUnique 226

-- IdUniques available: 200-399
-- If you want to change this, make sure you check in PrelNames

returnQIdKey, bindQIdKey, sequenceQIdKey, liftIdKey, newNameIdKey,
    mkNameIdKey, mkNameG_vIdKey, mkNameG_dIdKey, mkNameG_tcIdKey,
    mkNameLIdKey :: Unique
returnQIdKey        = mkPreludeMiscIdUnique 200
bindQIdKey          = mkPreludeMiscIdUnique 201
sequenceQIdKey      = mkPreludeMiscIdUnique 202
liftIdKey           = mkPreludeMiscIdUnique 203
newNameIdKey         = mkPreludeMiscIdUnique 204
mkNameIdKey          = mkPreludeMiscIdUnique 205
mkNameG_vIdKey       = mkPreludeMiscIdUnique 206
mkNameG_dIdKey       = mkPreludeMiscIdUnique 207
mkNameG_tcIdKey      = mkPreludeMiscIdUnique 208
mkNameLIdKey         = mkPreludeMiscIdUnique 209


-- data Lit = ...
charLIdKey, stringLIdKey, integerLIdKey, intPrimLIdKey, wordPrimLIdKey,
    floatPrimLIdKey, doublePrimLIdKey, rationalLIdKey :: Unique
charLIdKey        = mkPreludeMiscIdUnique 220
stringLIdKey      = mkPreludeMiscIdUnique 221
integerLIdKey     = mkPreludeMiscIdUnique 222
intPrimLIdKey     = mkPreludeMiscIdUnique 223
wordPrimLIdKey    = mkPreludeMiscIdUnique 224
floatPrimLIdKey   = mkPreludeMiscIdUnique 225
doublePrimLIdKey  = mkPreludeMiscIdUnique 226
rationalLIdKey    = mkPreludeMiscIdUnique 227

liftStringIdKey :: Unique
liftStringIdKey     = mkPreludeMiscIdUnique 228

-- data Pat = ...
litPIdKey, varPIdKey, tupPIdKey, unboxedTupPIdKey, conPIdKey, infixPIdKey, tildePIdKey, bangPIdKey,
    asPIdKey, wildPIdKey, recPIdKey, listPIdKey, sigPIdKey, viewPIdKey :: Unique
litPIdKey         = mkPreludeMiscIdUnique 240
varPIdKey         = mkPreludeMiscIdUnique 241
tupPIdKey         = mkPreludeMiscIdUnique 242
unboxedTupPIdKey  = mkPreludeMiscIdUnique 243
conPIdKey         = mkPreludeMiscIdUnique 244
infixPIdKey       = mkPreludeMiscIdUnique 245
tildePIdKey       = mkPreludeMiscIdUnique 246
bangPIdKey        = mkPreludeMiscIdUnique 247
asPIdKey          = mkPreludeMiscIdUnique 248
wildPIdKey        = mkPreludeMiscIdUnique 249
recPIdKey         = mkPreludeMiscIdUnique 250
listPIdKey        = mkPreludeMiscIdUnique 251
sigPIdKey         = mkPreludeMiscIdUnique 252
viewPIdKey        = mkPreludeMiscIdUnique 253

-- type FieldPat = ...
fieldPatIdKey :: Unique
fieldPatIdKey       = mkPreludeMiscIdUnique 260

-- data Match = ...
matchIdKey :: Unique
matchIdKey          = mkPreludeMiscIdUnique 261

-- data Clause = ...
clauseIdKey :: Unique
clauseIdKey         = mkPreludeMiscIdUnique 262


-- data Exp = ...
varEIdKey, conEIdKey, litEIdKey, appEIdKey, infixEIdKey, infixAppIdKey,
    sectionLIdKey, sectionRIdKey, lamEIdKey, tupEIdKey, unboxedTupEIdKey,
    condEIdKey,
    letEIdKey, caseEIdKey, doEIdKey, compEIdKey,
    fromEIdKey, fromThenEIdKey, fromToEIdKey, fromThenToEIdKey,
    listEIdKey, sigEIdKey, recConEIdKey, recUpdEIdKey :: Unique
varEIdKey         = mkPreludeMiscIdUnique 270
conEIdKey         = mkPreludeMiscIdUnique 271
litEIdKey         = mkPreludeMiscIdUnique 272
appEIdKey         = mkPreludeMiscIdUnique 273
infixEIdKey       = mkPreludeMiscIdUnique 274
infixAppIdKey     = mkPreludeMiscIdUnique 275
sectionLIdKey     = mkPreludeMiscIdUnique 276
sectionRIdKey     = mkPreludeMiscIdUnique 277
lamEIdKey         = mkPreludeMiscIdUnique 278
tupEIdKey         = mkPreludeMiscIdUnique 279
unboxedTupEIdKey  = mkPreludeMiscIdUnique 280
condEIdKey        = mkPreludeMiscIdUnique 281
letEIdKey         = mkPreludeMiscIdUnique 282
caseEIdKey        = mkPreludeMiscIdUnique 283
doEIdKey          = mkPreludeMiscIdUnique 284
compEIdKey        = mkPreludeMiscIdUnique 285
fromEIdKey        = mkPreludeMiscIdUnique 286
fromThenEIdKey    = mkPreludeMiscIdUnique 287
fromToEIdKey      = mkPreludeMiscIdUnique 288
fromThenToEIdKey  = mkPreludeMiscIdUnique 289
listEIdKey        = mkPreludeMiscIdUnique 290
sigEIdKey         = mkPreludeMiscIdUnique 291
recConEIdKey      = mkPreludeMiscIdUnique 292
recUpdEIdKey      = mkPreludeMiscIdUnique 293

-- type FieldExp = ...
fieldExpIdKey :: Unique
fieldExpIdKey       = mkPreludeMiscIdUnique 310

-- data Body = ...
guardedBIdKey, normalBIdKey :: Unique
guardedBIdKey     = mkPreludeMiscIdUnique 311
normalBIdKey      = mkPreludeMiscIdUnique 312

-- data Guard = ...
normalGEIdKey, patGEIdKey :: Unique
normalGEIdKey     = mkPreludeMiscIdUnique 313
patGEIdKey        = mkPreludeMiscIdUnique 314

-- data Stmt = ...
bindSIdKey, letSIdKey, noBindSIdKey, parSIdKey :: Unique
bindSIdKey       = mkPreludeMiscIdUnique 320
letSIdKey        = mkPreludeMiscIdUnique 321
noBindSIdKey     = mkPreludeMiscIdUnique 322
parSIdKey        = mkPreludeMiscIdUnique 323

-- data Dec = ...
funDIdKey, valDIdKey, dataDIdKey, newtypeDIdKey, tySynDIdKey,
    classDIdKey, instanceDIdKey, sigDIdKey, forImpDIdKey, pragInlDIdKey,
    pragSpecDIdKey, pragSpecInlDIdKey, familyNoKindDIdKey, familyKindDIdKey,
    dataInstDIdKey, newtypeInstDIdKey, tySynInstDIdKey, 
    infixLDIdKey, infixRDIdKey, infixNDIdKey :: Unique 
funDIdKey          = mkPreludeMiscIdUnique 330
valDIdKey          = mkPreludeMiscIdUnique 331
dataDIdKey         = mkPreludeMiscIdUnique 332
newtypeDIdKey      = mkPreludeMiscIdUnique 333
tySynDIdKey        = mkPreludeMiscIdUnique 334
classDIdKey        = mkPreludeMiscIdUnique 335
instanceDIdKey     = mkPreludeMiscIdUnique 336
sigDIdKey          = mkPreludeMiscIdUnique 337
forImpDIdKey       = mkPreludeMiscIdUnique 338
pragInlDIdKey      = mkPreludeMiscIdUnique 339
pragSpecDIdKey     = mkPreludeMiscIdUnique 340
pragSpecInlDIdKey  = mkPreludeMiscIdUnique 341
familyNoKindDIdKey = mkPreludeMiscIdUnique 342
familyKindDIdKey   = mkPreludeMiscIdUnique 343
dataInstDIdKey     = mkPreludeMiscIdUnique 344
newtypeInstDIdKey  = mkPreludeMiscIdUnique 345
tySynInstDIdKey    = mkPreludeMiscIdUnique 346
infixLDIdKey       = mkPreludeMiscIdUnique 347
infixRDIdKey       = mkPreludeMiscIdUnique 348
infixNDIdKey       = mkPreludeMiscIdUnique 349

-- type Cxt = ...
cxtIdKey :: Unique
cxtIdKey            = mkPreludeMiscIdUnique 360

-- data Pred = ...
classPIdKey, equalPIdKey :: Unique
classPIdKey         = mkPreludeMiscIdUnique 361
equalPIdKey         = mkPreludeMiscIdUnique 362

-- data Strict = ...
isStrictKey, notStrictKey, unpackedKey :: Unique
isStrictKey         = mkPreludeMiscIdUnique 363
notStrictKey        = mkPreludeMiscIdUnique 364
unpackedKey         = mkPreludeMiscIdUnique 365

-- data Con = ...
normalCIdKey, recCIdKey, infixCIdKey, forallCIdKey :: Unique
normalCIdKey      = mkPreludeMiscIdUnique 370
recCIdKey         = mkPreludeMiscIdUnique 371
infixCIdKey       = mkPreludeMiscIdUnique 372
forallCIdKey      = mkPreludeMiscIdUnique 373

-- type StrictType = ...
strictTKey :: Unique
strictTKey        = mkPreludeMiscIdUnique 374

-- type VarStrictType = ...
varStrictTKey :: Unique
varStrictTKey     = mkPreludeMiscIdUnique 375

-- data Type = ...
forallTIdKey, varTIdKey, conTIdKey, tupleTIdKey, unboxedTupleTIdKey, arrowTIdKey,
    listTIdKey, appTIdKey, sigTIdKey :: Unique
forallTIdKey       = mkPreludeMiscIdUnique 380
varTIdKey          = mkPreludeMiscIdUnique 381
conTIdKey          = mkPreludeMiscIdUnique 382
tupleTIdKey        = mkPreludeMiscIdUnique 383
unboxedTupleTIdKey = mkPreludeMiscIdUnique 384
arrowTIdKey        = mkPreludeMiscIdUnique 385
listTIdKey         = mkPreludeMiscIdUnique 386
appTIdKey          = mkPreludeMiscIdUnique 387
sigTIdKey          = mkPreludeMiscIdUnique 388

-- data TyVarBndr = ...
plainTVIdKey, kindedTVIdKey :: Unique
plainTVIdKey      = mkPreludeMiscIdUnique 390
kindedTVIdKey     = mkPreludeMiscIdUnique 391

-- data Kind = ...
starKIdKey, arrowKIdKey :: Unique
starKIdKey        = mkPreludeMiscIdUnique 392
arrowKIdKey       = mkPreludeMiscIdUnique 393

-- data Callconv = ...
cCallIdKey, stdCallIdKey :: Unique
cCallIdKey      = mkPreludeMiscIdUnique 394
stdCallIdKey    = mkPreludeMiscIdUnique 395

-- data Safety = ...
unsafeIdKey, safeIdKey, interruptibleIdKey :: Unique
unsafeIdKey        = mkPreludeMiscIdUnique 400
safeIdKey          = mkPreludeMiscIdUnique 401
interruptibleIdKey = mkPreludeMiscIdUnique 403

-- data InlineSpec =
inlineSpecNoPhaseIdKey, inlineSpecPhaseIdKey :: Unique
inlineSpecNoPhaseIdKey = mkPreludeMiscIdUnique 404
inlineSpecPhaseIdKey   = mkPreludeMiscIdUnique 405

-- data FunDep = ...
funDepIdKey :: Unique
funDepIdKey = mkPreludeMiscIdUnique 406

-- data FamFlavour = ...
typeFamIdKey, dataFamIdKey :: Unique
typeFamIdKey = mkPreludeMiscIdUnique 407
dataFamIdKey = mkPreludeMiscIdUnique 408

-- quasiquoting
quoteExpKey, quotePatKey, quoteDecKey, quoteTypeKey :: Unique
quoteExpKey  = mkPreludeMiscIdUnique 410
quotePatKey  = mkPreludeMiscIdUnique 411
quoteDecKey  = mkPreludeMiscIdUnique 412
quoteTypeKey = mkPreludeMiscIdUnique 413
