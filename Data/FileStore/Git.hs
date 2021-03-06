{- |
   Module      : Data.FileStore.Git
   Copyright   : Copyright (C) 2009 John MacFarlane
   License     : BSD 3

   Maintainer  : John MacFarlane <jgm@berkeley.edu>
   Stability   : alpha
   Portability : GHC 6.10 required

   A versioned filestore implemented using git.
   Normally this module should not be imported: import
   "Data.FileStore" instead.
-}

module Data.FileStore.Git
           ( gitFileStore
           , remoteGitFileStore
           , Remote(..)
           )
where
import Data.FileStore.Types
import Data.Maybe (mapMaybe)
import Data.List.Split (endByOneOf)
import System.Exit
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Data.FileStore.Utils (withSanityCheck, hashsMatch, runShellCommand, escapeRegexSpecialChars, withVerifyDir) 
import Data.ByteString.Lazy.UTF8 (toString)
import qualified Data.ByteString.Lazy as B
import qualified Text.ParserCombinators.Parsec as P
import Codec.Binary.UTF8.String (encodeString)
import Control.Monad (when)
import System.FilePath ((</>))
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, executable, getPermissions, setPermissions)
import Control.Exception (throwIO)
import Paths_filestore

-- | Return a filestore implemented using the git distributed revision control system
-- (<http://git-scm.com/>).
gitFileStore :: FilePath -> FileStore
gitFileStore repo = FileStore {
    initialize        = gitInit repo
  , save              = gitSave repo 
  , retrieve          = gitRetrieve repo
  , delete            = gitDelete repo
  , rename            = gitMove repo
  , history           = gitLog repo
  , latest            = gitLatestRevId repo
  , revision          = gitGetRevision repo
  , index             = gitIndex repo
  , directory         = gitDirectory repo
  , search            = gitSearch repo 
  , idsMatch          = const hashsMatch repo
  }

-- | Run a git command and return error status, error output, standard output.  The repository
-- is used as working directory.
runGitCommand :: FilePath -> String -> [String] -> IO (ExitCode, String, B.ByteString)
runGitCommand repo command args = do
  let env = Just [("GIT_DIFF_OPTS","-u100000")]
  (status, err, out) <- runShellCommand repo env "git" (command : args)
  return (status, toString err, out)

-- | Initialize a repository, creating the directory if needed.
gitInit :: FilePath -> IO ()
gitInit repo = do
  exists <- doesDirectoryExist repo
  when exists $ withVerifyDir repo $ throwIO RepositoryExists
  createDirectoryIfMissing True repo
  (status, err, _) <- runGitCommand repo "init" []
  if status == ExitSuccess
     then do
       -- Add the post-update hook, so that changes made remotely via git
       -- will be reflected in the working directory.
       postupdatepath <- getDataFileName $ "extra" </> "post-update"
       postupdatecontents <- B.readFile postupdatepath
       let postupdate = repo </> ".git" </> "hooks" </> "post-update"
       B.writeFile postupdate postupdatecontents
       perms <- getPermissions postupdate
       setPermissions postupdate (perms {executable = True})
       -- Set up repo to allow push to current branch
       (status', err', _) <- runGitCommand repo "config" ["receive.denyCurrentBranch","ignore"]
       if status' == ExitSuccess
          then return ()
          else throwIO $ UnknownError $ "git config failed:\n" ++ err'
     else throwIO $ UnknownError $ "git-init failed:\n" ++ err 

-- | Commit changes to a resource.  Raise 'Unchanged' exception if there were
-- no changes.
gitCommit :: FilePath -> [FilePath] -> Author -> String -> IO ()
gitCommit repo names author logMsg = do
  (statusCommit, errCommit, _) <- runGitCommand repo "commit" $ ["--author", authorName author ++ " <" ++
                                    authorEmail author ++ ">", "-m", logMsg] ++ names
  if statusCommit == ExitSuccess
     then return ()
     else throwIO $ if null errCommit
                       then Unchanged
                       else UnknownError $ "Could not git commit " ++ unwords names ++ "\n" ++ errCommit

-- | Save changes (creating file and directory if needed), add, and commit.
gitSave :: Contents a => FilePath -> FilePath -> Author -> Description -> a -> IO ()
gitSave repo name author logMsg contents = do
  withSanityCheck repo [".git"] name $ B.writeFile (repo </> encodeString name) $ toByteString contents
  (statusAdd, errAdd, _) <- runGitCommand repo "add" [name]
  if statusAdd == ExitSuccess
     then gitCommit repo [name] author logMsg
     else throwIO $ UnknownError $ "Could not git add '" ++ name ++ "'\n" ++ errAdd

-- | Retrieve contents from resource.
gitRetrieve :: Contents a
            => FilePath
            -> FilePath
            -> Maybe RevisionId    -- ^ @Just@ revision ID, or @Nothing@ for latest
            -> IO a
gitRetrieve repo name revid = do
  let objectName = case revid of
                        Nothing  -> "HEAD:" ++ name
                        Just rev -> rev ++ ":" ++ name
  -- Check that the object is a file (blob), not a directory (tree)
  (_, _, output) <- runGitCommand repo "cat-file" ["-t", objectName]
  when (take 4 (toString output) /= "blob") $ throwIO NotFound
  (status', err', output') <- runGitCommand repo "cat-file" ["-p", objectName]
  if status' == ExitSuccess
     then return $ fromByteString output'
     else throwIO $ UnknownError $ "Error in git cat-file:\n" ++ err'

-- | Delete a resource from the repository.
gitDelete :: FilePath -> FilePath -> Author -> Description -> IO ()
gitDelete repo name author logMsg = withSanityCheck repo [".git"] name $ do
  (statusAdd, errRm, _) <- runGitCommand repo "rm" [name]
  if statusAdd == ExitSuccess
     then gitCommit repo [name] author logMsg
     else throwIO $ UnknownError $ "Could not git rm '" ++ name ++ "'\n" ++ errRm

-- | Change the name of a resource.
gitMove :: FilePath -> FilePath -> FilePath -> Author -> Description -> IO ()
gitMove repo oldName newName author logMsg = do
  _ <- gitLatestRevId repo oldName   -- will throw a NotFound error if oldName doesn't exist
  (statusAdd, err, _) <- withSanityCheck repo [".git"] newName $ runGitCommand repo "mv" [oldName, newName] 
  if statusAdd == ExitSuccess
     then gitCommit repo [oldName, newName] author logMsg
     else throwIO $ UnknownError $ "Could not git mv " ++ oldName ++ " " ++ newName ++ "\n" ++ err

-- | Return revision ID for latest commit for a resource.
gitLatestRevId :: FilePath -> FilePath -> IO RevisionId
gitLatestRevId repo name = do
  (revListStatus, _, output) <- runGitCommand repo "rev-list" ["--max-count=1", "HEAD", "--", name]
  -- we need to check separately to make sure the resource hasn't been removed
  -- from the repository:
  (catStatus,_, _) <- runGitCommand repo "cat-file" ["-e", "HEAD:" ++ name]
  if revListStatus == ExitSuccess && catStatus == ExitSuccess
     then do
       let result = takeWhile (`notElem` "\n\r \t") $ toString output
       if null result
          then throwIO NotFound
          else return result
     else throwIO NotFound

-- | Get revision information for a particular revision ID, or latest revision.
gitGetRevision :: FilePath -> RevisionId -> IO Revision
gitGetRevision repo revid = do
  (status, _, output) <- runGitCommand repo "whatchanged" ["-z","--pretty=format:" ++ gitLogFormat, "--max-count=1", revid]
  if status == ExitSuccess
     then case P.parse parseGitLog "" (toString output) of
                 Left err'   -> throwIO $ UnknownError $ "error parsing git log: " ++ show err'
                 Right [r]   -> return r
                 Right []    -> throwIO NotFound
                 Right xs    -> throwIO $ UnknownError $ "git rev-list returned more than one result: " ++ show xs
     else throwIO NotFound

-- | Get a list of all known files inside and managed by a repository.
gitIndex :: FilePath -> IO [FilePath]
gitIndex repo = withVerifyDir repo $ do
  (status, _err, output) <- runGitCommand repo "ls-tree" ["-r","-t","-z","HEAD"]
  if status == ExitSuccess
     then return $ mapMaybe (lineToFilename . words) . endByOneOf ['\0'] . toString $ output
     else return [] -- if error, will return empty list
                    -- note:  on a newly initialized repo, 'git ls-tree HEAD' returns an error
   where lineToFilename (_:"blob":_:rest) = Just $ unwords rest
         lineToFilename _                 = Nothing

-- | Get list of resources in one directory of the repository.
gitDirectory :: FilePath -> FilePath -> IO [Resource]
gitDirectory repo dir = withVerifyDir (repo </> dir) $ do
  (status, _err, output) <- runGitCommand repo "ls-tree" ["-z","HEAD:" ++ dir]
  if status == ExitSuccess
     then return $ map (lineToResource . words) $ endByOneOf ['\0'] $ toString output
     else return []   -- if error, this will return empty list
                      -- note:  on a newly initialized repo, 'git ls-tree HEAD:' returns an error
   where lineToResource (_:"blob":_:rest) = FSFile $ unwords rest
         lineToResource (_:"tree":_:rest) = FSDirectory $ unwords rest
         lineToResource _                 = error "Encountered an item that is neither blob nor tree in git ls-tree"

-- | Uses git-grep to search repository.  Escape regex special characters, so the pattern
-- is interpreted as an ordinary string.
gitSearch :: FilePath -> SearchQuery -> IO [SearchMatch]
gitSearch repo query = do
  let opts = ["-I","-n","--null"] ++
             ["--ignore-case" | queryIgnoreCase query] ++
             ["--all-match" | queryMatchAll query] ++
             ["--word-regexp" | queryWholeWords query]
  (status, errOutput, output) <- runGitCommand repo "grep" (opts ++
                                   concatMap (\term -> ["-e", escapeRegexSpecialChars term]) (queryPatterns query))
  case status of
     ExitSuccess   -> return $ map parseMatchLine $ lines $ toString output
     ExitFailure 1 -> return []  -- status of 1 means no matches in recent versions of git
     ExitFailure _ -> throwIO $ UnknownError $ "git grep returned error status.\n" ++ errOutput

-- Auxiliary function for searchResults
parseMatchLine :: String -> SearchMatch
parseMatchLine str =
  SearchMatch{ matchResourceName = fname
             , matchLineNumber = if not (null ln)
                                    then read ln
                                    else error $ "parseMatchLine: " ++ str
             , matchLine = cont}
    where (fname,xs) = break (== '\NUL') str
          rest = drop 1 xs 
          -- for some reason, NUL is used after line number instead of
          -- : when --match-all is passed to git-grep.
          (ln,ys) = span (`elem` ['0'..'9']) rest
          cont = drop 1 ys   -- drop : or NUL after line number

{-
-- | Uses git-diff to get a dif between two revisions.
gitDiff :: FilePath -> FilePath -> RevisionId -> RevisionId -> IO String
gitDiff repo name from to = do
  (status, _, output) <- runGitCommand repo "diff" [from, to, name]
  if status == ExitSuccess
     then return $ toString output
     else do
       -- try it without the path, since the error might be "not in working tree" for a deleted file
       (status', err', output') <- runGitCommand repo "diff" [from, to]
       if status' == ExitSuccess
          then return $ toString output'
          else throwIO $ UnknownError $ "git diff returned error:\n" ++ err'
-}

gitLogFormat :: String
gitLogFormat = "%H%n%ct%n%an%n%ae%n%s%n%x00"

-- | Return list of log entries for the given time frame and list of resources.
-- If list of resources is empty, log entries for all resources are returned.
gitLog :: FilePath -> [FilePath] -> TimeRange -> IO [Revision]
gitLog repo names (TimeRange mbSince mbUntil) = do
  (status, err, output) <- runGitCommand repo "whatchanged" $
                           ["-z","--pretty=format:" ++ gitLogFormat] ++
                           (case mbSince of
                                 Just since   -> ["--since='" ++ show since ++ "'"]
                                 Nothing      -> []) ++
                           (case mbUntil of
                                 Just til   -> ["--until='" ++ show til ++ "'"]
                                 Nothing      -> []) ++
                           ["--"] ++ names 
  if status == ExitSuccess
     then case P.parse parseGitLog "" (toString output) of
                Left err'    -> throwIO $ UnknownError $ "Error parsing git log.\n" ++ show err'
                Right parsed -> return parsed
     else throwIO $ UnknownError $ "git whatchanged returned error status.\n" ++ err

--
-- Parsers to parse git log into Revisions.
--

parseGitLog :: P.Parser [Revision]
parseGitLog = P.manyTill gitLogEntry P.eof

wholeLine :: P.GenParser Char st String
wholeLine = P.manyTill P.anyChar P.newline

nonblankLine :: P.GenParser Char st String
nonblankLine = P.notFollowedBy P.newline >> wholeLine

nullChar :: P.GenParser Char st ()
nullChar = P.satisfy (=='\0') >> return ()

gitLogEntry :: P.Parser Revision
gitLogEntry = do
  rev <- nonblankLine
  date <- nonblankLine
  author <- wholeLine
  email <- wholeLine
  subject <- P.manyTill P.anyChar nullChar
  P.spaces
  changes <- P.manyTill gitLogChange (P.eof P.<|> nullChar)
  let stripTrailingNewlines = reverse . dropWhile (=='\n') . reverse
  return Revision {
              revId          = rev
            , revDateTime    = posixSecondsToUTCTime $ realToFrac (read date :: Integer)
            , revAuthor      = Author { authorName = author, authorEmail = email }
            , revDescription = stripTrailingNewlines subject
            , revChanges     = changes }

gitLogChange :: P.Parser Change
gitLogChange = do
  line <- P.manyTill P.anyChar nullChar
  let changeType = take 1 $ reverse line
  file' <- P.manyTill P.anyChar nullChar
  case changeType of
         "A"  -> return $ Added file'
         "M"  -> return $ Modified file'
         "D"  -> return $ Deleted file'
         _    -> return $ Modified file'


data Remote = Remote {
    remoteName :: String
  , remoteBranch :: String
  , remoteUrl :: String
}

qualifiedBranch :: Remote -> String
qualifiedBranch remote = (remoteName remote) ++ "/" ++ (remoteBranch remote)

remoteGitFileStore :: FilePath -> Remote -> FileStore
remoteGitFileStore repo remote = FileStore {
    initialize        = remoteInit repo remote 
  , save              = remoteSave repo remote
  , retrieve          = remoteRetrieve repo remote
  , delete            = remoteDelete repo remote
  , rename            = remoteMove repo remote
  , history           = remoteLog repo remote
  , latest            = remoteLatest repo remote
  , revision          = remoteGetRevision repo remote
  , index             = remoteIndex repo remote
  , directory         = remoteDirectory repo remote
  , search            = remoteSearch repo remote
  , idsMatch          = const hashsMatch repo
  }
  where

remoteInit :: FilePath -> Remote -> IO ()
remoteInit repo remote = do
    let fs = gitFileStore repo
    initialize fs
    (status, err, _) <- runGitCommand repo "remote" ["add", remoteName remote, remoteUrl remote]
    if status == ExitSuccess
       then return ()
       else throwIO $ UnknownError $ "git add remote failed:\n" ++ err

fetch :: FilePath -> IO ()
fetch repo = do
    (status, err, _) <- runGitCommand repo "fetch" []
    if status == ExitSuccess
       then return ()
       else throwIO $ UnknownError $ "git fetch failed with error " ++ err

checkoutRemote :: FilePath -> Remote -> IO ()
checkoutRemote repo remote = do
    (statusCh, errCh, _) <- runGitCommand repo "checkout" [remoteBranch remote]
    if statusCh == ExitSuccess
       then do
         (statusReset, errReset, _) <- runGitCommand repo "reset" ["--hard", qualifiedBranch remote]
         if statusReset == ExitSuccess
            then return ()
            else throwIO $ UnknownError $ "git reset --hard failed with error " ++ errReset
       else throwIO $ UnknownError $ "git checkout failed with error " ++ errCh

pushRemote :: FilePath -> Remote -> IO ()
pushRemote repo remote = do
    (status, err, _) <- runGitCommand repo "push" [remoteName remote, remoteBranch remote]
    if status == ExitSuccess
       then return ()
       else throwIO $ UnknownError $ "git push failed with error " ++ err

withSyncDown :: FilePath -> Remote -> (FileStore -> IO a) -> IO a
withSyncDown repo remote f = do
    let fs = gitFileStore repo
    fetch repo
    checkoutRemote repo remote
    f fs

withSyncBoth :: FilePath -> Remote -> (FileStore -> IO a) -> IO a
withSyncBoth repo remote f = do
    let fs = gitFileStore repo
    fetch repo
    checkoutRemote repo remote
    result <- f fs
    pushRemote repo remote
    return result

remoteSave :: Contents a
           => FilePath
           -> Remote
           -> FilePath
           -> Author
           -> Description
           -> a
           -> IO ()
remoteSave repo remote name author logMsg contents =
    withSyncBoth repo remote $ \fs -> (save fs) name author logMsg contents

remoteRetrieve :: Contents a => FilePath -> Remote -> FilePath -> Maybe RevisionId -> IO a
remoteRetrieve repo remote name revid =
    withSyncDown repo remote $ \fs -> (retrieve fs) name revid

remoteDelete :: FilePath -> Remote -> FilePath -> Author -> Description -> IO ()
remoteDelete repo remote name author logMsg =
    withSyncBoth repo remote $ \fs -> (delete fs) name author logMsg

remoteMove :: FilePath -> Remote -> FilePath -> FilePath -> Author -> Description -> IO ()
remoteMove repo remote oldName newName author logMsg =
    withSyncBoth repo remote $ \fs -> (rename fs) oldName newName author logMsg

remoteLog :: FilePath -> Remote -> [FilePath] -> TimeRange -> IO [Revision]
remoteLog repo remote names time =
    withSyncDown repo remote $ \fs -> (history fs) names time

remoteLatest :: FilePath -> Remote -> FilePath -> IO RevisionId
remoteLatest repo remote name =
    withSyncDown repo remote $ \fs -> (latest fs) name

remoteGetRevision :: FilePath -> Remote -> RevisionId -> IO Revision
remoteGetRevision repo remote revid =
    withSyncDown repo remote $ \fs -> (revision fs) revid

remoteIndex :: FilePath -> Remote -> IO [FilePath]
remoteIndex repo remote =
    withSyncDown repo remote $ index

remoteDirectory :: FilePath -> Remote -> FilePath -> IO [Resource]
remoteDirectory repo remote dir =
    withSyncDown repo remote $ \fs -> (directory fs) dir

remoteSearch :: FilePath -> Remote -> SearchQuery -> IO [SearchMatch]
remoteSearch repo remote query =
    withSyncDown repo remote $ \fs -> (search fs) query
