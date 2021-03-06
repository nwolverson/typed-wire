{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
module Main where

import TW.Ast
import TW.Check
import TW.Loader
import TW.Parser
import TW.Types
import qualified TW.CodeGen.Elm as Elm
import qualified TW.CodeGen.Haskell as HS
import qualified TW.CodeGen.PureScript as PS

import qualified Paths_typed_wire as Meta

import Development.GitRev
import Options.Applicative
import System.Directory
import System.FilePath
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Traversable as T
import qualified Data.Version as Vers

data Options
   = Options
   { o_showVersion :: Bool
   , o_sourceDirs :: [FilePath]
   , o_entryPoints :: [ModuleName]
   , o_hsOutDir :: Maybe FilePath
   , o_elmOutDir :: Maybe FilePath
   , o_psOutDir :: Maybe FilePath
   }

optParser :: Parser Options
optParser =
    Options
    <$> switch (long "version" <> help "Show version and exit")
    <*> sourceDirsP
    <*> entryPointsP
    <*> hsOutP
    <*> elmOutP
    <*> psOutP

sourceDirsP :: Parser [FilePath]
sourceDirsP =
    many $ strOption $
    long "include-dir" <> short 'i' <> metavar "DIR" <> help "Directory to search for modules"

entryPointsP :: Parser [ModuleName]
entryPointsP =
    many $ option (str >>= mkMod) $
    long "entrypoint" <> short 'e' <> metavar "MODULE-NAME" <> help "Entrypoint for compiler"
    where
      mkMod t =
          case makeModuleName (T.pack t) of
            Left _ -> fail $ "Can not parse " ++ t ++ " as module"
            Right x -> return x

hsOutP :: Parser (Maybe FilePath)
hsOutP =
    optional $ strOption $
    long "hs-out" <> metavar "DIR" <> help "Generate Haskell bindings to specified dir"

elmOutP :: Parser (Maybe FilePath)
elmOutP =
    optional $ strOption $
    long "elm-out" <> metavar "DIR" <> help "Generate Elm bindings to specified dir"

psOutP :: Parser (Maybe FilePath)
psOutP =
    optional $ strOption $
    long "purescript-out" <> metavar "DIR" <> help "Generate PureScript bindings to specified dir"

main :: IO ()
main =
    execParser opts >>= run
    where
      opts =
          info (helper <*> optParser)
          ( fullDesc
          <> progDesc "Language idependent type-safe communication"
          <> header "Generate bindings using typed-wire for different languages"
          )

showVersion :: IO ()
showVersion =
    T.putStrLn versionMessage
    where
      versionMessage =
          T.unlines
          [ "Version " <> T.pack (Vers.showVersion Meta.version)
          , "Git: " <> $(gitBranch) <> "@" <> $(gitHash)
          , " (" <> $(gitCommitCount) <> " commits in HEAD)"
          , if $(gitDirty) then " (includes uncommited changes)" else ""
          ]

run :: Options -> IO ()
run opts =
    if o_showVersion opts
    then showVersion
    else run' opts

run' :: Options -> IO ()
run' opts =
    do allModules <- loadModules (o_sourceDirs opts) (o_entryPoints opts)
       putStrLn "All modules loaded"
       case allModules of
         Left err -> fail err
         Right ok ->
             case checkModules ok of
               Left err -> fail err
               Right readyModules ->
                   do _ <- T.forM (o_hsOutDir opts) $ \dir ->
                          do T.putStrLn $
                                  "Required Haskell library is "
                                  <> li_name HS.libraryInfo <> "@" <> li_version HS.libraryInfo
                             mapM_ (runner dir HS.makeModule HS.makeFileName) readyModules
                      _ <- T.forM (o_elmOutDir opts) $ \dir ->
                          do T.putStrLn $
                                  "Required Elm library is "
                                  <> li_name Elm.libraryInfo <> " version " <> li_version Elm.libraryInfo
                             mapM_ (runner dir Elm.makeModule Elm.makeFileName) readyModules
                      _ <- T.forM (o_psOutDir opts) $ \dir ->
                          do T.putStrLn $
                                  "Required PureScript library is "
                                  <> li_name PS.libraryInfo <> " version " <> li_version PS.libraryInfo
                             mapM_ (runner dir PS.makeModule PS.makeFileName) readyModules
                      return ()

runner :: FilePath -> (Module -> T.Text) -> (ModuleName -> FilePath) -> Module -> IO ()
runner baseDir mkModule mkFilename m =
    let moduleSrc = mkModule m
        moduleFp = baseDir </> mkFilename (m_name m)
    in do createDirectoryIfMissing True (takeDirectory moduleFp)
          putStrLn $ "Writing " ++ moduleFp ++ " ..."
          T.writeFile moduleFp moduleSrc
