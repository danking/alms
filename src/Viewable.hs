{-# LANGUAGE TypeFamilies #-}
module Viewable where

import Util

class Viewable a where
  type View a
  view :: a -> View a

newtype HIDDEN a = HIDE { unHIDE :: a }

instance Viewable (HIDDEN a) where
  type View (HIDDEN a) = a
  view (HIDE a) = a

instance Viewable a => Viewable [a] where
  type View [a] = [View a]
  view = fmap view

instance Viewable a => Viewable (Maybe a) where
  type View (Maybe a) = Maybe (View a)
  view = fmap view

instance (Viewable a, Viewable b) => Viewable (Either a b) where
  type View (Either a b) = Either (View a) (View b)
  view = view +++ view

instance (Viewable a, Viewable b) => Viewable (a, b) where
  type View (a, b) = (View a, View b)
  view = view *** view

instance (Viewable a, Viewable b, Viewable c) =>
         Viewable (a, b, c) where
  type View (a, b, c) = (View a, View b, View c)
  view (a, b, c) = (view a, view b, view c)

instance (Viewable a, Viewable b, Viewable c, Viewable d) =>
         Viewable (a, b, c, d) where
  type View (a, b, c, d) = (View a, View b, View c, View d)
  view (a, b, c, d) = (view a, view b, view c, view d)

instance (Viewable a, Viewable b, Viewable c, Viewable d, Viewable e) =>
         Viewable (a, b, c, d, e) where
  type View (a, b, c, d, e) = (View a, View b, View c, View d, View e)
  view (a, b, c, d, e) = (view a, view b, view c, view d, view e)
