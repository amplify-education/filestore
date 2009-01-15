{- |
   Module      : Data.FileStore.Generic
   Copyright   : Copyright (C) 2008 John MacFarlane
   License     : BSD 3

   Maintainer  : John MacFarlane <jgm@berkeley.edu>
   Stability   : alpha
   Portability : GHC 6.10 required

   Generic functions for "Data.FileStore".
-}

module Data.FileStore.Generic
           ( modify
           , create
           , diff )

where
import Data.FileStore.Types

import Control.Exception (throwIO, catch, SomeException)
import Data.FileStore.Utils
import Prelude hiding (catch)

handleUnknownError :: SomeException -> IO a
handleUnknownError = throwIO . UnknownError . show

-- | Like save, but first verify that the resource name is new.  If not, throws a 'ResourceExists'
-- error.
create :: Contents a
       => FileStore
       -> ResourceName      -- ^ Resource to create.
       -> Author            -- ^ Author of change.
       -> String            -- ^ Description of change.
       -> a                 -- ^ Contents of resource.
       -> IO ()
create fs name author logMsg contents = catch (latest fs name >> throwIO ResourceExists)
                                                (\e -> if e == NotFound
                                                 then save fs name author logMsg contents
                                                 else throwIO e)

-- | Modify a named resource in the filestore.  Like save, except that a revision ID
-- must be specified.  If the resource has been modified since the specified revision,
-- @Left@ merge information is returned.  Otherwise, @Right@ the new contents are saved.  
modify  :: Contents a
        => FileStore
        -> ResourceName      -- ^ Resource to create.
        -> RevisionId        -- ^ ID of previous revision that is being modified.
        -> Author            -- ^ Author of change.
        -> String            -- ^ Description of change.
        -> a                 -- ^ Contents of resource.
        -> IO (Either MergeInfo ())
modify fs name originalRevId author msg contents = do
  latestRevId <- latest fs name
  latestRev <- revision fs latestRevId
  if idsMatch fs originalRevId latestRevId
     then save fs name author msg contents >> return (Right ())
     else do
       latestContents <- retrieve fs name (Just latestRevId)
       originalContents <- retrieve fs name (Just originalRevId)
       (conflicts, mergedText) <- catch 
                                  (mergeContents ("edited", toByteString contents) (originalRevId, originalContents) (latestRevId, latestContents))
                                  handleUnknownError
       return $ Left (MergeInfo latestRev conflicts mergedText)

-- | Return a unified diff of two revisions of a named resource, using an external @diff@
-- program.
diff :: FileStore
     -> ResourceName      -- ^ Resource name to get diff for.
     -> RevisionId        -- ^ Old revision ID.
     -> RevisionId        -- ^ New revision ID.
     -> IO String
diff fs name id1 id2 = do
  contents1 <- retrieve fs name (Just id1)
  contents2 <- retrieve fs name (Just id2)
  diffContents contents1 contents2

