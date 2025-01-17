{-# LANGUAGE TemplateHaskellQuotes #-}

{- Data/Singletons/TH/Promote/Defun.hs

(c) Richard Eisenberg, Jan Stolarek 2014
rae@cs.brynmawr.edu

This file creates defunctionalization symbols for types during promotion.
-}

module Data.Singletons.TH.Promote.Defun where

import Language.Haskell.TH.Desugar
import Language.Haskell.TH.Syntax
import Data.Singletons.TH.Names
import Data.Singletons.TH.Options
import Data.Singletons.TH.Promote.Monad
import Data.Singletons.TH.Promote.Type
import Data.Singletons.TH.Syntax
import Data.Singletons.TH.Util
import Control.Monad
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Maybe

defunInfo :: DInfo -> PrM [DDec]
defunInfo (DTyConI dec _instances) = buildDefunSyms dec
defunInfo (DPrimTyConI _name _numArgs _unlifted) =
  fail $ "Building defunctionalization symbols of primitive " ++
         "type constructors not supported"
defunInfo (DVarI _name _ty _mdec) =
  fail "Building defunctionalization symbols of values not supported"
defunInfo (DTyVarI _name _ty) =
  fail "Building defunctionalization symbols of type variables not supported"
defunInfo (DPatSynI {}) =
  fail "Building defunctionalization symbols of pattern synonyms not supported"

-- Defunctionalize type families defined at the top level (i.e., not associated
-- with a type class).
defunTopLevelTypeDecls ::
     [TySynDecl]
  -> [ClosedTypeFamilyDecl]
  -> [OpenTypeFamilyDecl]
  -> PrM ()
defunTopLevelTypeDecls ty_syns c_tyfams o_tyfams = do
  defun_ty_syns <-
    concatMapM (\(TySynDecl name tvbs rhs) -> buildDefunSymsTySynD name tvbs rhs) ty_syns
  defun_c_tyfams <-
    concatMapM (buildDefunSymsClosedTypeFamilyD . getTypeFamilyDecl) c_tyfams
  defun_o_tyfams <-
    concatMapM (buildDefunSymsOpenTypeFamilyD . getTypeFamilyDecl) o_tyfams
  emitDecs $ defun_ty_syns ++ defun_c_tyfams ++ defun_o_tyfams

-- Defunctionalize all the type families associated with a type class.
defunAssociatedTypeFamilies ::
     [DTyVarBndrVis]      -- The type variables bound by the parent class
  -> [OpenTypeFamilyDecl] -- The type families associated with the parent class
  -> PrM ()
defunAssociatedTypeFamilies cls_tvbs atfs = do
  defun_atfs <- concatMapM defun atfs
  emitDecs defun_atfs
  where
    defun :: OpenTypeFamilyDecl -> PrM [DDec]
    defun (TypeFamilyDecl tf_head) =
      buildDefunSymsTypeFamilyHead ascribe_tf_tvb_kind id tf_head

    -- Maps class-bound type variables to their kind annotations (if supplied).
    -- For example, `class C (a :: Bool) b (c :: Type)` will produce
    -- {a |-> Bool, c |-> Type}.
    cls_tvb_kind_map :: Map Name DKind
    cls_tvb_kind_map = Map.fromList [ (extractTvbName tvb, tvb_kind)
                                    | tvb <- cls_tvbs
                                    , Just tvb_kind <- [extractTvbKind tvb]
                                    ]

    -- If the parent class lacks a SAK, we cannot safely default kinds to
    -- Type. All we can do is make use of whatever kind information that parent
    -- class provides and let kind inference do the rest.
    --
    -- We can sometimes learn more specific information about unannotated type
    -- family binders from the parent class, as in the following example:
    --
    --   class C (a :: Bool) where
    --     type T a :: Type
    --
    -- Here, we know that `T :: Bool -> Type` because we can infer that the `a`
    -- in `type T a` should be of kind `Bool` from the class SAK.
    ascribe_tf_tvb_kind :: DTyVarBndrVis -> DTyVarBndrVis
    ascribe_tf_tvb_kind tvb =
      case tvb of
        DKindedTV{}  -> tvb
        DPlainTV n _ -> maybe tvb (DKindedTV n BndrReq) $ Map.lookup n cls_tvb_kind_map

buildDefunSyms :: DDec -> PrM [DDec]
buildDefunSyms dec =
  case dec of
    DDataD _new_or_data _cxt _tyName _tvbs _k ctors _derivings ->
      buildDefunSymsDataD ctors
    DClosedTypeFamilyD tf_head _ ->
      buildDefunSymsClosedTypeFamilyD tf_head
    DOpenTypeFamilyD tf_head ->
      buildDefunSymsOpenTypeFamilyD tf_head
    DTySynD name tvbs rhs ->
      buildDefunSymsTySynD name tvbs rhs
    DClassD _cxt name tvbs _fundeps _members ->
      defunReify name tvbs (Just (DConT constraintName))
    _ -> fail $ "Defunctionalization symbols can only be built for " ++
                "type families and data declarations"

-- Unlike open type families, closed type families that lack SAKS do not
-- default anything to Type, instead relying on kind inference to figure out
-- unspecified kinds.
buildDefunSymsClosedTypeFamilyD :: DTypeFamilyHead -> PrM [DDec]
buildDefunSymsClosedTypeFamilyD = buildDefunSymsTypeFamilyHead id id

-- If an open type family lacks a SAK and has type variable binders or a result
-- without explicit kinds, then they default to Type (hence the uses of
-- default{Tvb,Maybe}ToTypeKind).
buildDefunSymsOpenTypeFamilyD :: DTypeFamilyHead -> PrM [DDec]
buildDefunSymsOpenTypeFamilyD =
  buildDefunSymsTypeFamilyHead defaultTvbToTypeKind (Just . defaultMaybeToTypeKind)

buildDefunSymsTypeFamilyHead
  :: (DTyVarBndrVis -> DTyVarBndrVis) -- How to default each type variable binder
  -> (Maybe DKind -> Maybe DKind)     -- How to default the result kind
  -> DTypeFamilyHead -> PrM [DDec]
buildDefunSymsTypeFamilyHead default_tvb default_kind
    (DTypeFamilyHead name tvbs result_sig _) = do
  let arg_tvbs = map default_tvb tvbs
      res_kind = default_kind (resultSigToMaybeKind result_sig)
  defunReify name arg_tvbs res_kind

buildDefunSymsTySynD :: Name -> [DTyVarBndrVis] -> DType -> PrM [DDec]
buildDefunSymsTySynD name tvbs rhs = defunReify name tvbs mb_res_kind
  where
    -- If a type synonym lacks a SAK, we can "infer" its result kind by
    -- checking for an explicit kind annotation on the right-hand side.
    mb_res_kind :: Maybe DKind
    mb_res_kind = case rhs of
                    DSigT _ k -> Just k
                    _         -> Nothing

buildDefunSymsDataD :: [DCon] -> PrM [DDec]
buildDefunSymsDataD ctors =
  concatMapM promoteCtor ctors
  where
    promoteCtor :: DCon -> PrM [DDec]
    promoteCtor (DCon tvbs _ name fields res_ty) = do
      opts <- getOptions
      let name'   = promotedDataTypeOrConName opts name
          arg_tys = tysOfConFields fields
      arg_kis <- traverse promoteType_NC arg_tys
      res_ki  <- promoteType_NC res_ty
      let con_ki = ravelVanillaDType tvbs [] arg_kis res_ki
      m_fixity <- reifyFixityWithLocals name'
      defunctionalize name' m_fixity $ DefunSAK con_ki

-- Generate defunctionalization symbols for a name, using reifyFixityWithLocals
-- to determine what the fixity of each symbol should be
-- (see Note [Fixity declarations for defunctionalization symbols])
-- and dsReifyType to determine whether defunctionalization should make use
-- of SAKs or not (see Note [Defunctionalization game plan]).
defunReify :: Name            -- Name of the declaration to be defunctionalized
           -> [DTyVarBndrVis] -- The declaration's type variable binders
                              -- (only used if the declaration lacks a SAK)
           -> Maybe DKind     -- The declaration's return kind, if it has one
                              -- (only used if the declaration lacks a SAK)
           -> PrM [DDec]
defunReify name tvbs m_res_kind = do
  m_fixity <- reifyFixityWithLocals name
  m_sak    <- dsReifyType name
  let defun = defunctionalize name m_fixity
  case m_sak of
    Just sak -> defun $ DefunSAK sak
    Nothing  -> defun $ DefunNoSAK tvbs m_res_kind

-- Generate symbol data types, Apply instances, and other declarations required
-- for defunctionalization.
-- See Note [Defunctionalization game plan] for an overview of the design
-- considerations involved.
defunctionalize :: Name
                -> Maybe Fixity
                -> DefunKindInfo
                -> PrM [DDec]
defunctionalize name m_fixity defun_ki = do
  case defun_ki of
    DefunSAK sak ->
      -- Even if a declaration has a SAK, its kind may not be vanilla.
      case unravelVanillaDType_either sak of
        -- If the kind isn't vanilla, use the fallback approach.
        -- See Note [Defunctionalization game plan],
        -- Wrinkle 2: Non-vanilla kinds.
        Left _ -> defun_fallback [] (Just sak)
        -- Otherwise, proceed with defun_vanilla_sak.
        Right (sak_tvbs, _sak_cxt, sak_arg_kis, sak_res_ki)
               -> defun_vanilla_sak sak_tvbs sak_arg_kis sak_res_ki
    -- If a declaration lacks a SAK, it likely has a partial kind.
    -- See Note [Defunctionalization game plan], Wrinkle 1: Partial kinds.
    DefunNoSAK tvbs m_res -> defun_fallback tvbs m_res
  where
    -- Generate defunctionalization symbols for things with vanilla SAKs.
    -- The symbols themselves will also be given SAKs.
    defun_vanilla_sak :: [DTyVarBndrSpec] -> [DKind] -> DKind -> PrM [DDec]
    defun_vanilla_sak sak_tvbs sak_arg_kis sak_res_ki = do
      opts <- getOptions
      extra_name <- qNewName "arg"
      let sak_arg_n = length sak_arg_kis
      -- Use noExactName below to avoid GHC#17537.
      -- See also Note [Pitfalls of NameU/NameL] in Data.Singletons.TH.Util.
      arg_names <- replicateM sak_arg_n (noExactName <$> qNewName "a")

      let -- The inner loop. @go n arg_nks res_nks@ returns @(res_k, decls)@.
          -- Using one particular example:
          --
          -- @
          -- type ExampleSym2 :: a -> b -> c ~> d ~> Type
          -- data ExampleSym2 (x :: a) (y :: b) :: c ~> d ~> Type where ...
          -- type instance Apply (ExampleSym2 x y) z = ExampleSym3 x y z
          -- ...
          -- @
          --
          -- We have:
          --
          -- * @n@ is 2. This is incremented in each iteration of `go`.
          --
          -- * @arg_nks@ is [(x, a), (y, b)]. Each element in this list is a
          -- (type variable name, type variable kind) pair. The kinds appear in
          -- the SAK, separated by matchable arrows (->).
          --
          -- * @res_tvbs@ is [(z, c), (w, d)]. Each element in this list is a
          -- (type variable name, type variable kind) pair. The kinds appear in
          -- @res_k@, separated by unmatchable arrows (~>).
          --
          -- * @res_k@ is `c ~> d ~> Type`. @res_k@ is returned so that earlier
          --   defunctionalization symbols can build on the result kinds of
          --   later symbols. For instance, ExampleSym1 would get the result
          --   kind `b ~> c ~> d ~> Type` by prepending `b` to ExampleSym2's
          --   result kind `c ~> d ~> Type`.
          --
          -- * @decls@ are all of the declarations corresponding to ExampleSym2
          --   and later defunctionalization symbols. This is the main payload of
          --   the function.
          --
          -- Note that the body of ExampleSym2 redundantly includes the
          -- argument kinds and result kind, which are already stated in the
          -- standalone kind signature. This is a deliberate choice.
          -- See Note [Keep redundant kind information for Haddocks]
          -- in D.S.TH.Promote.
          --
          -- This function is quadratic because it appends a variable at the end of
          -- the @arg_nks@ list at each iteration. In practice, this is unlikely
          -- to be a performance bottleneck since the number of arguments rarely
          -- gets to be that large.
          go :: Int -> [(Name, DKind)] -> [(Name, DKind)] -> (DKind, [DDec])
          go n arg_nks res_nkss =
            let arg_tvbs :: [DTyVarBndrVis]
                arg_tvbs = map (\(na, ki) -> DKindedTV na BndrReq ki) arg_nks

                mk_sak_dec :: DKind -> DDec
                mk_sak_dec res_ki =
                  DKiSigD (defunctionalizedName opts name n) $
                  ravelVanillaDType sak_tvbs [] (map snd arg_nks) res_ki in
            case res_nkss of
              [] ->
                let sat_sak_dec = mk_sak_dec sak_res_ki
                    -- Compute the type variable binders needed to give the type
                    -- family the correct arity.
                    -- See Note [Generating type families with the correct arity]
                    -- in D.S.TH.Promote.
                    sak_tvbs' | null sak_tvbs
                              = changeDTVFlags SpecifiedSpec $
                                toposortTyVarsOf (sak_arg_kis ++ [sak_res_ki])
                              | otherwise
                              = sak_tvbs
                    sat_decs = mk_sat_decs opts n sak_tvbs' arg_tvbs (Just sak_res_ki)
                in (sak_res_ki, sat_sak_dec:sat_decs)
              res_nk:res_nks ->
                let (res_ki, decs)   = go (n+1) (arg_nks ++ [res_nk]) res_nks
                    tyfun            = buildTyFunArrow (snd res_nk) res_ki
                    defun_sak_dec    = mk_sak_dec tyfun
                    defun_other_decs = mk_defun_decs opts n sak_arg_n
                                                     arg_tvbs (fst res_nk)
                                                     extra_name (Just tyfun)
                in (tyfun, defun_sak_dec:defun_other_decs ++ decs)

      pure $ snd $ go 0 [] $ zip arg_names sak_arg_kis

    -- If defun_sak can't be used to defunctionalize something, this fallback
    -- approach is used. This is used when defunctionalizing something with a
    -- partial kind
    -- (see Note [Defunctionalization game plan], Wrinkle 1: Partial kinds)
    -- or a non-vanilla kind
    -- (see Note [Defunctionalization game plan], Wrinkle 2: Non-vanilla kinds).
    defun_fallback :: [DTyVarBndrVis] -> Maybe DKind -> PrM [DDec]
    defun_fallback tvbs' m_res' = do
      opts <- getOptions
      extra_name <- qNewName "arg"
      -- Use noExactTyVars below to avoid GHC#11812.
      -- See also Note [Pitfalls of NameU/NameL] in Data.Singletons.TH.Util.
      (tvbs, m_res) <- eta_expand (noExactTyVars tvbs') (noExactTyVars m_res')

      let tvbs_n = length tvbs

          -- The inner loop. @go n arg_tvbs res_tvbs@ returns @(m_res_k, decls)@.
          -- Using one particular example:
          --
          -- @
          -- data ExampleSym2 (x :: a) y :: c ~> d ~> Type where ...
          -- type instance Apply (ExampleSym2 x y) z = ExampleSym3 x y z
          -- ...
          -- @
          --
          -- This works very similarly to the `go` function in
          -- `defun_vanilla_sak`. The main differences are:
          --
          -- * This function does not produce any SAKs for defunctionalization
          --   symbols.
          --
          -- * Instead of [(Name, DKind)], this function uses [DTyVarBndr] as
          --   the types of @arg_tvbs@ and @res_tvbs@. This is because the
          --   kinds are not always known. By a similar token, this function
          --   uses Maybe DKind, not DKind, as the type of @m_res_k@, since
          --   the result kind is not always fully known.
          go :: Int -> [DTyVarBndrVis] -> [DTyVarBndrVis] -> (Maybe DKind, [DDec])
          go n arg_tvbs res_tvbss =
            case res_tvbss of
              [] ->
                let sat_decs = mk_sat_decs opts n [] arg_tvbs m_res
                in (m_res, sat_decs)
              res_tvb:res_tvbs ->
                let (m_res_ki, decs) = go (n+1) (arg_tvbs ++ [res_tvb]) res_tvbs
                    m_tyfun          = buildTyFunArrow_maybe (extractTvbKind res_tvb)
                                                             m_res_ki
                    defun_decs'      = mk_defun_decs opts n tvbs_n arg_tvbs
                                                     (extractTvbName res_tvb)
                                                     extra_name m_tyfun
                in (m_tyfun, defun_decs' ++ decs)

      pure $ snd $ go 0 [] tvbs

    mk_defun_decs :: Options
                  -> Int
                  -> Int
                  -> [DTyVarBndrVis]
                  -> Name
                  -> Name
                  -> Maybe DKind
                  -> [DDec]
    mk_defun_decs opts n fully_sat_n arg_tvbs tyfun_name extra_name m_tyfun =
      let data_name   = defunctionalizedName opts name n
          next_name   = defunctionalizedName opts name (n+1)
          con_name    = prefixName "" ":" $ suffixName "KindInference" "###" data_name
          params      = arg_tvbs ++ [DPlainTV tyfun_name BndrReq]
          con_eq_ct   = DConT sameKindName `DAppT` lhs `DAppT` rhs
            where
              lhs = app_data_ty `apply` DVarT extra_name
              rhs = foldTypeTvbs (DConT next_name)
                      (arg_tvbs ++ [DPlainTV extra_name BndrReq])
          con_decl    = DCon [] [con_eq_ct] con_name (DNormalC False [])
                             (foldTypeTvbs (DConT data_name) params)
          data_decl   = DDataD Data [] data_name args m_tyfun [con_decl] []
            where
              args | isJust m_tyfun = arg_tvbs
                   | otherwise      = params
          app_data_ty = foldTypeTvbs (DConT data_name) arg_tvbs
          app_eqn     = DTySynEqn Nothing
                                  (DConT applyName `DAppT` app_data_ty
                                                   `DAppT` DVarT tyfun_name)
                                  (foldTypeTvbs (DConT app_eqn_rhs_name) params)
          -- If the next defunctionalization symbol is fully saturated, then
          -- use the original declaration name instead.
          -- See Note [Fully saturated defunctionalization symbols]
          -- (Wrinkle: avoiding reduction stack overflows).
          app_eqn_rhs_name | n+1 == fully_sat_n = name
                           | otherwise          = next_name
          app_decl    = DTySynInstD app_eqn
          suppress    = DInstanceD Nothing Nothing []
                          (DConT suppressClassName `DAppT` app_data_ty)
                          [DLetDec $ DFunD suppressMethodName
                                           [DClause []
                                                    ((DVarE 'snd) `DAppE`
                                                     mkTupleDExp [DConE con_name,
                                                                  mkTupleDExp []])]]

          -- See Note [Fixity declarations for defunctionalization symbols]
          fixity_decl = maybeToList $ fmap (mk_fix_decl data_name) m_fixity
      in data_decl : app_decl : suppress : fixity_decl

    -- Generate a "fully saturated" defunction symbol, along with a fixity
    -- declaration (if needed).
    -- See Note [Fully saturated defunctionalization symbols].
    mk_sat_decs ::
         Options
      -> Int
      -> [DTyVarBndrSpec]
         -- ^ The invisible type variable binders to put in the type family
         -- head in order to give it the correct arity.
         -- See Note [Generating type families with the correct arity] in
         -- D.S.TH.Promote.
      -> [DTyVarBndrVis]
         -- ^ The visible kind arguments.
      -> Maybe DKind
         -- ^ The result kind (if known).
      -> [DDec]
    mk_sat_decs opts n sat_tvbs sat_args m_sat_res =
      let sat_name = defunctionalizedName opts name n
          sat_dec  = DClosedTypeFamilyD
                       (DTypeFamilyHead sat_name
                                        (tvbSpecsToBndrVis sat_tvbs ++ sat_args)
                                        (maybeKindToResultSig m_sat_res) Nothing)
                       [DTySynEqn Nothing
                                  (foldTypeTvbs (DConT sat_name) sat_args)
                                  (foldTypeTvbs (DConT name)     sat_args)]
          sat_fixity_dec = maybeToList $ fmap (mk_fix_decl sat_name) m_fixity
      in sat_dec : sat_fixity_dec

    -- Generate extra kind variable binders corresponding to the number of
    -- arrows in the return kind (if provided). Examples:
    --
    -- >>> eta_expand [(x :: a), (y :: b)] (Just (c -> Type))
    -- ([(x :: a), (y :: b), (e :: c)], Just Type)
    --
    -- >>> eta_expand [(x :: a), (y :: b)] Nothing
    -- ([(x :: a), (y :: b)], Nothing)
    eta_expand :: [DTyVarBndrVis] -> Maybe DKind -> PrM ([DTyVarBndrVis], Maybe DKind)
    eta_expand m_arg_tvbs Nothing = pure (m_arg_tvbs, Nothing)
    eta_expand m_arg_tvbs (Just res_kind) = do
        let (arg_ks, result_k) = unravelDType res_kind
            vis_arg_ks = filterDVisFunArgs arg_ks
        extra_arg_tvbs <- traverse mk_extra_tvb vis_arg_ks
        pure (m_arg_tvbs ++ extra_arg_tvbs, Just result_k)

    -- Convert a DVisFunArg to a DTyVarBndr, generating a fresh type variable
    -- name if the DVisFunArg is an anonymous argument.
    mk_extra_tvb :: DVisFunArg -> PrM DTyVarBndrVis
    mk_extra_tvb vfa =
      case vfa of
        DVisFADep tvb -> pure (BndrReq <$ tvb)
        DVisFAAnon k  -> (\n -> DKindedTV n BndrReq k) <$>
                           -- Use noExactName below to avoid GHC#19743.
                           -- See also Note [Pitfalls of NameU/NameL]
                           -- in Data.Singletons.TH.Util.
                           (noExactName <$> qNewName "e")

    mk_fix_decl :: Name -> Fixity -> DDec
    mk_fix_decl n f = DLetDec $ DInfixD f NoNamespaceSpecifier n

-- Indicates whether the type being defunctionalized has a standalone kind
-- signature. If it does, DefunSAK contains the kind. If not, DefunNoSAK
-- contains whatever information is known about its type variable binders
-- and result kind.
-- See Note [Defunctionalization game plan] for details on how this
-- information is used.
data DefunKindInfo
  = DefunSAK DKind
  | DefunNoSAK [DTyVarBndrVis] (Maybe DKind)

-- Shorthand for building (k1 ~> k2)
buildTyFunArrow :: DKind -> DKind -> DKind
buildTyFunArrow k1 k2 = DConT tyFunArrowName `DAppT` k1 `DAppT` k2

buildTyFunArrow_maybe :: Maybe DKind -> Maybe DKind -> Maybe DKind
buildTyFunArrow_maybe m_k1 m_k2 = buildTyFunArrow <$> m_k1 <*> m_k2

{-
Note [Defunctionalization game plan]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Generating defunctionalization symbols involves a surprising amount of
complexity. This Note gives a broad overview of what happens during
defunctionalization and highlights various design considerations.
As a working example, we will use the following type family:

  type Foo :: forall c a b. a -> b -> c -> c
  type family Foo x y z where ...

We must generate a defunctionalization symbol for every number of arguments
to which Foo can be partially applied. We do so by generating the following
declarations:

  type FooSym0 :: forall c a b. a ~> b ~> c ~> c
  data FooSym0 f where
   FooSym0KindInference :: SameKind (Apply FooSym0 arg) (FooSym1 arg)
                        => FooSym0 f
  type instance Apply FooSym0 x = FooSym1 x

  type FooSym1 :: forall c a b. a -> b ~> c ~> c
  data FooSym1 x f where
    FooSym1KindInference :: SameKind (Apply (FooSym1 a) arg) (FooSym2 a arg)
                         => FooSym1 a f
  type instance Apply (FooSym1 x) y = FooSym2 x y

  type FooSym2 :: forall c a b. a -> b -> c ~> c
  data FooSym2 x y f where
    FooSym2KindInference :: SameKind (Apply (FooSym2 x y) arg) (FooSym3 x y arg)
                         => FooSym2 x y f
  type instance Apply (FooSym2 x y) z = Foo x y z

  type FooSym3 :: forall c a b. a -> b -> c -> c
  type family FooSym3 x y z where
    FooSym3 x y z = Foo x y z

Some things to note:

* Each defunctionalization symbol has its own standalone kind signature. The
  number after `Sym` in each symbol indicates the number of leading -> arrows
  in its kind—that is, the number of arguments to which it can be applied
  directly to without the use of the Apply type family.

  See "Wrinkle 1: Partial kinds" below for what happens if the declaration
  being defunctionalized does *not* have a standalone kind signature.

* Each data declaration has a constructor with the suffix `-KindInference`
  in its name. These are redundant in the particular case of Foo, where the
  kind is already known. They play a more vital role when the kind of the
  declaration being defunctionalized is only partially known.
  See "Wrinkle 1: Partial kinds" below for more information.

* FooSym3, the last defunctionalization symbol, is somewhat special in that
  it is a type family, not a data type. These sorts of symbols are referred
  to as "fully saturated" defunctionalization symbols.
  See Note [Fully saturated defunctionalization symbols].

* If Foo had a fixity declaration (e.g., infixl 4 `Foo`), then we would also
  generate fixity declarations for each defunctionalization symbol (e.g.,
  infixl 4 `FooSym0`).
  See Note [Fixity declarations for defunctionalization symbols].

* Foo has a vanilla kind signature. (See
  Note [Vanilla-type validity checking during promotion] in D.S.TH.Promote.Type
  for what "vanilla" means in this context.) Having a vanilla type signature is
  important, as it is a property that makes it much simpler to preserve the
  order of type variables (`forall c a b.`) in each of the defunctionalization
  symbols.

  That being said, it is not strictly required that the kind be vanilla. There
  is another approach that can be used to defunctionalize things with
  non-vanilla types, at the possible expense of having different type variable
  orders between different defunctionalization symbols.
  See "Wrinkle 2: Non-vanilla kinds" below for more information.

-----
-- Wrinkle 1: Partial kinds
-----

The Foo example above has a standalone kind signature, but not everything has
this much kind information. For example, consider this:

  $(singletons [d|
    type family Not x where
      Not False = True
      Not True  = False
    |])

The inferred kind for Not is `Bool -> Bool`, but since Not was declared in TH
quotes, `singletons-th` has no knowledge of this. Instead, we must rely on kind
inference to give Not's defunctionalization symbols the appropriate kinds.
Here is a naïve first attempt:

  data NotSym0 f
  type instance Apply NotSym0 x = Not x

  type family NotSym1 x where
    NotSym1 x = Not x

NotSym1 will have the inferred kind `Bool -> Bool`, but poor NotSym0 will have
the inferred kind `forall k. k -> Type`, which is far more general than we
would like. We can do slightly better by supplying additional kind information
in a data constructor, like so:

  type SameKind :: k -> k -> Constraint
  class SameKind x y = ()

  data NotSym0 f where
    NotSym0KindInference :: SameKind (Apply NotSym0 arg) (NotSym1 arg)
                         => NotSym0 f

NotSym0KindInference is not intended to ever be seen by the user. Its only
reason for existing is its existential
`SameKind (Apply NotSym0 arg) (NotSym1 arg)` context, which allows GHC to
figure out that NotSym0 has kind `Bool ~> Bool`. This is a bit of a hack, but
it works quite nicely. The only problem is that GHC is likely to warn that
NotSym0KindInference is unused, which is annoying. To work around this, we
mention the data constructor in an instance of a dummy class:

  instance SuppressUnusedWarnings NotSym0 where
    suppressUnusedWarnings = snd (NotSym0KindInference, ())

Similarly, this SuppressUnusedWarnings class is not intended to ever be seen
by the user. As its name suggests, it only exists to help suppress "unused
data constructor" warnings.

Some declarations have a mixture of known kinds and unknown kinds, such as in
this example:

  $(singletons [d|
    type family Bar x (y :: Nat) (z :: Nat) :: Nat where ...
    |])

We can use the known kinds to guide kind inference. In this particular example
of Bar, here are the defunctionalization symbols that would be generated:

  data BarSym0 f where ...
  data BarSym1 x :: Nat ~> Nat ~> Nat where ...
  data BarSym2 x (y :: Nat) :: Nat ~> Nat where ...
  type family BarSym3 x (y :: Nat) (z :: Nat) :: Nat where ...

-----
-- Wrinkle 2: Non-vanilla kinds
-----

There is only limited support for defunctionalizing declarations with
non-vanilla kinds. One example of something with a non-vanilla kind is the
following, which uses a nested forall:

  $(singletons [d|
    type Baz :: forall a. a -> forall b. b -> Type
    data Baz x y
    |])

One might envision generating the following defunctionalization symbols for
Baz:

  type BazSym0 :: forall a. a ~> forall b. b ~> Type
  data BazSym0 f where ...

  type BazSym1 :: forall a. a -> forall b. b ~> Type
  data BazSym1 x f where ...

  type BazSym2 :: forall a. a -> forall b. b -> Type
  type family BazSym2 x y where
    BazSym2 x y = Baz x y

Unfortunately, doing so would require impredicativity, since we would have:

    forall a. a ~> forall b. b ~> Type
  = forall a. (~>) a (forall b. b ~> Type)
  = forall a. TyFun a (forall b. b ~> Type) -> Type

Note that TyFun is an ordinary data type, so having its second argument be
(forall b. b ~> Type) is truly impredicative. As a result, trying to preserve
nested or higher-rank foralls is a non-starter.

We need not reject Baz entirely, however. We can still generate perfectly
usable defunctionalization symbols if we are willing to sacrifice the exact
order of foralls. When we encounter a non-vanilla kind such as Baz's, we simply
fall back to the algorithm used when we encounter a partial kind (as described
in "Wrinkle 1: Partial kinds" above.) In other words, we generate the
following symbols:

  data BazSym0 :: a ~> b ~> Type where ...
  data BazSym1 (x :: a) :: b ~> Type where ...
  type family BazSym2 (x :: a) (y :: b) :: Type where ...

The kinds of BazSym0 and BazSym1 both start with `forall a b.`,
whereas the `b` is quantified later in Baz itself. For most use cases, however,
this is not a huge concern.

Another way kinds can be non-vanilla is if they contain visible dependent
quantification, like so:

  $(singletons [d|
    type Quux :: forall (k :: Type) -> k -> Type
    data Quux x y
    |])

What should the kind of QuuxSym0 be? Intuitively, it should be this:

  type QuuxSym0 :: forall (k :: Type) ~> k ~> Type

Alas, `forall (k :: Type) ~>` simply doesn't work. See #304. But there is an
acceptable compromise we can make that can give us defunctionalization symbols
for Quux. Once again, we fall back to the partial kind algorithm:

  data QuuxSym0 :: Type ~> k ~> Type where ...
  data QuuxSym1 (k :: Type) :: k ~> Type where ...
  type family QuuxSym2 (k :: Type) (x :: k) :: Type where ...

The catch is that the kind of QuuxSym0, `forall k. Type ~> k ~> Type`, is
slightly more general than it ought to be. In practice, however, this is
unlikely to be a problem as long as you apply QuuxSym0 to arguments of the
right kinds.

Note [Fully saturated defunctionalization symbols]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
When generating defunctionalization symbols, most of the symbols are data
types. The last one, however, is a type family. For example, this code:

  $(singletons [d|
    type Const :: a -> b -> a
    type Const x y = x
    |])

Will generate the following symbols:

  type ConstSym0 :: a ~> b ~> a
  data ConstSym0 f where ...

  type ConstSym1 :: a -> b ~> a
  data ConstSym1 x f where ...

  type ConstSym2 :: a -> b -> a
  type family ConstSym2 x y where
    ConstSym2 x y = Const x y

ConstSym2, the sole type family of the bunch, is what is referred to as a
"fully saturated" defunctionaliztion symbol.

At first glance, ConstSym2 may not seem terribly useful, since it is
effectively a thin wrapper around the original Const type. Indeed, fully
saturated symbols almost never appear directly in user-written code. Instead,
they are most valuable in TH-generated code, as singletons-th often generates code
that directly applies a defunctionalization symbol to some number of arguments
(see, for instance, D.S.TH.Names.promoteTySym). In theory, such code could carve
out a special case for fully saturated applications and apply the original
type instead of a defunctionalization symbol, but determining when an
application is fully saturated is often difficult in practice. As a result, it
is more convenient to just generate code that always applies FuncSymN to N
arguments, and to let fully saturated defunctionalization symbols handle the
case where N equals the number of arguments needed to fully saturate Func.

One might wonder if, instead of using a closed type family with a single
equation, we could use a type synonym to define ConstSym2:

  type ConstSym2 :: a -> b -> a
  type ConstSym2 x y = Const x y

This approach has various downsides which make it impractical:

* Type synonyms are often not expanded in the output of GHCi's :kind! command.
  As issue #445 chronicles, this can significantly impact the readability of
  even simple :kind! queries. It can be the difference between this:

    λ> :kind! Map IdSym0 '[1,2,3]
    Map IdSym0 '[1,2,3] :: [Nat]
    = 1 :@#@$$$ '[2, 3]

  And this:

    λ> :kind! Map IdSym0 '[1,2,3]
    Map IdSym0 '[1,2,3] :: [Nat]
    = '[1, 2, 3]

  Making fully saturated defunctionalization symbols like (:@#@$$$) type
  families makes this issue moot, since :kind! always expands type families.
* There are a handful of corner cases where using type synonyms can actually
  make fully saturated defunctionalization symbols fail to typecheck.
  Here is one such corner case:

    $(promote [d|
      class Applicative f where
        pure :: a -> f a
        ...
        (*>) :: f a -> f b -> f b
      |])

    ==>

    class PApplicative f where
      type Pure (x :: a) :: f a
      type (*>) (x :: f a) (y :: f b) :: f b

  What would happen if we were to defunctionalize the promoted version of (*>)?
  We'd end up with the following defunctionalization symbols:

    type (*>@#@$)   :: f a ~> f b ~> f b
    data (*>@#@$) f where ...

    type (*>@#@$$)  :: f a -> f b ~> f b
    data (*>@#@$$) x f where ...

    type (*>@#@$$$) :: f a -> f b -> f b
    type (*>@#@$$$) x y = (*>) x y

  It turns out, however, that (*>@#@$$$) will not kind-check. Because (*>@#@$$$)
  has a standalone kind signature, it is kind-generalized *before* kind-checking
  the actual definition itself. Therefore, the full kind is:

    type (*>@#@$$$) :: forall {k} (f :: k -> Type) (a :: k) (b :: k).
                       f a -> f b -> f b
    type (*>@#@$$$) x y = (*>) x y

  However, the kind of (*>) is
  `forall (f :: Type -> Type) (a :: Type) (b :: Type). f a -> f b -> f b`.
  This is not general enough for (*>@#@$$$), which expects kind-polymorphic `f`,
  `a`, and `b`, leading to a kind error. You might think that we could somehow
  infer this information, but note the quoted definition of Applicative (and
  PApplicative, as a consequence) omits the kinds of `f`, `a`, and `b` entirely.
  Unless we were to implement full-blown kind inference inside of Template
  Haskell (which is a tall order), the kind `f a -> f b -> f b` is about as good
  as we can get.

  Making (*>@#@$$$) a type family rather than a type synonym avoids this issue
  since type family equations are allowed to match on kind arguments. In this
  example, (*>@#@$$$) would have kind-polymorphic `f`, `a`, and `b` in its kind
  signature, but its equation would implicitly equate `k` with `Type`. Note
  that (*>@#@$) and (*>@#@$$), which are GADTs, also use a similar trick by
  equating `k` with `Type` in their GADT constructors.

-----
-- Wrinkle: avoiding reduction stack overflows
-----

A naïve attempt at declaring all fully saturated defunctionalization symbols
as type families can make certain programs overflow the reduction stack, such
as the T445 test case. This is because when evaluating
`FSym0 `Apply` x_1 `Apply` ... `Apply` x_N`, (where F is a promoted function
that requires N arguments), we will eventually bottom out by evaluating
`FSymN x_1 ... x_N`, where FSymN is a fully saturated defunctionalization
symbol. Since FSymN is a type family, this is yet another type family
reduction that contributes to the overall reduction limit. This might not
seem like a lot, but it can add up if F is invoked several times in a single
type-level computation!

Fortunately, we can bypass evaluating FSymN entirely by just making a slight
tweak to the TH machinery. Instead of generating this Apply instance:

  type instance Apply (FSym{N-1} x_1 ... x_{N-1}) x_N =
    FSymN x_1 ... x_{N-1} x_N

Generate this instance, which jumps straight to F:

  type instance Apply (FSym{N-1} x_1 ... x_{N-1}) x_N =
    F x_1 ... x_{N-1} x_N

Now evaluating `FSym0 `Apply` x_1 `Apply` ... `Apply` x_N` will require one
less type family reduction. In practice, this is usually enough to keep the
reduction limit at bay in most situations.

Note [Fixity declarations for defunctionalization symbols]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Just like we promote fixity declarations, we should also generate fixity
declarations for defunctionaliztion symbols. A primary use case is the
following scenario:

  (.) :: (b -> c) -> (a -> b) -> (a -> c)
  (f . g) x = f (g x)
  infixr 9 .

One often writes (f . g . h) at the value level, but because (.) is promoted
to a type family with three arguments, this doesn't directly translate to the
type level. Instead, one must write this:

  f .@#@$$$ g .@#@$$$ h

But in order to ensure that this associates to the right as expected, one must
generate an `infixr 9 .@#@#$$$` declaration. This is why defunctionalize accepts
a Maybe Fixity argument.
-}
