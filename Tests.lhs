#!/usr/bin/env runghc

This program runs tests for the filestore modules.
Invoke it with:

    runghc -idist/build/autogen Tests.lhs

> import Data.FileStore
> import Test.HUnit
> import System.Directory (removeDirectoryRecursive)
> import Control.Monad (forM)
> import Prelude hiding (catch)
> import Control.Exception (catch)
> import Data.DateTime
> import Data.Maybe (mapMaybe)
> import System.Directory (doesFileExist)
> import System.Process
> import Data.Algorithm.Diff (DI(..))

> main = do
>   testFileStore (gitFileStore "tmp/gitfs") "Data.FileStore.Git"
>   testFileStore (darcsFileStore "tmp/darcsfs") "Data.FileStore.Darcs"
>   removeDirectoryRecursive "tmp"

> testFileStore :: FileStore -> String -> IO Counts 
> testFileStore fs fsName = do
>   putStrLn $ "**********************************"
>   putStrLn $ "Testing " ++ fsName
>   putStrLn $ "**********************************"
>   runTestTT $ TestList $ map (\(label, testFn) -> TestLabel label $ testFn fs) 
>     [ ("initialize", initializeTest)
>     , ("create resource", createTest1)
>     , ("create resource in subdirectory", createTest2)
>     , ("create resource with non-ascii name", createTest3)
>     , ("try to create resource outside repo", createTest4)
>     , ("retrieve resource", retrieveTest1)
>     , ("retrieve resource in a subdirectory", retrieveTest2)
>     , ("retrieve resource with non-ascii name", retrieveTest3)
>     , ("modify resource", modifyTest)
>     , ("delete resource", deleteTest)
>     , ("rename resource", renameTest)
>     , ("test for matching IDs", matchTest)
>     , ("history and revision", historyTest)
>     , ("diff", diffTest)
>     , ("search", searchTest)
>     ]

> testAuthor :: Author
> testAuthor = Author "Test Suite" "suite@test.org"

> testContents :: String
> testContents = "Test contents.\nSecond line.\nThird test line with some Greek αβ."

> testTitle :: String
> testTitle = "New resource.txt"

> subdirTestTitle :: String
> subdirTestTitle = "subdir/Subdir title.txt"

> nonasciiTestTitle :: String
> nonasciiTestTitle = "αβγ"

*** Initialize a repository, check for empty index, and then try to initialize again
*** in the same directory (should raise an error):

> initializeTest fs = TestCase $ do
>   initialize fs
>   ind <- index fs
>   assertEqual "index of just-initialized repository" ind []
>   catch (initialize fs >> assertFailure "did not return error for existing repository") $
>     \e -> assertEqual "error status from existing repository" e RepositoryExists

*** Create a resource, and check to see that latest returns a revision ID for it:

> createTest1 fs = TestCase $ do
>   create fs testTitle testAuthor "description of change" testContents
>   revid <- latest fs testTitle
>   assertBool "revision returns a revision after create" (not (null revid))

*** Create a resource in a subdirectory, and check to see that revision returns a revision for it:

> createTest2 fs = TestCase $ do
>   create fs subdirTestTitle testAuthor "description of change" testContents
>   revid <- latest fs testTitle
>   assertBool "revision returns a revision after create" (not (null revid))

*** Create a resource with a non-ascii title, and check to see that revision returns a revision for it:

> createTest3 fs = TestCase $ do
>   create fs nonasciiTestTitle testAuthor "description of change" testContents
>   revid <- latest fs testTitle
>   assertBool "revision returns a revision after create" (not (null revid))

*** Try to create a resource outside the repository (should fail with an error and NOT write the file):

> createTest4 fs = TestCase $ do
>   catch (create fs "../oops" testAuthor "description of change" testContents >>
>          assertFailure "did not return error from create ../oops") $
>          \e -> assertEqual "error from create ../oops" IllegalResourceName e 
>   exists <- doesFileExist "tmp/oops"
>   assertBool "file ../oops was created outside repository" (not exists)

*** Retrieve latest version of a resource:

> retrieveTest1 fs = TestCase $ do
>   cont <- retrieve fs testTitle Nothing
>   assertEqual "contents returned by retrieve" testContents cont 

*** Retrieve latest version of a resource (in a subdirectory):

