{-# LANGUAGE RecordWildCards #-}

module Summary (generateSummary) where

import qualified Data.Map as Map
import Control.Monad
import System.FilePath
import Data.List.Extra

import Idea
import Apply
import Hint.Type
import Hint.All
import Config.Type
import Test.Annotations


-- | A map from (hint name, hint severity, does hint support refactoring) to an example.
type BuiltinSummary = Map.Map (String, Severity, Bool) BuiltinEx

data BuiltinEx = BuiltinEx
    { builtinInp :: !String
    , builtinFrom :: !String
    , builtinTo :: !(Maybe String)
    }

-- | Generate a summary of hints, including built-in hints and YAML-configured hints
-- from @data/hlint.yaml@.
generateSummary :: [Setting] -> IO String
generateSummary settings = do
    builtinHints <- mkBuiltinSummary
    let lhsRhsHints = [hint | SettingMatchExp hint <- settings]
    return $ genBuiltinSummaryMd builtinHints lhsRhsHints

-- | The summary of built-in hints is generated by running the test cases in
-- @src/Hint/*.hs@. One entry per (hint name, severity, does it support refactoring).
mkBuiltinSummary :: IO BuiltinSummary
mkBuiltinSummary = foldM f Map.empty builtinHints
  where
    f :: BuiltinSummary -> (String, Hint) -> IO BuiltinSummary
    f summ (name, hint) = do
        let file = "src/Hint" </> name <.> "hs"
        tests <- parseTestFile file
        foldM (g hint file) summ tests

    g :: Hint -> FilePath -> BuiltinSummary -> TestCase -> IO BuiltinSummary
    g hint file summ (TestCase _ _ inp _ _) = do
        m <- parseModuleEx defaultParseFlags file (Just inp)
        let ideas = case m of
                Right m -> applyHints [] hint [m]
                Left _ -> []
        pure $ foldl' (addIdea inp) summ ideas

    addIdea :: String -> BuiltinSummary -> Idea -> BuiltinSummary
    addIdea inp summ Idea{..}
      | "Parse error" `isPrefixOf` ideaHint = summ
      | otherwise =
            let k = (ideaHint, ideaSeverity, notNull ideaRefactoring)
                v = BuiltinEx inp ideaFrom ideaTo
            -- Do not insert if the key already exists in the map. This has the effect
            -- of picking the first test case of a hint as the example in the summary.
            in Map.insertWith (curry snd) k v summ

genBuiltinSummaryMd :: BuiltinSummary -> [HintRule] -> String
genBuiltinSummaryMd builtins lhsRhs = unlines $
  [ "# Summary of Hints"
  , ""
  , "This page is auto-generated from `hlint --generate-summary`."
  , ""
  , "## Built-in Hints"
  , ""
  ]
  ++ builtinTable builtins
  ++
  [ ""
  , "## LHS/RHS hints"
  , ""
  ]
  ++ lhsRhsTable lhsRhs

row :: [String] -> [String]
row xs = ["<tr>"] ++ xs ++ ["</tr>"]

-- | Render using <code> if it is single-line, otherwise using <pre>.
haskell :: String -> [String]
haskell s
  | '\n' `elem` s = ["<pre>", s, "</pre>"]
  | otherwise = ["<code>", s, "</code>", "<br>"]

builtinTable :: BuiltinSummary -> [String]
builtinTable builtins =
  ["<table>"]
  ++ row ["<th>Hint Name</th>", "<th>Severity</th>", "<th>Support Refactoring?</th>"]
  ++ Map.foldMapWithKey showBuiltin builtins
  ++ ["</table>"]

showBuiltin :: (String, Severity, Bool) -> BuiltinEx -> [String]
showBuiltin (hint, sev, refact) BuiltinEx{..} = row1 ++ row2
  where
    row1 = row
      [ "<td rowspan=2>" ++ hint ++ "</td>"
      , "<td>" ++ show sev ++ "</td>"
      , "<td>" ++ (if refact then "Yes" else "No") ++ "</td>"
      ]
    row2 = row example
    example =
      [ "<td colspan=2>"
      , "Example:"
      ]
      ++ haskell builtinInp
      ++ ["Found:"]
      ++ haskell builtinFrom
      ++ ["Suggestion:"]
      ++ haskell to
      ++ ["</td>"]
    to = case builtinTo of
      Nothing -> ""
      Just "" -> "Perhaps you should remove it."
      Just s -> s

lhsRhsTable :: [HintRule] -> [String]
lhsRhsTable hints =
  ["<table>"]
  ++ row ["<th>Hint Name</th>", "<th>Hint</th>", "<th>Severity</th>"]
  ++ concatMap showLhsRhs hints
  ++ ["</table>"]

showLhsRhs :: HintRule -> [String]
showLhsRhs HintRule{..} = row $
  [ "<td>" ++ hintRuleName ++ "</td>"
  , "<td>"
  , "LHS:"
  ]
  ++ haskell (show hintRuleLHS)
  ++ ["RHS:"]
  ++ haskell (show hintRuleRHS)
  ++
  [ "</td>"
  , "<td>" ++ show hintRuleSeverity ++ "</td>"
  ]
