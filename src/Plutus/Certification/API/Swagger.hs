{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedLists #-}

module Plutus.Certification.API.Swagger where

import Servant.Swagger.UI
import Servant.API as Servant
import Control.Lens hiding ((.=))
import Servant.Swagger
import Data.Proxy
import Data.Swagger as SWG
import Plutus.Certification.API.Routes
import Data.Text

type UnnamedApi
     = VersionRoute
  :<|> VersionHeadRoute
  :<|> CreateRunRoute
  :<|> GetRunRoute
  :<|> AbortRunRoute
  :<|> GetLogsRoute
  :<|> GetRunsRoute
  :<|> GetCurrentProfileRoute
  :<|> UpdateCurrentProfileRoute
  :<|> CreateCertificationRoute
  :<|> GetCertificateRoute

instance (HasSwagger sub) => HasSwagger (AuthProtect  "public-key" :> sub) where
  toSwagger _ = toSwagger (Proxy :: Proxy (Servant.Header "Authorization" Text :> sub))

swaggerJson :: Swagger
swaggerJson = toSwagger (Proxy :: Proxy UnnamedApi)
  & info.title          .~ "Plutus Certification API"
  & info.(SWG.version)  .~ "1.0"
  & info.description    ?~ "This is an API for the Plutus Certification Service"
  {-& info.license        ?~ "IOG"-}
  {-& host                ?~ "localhost:9671" -}

type APIWithSwagger = SwaggerSchemaUI "swagger-ui" "swagger.json" :<|> API