> retrieveTest2 fs = TestCase $ do
>   cont <- retrieve fs subdirTestTitle Nothing
>   assertEqual "contents returned by retrieve" testContents cont 

*** Retrieve latest version of a resource with a nonascii name:

> retrieveTest3 fs = TestCase $ do
>   cont <- retrieve fs nonasciiTestTitle Nothing
>   assertEqual "contents returned by retrieve" testContents cont 

*** Modify a resource:

> modifyTest fs = TestCase $ do

    Modify a resource.  Should return Right ().

>   revid <- latest fs testTitle
>   let modifiedContents = unlines $ take 2 $ lines testContents
>   modResult <- modify fs testTitle revid testAuthor "removed third line" modifiedContents
>   assertEqual "results of modify" (Right ()) modResult

    Now retrieve the contents and make sure they were changed.

>   modifiedContents' <- retrieve fs testTitle Nothing
>   newRevId <- latest fs testTitle
>   newRev <- revision fs newRevId
>   assertEqual "retrieved contents after modify" modifiedContents' modifiedContents

    Now try to modify again, using the old revision as base.  This should result in a merge with conflicts.

>   modResult2 <- modify fs testTitle revid testAuthor "modified from old version" (testContents ++ "\nFourth line")
>   let normModResult2 = Left (MergeInfo {mergeRevision = newRev, mergeConflicts = True, mergeText =
>                         "Test contents.\nSecond line.\n<<<<<<< edited\nThird test line with some Greek \945\946.\nFourth line\n=======\n>>>>>>> " ++
>                         newRevId ++ "\n"})
>   assertEqual "results of modify from old version" normModResult2 modResult2

    Now try it again, still using the old version as base, but with contents of the new version.
    This should result in a merge without conflicts.

>   modResult3 <- modify fs testTitle revid testAuthor "modified from old version" modifiedContents
>   let normModResult3 = Left (MergeInfo {mergeRevision = newRev, mergeConflicts = False, mergeText = modifiedContents})
>   assertEqual "results of modify from old version with new version's contents" normModResult3 modResult3

    Now try modifying again, this time using the new version as base. Should succeed with Right ().

>   modResult4 <- modify fs testTitle newRevId testAuthor "modified from new version" (modifiedContents ++ "\nThird line")
>   assertEqual "results of modify from new version" (Right ()) modResult4 

*** Delete a resource:

> deleteTest fs = TestCase $ do

    Create a file and verify that it's there.

>   let toBeDeleted = "Aaack!"
>   create fs toBeDeleted testAuthor "description of change" testContents
>   ind <- index fs
>   assertBool "index contains resource to be deleted" (toBeDeleted `elem` ind) 

    Now delete it and verify that it's gone.

>   delete fs toBeDeleted testAuthor "goodbye"
>   ind <- index fs
>   assertBool "index does not contain resource that was deleted" (not (toBeDeleted `elem` ind))

*** Rename a resource:

> renameTest fs = TestCase $ do

    Create a file and verify that it's there.

>   let oldName = "Old Name"
>   let newName = "newdir/New Name.txt"
>   create fs oldName testAuthor "description of change" testContents
>   ind <- index fs
>   assertBool "index contains old name" (oldName `elem` ind) 
>   assertBool "index does not contain new name" (newName `notElem` ind)

    Now rename it and verify that it changed names.

>   rename fs oldName newName testAuthor "rename"
>   ind <- index fs
>   assertBool "index does not contain old name" (oldName `notElem` ind) 
>   assertBool "index contains new name" (newName `elem` ind)

    Try renaming a file that doesn't exist.

>   catch (rename fs "nonexistent file" "other name" testAuthor "rename" >>
>       assertFailure "rename of nonexistent file did not throw error") $
>       \e -> assertEqual "error status from rename of nonexistent file" NotFound e

*** Test history and revision

> historyTest fs = TestCase $ do

    Get history for three files

