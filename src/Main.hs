{-# LANGUAGE OverloadedStrings, LambdaCase #-}

module Main where

import Network.Wai
import Network.HTTP.Types (status200)
import Network.Wai.Handler.Warp (run)
import qualified Data.Aeson as JSON
import Data.Int (Int32)
import Data.Text.Encoding (decodeUtf8)
import Data.Attoparsec.Text (parseOnly, endOfInput)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.ByteString.Lazy (toStrict)
import qualified Data.GraphQL.AST as AST
import Data.GraphQL.Parser (document)
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import Data.IORef
import Haxl.Prelude
import Haxl.Core

type Name = Text

-- GraphQL schema
data SchemaType
     = TString
     | TInt
     | TFloat
     | TBoolean
     | TID
     | TObject (HashMap Name SchemaType)
     | TEnum {- ... -}
     | TInterface {- ... -}
     | TUnion {- ... -}
     | TList SchemaType
     | TNonNull SchemaType

-- Is this part of the AST or the runtime representation of a value?
data Value
     = VNull
     | VInt Int32
     | VFloat Double
     | VBoolean Bool
     | VString Text
     | VEnum Text -- unquoted on parse
     | VList [Main.Value]
     | VObject (HashMap Text Main.Value)
     | VVar Name -- looked up in environment

instance JSON.ToJSON Main.Value where
  toJSON VNull = JSON.Null
  toJSON (VInt i) = JSON.toJSON i
  toJSON (VFloat f) = JSON.toJSON f
  toJSON (VBoolean b) = JSON.toJSON b
  toJSON (VString s) = JSON.toJSON s
  toJSON (VEnum n) = JSON.toJSON n
  toJSON (VList ls) = JSON.toJSON ls
  toJSON (VObject o) = JSON.toJSON o
  toJSON (VVar _) = error "Unresolved variable in JSON encoding"

data QueryParameter = QueryParameter Name SchemaType
data Query = Query Name [QueryParameter] SchemaType
data Mutation = Mutation Name [QueryParameter] SchemaType
data ServerSchema = ServerSchema [Query] [Mutation]

{-
enum DogCommand { SIT, DOWN, HEEL }

type Dog implements Pet {
  name: String!
  nickname: String
  barkVolume: Int
  doesKnowCommand(dogCommand: DogCommand!): Boolean!
  isHousetrained(atOtherHomes: Boolean): Boolean!
  owner: Human
}

interface Sentient {
  name: String!
}

interface Pet {
  name: String!
}

type Alien implements Sentient {
  name: String!
  homePlanet: String
}

type Human implements Sentient {
  name: String!
}

enum CatCommand { JUMP }

type Cat implements Pet {
  name: String!
  nickname: String
  doesKnowCommand(catCommand: CatCommand!): Boolean!
  meowVolume: Int
}

union CatOrDog = Cat | Dog
union DogOrHuman = Dog | Human
union HumanOrAlien = Human | Alien

type QueryRoot {
  dog: Dog
}
-}

{-
data ResponseValue
     = RVNull
     | VList [Main.Value]
     | VObject (HashMap Text Main.Value)
     | VVar Name -- looked up in environment
-}

data Scalar
     = SInt Int32
     | SFloat Double
     | SBoolean Bool
     | SString Text
     | SEnum Text -- unquoted on parse

instance JSON.ToJSON Scalar where
  toJSON (SInt i) = JSON.toJSON i
  toJSON (SFloat f) = JSON.toJSON f
  toJSON (SBoolean b) = JSON.toJSON b
  toJSON (SString s) = JSON.toJSON s
  toJSON (SEnum t) = JSON.toJSON t

data InputValue
     = IVar Text
     | IScalar Scalar
     | IList [InputValue]
     | IObject (HashMap Text InputValue)

data ResponseValue
     = RNull
     | RScalar Scalar
     | RList [ResponseValue]
     | RObject (HashMap Text ResponseValue)

instance JSON.ToJSON ResponseValue where
  toJSON RNull = JSON.Null
  toJSON (RScalar s) = JSON.toJSON s
  toJSON (RList l) = JSON.toJSON l
  toJSON (RObject o) = JSON.toJSON o

-- introduce a sum type: is this a record containing deeper info or a value

type TheMonad a = GenHaxl () a

data KeyResponse = NodeResponse NodeHandler | ValueResponse ResponseValue
data KeyHandler = KeyHandler (HashMap Text InputValue -> TheMonad KeyResponse)
data NodeHandler = NodeHandler (HashMap Text KeyHandler)

data Server = Server
              { rootQuery :: NodeHandler
              }

processSelectionSet :: NodeHandler -> AST.SelectionSet -> TheMonad (HashMap Text ResponseValue)
processSelectionSet (NodeHandler keyHandlers) selectionSet = do
  rv <- newIORef $ HashMap.empty
  forM_ selectionSet $ \case
    AST.SelectionField (AST.Field alias name arguments directives innerSelectionSet) -> do
      let (Just (KeyHandler keyHandler)) = HashMap.lookup name keyHandlers
      let arguments = HashMap.empty -- TODO
      outputValue <- keyHandler arguments >>= \case
        NodeResponse handler -> do
          if null innerSelectionSet then do
            fail "Must select fields of node"
          else do
            RObject <$> processSelectionSet handler innerSelectionSet
        ValueResponse value -> do
          if null innerSelectionSet then do
            -- TODO: assert not RObject
            return value
          else do
            -- TODO: assert RObject
            let (RObject m) = value
            RObject <$> processSelectionSet (NodeHandler $ fmap (KeyHandler . const . return . ValueResponse) m) innerSelectionSet
      modifyIORef rv $ HashMap.insert (if Text.null alias then name else alias) outputValue
    _ -> error "unsupported selection"
  readIORef rv

handleRequest server respond doc = do
  -- TODO: bad bad bad
  let (AST.Document defns) = doc
  let (query:_) = [node | AST.DefinitionOperation (AST.Query node) <- defns]
  putStrLn $ show query

  let AST.Node name [] [] selectionSet = query

  env <- initEnv stateEmpty ()
  output <- runHaxl env $ processSelectionSet (rootQuery server) selectionSet

  let response = HashMap.fromList [("data" :: Text, HashMap.fromList [(name, output)] )]
  respond $ responseLBS
    status200
    [("Content-Type", "application/json")]
    (JSON.encode response)



meHandler :: HashMap Text InputValue -> IO KeyResponse
meHandler _ = do
  return $ ValueResponse $ RObject $ HashMap.fromList [("name", RScalar $ SString "me!")]

app :: Application
app request respond = do
  -- TODO: check the request URL
  -- TODO: check the request method (require POST)

  body <- fmap (decodeUtf8 . toStrict) $ strictRequestBody request
  let body' = "query is_this_needed { me { name } }"

  queryDoc <- case parseOnly (document <* endOfInput) body' of
    Left err -> do
      fail $ "Error parsing query: " ++ err
    Right d -> do
      return d

  let rootQuery = NodeHandler $ HashMap.fromList
                  [ ("me", KeyHandler meHandler)
                  ]
  let server = Server rootQuery
  handleRequest server respond queryDoc

main :: IO ()
main = do
  putStrLn $ "http://localhost:8080/"
  run 8080 app
