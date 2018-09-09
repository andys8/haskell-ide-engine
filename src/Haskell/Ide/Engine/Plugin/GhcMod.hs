{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE TypeFamilies        #-}
module Haskell.Ide.Engine.Plugin.GhcMod where

import           Bag
import           Control.Monad.IO.Class
import           Control.Lens hiding (cons, children)
import           Control.Lens.Setter ((%~))
import           Control.Lens.Traversal (traverseOf)
import           Data.Aeson
#if __GLASGOW_HASKELL__ < 802
import           Data.Aeson.Types
#endif
import           Data.Function
import qualified Data.HashMap.Strict               as HM
import           Data.IORef
import           Data.List
import qualified Data.Map.Strict                   as Map
import           Data.Maybe
#if __GLASGOW_HASKELL__ < 804
import           Data.Monoid
#endif
import qualified Data.Set                          as Set
import qualified Data.Text                         as T
import qualified Data.Text.IO                      as T
import           ErrUtils
import qualified Exception                         as G
import           Name
import           GHC.Generics
import qualified GhcMod                            as GM
import qualified GhcMod.DynFlags                   as GM
import qualified GhcMod.Error                      as GM
import qualified GhcMod.Gap                        as GM
import qualified GhcMod.ModuleLoader               as GM
import qualified GhcMod.Monad                      as GM
import qualified GhcMod.SrcUtils                   as GM
import qualified GhcMod.Types                      as GM
import qualified GhcMod.Utils                      as GM
import qualified GhcMod.Exe.CaseSplit              as GM
import           Haskell.Ide.Engine.MonadFunctions
import           Haskell.Ide.Engine.MonadTypes
import           Haskell.Ide.Engine.PluginUtils
import           Haskell.Ide.Engine.Plugin.HaRe (HarePoint(..))
import qualified Haskell.Ide.Engine.Plugin.HieExtras as Hie
import           Haskell.Ide.Engine.ArtifactMap
import qualified Language.Haskell.LSP.Types        as LSP
import           Language.Haskell.Refact.API       (hsNamessRdr)

import           DynFlags
import           GHC
import           IOEnv                             as G
import           HscTypes
import           DataCon
import           TcRnTypes
import           Outputable                        (renderWithStyle, mkUserStyle, Depth(..))

-- ---------------------------------------------------------------------

ghcmodDescriptor :: PluginId -> PluginDescriptor
ghcmodDescriptor plId = PluginDescriptor
  { pluginId = plId
  , pluginName = "ghc-mod"
  , pluginDesc = "ghc-mod is a backend program to enrich Haskell programming "
              <> "in editors. It strives to offer most of the features one has come to expect "
              <> "from modern IDEs in any editor."
  , pluginCommands =
      [ PluginCommand "check" "check a file for GHC warnings and errors" checkCmd
      , PluginCommand "lint" "Check files using `hlint'" lintCmd
      , PluginCommand "info" "Look up an identifier in the context of FILE (like ghci's `:info')" infoCmd
      , PluginCommand "type" "Get the type of the expression under (LINE,COL)" typeCmd
      , PluginCommand "casesplit" "Generate a pattern match for a binding under (LINE,COL)" splitCaseCmd
      ]
  , pluginCodeActionProvider = Just codeActionProvider
  , pluginDiagnosticProvider = Nothing
  , pluginHoverProvider = Just hoverProvider
  , pluginSymbolProvider = Just symbolProvider
  }

-- ---------------------------------------------------------------------

type Diagnostics = Map.Map Uri (Set.Set Diagnostic)
type AdditionalErrs = [T.Text]

checkCmd :: CommandFunc Uri (Diagnostics, AdditionalErrs)
checkCmd = CmdSync $ \ uri ->
  setTypecheckedModule uri

-- ---------------------------------------------------------------------

lspSev :: Severity -> DiagnosticSeverity
lspSev SevWarning = DsWarning
lspSev SevError   = DsError
lspSev SevFatal   = DsError
lspSev SevInfo    = DsInfo
lspSev _          = DsInfo

-- type LogAction = DynFlags -> WarnReason -> Severity -> SrcSpan -> PprStyle -> MsgDoc -> IO ()
logDiag :: (FilePath -> FilePath) -> IORef AdditionalErrs -> IORef Diagnostics -> LogAction
logDiag rfm eref dref df _reason sev spn style msg = do
  eloc <- srcSpan2Loc rfm spn
  let msgTxt = T.pack $ renderWithStyle df msg style
  case eloc of
    Right (Location uri range) -> do
      let update = Map.insertWith Set.union uri l
            where l = Set.singleton diag
          diag = Diagnostic range (Just $ lspSev sev) Nothing (Just "ghcmod") msgTxt Nothing
      modifyIORef' dref update
    Left _ -> do
      modifyIORef' eref (msgTxt:)
      return ()

unhelpfulSrcSpanErr :: T.Text -> IdeError
unhelpfulSrcSpanErr err =
  IdeError PluginError
            ("Unhelpful SrcSpan" <> ": \"" <> err <> "\"")
            Null

srcErrToDiag :: MonadIO m
  => DynFlags
  -> (FilePath -> FilePath)
  -> SourceError -> m (Diagnostics, AdditionalErrs)
srcErrToDiag df rfm se = do
  debugm "in srcErrToDiag"
  let errMsgs = bagToList $ srcErrorMessages se
      processMsg err = do
        let sev = Just DsError
            unqual = errMsgContext err
            st = GM.mkErrStyle' df unqual
            msgTxt = T.pack $ renderWithStyle df (pprLocErrMsg err) st
        eloc <- srcSpan2Loc rfm $ errMsgSpan err
        case eloc of
          Right (Location uri range) ->
            return $ Right (uri, Diagnostic range sev Nothing (Just "ghcmod") msgTxt Nothing)
          Left _ -> return $ Left msgTxt
      processMsgs [] = return (Map.empty,[])
      processMsgs (x:xs) = do
        res <- processMsg x
        (m,es) <- processMsgs xs
        case res of
          Right (uri, diag) ->
            return (Map.insertWith Set.union uri (Set.singleton diag) m, es)
          Left e -> return (m, e:es)
  processMsgs errMsgs

myWrapper :: GM.IOish m
  => (FilePath -> FilePath)
  -> GM.GmlT m ()
  -> GM.GmlT m (Diagnostics, AdditionalErrs)
myWrapper rfm action = do
  env <- getSession
  diagRef <- liftIO $ newIORef Map.empty
  errRef <- liftIO $ newIORef []
  let setLogger df = df { log_action = logDiag rfm errRef diagRef }
      setDeferTypedHoles = setGeneralFlag' Opt_DeferTypedHoles
      ghcErrRes msg = (Map.empty, [T.pack msg])
      handlers = errorHandlers ghcErrRes (srcErrToDiag (hsc_dflags env) rfm )
      action' = do
        GM.withDynFlags (setLogger . setDeferTypedHoles) action
        diags <- liftIO $ readIORef diagRef
        errs <- liftIO $ readIORef errRef
        return (diags,errs)
  GM.gcatches action' handlers

errorHandlers :: (Monad m) => (String -> a) -> (SourceError -> m a) -> [GM.GHandler m a]
errorHandlers ghcErrRes renderSourceError = handlers
  where
      -- ghc throws GhcException, SourceError, GhcApiError and
      -- IOEnvFailure. ghc-mod-core throws GhcModError.
      handlers =
        [ GM.GHandler $ \(ex :: GM.GhcModError) ->
            return $ ghcErrRes (show ex)
        , GM.GHandler $ \(ex :: IOEnvFailure) ->
            return $ ghcErrRes (show ex)
        , GM.GHandler $ \(ex :: GhcApiError) ->
            return $ ghcErrRes (show ex)
        , GM.GHandler $ \(ex :: SourceError) ->
            renderSourceError ex
        , GM.GHandler $ \(ex :: GhcException) ->
            return $ ghcErrRes $ GM.renderGm $ GM.ghcExceptionDoc ex
        , GM.GHandler $ \(ex :: IOError) ->
            return $ ghcErrRes (show ex)
        -- , GM.GHandler $ \(ex :: GM.SomeException) ->
        --     return $ ghcErrRes (show ex)
        ]

setTypecheckedModule :: Uri -> IdeGhcM (IdeResult (Diagnostics, AdditionalErrs))
setTypecheckedModule uri =
  pluginGetFile "setTypecheckedModule: " uri $ \fp -> do
    fileMap <- GM.getMMappedFiles
    debugm $ "setTypecheckedModule: file mapping state is: " ++ show fileMap
    rfm <- GM.mkRevRedirMapFunc
    let
      ghcErrRes msg = ((Map.empty, [T.pack msg]),Nothing,Nothing)
    debugm "setTypecheckedModule: before ghc-mod"
    ((diags', errs), mtm, mpm) <- GM.gcatches
                              (GM.getModulesGhc' (myWrapper rfm) fp)
                              (errorHandlers ghcErrRes (return . ghcErrRes . show))
    debugm "setTypecheckedModule: after ghc-mod"

    canonUri <- canonicalizeUri uri
    let diags = Map.insertWith Set.union canonUri Set.empty diags'
    case (mpm,mtm) of
      (Just pm, Nothing) -> do
        debugm $ "setTypecheckedModule: Did get parsed module for: " ++ show fp
        cacheModule fp (Left pm)
        debugm "setTypecheckedModule: done"

      (_, Just tm) -> do
        debugm $ "setTypecheckedModule: Did get typechecked module for: " ++ show fp
        sess <- fmap GM.gmgsSession . GM.gmGhcSession <$> GM.gmsGet

        -- set the session before we cache the module, so that deferred
        -- responses triggered by cacheModule can access it
        modifyMTS (\s -> s {ghcSession = sess})
        cacheModule fp (Right tm)
        debugm "setTypecheckedModule: done"
        
      _ -> do
        debugm $ "setTypecheckedModule: Didn't get typechecked or parsed module for: " ++ show fp

        failModule fp

    return $ IdeResultOk (diags,errs)

-- ---------------------------------------------------------------------

lintCmd :: CommandFunc Uri T.Text
lintCmd = CmdSync $ \ uri ->
  lintCmd' uri

lintCmd' :: Uri -> IdeGhcM (IdeResult T.Text)
lintCmd' uri =
  pluginGetFile "lint: " uri $ \file ->
    fmap T.pack <$> runGhcModCommand (GM.lint GM.defaultLintOpts file)

-- ---------------------------------------------------------------------

customOptions :: Options
customOptions = defaultOptions { fieldLabelModifier = camelTo2 '_' . drop 2}

data InfoParams =
  IP { ipFile :: Uri
     , ipExpr :: T.Text
     } deriving (Eq,Show,Generic)

instance FromJSON InfoParams where
  parseJSON = genericParseJSON customOptions
instance ToJSON InfoParams where
  toJSON = genericToJSON customOptions

infoCmd :: CommandFunc InfoParams T.Text
infoCmd = CmdSync $ \(IP uri expr) ->
  infoCmd' uri expr

infoCmd' :: Uri -> T.Text -> IdeGhcM (IdeResult T.Text)
infoCmd' uri expr =
  pluginGetFile "info: " uri $ \file ->
    fmap T.pack <$> runGhcModCommand (GM.info file (GM.Expression (T.unpack expr)))

-- ---------------------------------------------------------------------
data TypeParams =
  TP { tpIncludeConstraints :: Bool
     , tpFile               :: Uri
     , tpPos                :: Position
     } deriving (Eq,Show,Generic)

instance FromJSON TypeParams where
  parseJSON = genericParseJSON customOptions
instance ToJSON TypeParams where
  toJSON = genericToJSON customOptions

typeCmd :: CommandFunc TypeParams [(Range,T.Text)]
typeCmd = CmdSync $ \(TP _bool uri pos) ->
  liftToGhc $ newTypeCmd pos uri

newTypeCmd :: Position -> Uri -> IdeM (IdeResult [(Range, T.Text)])
newTypeCmd newPos uri =
  pluginGetFile "newTypeCmd: " uri $ \fp ->
    ifCachedModule fp (IdeResultOk []) $ \tm info ->
      return $ IdeResultOk $ pureTypeCmd newPos tm info

pureTypeCmd :: Position -> GHC.TypecheckedModule -> CachedInfo -> [(Range,T.Text)]
pureTypeCmd newPos tm info =
    case mOldPos of
      Nothing -> []
      Just pos -> concatMap f (spanTypes pos)
  where
    mOldPos = newPosToOld info newPos
    typm = typeMap info
    spanTypes' pos = getArtifactsAtPos pos typm
    spanTypes pos = sortBy (cmp `on` fst) (spanTypes' pos)
    dflag = ms_hspp_opts $ pm_mod_summary $ tm_parsed_module tm
    unqual = mkPrintUnqualified dflag $ tcg_rdr_env $ fst $ tm_internals_ tm
#if __GLASGOW_HASKELL__ >= 802
    st = mkUserStyle dflag unqual AllTheWay
#else
    st = mkUserStyle unqual AllTheWay
#endif

    f (range', t) =
      case oldRangeToNew info range' of
        (Just range) -> [(range , T.pack $ GM.pretty dflag st t)]
        _ -> []

cmp :: Range -> Range -> Ordering
cmp a b
  | a `isSubRangeOf` b = LT
  | b `isSubRangeOf` a = GT
  | otherwise = EQ

isSubRangeOf :: Range -> Range -> Bool
isSubRangeOf (Range sa ea) (Range sb eb) = sb <= sa && eb >= ea


splitCaseCmd :: CommandFunc HarePoint WorkspaceEdit
splitCaseCmd = CmdSync $ \(HP uri pos) -> splitCaseCmd' uri pos

splitCaseCmd' :: Uri -> Position -> IdeGhcM (IdeResult WorkspaceEdit)
splitCaseCmd' uri newPos =
  pluginGetFile "splitCaseCmd: " uri $ \path -> do
    origText <- GM.withMappedFile path $ liftIO . T.readFile
    ifCachedModule path (IdeResultOk mempty) $ \tm info -> runGhcModCommand $
      case newPosToOld info newPos of
        Just oldPos -> do
          let (line, column) = unPos oldPos
          splitResult' <- GM.splits' path tm line column
          case splitResult' of
            Just splitResult -> do
              wEdit <- liftToGhc $ splitResultToWorkspaceEdit origText splitResult
              return $ oldToNewPositions info wEdit
            Nothing -> return mempty
        Nothing -> return mempty
  where

    -- | Transform all ranges in a WorkspaceEdit from old to new positions.
    oldToNewPositions :: CachedInfo -> WorkspaceEdit -> WorkspaceEdit
    oldToNewPositions info wsEdit =
      wsEdit
        & LSP.documentChanges %~ (>>= traverseOf (traverse . LSP.edits . traverse . LSP.range) (oldRangeToNew info))
        & LSP.changes %~ (>>= traverseOf (traverse . traverse . LSP.range) (oldRangeToNew info))

    -- | Given the range and text to replace, construct a 'WorkspaceEdit'
    -- by diffing the change against the current text.
    splitResultToWorkspaceEdit :: T.Text -> GM.SplitResult -> IdeM WorkspaceEdit
    splitResultToWorkspaceEdit originalText (GM.SplitResult replaceFromLine replaceFromCol replaceToLine replaceToCol replaceWith) =
      diffText (uri, originalText) newText IncludeDeletions
      where
        before = takeUntil (toPos (replaceFromLine, replaceFromCol)) originalText
        after = dropUntil (toPos (replaceToLine, replaceToCol)) originalText
        newText = before <> replaceWith <> after

    -- | Take the first part of text until the given position.
    -- Returns all characters before the position.
    takeUntil :: Position -> T.Text -> T.Text
    takeUntil (Position l c) txt =
      T.unlines takeLines <> takeCharacters
      where
        textLines = T.lines txt
        takeLines = take l textLines
        takeCharacters = T.take c (textLines !! c)

    -- | Drop the first part of text until the given position.
    -- Returns all characters after and including the position.
    dropUntil :: Position -> T.Text -> T.Text
    dropUntil (Position l c) txt = dropCharacters
      where
        textLines = T.lines txt
        dropLines = drop l textLines
        dropCharacters = T.drop c (T.unlines dropLines)

-- ---------------------------------------------------------------------

runGhcModCommand :: IdeGhcM a
                 -> IdeGhcM (IdeResult a)
runGhcModCommand cmd =
  (IdeResultOk <$> cmd) `G.gcatch`
    \(e :: GM.GhcModError) ->
      return $
      IdeResultFail $
      IdeError PluginError (T.pack $ "hie-ghc-mod: " ++ show e) Null

-- ---------------------------------------------------------------------

newtype TypeDef = TypeDef T.Text deriving (Eq, Show)

data FunctionSig =
  FunctionSig { fsName :: !T.Text
              , fsType :: !TypeDef
              } deriving (Eq, Show)

newtype ValidSubstitutions = ValidSubstitutions [FunctionSig] deriving (Eq, Show)

newtype Bindings = Bindings [FunctionSig] deriving (Eq, Show)

data TypedHoles =
  TypedHoles { thDiag :: LSP.Diagnostic
             , thWant :: TypeDef
             , thSubstitutions :: ValidSubstitutions
             , thBIndings :: Bindings
             } deriving (Eq, Show)

codeActionProvider :: CodeActionProvider
codeActionProvider pid docId mfp r ctx = do
  support <- clientSupportsDocumentChanges
  codeActionProvider' support pid docId mfp r ctx

codeActionProvider' :: Bool -> CodeActionProvider
codeActionProvider' supportsDocChanges _ docId _ _ context =
  let LSP.List diags = context ^. LSP.diagnostics
      terms = concatMap getRenamables diags
      renameActions = map (uncurry mkRenamableAction) terms
      redundantTerms = mapMaybe getRedundantImports diags
      redundantActions = concatMap (uncurry mkRedundantImportActions) redundantTerms
      typedHoleActions = concatMap mkTypedHoleActions (mapMaybe getTypedHoles diags)
  in return $ IdeResultOk (renameActions ++ redundantActions ++ typedHoleActions)

  where

    docUri = docId ^. LSP.uri

    mkWorkspaceEdit :: [LSP.TextEdit] -> LSP.WorkspaceEdit
    mkWorkspaceEdit es = do
      let changes = HM.singleton docUri (LSP.List es)
          docChanges = LSP.List [textDocEdit]
          textDocEdit = LSP.TextDocumentEdit docId (LSP.List es)
      if supportsDocChanges
        then LSP.WorkspaceEdit Nothing (Just docChanges)
        else LSP.WorkspaceEdit (Just changes) Nothing

    mkRenamableAction :: LSP.Diagnostic -> T.Text -> LSP.CodeAction
    mkRenamableAction diag replacement = codeAction
     where
       title = "Replace with " <> replacement
       kind = LSP.CodeActionQuickFix
       diags = LSP.List [diag]
       we = mkWorkspaceEdit [textEdit]
       textEdit = LSP.TextEdit (diag ^. LSP.range) replacement
       codeAction = LSP.CodeAction title (Just kind) (Just diags) (Just we) Nothing

    getRenamables :: LSP.Diagnostic -> [(LSP.Diagnostic, T.Text)]
    getRenamables diag@(LSP.Diagnostic _ _ _ (Just "ghcmod") msg _) = map (diag,) $ extractRenamableTerms msg
    getRenamables _ = []

    mkRedundantImportActions :: LSP.Diagnostic -> T.Text -> [LSP.CodeAction]
    mkRedundantImportActions diag modName = [removeAction, importAction]
      where
        removeAction = LSP.CodeAction "Remove redundant import"
                                    (Just LSP.CodeActionQuickFix)
                                    (Just (LSP.List [diag]))
                                    (Just removeEdit)
                                    Nothing

        removeEdit = mkWorkspaceEdit [LSP.TextEdit range ""]
        range = LSP.Range (diag ^. LSP.range . LSP.start)
                          (LSP.Position ((diag ^. LSP.range . LSP.start . LSP.line) + 1) 0)

        importAction = LSP.CodeAction "Import instances"
                                    (Just LSP.CodeActionQuickFix)
                                    (Just (LSP.List [diag]))
                                    (Just importEdit)
                                    Nothing
        --TODO: Use hsimport to preserve formatting/whitespace
        importEdit = mkWorkspaceEdit [tEdit]
        tEdit = LSP.TextEdit (diag ^. LSP.range) ("import " <> modName <> "()")

    getRedundantImports :: LSP.Diagnostic -> Maybe (LSP.Diagnostic, T.Text)
    getRedundantImports diag@(LSP.Diagnostic _ _ _ (Just "ghcmod") msg _) = (diag,) <$> extractRedundantImport msg
    getRedundantImports _ = Nothing

    mkTypedHoleActions :: TypedHoles -> [LSP.CodeAction]
    mkTypedHoleActions (TypedHoles diag (TypeDef want) (ValidSubstitutions subs) (Bindings bindings))
      | onlyErrorFuncs = substitutions <> suggestions
      | otherwise = substitutions
      where
        onlyErrorFuncs = null
                       $ map fsName subs \\ ["undefined", "error", "errorWithoutStackTrace"]
        substitutions = map mkHoleAction subs
        suggestions = map mkHoleAction bindings
        mkHoleAction (FunctionSig name (TypeDef sig)) = codeAction
          where title :: T.Text
                title = "Substitute hole (" <> want <> ") with " <> name <> " (" <> sig <> ")"
                diags = LSP.List [diag]
                edit = mkWorkspaceEdit [LSP.TextEdit (diag ^. LSP.range) name]
                kind = LSP.CodeActionQuickFix
                codeAction = LSP.CodeAction title (Just kind) (Just diags) (Just edit) Nothing


    getTypedHoles :: LSP.Diagnostic -> Maybe TypedHoles
    getTypedHoles diag@(LSP.Diagnostic _ _ _ (Just "ghcmod") msg _) =
      case extractHoleSubstitutions msg of
        Nothing -> Nothing
        Just (want, subs, bindings) -> Just $ TypedHoles diag want subs bindings
    getTypedHoles _ = Nothing

extractRenamableTerms :: T.Text -> [T.Text]
extractRenamableTerms msg
  -- Account for both "Variable not in scope" and "Not in scope"
  | "ot in scope:" `T.isInfixOf` msg = extractSuggestions msg
  | otherwise = []
  where
    extractSuggestions = map getEnclosed
                       . concatMap singleSuggestions
                       . filter isKnownSymbol
                       . T.lines
    singleSuggestions = T.splitOn "), " -- Each suggestion is comma delimited
    isKnownSymbol t = " (imported from" `T.isInfixOf` t  || " (line " `T.isInfixOf` t
    getEnclosed = T.dropWhile (== '‘')
                . T.dropWhileEnd (== '’')
                . T.dropAround (\c -> c /= '‘' && c /= '’')

extractRedundantImport :: T.Text -> Maybe T.Text
extractRedundantImport msg =
  if ("The import of " `T.isPrefixOf` firstLine || "The qualified import of " `T.isPrefixOf` firstLine)
      && " is redundant" `T.isSuffixOf` firstLine
    then Just $ T.init $ T.tail $ T.dropWhileEnd (/= '’') $ T.dropWhile (/= '‘') firstLine
    else Nothing
  where firstLine = head (T.lines msg)

extractHoleSubstitutions :: T.Text -> Maybe (TypeDef, ValidSubstitutions, Bindings)
extractHoleSubstitutions diag
  | "Found hole:" `T.isInfixOf` diag =
      let (header, subsBlock) = T.breakOn "Valid substitutions include" diag
          (foundHole, expr) = T.breakOn "In the expression:" header
          expectedType = TypeDef
                       . T.strip
                       . fst
                       . T.breakOn "\n"
                       . keepAfter "::"
                       $ foundHole
          bindingsBlock = T.dropWhile (== '\n')
                        . keepAfter "Relevant bindings include"
                        $ expr
          substitutions = extractSignatures
                        . T.dropWhile (== '\n')
                        . fromMaybe ""
                        . T.stripPrefix "Valid substitutions include"
                        $ subsBlock
          bindings = extractSignatures bindingsBlock
      in Just (expectedType, ValidSubstitutions substitutions, Bindings bindings)
  | otherwise = Nothing
  where
    keepAfter prefix = fromMaybe ""
                     . T.stripPrefix prefix
                     . snd
                     . T.breakOn prefix

    extractSignatures :: T.Text -> [FunctionSig]
    extractSignatures tBlock = map nameAndSig
                              . catMaybes
                              . gatherLastGroup
                              . mapAccumL (groupSignatures (countSpaces tBlock)) T.empty
                              . T.lines
                              $ tBlock

    countSpaces = T.length . T.takeWhile (== ' ')

    groupSignatures indentSize acc line
      | "(" `T.isPrefixOf` T.strip line = (acc, Nothing)
      | countSpaces line == indentSize && acc /= T.empty = (T.strip line, Just acc)
      | otherwise = (acc <> " " <> T.strip line, Nothing)

    gatherLastGroup :: (T.Text, [Maybe T.Text]) -> [Maybe T.Text]
    gatherLastGroup ("", groupped) = groupped
    gatherLastGroup (lastGroup, groupped) = groupped ++ [Just lastGroup]

    nameAndSig :: T.Text -> FunctionSig
    nameAndSig t = FunctionSig extractName extractSig
      where
        extractName = T.strip . fst . T.breakOn "::" $ t
        extractSig = TypeDef
                   . T.strip
                   . fst
                   . T.breakOn "(bound at"
                   . keepAfter "::"
                   $ t

-- ---------------------------------------------------------------------

hoverProvider :: HoverProvider
hoverProvider doc pos = runIdeResultT $ do
  info' <- IdeResultT $ newTypeCmd pos doc
  names' <- IdeResultT $ pluginGetFile "ghc-mod:hoverProvider" doc $ \fp ->
    ifCachedModule fp (IdeResultOk []) $ \(_ :: GHC.ParsedModule) info ->
      return $ IdeResultOk $ Hie.getSymbolsAtPoint pos info
  let
    f = (==) `on` (Hie.showName . snd)
    f' = compare `on` (Hie.showName . snd)
    names = mapMaybe pickName $ groupBy f $ sortBy f' names'
    pickName [] = Nothing
    pickName [x] = Just x
    pickName xs@(x:_) = case find (isJust . nameModule_maybe . snd) xs of
      Nothing -> Just x
      Just a -> Just a
    nnames = length names
    (info,mrange) =
      case map last $ groupBy ((==) `on` fst) info' of
        ((r,typ):_) ->
          case find ((r ==) . fst) names of
            Nothing ->
              (Just $ LSP.CodeString $ LSP.LanguageString "haskell" $ "_ :: " <> typ, Just r)
            Just (_,name)
              | nnames == 1 ->
                (Just $ LSP.CodeString $ LSP.LanguageString "haskell" $ Hie.showName name <> " :: " <> typ, Just r)
              | otherwise ->
                (Just $ LSP.CodeString $ LSP.LanguageString "haskell" $ "_ :: " <> typ, Just r)
        [] -> case names of
          [] -> (Nothing, Nothing)
          ((r,_):_) -> (Nothing, Just r)
  return $ case mrange of
    Just r -> [LSP.Hover (LSP.List $ catMaybes [info]) (Just r)]
    Nothing -> []

-- ---------------------------------------------------------------------

data Decl = Decl LSP.SymbolKind (Located RdrName) [Decl] SrcSpan
          | Import LSP.SymbolKind (Located ModuleName) [Decl] SrcSpan

symbolProvider :: Uri -> IdeDeferM (IdeResult [LSP.DocumentSymbol])
symbolProvider uri = pluginGetFile "ghc-mod symbolProvider: " uri $
  \file -> withCachedModule file (IdeResultOk []) $ \pm _ -> do
    let hsMod = unLoc $ pm_parsed_source pm
        imports = hsmodImports hsMod
        imps  = concatMap goImport imports
        decls = concatMap go $ hsmodDecls hsMod

        go :: LHsDecl GM.GhcPs -> [Decl]
        go (L l (TyClD FamDecl { tcdFam = FamilyDecl { fdLName = n } })) = pure (Decl LSP.SkClass n [] l)
        go (L l (TyClD SynDecl { tcdLName = n })) = pure (Decl LSP.SkClass n [] l)
        go (L l (TyClD DataDecl { tcdLName = n, tcdDataDefn = HsDataDefn { dd_cons = cons } })) =
          pure (Decl LSP.SkClass n (concatMap processCon cons) l)
        go (L l (TyClD ClassDecl { tcdLName = n, tcdSigs = sigs, tcdATs = fams })) =
          pure (Decl LSP.SkInterface n children l)
          where children = famDecls ++ sigDecls
                famDecls = concatMap (go . fmap (TyClD . FamDecl)) fams
                sigDecls = concatMap processSig sigs

        go (L l (ValD FunBind { fun_id = ln, fun_matches = MG { mg_alts = llms } })) =
          pure (Decl LSP.SkFunction ln wheres l)
          where
            wheres = concatMap (gomatch . unLoc) (unLoc llms)
            gomatch Match { m_grhss = GRHSs { grhssLocalBinds = lbs } } = golbs (unLoc lbs)
            golbs (HsValBinds (ValBindsIn lhsbs _ )) = concatMap (go . fmap ValD) lhsbs
            golbs _ = []

        go (L l (ValD PatBind { pat_lhs = p })) =
          map (\n -> Decl LSP.SkVariable n [] l) $ hsNamessRdr p
        go (L l (ForD ForeignImport { fd_name = n })) = pure (Decl LSP.SkFunction n [] l)
        go _ = []

        processSig :: LSig GM.GhcPs -> [Decl]
        processSig (L l (ClassOpSig False names _)) =
          map (\n -> Decl LSP.SkMethod n [] l) names
        processSig _ = []

        processCon :: LConDecl GM.GhcPs -> [Decl]
        processCon (L l ConDeclGADT { con_names = names }) =
          map (\n -> Decl LSP.SkConstructor n [] l) names
        processCon (L l ConDeclH98 { con_name = name, con_details = dets }) =
          pure (Decl LSP.SkConstructor name xs l)
          where
            f (L fl ln) = Decl LSP.SkField ln [] fl
            xs = case dets of
              RecCon (L _ rs) -> concatMap (map (f . fmap rdrNameFieldOcc)
                                            . cd_fld_names
                                            . unLoc) rs
              _ -> []

        goImport :: LImportDecl GM.GhcPs -> [Decl]
        goImport (L l ImportDecl { ideclName = lmn, ideclAs = as, ideclHiding = meis }) = pure im
          where
            im = Import imKind lmn xs l
            imKind
              | isJust as = LSP.SkNamespace
              | otherwise = LSP.SkModule
            xs = case meis of
                    Just (False, eis) -> concatMap f (unLoc eis)
                    _ -> []
            f (L l' (IEVar n)) = pure (Decl LSP.SkFunction (ieLWrappedName n) [] l')
            f (L l' (IEThingAbs n)) = pure (Decl LSP.SkClass (ieLWrappedName n) [] l')
            f (L l' (IEThingAll n)) = pure (Decl LSP.SkClass (ieLWrappedName n) [] l')
            f (L l' (IEThingWith n _ vars fields)) =
              let funcDecls = map (\n' -> Decl LSP.SkFunction (ieLWrappedName n') [] (getLoc n')) vars
                  fieldDecls = map (\f' -> Decl LSP.SkField (flSelector <$> f') [] (getLoc f')) fields
                  children = funcDecls ++ fieldDecls
                in pure (Decl LSP.SkClass (ieLWrappedName n) children l')
            f _ = []

        declsToSymbolInf :: Decl -> IdeDeferM [LSP.DocumentSymbol]
        declsToSymbolInf (Decl kind (L nl rdrName) children l) =
          declToSymbolInf' l kind nl (Hie.showName rdrName) children
        declsToSymbolInf (Import kind (L nl modName) children l) =
          declToSymbolInf' l kind nl (Hie.showName modName) children

        declToSymbolInf' :: SrcSpan -> LSP.SymbolKind -> SrcSpan -> T.Text -> [Decl] -> IdeDeferM [LSP.DocumentSymbol]
        declToSymbolInf' ss kind nss name children = do
          childrenSymbols <- concat <$> mapM declsToSymbolInf children
          case (srcSpan2Range ss, srcSpan2Range nss) of
            (Right r, Right selR) ->
              let chList = Just (LSP.List childrenSymbols)
              in return $ pure $
                LSP.DocumentSymbol name (Just "") kind Nothing r selR chList
            _ -> return childrenSymbols

    symInfs <- concat <$> mapM declsToSymbolInf (imps ++ decls)
    return $ IdeResultOk symInfs
