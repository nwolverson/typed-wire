{-# LANGUAGE OverloadedStrings #-}
module TW.CodeGen.Elm
    ( makeFileName, makeModule
    , libraryInfo
    )
where

import TW.Ast
import TW.BuiltIn
import TW.JsonRepr
import TW.Types

import Data.Maybe
import Data.Monoid
import System.FilePath
import qualified Data.List as L
import qualified Data.Text as T

jsonEncQual :: T.Text
jsonEncQual = "JE"

jsonEnc :: T.Text -> T.Text
jsonEnc x = jsonEncQual <> "." <> x

jsonDecQual :: T.Text
jsonDecQual = "JD"

jsonDec :: T.Text -> T.Text
jsonDec x = jsonDecQual <> "." <> x

makeFileName :: ModuleName -> FilePath
makeFileName (ModuleName parts) =
    (L.foldl' (</>) "" $ map T.unpack parts) ++ ".elm"

libraryInfo :: LibraryInfo
libraryInfo = LibraryInfo "elm-typed-wire-utils" "1.0.0"

makeModule :: Module -> T.Text
makeModule m =
    T.unlines
    [ "-- | This file was auto generated by typed-wire. Do not modify by hand"
    , "module " <> printModuleName (m_name m) <> " where"
    , ""
    , T.intercalate "\n" (map makeImport $ m_imports m)
    , ""
    , "import TypedWire as ELib"
    , "import List as L"
    , "import Json.Decode as " <> jsonDecQual
    , "import Json.Decode exposing ((:=))"
    , "import Json.Encode as " <> jsonEncQual
    , ""
    , T.intercalate "\n" (map makeTypeDef $ m_typeDefs m)
    ]

makeImport :: ModuleName -> T.Text
makeImport m =
    "import " <> printModuleName m

makeTypeDef :: TypeDef -> T.Text
makeTypeDef td =
    case td of
      TypeDefEnum ed ->
          makeEnumDef ed
      TypeDefStruct sd ->
          makeStructDef sd

makeStructDef :: StructDef -> T.Text
makeStructDef sd =
    T.unlines
    [ "type alias " <> fullType <> " ="
    , "   { " <> T.intercalate "\n   , " (map makeStructField $ sd_fields sd)
    , "   }"
    , ""
    , "jenc" <> unTypeName (sd_name sd) <> " : " <> encTy <> fullType <> " -> " <> jsonEnc "Value"
    , "jenc" <> unTypeName (sd_name sd) <> " = " <> jsonEnc "object" <> " << " <> "jencTuples" <> unTypeName (sd_name sd)
    , "jencTuples" <> unTypeName (sd_name sd) <> " : " <> encTy <> fullType <> " -> List (String, " <> jsonEnc "Value" <> ")"
    , "jencTuples" <> unTypeName (sd_name sd) <> " " <> encArgs <> " x ="
    , "    [ " <> T.intercalate "\n    , " (map makeToJsonFld $ sd_fields sd)
    , "    ]"
    , "jdec" <> unTypeName (sd_name sd) <> " : " <> jsonDec "Decoder" <> " (" <> fullType <> ")"
    , "jdec" <> unTypeName (sd_name sd) <> " ="
    , "    " <> T.intercalate "\n    " (map makeFromJsonFld $ sd_fields sd)
    , "    " <> jsonDec "succeed" <> " (" <> unTypeName (sd_name sd) <> " " <> funArgs <> ")"
    ]
    where
      (encTy, encArgs) =
          case sd_args sd of
            [] -> ("", "")
            _ ->
                let mkEncTy (TypeVar v) =
                        "(" <> v <> " -> " <> jsonEnc "Value" <> ")"
                in ( T.intercalate " -> " (map mkEncTy $ sd_args sd) <> " -> "
                   , T.intercalate " " (map varEnc $ sd_args sd)
                   )
      jArg fld = "j_" <> (unFieldName $ sf_name fld)
      makeFromJsonFld fld =
          let name = unFieldName $ sf_name fld
              arg = jArg fld
              (maybePrefix, decoder) =
                  case isBuiltIn (sf_type fld) of
                    Just (bi, [maybeArg]) | bi == tyMaybe ->
                        ( jsonDec "maybe" <> " "
                        , jsonDecFor maybeArg
                        )
                    _ -> ("", jsonDecFor $ sf_type fld)
              dec =
                  maybePrefix <> "(" <> T.pack (show name) <> " := " <> decoder <> ")"
          in dec <> " `" <> jsonDec "andThen" <> "` \\" <> arg <> " -> "
      makeToJsonFld fld =
          let name = unFieldName $ sf_name fld
              encoder = jsonEncFor (sf_type fld)
          in "(" <> T.pack (show name) <> ", " <> encoder <> " x." <> name <> ")"
      funArgs =
          T.intercalate " " $ map jArg (sd_fields sd)
      fullType =
          unTypeName (sd_name sd) <> " " <> T.intercalate " " (map unTypeVar $ sd_args sd)

makeStructField :: StructField -> T.Text
makeStructField sf =
    (unFieldName $ sf_name sf) <> " : " <> (makeType $ sf_type sf)

makeEnumDef :: EnumDef -> T.Text
makeEnumDef ed =
    T.unlines
    [ "type " <> fullType
    , "   = " <> T.intercalate "\n   | " (map makeEnumChoice $ ed_choices ed)
    , ""
    , "jenc" <> unTypeName (ed_name ed) <> " : " <> encTy <> fullType <> " -> " <> jsonEnc "Value"
    , "jenc" <> unTypeName (ed_name ed) <> " " <> encArgs <> " x ="
    , "    case x of"
    , "      " <> T.intercalate "\n      " (map mkToJsonChoice $ ed_choices ed)
    , "jdec" <> unTypeName (ed_name ed) <> " : " <> jsonDec "Decoder" <> " (" <> fullType <> ")"
    , "jdec" <> unTypeName (ed_name ed) <> " ="
    , "    " <> jsonDec "oneOf"
    , "    [ " <> T.intercalate "\n    , " (map mkFromJsonChoice $ ed_choices ed)
    , "    ]"
    ]
    where
      (encTy, encArgs) =
          case ed_args ed of
            [] -> ("", "")
            _ ->
                let mkEncTy (TypeVar v) =
                        "(" <> v <> " -> " <> jsonEnc "Value" <> ")"
                in ( T.intercalate " -> " (map mkEncTy $ ed_args ed) <> " -> "
                   , T.intercalate " " (map varEnc $ ed_args ed)
                   )
      mkFromJsonChoice ec =
          let constr = unChoiceName $ ec_name ec
              tag = camelTo2 '_' $ T.unpack constr
              (decoder, andThen) =
                  case ec_arg ec of
                    Nothing -> (jsonDec "bool", "\\_ -> " <> jsonDec "succeed" <> " " <> constr)
                    Just arg -> (jsonDecFor arg, "\\z -> " <> jsonDec "succeed" <> " (" <> constr <> " z)")
          in "(" <> T.pack (show tag) <> " := " <> decoder <> ") `" <> jsonDec "andThen" <> "` " <> andThen
      mkToJsonChoice ec =
          let constr = unChoiceName $ ec_name ec
              tag = camelTo2 '_' $ T.unpack constr
              (argParam, argVal, encoder) =
                  case ec_arg ec of
                    Nothing -> ("", "True", jsonEnc "bool")
                    Just arg -> ("x", "x", jsonEncFor arg)
          in constr <> " " <> argParam <> " -> "
             <> jsonEnc "object" <> "[(" <> T.pack (show tag) <>  ", " <> encoder <> " " <> argVal <> ")]"
      fullType =
          unTypeName (ed_name ed) <> " " <> T.intercalate " " (map unTypeVar $ ed_args ed)

makeEnumChoice :: EnumChoice -> T.Text
makeEnumChoice ec =
    (unChoiceName $ ec_name ec) <> fromMaybe "" (fmap ((<>) " " . makeType) $ ec_arg ec)

jsonEncFor :: Type -> T.Text
jsonEncFor t =
    case isBuiltIn t of
      Nothing ->
          case t of
            TyVar v -> varEnc v
            TyCon qt args ->
                let ty = makeQualEnc qt
                in case args of
                     [] -> ty
                     _ -> "(" <> ty <> " " <> T.intercalate " " (map jsonEncFor args) <> ")"
      Just (bi, tvars)
          | bi == tyString -> jsonEnc "string"
          | bi == tyInt -> jsonEnc "int"
          | bi == tyBool -> jsonEnc "bool"
          | bi == tyFloat -> jsonEnc "float"
          | bi == tyBytes -> "ELib.jencAsBase64"
          | bi == tyDateTime -> "ELib.jencDateTime"
          | bi == tyTime -> "ELib.jencTime"
          | bi == tyDate -> "ELib.jencDate"
          | bi == tyList ->
              case tvars of
                [arg] ->
                    "(" <> jsonEnc "list" <> " << L.map (" <> jsonEncFor arg <> "))"
                _ -> error $ "Elm: odly shaped List value"
          | bi == tyMaybe ->
              case tvars of
                [arg] -> "ELib.encMaybe (" <> jsonEncFor arg <> ")"
                _ -> error $ "Elm: odly shaped Maybe value"
          | otherwise ->
              error $ "Elm: Missing jsonEnc for built in type: " ++ show t

jsonDecFor :: Type -> T.Text
jsonDecFor t =
    case isBuiltIn t of
      Nothing ->
          case t of
            TyVar v -> varDec v
            TyCon qt args ->
                let ty = makeQualDec qt
                in case args of
                     [] -> ty
                     _ -> "(" <> ty <> " " <> T.intercalate " " (map jsonDecFor args) <> ")"
      Just (bi, tvars)
          | bi == tyString -> jsonDec "string"
          | bi == tyInt -> jsonDec "int"
          | bi == tyBool -> jsonDec "bool"
          | bi == tyFloat -> jsonDec "float"
          | bi == tyBytes -> "ELib.jdecAsBase64"
          | bi == tyDateTime -> "ELib.jdecDateTime"
          | bi == tyTime -> "ELib.jdecTime"
          | bi == tyDate -> "ELib.jdecDate"
          | bi == tyList ->
              case tvars of
                [arg] -> jsonDec "list" <> " (" <> jsonDecFor arg <> ")"
                _ -> error $ "Elm: odly shaped List value"
          | bi == tyMaybe ->
              case tvars of
                [arg] -> jsonDec "maybe" <> " (" <> jsonDecFor arg <> ")"
                _ -> error $ "Elm: odly shaped Maybe value"
          | otherwise ->
              error $ "Elm: Missing jsonDec for built in type: " ++ show t

varEnc :: TypeVar -> T.Text
varEnc (TypeVar x) = "enc_" <> x

varDec :: TypeVar -> T.Text
varDec (TypeVar x) = "dec_" <> x

makeType :: Type -> T.Text
makeType t =
    case isBuiltIn t of
      Nothing ->
          case t of
            TyVar (TypeVar x) -> x
            TyCon qt args ->
                let ty = makeQualTypeName qt
                in case args of
                     [] -> ty
                     _ -> "(" <> ty <> " " <> T.intercalate " " (map makeType args) <> ")"
      Just (bi, tvars)
          | bi == tyString -> "String"
          | bi == tyInt -> "Int"
          | bi == tyBool -> "Bool"
          | bi == tyFloat -> "Float"
          | bi == tyDateTime -> "ELib.DateTime"
          | bi == tyTime -> "ELib.Time"
          | bi == tyDate -> "ELib.Date"
          | bi == tyMaybe -> "(Maybe " <> T.intercalate " " (map makeType tvars) <> ")"
          | bi == tyList -> "(List " <> T.intercalate " " (map makeType tvars) <> ")"
          | bi == tyBytes -> "ELib.AsBase64"
          | otherwise ->
              error $ "Elm: Unimplemented built in type: " ++ show t

makeQualTypeName :: QualTypeName -> T.Text
makeQualTypeName qtn =
    case unModuleName $ qtn_module qtn of
      [] -> ty
      _ -> printModuleName (qtn_module qtn) <> "." <> ty
    where
      ty = unTypeName $ qtn_type qtn

makeQualEnc :: QualTypeName -> T.Text
makeQualEnc qtn =
    case unModuleName $ qtn_module qtn of
      [] -> "jenc" <> ty
      _ -> printModuleName (qtn_module qtn) <> ".jenc" <> ty
    where
      ty = unTypeName $ qtn_type qtn

makeQualDec :: QualTypeName -> T.Text
makeQualDec qtn =
    case unModuleName $ qtn_module qtn of
      [] -> "jdec" <> ty
      _ -> printModuleName (qtn_module qtn) <> ".jdec" <> ty
    where
      ty = unTypeName $ qtn_type qtn
