{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DuplicateRecordFields      #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedLabels           #-}
{-# LANGUAGE OverloadedLists            #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE DerivingVia                #-}
{-# LANGUAGE LambdaCase                 #-}

{-# OPTIONS_GHC -Wno-ambiguous-fields #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module IOHK.Certification.Persistence.Structure.Certification where

import           Control.Lens         hiding (index, (.=))
import           Data.Aeson
import           Data.Proxy
--import           Control.Exception ( throw)
import           Data.Swagger         hiding (Contact)
import           Database.Selda
import           Database.Selda.SqlType as Selda
import           GHC.OverloadedLabels
import           IOHK.Certification.Persistence.Structure.Profile
import           Control.Exception ( throw)
import           IOHK.Certification.Persistence.Structure.Run

import qualified Data.Aeson.KeyMap as KM

--------------------------------------------------------------------------------
-- | Certification
data CertificationLevel = L0 | L1 | L2 | L3
  deriving (Generic,Show,Read,Eq,Ord,Enum)

instance SqlType CertificationLevel where
  mkLit n = LCustom TInt64 (LInt64 (toInt64 n))
    where
    toInt64 = \case
      L0 -> 0
      L1 -> 1
      L2 -> 2
      L3 -> 3
  sqlType _ = TInt64
  fromSql (SqlInt64 0) = L0
  fromSql (SqlInt64 1) = L1
  fromSql (SqlInt64 2) = L2
  fromSql (SqlInt64 3) = L3
  fromSql v            = throw $ userError $ "fromSql: expected SqlInt64, got " ++ show v
  defaultValue = mkLit L1

instance ToJSON CertificationLevel where
  toJSON = toJSON . \case
    L0 -> "l0" :: String
    L1 -> "l1"
    L2 -> "l2"
    L3 -> "l3"

instance FromJSON CertificationLevel where
  parseJSON = withText "CertificationLevel" $ \case
    "l0" -> pure L0
    "l1" -> pure L1
    "l2" -> pure L2
    "l3" -> pure L3
    _    -> fail "CertificationLevel"

instance ToSchema CertificationLevel where
   declareNamedSchema _ = do
     let values = [ "l0", "l1", "l2", "l3" ] :: [Value]
     return $ NamedSchema (Just "CertificationLevel") $ mempty
       & type_ ?~ SwaggerString
       & enum_ ?~ values

data Certification = Certification
  { certId              :: ID Certification
  , certTransactionId   :: Text
  , certCreatedAt       :: UTCTime
  } deriving (Generic,Show)

instance IsLabel "certId" (ID Certification -> Certification -> Certification) where
  fromLabel v cert = cert { certId = v}


instance FromJSON Certification where
    parseJSON = withObject "Certification" $ \v -> Certification def
      <$> v .: "transactionId"
      <*> v .: "createdAt"

instance ToJSON Certification where
  toJSON (Certification{..}) = object
      [ "transactionId" .= certTransactionId
      , "createdAt" .= certCreatedAt
      ]

instance ToSchema Certification where
   declareNamedSchema _ = do
    textSchema <- declareSchemaRef (Proxy :: Proxy Text)
    utcSchema <- declareSchemaRef (Proxy :: Proxy UTCTime)
    return $ NamedSchema (Just "Certification") $ mempty
      & type_ ?~ SwaggerObject
      & properties .~
          [ ("transactionId", textSchema)
          , ("createdAt", utcSchema)
          ]
      & required .~ [ "createdAt" ]

instance SqlRow Certification

-- one to one mapping with Run
data L1Certification = L1Certification
  { l1CertRunId :: UUID
  , l1CertId  :: ID Certification
  } deriving (Generic,Show)

instance SqlRow L1Certification

data L1CertificationDTO = L1CertificationDTO
  { l1Certification :: L1Certification
  , certification :: Certification
  }

instance ToJSON L1CertificationDTO where
  toJSON L1CertificationDTO{..} = Object (x <> y)
    where
    x = case toJSON certification of
            Object obj -> obj
            _          -> KM.empty
    y = KM.fromList [ "runId" .= l1CertRunId l1Certification ]

instance FromJSON L1CertificationDTO where
  parseJSON = withObject "L1CertificationDTO" $ \v -> do
    l1Certification <- L1Certification
      <$> v .: "runId"
      <*> pure def
    L1CertificationDTO l1Certification <$> v .: "runId"

instance ToSchema L1CertificationDTO where
  declareNamedSchema _ = do
    certificationSchema <- declareSchema (Proxy :: Proxy Certification)
    uuidSchema <- declareSchemaRef (Proxy :: Proxy UUID)
    return $ NamedSchema (Just "L1CertificationDTO") $ certificationSchema
              & properties %~ (`mappend` [ ("certRunId", uuidSchema) ])
              & required %~  (<> [ "certRunId" ])

data Metadata = Metadata
  { metadataId :: ID Metadata
  , metadataCertId :: ID Certification
  , metadataIndex :: Int
  , metadataContent :: Text
  , metadataType :: MetadataType
  } deriving (Generic,Show)

instance SqlRow Metadata

data MetadataType = MetaIpfs | MetaUrl deriving (Generic,Show)

instance SqlType MetadataType where
  mkLit n = LCustom TInt64 (LInt64 (toInt64 n))
    where
    toInt64 = \case
      MetaIpfs -> 0
      MetaUrl -> 1
  sqlType _ = TInt64
  fromSql (SqlInt64 0) = MetaIpfs
  fromSql (SqlInt64 1) = MetaUrl
  fromSql v            = throw $ userError $ "fromSql: expected SqlInt64, got " ++ show v
  defaultValue = mkLit MetaIpfs

data CertificationAction = Certify | Audit deriving (Generic,Show)

instance SqlType CertificationAction where
  mkLit n = LCustom TInt64 (LInt64 (toInt64 n))
    where
    toInt64 = \case
      Certify -> 0
      Audit -> 1
  sqlType _ = TInt64
  fromSql (SqlInt64 0) = Certify
  fromSql (SqlInt64 1) = Audit
  fromSql v            = throw $ userError $ "fromSql: expected SqlInt64, got " ++ show v
  defaultValue = mkLit Certify

data CertificationType = CertificationType {
  typeId :: ID CertificationType,
  action :: CertificationAction,
  level :: CertificationLevel,
  issuer :: Text
} deriving (Generic,Show)

instance SqlRow CertificationType

data Algorithm = Ed25519 deriving (Generic,Show)


data OnChainCertification = OnChainCertification
  { certId  :: ID Certification               -- TODO: this has to be it's own and certificate to point here
                                              -- but for the moment we keep it like this because it allows
                                              -- us to make the onchain certification optionally
  , profileId :: ID Profile
  , subject :: Text
  , rootHash :: Text
  , schemaVersion :: Text
  , certificationTypeId :: ID CertificationType
  } deriving (Generic,Show)

data OnChainCertificationDTO = OnChainCertificationDTO
  { certification :: OnChainCertification
  , certificationType :: CertificationType
  , metadata :: [Metadata]
  }

instance SqlRow OnChainCertification

metadatas :: Table Metadata
metadatas = table "metadatas"
  [ #metadataId :- primary
  , #metadataContent :- unique
  , #metadataCertId :- foreignKey certifications #certId
  ]

certificationTypes :: Table CertificationType
certificationTypes = table "certification_types"
  [ #typeId :- primary
  ]

onChainCertifications :: Table OnChainCertification
onChainCertifications = table "onchain_certifications"
  [ #certId :- primary
  , #certId :- foreignKey certifications #certId
  , #profileId :- foreignKey profiles #profileId
  , #certificationTypeId :- foreignKey certificationTypes #typeId
  ]

certifications :: Table Certification
certifications = table "certification"
  [ #certId :- autoPrimary
  ]

l1Certifications :: Table L1Certification
l1Certifications = table "l1Certification"
  [ #l1CertRunId :- primary
  , #l1CertRunId :- foreignKey runs #runId
  , #l1CertId :- foreignKey certifications #certId
  , #l1CertId :- unique
  ]

