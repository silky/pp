{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleContexts #-}
module Language.PP.Infer where

import Control.Monad
import Control.Monad.Free

import Language.PP.Types
import Language.PP.Dist (categorical, uniform)
import Language.PP.Eval (eval, withP)

import Data.Random (MonadRandom)

-- | True if a program is terminated (i.e. is 'Pure')
terminated :: PP m a -> Bool
terminated (Free x) = False
terminated (Pure x) = True

-- | Unsafely extract a 'Pure' value
getPure :: PP m a -> a
getPure (Pure x) = x
getPure (Free x) = error "don't call getPure on Free!"

-- | Step a program once, returning a log-weight
step :: Monad m => Double -> PP m a -> m (Double, PP m a)
step p (Free (P m)) = fmap (\(p', x) -> (p + p', x)) m
step p (Pure x)     = return (p, return x)

-- | Step a list of weighted programs, replacing their weights
-- if they are not terminated.
stepAll
  :: MonadRandom m
  => [(Double, PP m a)]
  -> PP m [(Double, PP m a)]
stepAll ps = liftF . P $ f <$> mapM (uncurry step) ps
        -- Double of bootstrap filter itself is sum of child
        -- probabilities
  where f ps = (sum (map fst ps), ps)

-- | Resample a list of weighted programs (By their log weights).
resample
  :: MonadRandom m
  => Int
  -> [(Double, PP m a)]
  -> PP m [(Double, PP m a)]
resample n = replicateM n . liftF . categorical . fmap f
  where f x = (exp (fst x), x)

bootstrap :: MonadRandom m => Int -> PP m a -> PP m [(Double, a)]
bootstrap n prog = loop (replicate n (0.0, prog))
  where loop ps
          | all (terminated . snd) ps = return . map f $ ps
          | otherwise = stepAll ps >>= resample n >>= loop
        f (p, x) = (p, getPure x)

------------ PMMH ------------

type PMMH m theta a =
  ( PP m theta        -- prior
  , (theta -> PP m a) -- probabilistic program
  )

type Candidate theta a =
  ( Double  -- p(theta)
  , theta   -- theta
  , Double  -- p(a | theta)
  , a       -- a
  )

-- | Accept a new state with some probability (1 if p > 1)
accept :: MonadRandom m => Double -> a -> a -> PP m a
accept a x y = do
  p <- liftF (uniform 0 1)
  return $ if (a >= 1 || p <= a) then x else y

acceptCandidate :: MonadRandom m
  => Candidate theta a -- ^ proposed candidate
  -> Candidate theta a -- ^ previous candidate
  -> PP m (Candidate theta a) -- ^ resulting choice
acceptCandidate new@(pt, t, py, y) old@(pt', t', py', y')
  = accept a new old
  where num = py  + pt
        den = py' + pt'
        a = exp (num - den) -- MH accept ratio

propose
  :: MonadRandom m
  => Int
  -> PMMH m theta a
  -> PP m (Candidate theta a)
propose n (prior, prog) = do
  (pt, t) <- withP . P . eval $ prior
  (py, y) <- bootstrap n (prog t) >>= liftF . categorical . expWeights
  return (pt, t, py, y)
  where expWeights = map (\x@(w, _) -> (exp w, x))

pmmhStep :: MonadRandom m
         => Int
         -> PMMH m theta a
         -> Candidate theta a
         -> PP m (Candidate theta a)
pmmhStep n p@(prior, prog) c'@(_, t', _, _) =
  propose n p >>= (\c -> acceptCandidate c c')

-- Explicit looping here is a bit naff :<
pmmhLoop 0 _ _ _ = return []
pmmhLoop i n p c = do
  proposed <- propose n p
  next     <- acceptCandidate proposed c
  {-next <- pmmhStep n p c-}
  (next:) <$> pmmhLoop (i - 1) n p next

pmmh :: MonadRandom m
     => Int
     -> Int
     -> PMMH m theta a
     -> PP m ([Candidate theta a])
pmmh m n p = propose n p >>= pmmhLoop m n p
