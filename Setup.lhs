#!/usr/bin/env runhaskell
> import Distribution.Simple
> import System.Process
> import System.Exit

> main = defaultMainWithHooks $ simpleUserHooks { runTests  = runTestSuite }

Run test suite.

> runTestSuite _ _ _ _ = runCommand "runghc -idist/build/autogen Tests.lhs" >>= waitForProcess >>= exitWith