>   hist <- history fs [testTitle, subdirTestTitle, nonasciiTestTitle] (TimeRange Nothing Nothing)
>   assertBool "history is nonempty" (not (null hist))
>   now <- getCurrentTime
>   rev <- latest fs testTitle >>= revision fs  -- get latest revision
>   assertBool "history contains latest revision" (rev `elem` hist)
>   assertEqual "revAuthor" testAuthor (revAuthor rev)
>   assertBool "revId non-null" (not (null (revId rev)))
>   assertBool "revDescription non-null" (not (null (revDescription rev)))
>   assertEqual "revChanges" [Modified testTitle] (revChanges rev)
>   let revtime = revDateTime rev
>   histNow <- history fs [testTitle] (TimeRange (Just $ addMinutes (60 * 24) now) Nothing)
>   assertBool "history from now + 1 day onwards is empty" (null histNow)

*** Test diff

> diffTest fs = TestCase $ do

  Create a file and modiy it.

>   let diffTitle = "difftest.txt"
>   create fs diffTitle testAuthor "description of change" testContents
>   save fs diffTitle testAuthor "removed a line" (unlines . init . lines $ testContents)

>   [secondrev, firstrev] <- history fs [diffTitle] (TimeRange Nothing Nothing)
>   diff' <- diff fs diffTitle (Just $ revId firstrev) (Just $ revId secondrev)
>   let subtracted' = mapMaybe (\(d,s) -> if d == F then Just (concat s) else Nothing) diff'
>   assertEqual "subtracted lines" [last (lines testContents)] subtracted'

    Diff from Nothing should be diff from empty document.

>   diff'' <- diff fs diffTitle Nothing (Just $ revId firstrev)
>   let added'' = mapMaybe (\(d,s) -> if d == S then Just (concat s) else Nothing) diff''
>   assertEqual "added lines from empty document to first revision" [testContents] added''

    Diff to Nothing should be diff to latest.

>   diff''' <- diff fs diffTitle (Just $ revId firstrev) Nothing
>   assertEqual "diff from first revision to latest" diff' diff'''

*** Test search

> searchTest fs = TestCase $ do

    Search for "bing"

>   create fs "foo" testAuthor "my 1st search test doc" "bing\nbong\nbang\nφ"
>   create fs "bar" testAuthor "my 2nd search test doc" "bing BONG" 
>   create fs "baz" testAuthor "my 3nd search test doc" "bingbang\nbong"

    Search for "bing" with whole-word matches.

>   res1 <- search fs SearchQuery{queryPatterns = ["bing"], queryWholeWords = True, queryMatchAll = True, queryIgnoreCase = True}
>   assertEqual "search results 1" [SearchMatch "bar" 1 "bing BONG", SearchMatch "foo" 1 "bing"] res1

    Search for regex "BONG" case-sensitive.

>   res2 <- search fs SearchQuery{queryPatterns = ["BONG"], queryWholeWords = True, queryMatchAll = True, queryIgnoreCase = False}
>   assertEqual "search results 2" [SearchMatch "bar" 1 "bing BONG"] res2

    Search for "bong" and "φ"

>   res3 <- search fs SearchQuery{queryPatterns = ["bong", "φ"], queryWholeWords = True, queryMatchAll = True, queryIgnoreCase = True}
>   assertEqual "search results 3" [SearchMatch "foo" 2 "bong", SearchMatch "foo" 4 "φ"] res3

    Search for "bong" and "φ" but without match-all set

>   res4 <- search fs SearchQuery{queryPatterns = ["bong", "φ"], queryWholeWords = True, queryMatchAll = False, queryIgnoreCase = True}
>   assertEqual "search results 4" [SearchMatch "bar" 1 "bing BONG", SearchMatch "baz" 2 "bong", SearchMatch "foo" 2 "bong", SearchMatch "foo" 4 "φ"] res4

    Search for "bing" but without whole-words set

>   res5 <- search fs SearchQuery{queryPatterns = ["bing"], queryWholeWords = False, queryMatchAll = True, queryIgnoreCase = True}
>   assertEqual "search results 5" [SearchMatch "bar" 1 "bing BONG", SearchMatch "baz" 1 "bingbang", SearchMatch "foo" 1 "bing"] res5

*** Test IDs match

> matchTest fs = TestCase $ do

>   assertBool "match with two identical IDs" (idsMatch fs "abcde" "abcde")
>   assertBool "match with nonidentical but matching IDs" (idsMatch fs "abcde" "abcde5553")
>   assertBool "non-match" (not (idsMatch fs "abcde" "abedc"))

