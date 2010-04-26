-- | Flat, deep, and generalized environments
{-# LANGUAGE
      DeriveDataTypeable,
      FlexibleInstances,
      FunctionalDependencies,
      MultiParamTypeClasses,
      OverlappingInstances,
      ScopedTypeVariables,
      TypeOperators,
      UndecidableInstances #-}
module Env (
  -- * Basic type and operations
  Env(unEnv),
  -- ** Key subsumption
  (:>:)(..),
  -- ** Constructors
  empty, (-:-), (-::-),
  (-:+-), (-+-), (-\-), (-\\-), (-|-),
  -- ** Destructors
  isEmpty, (-.-),
  -- ** Higher-order constructors
  unionWith, unionSum, unionProduct,
  -- ** Higher-order destructors
  mapValsM, mapAccum, mapAccumM,
  -- ** List conversions
  toList, fromList, domain, range,

  -- * Deep environments
  PEnv(..), Path(..), ROOT(..), (<.>),

  -- * Generalized environments
  GenEmpty(..),
  GenExtend(..), (=++=), GenModify(..), GenRemove(..),
  GenLookup(..),

  -- * Aliases (why?)
  (=:=), (=::=), (=:+=)
) where

import Util
import qualified Data.Map as M
import qualified Data.Set as S
import Data.Generics (Typeable, Data)
import Data.Monoid

infix 6 -:-, -::-, -:+-
infixl 6 -.-
infixr 5 -+-
infixl 5 -\-, -\\-, -|-

-- | The basic type, mapping keys @k@ to values @v@
newtype Env k v = Env { unEnv:: M.Map k v }
  deriving (Typeable, Data)

-- | Key subsumption.  Downside: keys sometimes need to be
-- declared.  Upside: we can use shorter keys that embed into
-- larger keyspaces.
class (Ord x, Ord y) => x :>: y where
  liftKey :: y -> x
  liftEnv :: Env y v -> Env x v
  liftEnv (Env m) = Env (M.mapKeys liftKey m)

-- | Every ordered type is a key, reflexively
instance Ord k => (:>:) k k where
  liftKey = id
  liftEnv = id

-- | The empty environment
empty    :: Env k v
empty     = Env M.empty

-- | Is this an empty environment?
isEmpty  :: Env k v -> Bool
isEmpty   = M.null . unEnv

-- | Create a singleton environment
(-:-)    :: Ord k => k -> v -> Env k v
k -:- v   = Env (M.singleton k v)

-- | Monadic bind creates a singleton environment whose value is
--   monadic, given a pure value
(-::-)  :: (Monad m, Ord k) => k -> v -> Env k (m v)
k -::- v = k -:- return v

-- | "Closure bind" ensures that every element of the range maps to
--   itself as well.  (This is good for substitutions.)
(-:+-)   :: Ord k => k -> k -> Env k k
k -:+- k' = k -:- k' -+- k' -:- k'

-- | Union (right preference)
(-+-)    :: (k :>: k') => Env k v -> Env k' v -> Env k v
m -+- n   = m `mappend` liftEnv n

-- | Remove a binding
(-\-)    :: (k :>: k') => Env k v -> k' -> Env k v
m -\- y   = Env (M.delete (liftKey y) (unEnv m))

-- | Difference, removing a set of keys
(-\\-)   :: (k :>: k') => Env k v -> S.Set k' -> Env k v
m -\\- ys = Env (S.fold (M.delete . liftKey) (unEnv m) ys)

-- | Lookup
(-.-)    :: (k :>: k') => Env k v -> k' -> Maybe v
m -.- y   = M.lookup (liftKey y) (unEnv m)

-- | Intersection
(-|-)    :: (k :>: k') => Env k v -> Env k' w -> Env k (v, w)
m -|- n   = Env (M.intersectionWith (,) (unEnv m) (unEnv (liftEnv n)))

-- | Union, given a combining function
unionWith :: (k :>: k') => (v -> v -> v) -> 
                           Env k v -> Env k' v -> Env k v
unionWith f e e' = Env (M.unionWith f (unEnv e) (unEnv (liftEnv e')))

-- | Additive union (right preference)
unionSum :: (k :>: k') => Env k v -> Env k' w -> Env k (Either v w)
unionSum e e' = fmap Left e -+- fmap Right e'

-- | Multiplicative union
unionProduct :: (k :>: k') => Env k v -> Env k' w -> Env k (Maybe v, Maybe w)
unionProduct m n = Env (M.unionWith combine m' n') where
  m' = fmap (\v -> (Just v, Nothing)) (unEnv m)
  n' = fmap (\w -> (Nothing, Just w)) (unEnv (liftEnv n))
  combine (mv, _) (_, mw) = (mv, mw)

infix 5 `unionSum`, `unionProduct`

instance Ord k => Functor (Env k) where
  fmap f = Env . M.map f . unEnv

-- | Map over the values of an environment (monadic)
mapValsM :: (Ord k, Monad m) =>
            (v -> m w) -> Env k v -> m (Env k w)
mapValsM f = liftM snd . mapAccumM (\v _ -> (,) () `liftM` f v) ()

-- | Map over an environment, with an opportunity to maintain an
--   accumulator
mapAccum :: Ord k => (v -> a -> (a, w)) -> a -> Env k v -> (a, Env k w)
mapAccum f z m = case M.mapAccum (flip f) z (unEnv m) of
                   (w, m') -> (w, Env m')

-- | Map over an environment, with an opportunity to maintain an
--   accumulator (monadic)
mapAccumM :: (Ord k, Monad m) =>
             (v -> a -> m (a, w)) -> a -> Env k v -> m (a, Env k w)
mapAccumM f z m = do
  (a, elts) <- helper z [] (M.toAscList (unEnv m))
  return (a, Env (M.fromDistinctAscList (reverse elts)))
  where
    helper a acc [] = return (a, acc)
    helper a acc ((k, v):rest) = do
      (a', w) <- f v a
      helper a' ((k, w) : acc) rest

-- | Get an association list
toList   :: Ord k => Env k v -> [(k, v)]
toList    = M.toList . unEnv

-- | Make an environment from an association list
fromList :: Ord k => [(k, v)] -> Env k v
fromList  = Env . M.fromList

-- | The keys
domain   :: Ord k => Env k v -> [k]
domain    = M.keys . unEnv

-- | The values
range    :: Ord k => Env k v -> [v]
range     = M.elems . unEnv

instance Ord k => Monoid (Env k v) where
  mempty      = empty
  mappend m n = Env (M.unionWith (\_ v -> v) (unEnv m) (unEnv n))

instance (Ord k, Show k, Show v) => Show (Env k v) where
  showsPrec _ env = foldr (.) id
    [ shows k . (" : "++) . shows v . ('\n':)
    | (k, v) <- M.toList (unEnv env) ]

(=:=)  :: Ord k => k -> v -> Env k v
(=::=) :: (Ord k, Monad m) => k -> v -> Env k (m v)
(=:+=) :: Ord k => k -> k -> Env k k
(=:=)   = (-:-)
(=::=)  = (-::-)
(=:+=)  = (-:+-)

infix 6 =:=, =::=, =:+=
infixl 6 =.=, =..=
infixr 5 =+=, =++=
infixl 5 =\=, =\\=

instance (k :>: k') => GenExtend (Env k v) (Env k' v)    where (=+=) = (-+-)
instance Ord k      => GenRemove (Env k v) k             where (=\=) = (-\-)
instance (k :>: k') => GenLookup (Env k v) k' v          where (=..=) = (-.-)
instance (k :>: k') => GenModify (Env k v) k' v where
  genModify e k fv = case e =..= k of
    Nothing -> e
    Just v  -> e =+= k -:- fv v
instance GenEmpty (Env k v) where genEmpty = empty

-- | A path environment maps paths of @p@ components to @e@.
data PEnv p e = PEnv {
                  -- | Nested path environments
                  envenv :: Env p (PEnv p e),
                  -- | The top level flat environment
                  valenv :: e
                }
  deriving (Show, Typeable, Data)

-- | A path of @p@ components with final key type @k@
data Path p k = J {
                  jpath :: [p],
                  jname :: k
                }
  deriving (Eq, Ord, Typeable, Data)

-- | Add a qualifier to the front of a path
(<.>) :: p -> Path p k -> Path p k
p <.> J ps k = J (p:ps) k

infixr 8 <.>

-- | Newtype for selecting instances operations that operate at the root
newtype ROOT e = ROOT { unROOT :: e }
  deriving (Eq, Ord, Show, Typeable, Data)

-- Utility instances

instance Ord p => Functor (PEnv p) where
  fmap f (PEnv envs vals) = PEnv (fmap (fmap f) envs) (f vals)

instance (Show p, Show k) => Show (Path p k) where
  showsPrec _ (J ps k) = foldr (\p r -> shows p . ('.':) . r) (shows k) ps

instance Functor (Path p) where
  fmap f (J p k) = J p (f k)

instance Functor ROOT where
  fmap f (ROOT x) = ROOT (f x)

instance Monad ROOT where
  return       = ROOT
  ROOT x >>= f = f x

-- Some structural rules:

instance GenLookup e k v => GenLookup (Maybe e) k v where
  Just e  =..= k  = e =..= k
  Nothing =..= _  = Nothing

instance GenLookup e k v => GenLookup [e] k v where
  es =..= k  = foldr (\e r -> maybe r Just (e =..= k)) Nothing es

instance (GenEmpty e, GenExtend e e') => GenExtend [e] e' where
  (e:es) =+= e'  =  (e =+= e') : es
  []     =+= e'  =  [ (genEmpty :: e) =+= e' ]

instance GenEmpty e => GenEmpty [e] where
  genEmpty = [genEmpty]

instance GenRemove e k => GenRemove [e] k where
  e =\= k = map (=\= k) e

-- | A generalization of environment union.  If the environments
--   have different types, we assume the right type may be lifted
--   to the left types.
--
-- We can extend a nested env with
--
--  * some subenvs
--
--  * a value env
--
--  * another nested env (preferring the right)
--
--  * '(=++=)' pathwise-unions subenvs rather than replacing
class GenExtend e e' where
  (=+=) :: e -> e' -> e

instance Ord p => GenExtend (PEnv p e) (Env p (PEnv p e)) where
  penv =+= e = penv { envenv = envenv penv =+= e }

instance Ord p => GenExtend (PEnv p e) (Env p e) where
  penv =+= e = penv =+= fmap (PEnv (empty :: Env p (PEnv p e))) e

instance GenExtend e e' =>
         GenExtend (PEnv p e) e' where
  penv =+= e = penv { valenv = valenv penv =+= e }

instance (Ord p, GenExtend e e) =>
         GenExtend (PEnv p e) (PEnv p e) where
  PEnv es vs =+= PEnv es' vs' = PEnv (es =+= es') (vs =+= vs')

instance (Ord p, Ord k, GenEmpty e, GenExtend e (Env k v)) =>
         GenExtend (PEnv p e) (Env (Path p k) v) where
  penv =+= env = foldr (flip (=+=)) penv (toList env)

instance (Ord p, Ord k, GenEmpty e, GenExtend e (Env k v)) =>
         GenExtend (PEnv p e) (Path p k, v) where
  PEnv ee ve =+= (J ps0 k, v) = case ps0 of
    []   -> PEnv ee (ve =+= k =:= v)
    p:ps -> let penv' = maybe genEmpty id (ee =..= p) =+= (J ps k, v)
             in PEnv (ee =+= p =:= penv') ve

-- | tree-wise union:
(=++=) :: (Ord p, GenExtend e e) => PEnv p e -> PEnv p e -> PEnv p e
PEnv (Env m) e =++= PEnv (Env m') e' =
  PEnv (Env (M.unionWith (=++=) m m')) (e =+= e')

-- | Generalization class for lookup, where the environment and key
--   types determine the value type
--
-- Instances allow us to lookup in a nested env by
--
--  * one path component
--
--  * a path
--
--  * a path to a key
--
--  * a path to a path component
--
--  * one key (must wrap the environment in 'ROOT')
class GenLookup e k v | e k -> v where
  (=..=) :: e -> k -> Maybe v

instance Ord p => GenLookup (PEnv p e) p (PEnv p e) where
  penv =..= p = envenv penv =..= p

instance Ord p => GenLookup (PEnv p e) [p] (PEnv p e) where
  (=..=) = foldM (=..=)

instance Ord p => GenLookup (PEnv p e) (Path p p) (PEnv p e) where
  penv =..= J ps p = penv =..= (ps++[p])

instance (Ord p, GenLookup e k v) =>
         GenLookup (PEnv p e) (Path p k) v where
  penv =..= J path k = penv =..= path >>= (=.= k)

instance GenLookup e k v => GenLookup (ROOT (PEnv p e)) k v where
  ROOT penv =..= k = valenv penv =..= k    

-- alias for looking up a simple key
(=.=) :: GenLookup e k v => PEnv p e -> k -> Maybe v
(=.=)  = (=..=) . ROOT

-- | Generalization of a value update operation
--
-- We can modify a nested env at
--
--  * one path component
--
--  * a path to a nested env
--
--  * a path to an env
--
--  * a path to a key
--
--  * a single key (ROOT)
class GenModify e k v where
  genModify :: e -> k -> (v -> v) -> e

instance Ord p => GenModify (PEnv p e) p (PEnv p e) where
  genModify penv p f  =  genModify penv [p] f

instance Ord p => GenModify (PEnv p e) [p] (PEnv p e) where
  genModify penv [] f     = f penv
  genModify penv (p:ps) f = case envenv penv =..= p of
    Nothing    -> penv
    Just penv' -> penv =+= p =:= genModify penv' ps f

instance Ord p => GenModify (PEnv p e) [p] e where
  genModify penv path fe = genModify penv path fpenv where
    fpenv      :: PEnv p e -> PEnv p e
    fpenv penv' = penv' { valenv = fe (valenv penv') }

instance (Ord p, GenModify e k v) =>
         GenModify (PEnv p e) (Path p k) v where
  genModify penv (J path k) fv = genModify penv path fe where
    fe  :: e -> e
    fe e = genModify e k fv

instance GenModify e k v => GenModify (ROOT (PEnv p e)) k v where
  genModify (ROOT penv) k fv = ROOT (penv { valenv = fe (valenv penv) })
    where
    fe  :: e -> e
    fe e = genModify e k fv

-- | Generalization class for key removal
--
-- We can remove at
--
--  * a single path component
--
--  * a path to a key
--
--  * a path to a path
--
--  * a single key (using 'ROOT')
class GenRemove e k where
  (=\=)  :: e -> k -> e
  (=\\=) :: e -> S.Set k -> e
  e =\\= set = foldl (=\=) e (S.toList set)

instance Ord p => GenRemove (PEnv p e) p where
  penv =\= p = penv { envenv = envenv penv =\= p }

instance (Ord p, GenRemove e k) => GenRemove (PEnv p e) (Path p k) where
  penv =\= J path k = genModify penv path fe where
    fe :: e -> e
    fe  = (=\= k)

instance Ord p => GenRemove (PEnv p e) (Path p p) where
  penv =\= J path p = genModify penv path fpenv where
    fpenv :: PEnv p e -> PEnv p e
    fpenv  = (=\= p)

instance GenRemove e k => GenRemove (ROOT (PEnv p e)) k where
  ROOT penv =\= k = ROOT (penv { valenv = valenv penv =\= k })

-- | Generalization of the empty environment
class GenEmpty e where
  genEmpty :: e

-- we can make empty PEnvs if we can put an empty env in it
instance GenEmpty e => GenEmpty (PEnv p e) where
  genEmpty = PEnv genEmpty genEmpty

