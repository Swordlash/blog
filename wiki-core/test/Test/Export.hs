-- | The export archive ("Wiki.Core.Export") as files, without a zip file:
-- a wiki written as the tree of version 2 and read back as it was, where
-- each record and each file is in that tree, how slugs and attachment names
-- become safe file names, how comments' authors are matched by login, an
-- archive of version 1 read as the same wiki, and what a reader refuses.
module Test.Export (spec) where

import Data.Aeson (Value (..), decodeStrict', toJSON)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Protolude
import Test.Hspec
import Test.QuickCheck (elements, forAll, listOf, property, (==>))
import Wiki.Core.Access (Access (..))
import Wiki.Core.Anchor (Anchor (..))
import Wiki.Core.Attachment (Attachment (..), Source (..))
import Wiki.Core.Comment (Comment (..), Thread (..), absentAuthor, formerAuthor)
import Wiki.Core.Export
import Wiki.Core.Id
import Wiki.Core.Order (ChildOrder (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Permission (GlobalGrant (..), GlobalPermission (..), Grants (..), SpaceGrant (..), SpacePermission (..), Subject (..))
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.Space (Icon (..), Space (..))
import Wiki.Core.User (Group (..), Login (..), User (..))
import Wiki.Core.Version (Author (..))

at :: Integer -> UTCTime
at minutes = addUTCTime (fromIntegral (minutes * 60)) (UTCTime (fromGregorian 2026 10 1) 0)

slug :: Text -> Slug
slug t = either (panic . show) identity (mkSlug t)

alice, bob, administrator :: User
alice = User {id = UserId "u1", login = Login "alice", displayName = "Alice"}
bob = User {id = UserId "u2", login = Login "bob", displayName = "Bob"}

-- | A comment author who is not among the users, as the server's
-- administrator is not.
administrator = User {id = UserId "~administrator", login = Login "administrator", displayName = "Administrator"}

spaceOf :: Text -> Maybe Text -> Text -> Space
spaceOf i parent s =
  Space
    { id = SpaceId i
    , name = "The " <> s
    , slug = slug s
    , parent = SpaceId <$> parent
    , public = False
    , mathMacros = ""
    , createdAt = at 0
    , position = 0
    , subspaceOrder = ByName
    , pageOrder = ByName
    , homePage = Nothing
    , icon = Nothing
    , description = ""
    , blog = False
    }

pageOf :: Text -> Text -> Maybe Text -> Text -> Text -> Page
pageOf i s parent sl body =
  Page
    { id = PageId i
    , space = SpaceId s
    , parent = PageId <$> parent
    , title = "Title of " <> sl
    , slug = slug sl
    , body
    , attachments = []
    , createdAt = at 1
    , updatedAt = at 2
    , position = 0
    , template = False
    }

-- | An attachment whose bytes the wiki keeps, under a blob named for it.
kept :: Text -> Text -> Attachment
kept i name = Attachment {id = AttachmentId i, name, mediaType = "application/octet-stream", size = fromIntegral (BS.length (bytesOf i)), source = SourceBlob (BlobId ("blob-" <> i))}

bytesOf :: Text -> ByteString
bytesOf i = "bytes of " <> encodeUtf8 i

-- | A comment by an author, at a minute.
said :: Text -> Text -> Author -> Integer -> Comment
said thread i author minute = Comment {id = CommentId i, thread = CommentThreadId thread, author, body = "Said " <> i, createdAt = at minute, editedAt = Nothing}

as :: User -> Author
as u = Author {id = u.id, name = u.displayName}

-- | A wiki with some of everything: spaces and pages three deep, slugs that
-- are Windows device names, a page whose slug is @pages@, attachments of
-- both kinds with names no file system takes as they are, an icon, and
-- comments with replies by users, by an author who is not a user, and by
-- one kept by their name only.
wiki :: Archive
wiki =
  Archive
    { createdAt = at 100
    , app = "the tests"
    , users = [alice, bob]
    , groups = [Group {id = GroupId "g1", name = "Writers"}]
    , membership = Map.fromList [(GroupId "g1", Set.fromList [alice.id])]
    , grants =
        Grants
          { global = [GlobalGrant {subject = SubjectUser alice.id, permission = Administer}]
          , spaces = [SpaceGrant {space = SpaceId "s1", subject = SubjectGroup (GroupId "g1"), permission = Edit}]
          , access = Open
          }
    , spaces =
        [ (spaceOf "s1" Nothing "docs") {icon = Just (IconImage (BlobId "blob-icon") "image/png"), homePage = Just (PageId "p1"), description = "Guides.", mathMacros = "\\def\\x{1}"}
        , spaceOf "s2" (Just "s1") "con"
        , spaceOf "s3" Nothing "nul"
        , (spaceOf "s4" (Just "s2") "aux") {pageOrder = ByHand, createdAt = at 5}
        ]
    , pages =
        [ (pageOf "p1" "s1" Nothing "intro" "# Intro\r\n\nZażółć gęślą jaźń.\n")
            { attachments =
                [ kept "x1" "a/b:c?.txt"
                , Attachment {id = AttachmentId "x2", name = "web.png", mediaType = "image/png", size = 10, source = SourceUrl "https://example.com/web.png"}
                , kept "x3" "con.txt"
                , kept "x4" ".."
                , kept "x5" "żółw. "
                , kept "x6" "100%"
                ]
            }
        , pageOf "p2" "s1" (Just "p1") "prn" "Under the intro."
        , (pageOf "p3" "s1" (Just "p2") "deep" "") {position = 3, template = True}
        , pageOf "p4" "s4" Nothing "page" "In a space three deep."
        , pageOf "p5" "s2" Nothing "pages" "A page called pages."
        ]
    , threads =
        Map.fromList
          [
            ( PageId "p1"
            ,
              [ Thread
                  { id = CommentThreadId "t1"
                  , page = PageId "p1"
                  , anchor = Just Anchor {exact = "gęślą", prefix = "Zażółć ", suffix = " jaźń"}
                  , resolved = True
                  , createdAt = at 10
                  , comments =
                      [ said "t1" "c1" (as alice) 10
                      , (said "t1" "c2" (as bob) 11) {editedAt = Just (at 12)}
                      , said "t1" "c3" (as administrator) 13
                      , said "t1" "c4" (absentAuthor (formerAuthor "Carol")) 14
                      ]
                  }
              , Thread {id = CommentThreadId "t2", page = PageId "p1", anchor = Nothing, resolved = False, createdAt = at 20, comments = [said "t2" "c5" (as bob) 20]}
              ]
            )
          , (PageId "p2", [Thread {id = CommentThreadId "t3", page = PageId "p2", anchor = Nothing, resolved = False, createdAt = at 30, comments = [said "t3" "c6" (as alice) 30]}])
          ]
    , commentAuthors = [administrator]
    , blobs = Map.fromList ((BlobId "blob-icon", "PNG image") : [(BlobId ("blob-" <> i), bytesOf i) | i <- ["x1", "x3", "x4", "x5", "x6"]])
    , audit = []
    }

files :: Map Text ByteString
files = Map.fromList (writeArchive wiki)

-- | A JSON file's object, or nothing.
objectAt :: Text -> Map Text ByteString -> Maybe (KeyMap.KeyMap Value)
objectAt path fs = case decodeStrict' =<< Map.lookup path fs of
  Just (Object o) -> Just o
  _ -> Nothing

refused :: (HasCallStack) => Text -> Either Text a -> Expectation
refused saying = \case
  Left why -> (saying, saying `T.isInfixOf` why) `shouldBe` (saying, True)
  Right _ -> expectationFailure ("expected a refusal saying " <> show saying)

-- | The files of version 1 for a wiki without comments, as version 1 wrote
-- them: a file per kind of record, the attachments' bytes under their ids
-- and the icons' under their spaces' ids.
version1 :: Archive -> Map Text ByteString
version1 a =
  Map.fromList $
    [ ("manifest.json", encodeJson (Object (KeyMap.fromList [("format", String "wiki-export"), ("formatVersion", toJSON (1 :: Int)), ("createdAt", toJSON a.createdAt), ("app", String a.app)])))
    , ("users.json", encodeJson (map encodeUser a.users))
    , ("groups.json", encodeJson [encodeGroup g (Map.findWithDefault mempty g.id a.membership) | g <- a.groups])
    , ("grants.json", encodeJson (encodeGrants a.grants))
    , ("spaces.json", encodeJson (map encodeSpace a.spaces))
    , ("pages.json", encodeJson (map encodePage a.pages))
    , ("attachments.json", encodeJson [encodeAttachment p.id x | p <- a.pages, x <- p.attachments])
    ]
      <> [("attachments/" <> x.id.text <> "/" <> x.name, bytes) | p <- a.pages, x <- p.attachments, SourceBlob b <- [x.source], Just bytes <- [Map.lookup b a.blobs]]
      <> [("icons/" <> s.id.text, bytes) | s <- a.spaces, Just (IconImage b _) <- [s.icon], Just bytes <- [Map.lookup b a.blobs]]

spec :: Spec
spec = describe "Wiki.Core.Export" $ do
  it "reads a wiki back from its files as it was" $
    readArchive files `shouldBe` Right wiki

  it "reads two attachments that share a blob, as the server keeps them, and refuses their files when they differ" $ do
    let copy = Attachment {id = AttachmentId "x7", name = "copy.txt", mediaType = "text/plain", size = fromIntegral (BS.length (bytesOf "x1")), source = SourceBlob (BlobId "blob-x1")}
        shared = wiki {pages = [if p.id == PageId "p2" then p {attachments = [copy]} else p | p <- wiki.pages]}
        sharedFiles = Map.fromList (writeArchive shared)
        copyFile = "spaces/docs/pages/intro/pages/prn_/attachments/copy.txt"
    Map.lookup copyFile sharedFiles `shouldBe` Just (bytesOf "x1")
    readArchive sharedFiles `shouldBe` Right shared
    refused "Two files hold the blob \"blob-x1\", with different bytes." (readArchive (Map.insert copyFile (BS.map (+ 1) (bytesOf "x1")) sharedFiles))

  describe "the tree of version 2" $ do
    it "writes the manifest of version 2, the people and the grants, and no flat file of version 1" $ do
      (\o -> KeyMap.lookup "formatVersion" o) <$> objectAt "manifest.json" files `shouldBe` Just (Just (toJSON (2 :: Int)))
      filter (`Map.member` files) ["users.json", "groups.json", "grants.json"] `shouldBe` ["users.json", "groups.json", "grants.json"]
      filter (`Map.member` files) ["spaces.json", "pages.json", "attachments.json", "audit.json"] `shouldBe` []

    it "puts each space in its parent's directory, and each page in its parent's, by slug" $ do
      let present =
            [ "spaces/docs/space.json"
            , "spaces/docs/pages/intro/page.json"
            , "spaces/docs/pages/intro/pages/prn_/page.json"
            , "spaces/docs/pages/intro/pages/prn_/pages/deep/page.json"
            , "spaces/docs/spaces/con_/space.json"
            , "spaces/docs/spaces/con_/pages/pages/page.json"
            , "spaces/docs/spaces/con_/spaces/aux_/space.json"
            , "spaces/docs/spaces/con_/spaces/aux_/pages/page/page.json"
            , "spaces/nul_/space.json"
            ]
      filter (`Map.notMember` files) present `shouldBe` []
      length [p | p <- Map.keys files, "/space.json" `T.isSuffixOf` p] `shouldBe` 4
      length [p | p <- Map.keys files, "/page.json" `T.isSuffixOf` p] `shouldBe` 5

    it "writes a space's record without its parent, and its icon's image beside it" $ do
      let record = objectAt "spaces/docs/spaces/con_/space.json" files
      KeyMap.member "parent" <$> record `shouldBe` Just False
      (\o -> KeyMap.lookup "slug" o) <$> record `shouldBe` Just (Just (String "con"))
      Map.lookup "spaces/docs/icon.png" files `shouldBe` Just "PNG image"

    it "writes a page's body as page.md, byte for byte, and its record without its space, parent and body" $ do
      Map.lookup "spaces/docs/pages/intro/page.md" files `shouldBe` Just (encodeUtf8 "# Intro\r\n\nZażółć gęślą jaźń.\n")
      Map.lookup "spaces/docs/pages/intro/pages/prn_/pages/deep/page.md" files `shouldBe` Just ""
      let record = objectAt "spaces/docs/pages/intro/pages/prn_/page.json" files
      [KeyMap.member field <$> record | field <- ["space", "parent", "body"]] `shouldBe` [Just False, Just False, Just False]

    it "writes each attachment's bytes under a file name a file system takes, and a web one only in the record" $ do
      let dir = "spaces/docs/pages/intro/attachments/"
      [p | p <- Map.keys files, dir `T.isPrefixOf` p]
        `shouldMatchList` map (dir <>) ["a%2Fb%3Ac%3F.txt", "%63on.txt", "%2E%2E", "żółw.%20", "100%25"]
      Map.lookup (dir <> "a%2Fb%3Ac%3F.txt") files `shouldBe` Just (bytesOf "x1")

    it "writes a page's comments beside it, only for a page that has some" $ do
      [p | p <- Map.keys files, "comments.json" `T.isSuffixOf` p]
        `shouldMatchList` ["spaces/docs/pages/intro/comments.json", "spaces/docs/pages/intro/pages/prn_/comments.json"]

    it "names each comment's author by id, login and name, or by name only" $ do
      let authors = case decodeStrict' =<< Map.lookup "spaces/docs/pages/intro/comments.json" files of
            Just (Array threads) -> [author | Object t <- toList threads, Just (Array cs) <- [KeyMap.lookup "comments" t], Object c <- toList cs, Just (Object author) <- [KeyMap.lookup "author" c]]
            _ -> []
          field name o = KeyMap.lookup name o
      [(field "login" o, field "displayName" o) | o <- authors]
        `shouldBe` [ (Just (String "alice"), Just (String "Alice"))
                   , (Just (String "bob"), Just (String "Bob"))
                   , (Just (String "administrator"), Just (String "Administrator"))
                   , (Nothing, Just (String "Carol"))
                   , (Just (String "bob"), Just (String "Bob"))
                   ]

  describe "file names" $ do
    it "keeps a slug that every file system takes, and marks a Windows device name" $
      map safeDirectoryName ["docs", "a-1", "con", "lpt9", "console", "com10"] `shouldBe` ["docs", "a-1", "con_", "lpt9_", "console", "com10"]

    it "escapes what a file system refuses in an attachment's name, and keeps the rest" $
      map safeFileName ["report.pdf", "Zażółć.png", "a/b\\c", "x*y?z", "<|>\"", ".", "..", "...", "a.", "a ", "AUX.txt", "aux", "", "50%", "tab\there"]
        `shouldBe` ["report.pdf", "Zażółć.png", "a%2Fb%5Cc", "x%2Ay%3Fz", "%3C%7C%3E%22", "%2E", "%2E%2E", "%2E%2E%2E", "a%2E", "a%20", "%41UX.txt", "%61ux", "%", "50%25", "tab%09here"]

    it "never gives two names the same file name, nor one a file system refuses" $
      let gen = T.pack <$> listOf (elements "aAcnoux1. %/\\:*?\"<>|\t\x00f3")
       in property $ forAll gen $ \x -> forAll gen $ \y ->
            let fx = safeFileName x
             in x /= y ==> fx /= safeFileName y && not (T.any (`elem` ("/\\:*?\"<>|\t" :: [Char])) fx) && fx `notElem` [".", ".."] && not (T.null fx)

  describe "comments' authors" $ do
    it "are matched by login with the users of the wiki that imports them, and are otherwise kept by name" $ do
      let elsewhere = [User {id = UserId "x-alice", login = Login "alice", displayName = "Alice Elsewhere"}, User {id = UserId "x-root", login = Login "administrator", displayName = "Root"}]
          authors = [(c.author.id, c.author.name) | ts <- Map.elems (threadsAmong elsewhere wiki), t <- ts, c <- t.comments]
      authors
        `shouldBe` [ (UserId "x-alice", "Alice Elsewhere")
                   , (UserId "~former:Bob", "Bob (not a user here)")
                   , (UserId "x-root", "Root")
                   , (UserId "~former:Carol", "Carol (not a user here)")
                   , (UserId "~former:Bob", "Bob (not a user here)")
                   , (UserId "x-alice", "Alice Elsewhere")
                   ]

    it "are the archive's users, by login, in a wiki that takes the archive's users" $
      threadsAmong wiki.users wiki `shouldBe` Map.map (map (\t -> t {comments = map (\c -> if c.author.id == administrator.id then c {author = absentAuthor (formerAuthor "Administrator")} else c) t.comments})) wiki.threads

    it "are read by login, whatever id the record gives, and by name when the login matches nobody" $ do
      let path = "spaces/docs/pages/intro/pages/prn_/comments.json"
          record = "[{\"id\": \"t3\", \"comments\": [{\"id\": \"c6\", \"author\": {\"id\": \"elsewhere-7\", \"login\": \"alice\", \"displayName\": \"Al\"}, \"body\": \"Hi\", \"createdAt\": \"2026-10-01T00:30:00Z\"}, {\"id\": \"c7\", \"author\": {\"id\": \"u2\", \"displayName\": \"Not Bob\"}, \"body\": \"Hey\", \"createdAt\": \"2026-10-01T00:31:00Z\"}, {\"id\": \"c8\", \"author\": {\"displayName\": \"Dave\"}, \"body\": \"Ho\", \"createdAt\": \"2026-10-01T00:32:00Z\"}]}]"
      case readArchive (Map.insert path record files) of
        Left why -> expectationFailure (toS why)
        Right back -> do
          [(c.author, c.body) | t <- Map.findWithDefault [] (PageId "p2") back.threads, c <- t.comments]
            `shouldBe` [(as alice, "Hi"), (absentAuthor (formerAuthor "Not Bob"), "Hey"), (absentAuthor (formerAuthor "Dave"), "Ho")]
          (\t -> t.createdAt) <$> head (Map.findWithDefault [] (PageId "p2") back.threads) `shouldBe` Just (at 30)

  describe "version 1" $ do
    let flat = wiki {threads = mempty, commentAuthors = []}
    it "is read as the same wiki, with no comments" $
      readArchive (version1 flat) `shouldBe` Right flat

    it "is still checked as it was, naming its files" $ do
      let orphan = flat {pages = flat.pages <> [pageOf "p9" "s-nowhere" Nothing "lost" ""]}
      refused "pages.json: the page \"p9\" is in the space \"s-nowhere\", which is not in the archive." (readArchive (version1 orphan))
      refused "It has no pages.json." (readArchive (Map.delete "pages.json" (version1 flat)))

  describe "compatibility" $ do
    it "reads files and fields it does not know, ignoring them" $ do
      let extra = Map.insert "spaces/docs/notes.txt" "notes" (Map.insert "spaces/docs/space.json" (encodeJson (Object (KeyMap.insert "colour" (String "teal") (fromMaybe mempty (objectAt "spaces/docs/space.json" files))))) files)
      readArchive extra `shouldBe` Right wiki

    it "reads a page without page.md as empty, and a space without createdAt as made with its first page" $ do
      let thin =
            Map.delete "spaces/docs/spaces/con_/spaces/aux_/pages/page/page.md" $
              Map.adjust (\b -> maybe b (encodeJson . Object . KeyMap.delete "createdAt") (objectAt "spaces/docs/spaces/con_/spaces/aux_/space.json" files)) "spaces/docs/spaces/con_/spaces/aux_/space.json" files
      case readArchive thin of
        Left why -> expectationFailure (toS why)
        Right back -> do
          [p.body | p <- back.pages, p.id == PageId "p4"] `shouldBe` [""]
          [s.createdAt | s <- back.spaces, s.id == SpaceId "s4"] `shouldBe` [at 1]

    it "refuses an archive of a newer version, saying so" $ do
      let newer = Map.insert "manifest.json" (encodeJson (Object (KeyMap.insert "formatVersion" (toJSON (3 :: Int)) (fromMaybe mempty (objectAt "manifest.json" files))))) files
      refused "newer version of the wiki" (readArchive newer)

  describe "refusing" $ do
    it "a page's directory without its record" $
      refused "It has no spaces/docs/pages/ghost/page.json." (readArchive (Map.insert "spaces/docs/pages/ghost/page.md" "Boo" files))

    it "a body that is not UTF-8" $
      refused "spaces/docs/pages/intro/page.md: it is not UTF-8 text" (readArchive (Map.insert "spaces/docs/pages/intro/page.md" (BS.pack [0xff, 0xfe]) files))

    it "an attachment whose file is missing, or of the wrong size" $ do
      let file = "spaces/docs/pages/intro/attachments/%63on.txt"
      refused "is not in the archive" (readArchive (Map.delete file files))
      refused "bytes, where spaces/docs/pages/intro/page.json says" (readArchive (Map.insert file "short" files))

    it "an icon whose image is missing" $
      refused "names for the space's icon, is not in the archive" (readArchive (Map.delete "spaces/docs/icon.png" files))

    it "a space twice, naming both places" $
      refused
        "spaces/nul_/space.json and spaces/other/space.json: there are two of the space \"s3\"."
        (readArchive (Map.insert "spaces/other/space.json" (fromMaybe "" (Map.lookup "spaces/nul_/space.json" files)) files))

    it "two spaces side by side with one slug" $ do
      let twin = Map.insert "spaces/twin/space.json" (encodeJson (Object (KeyMap.insert "id" (String "s9") (fromMaybe mempty (objectAt "spaces/nul_/space.json" files))))) files
      refused "two spaces side by side have the slug \"nul\"" (readArchive twin)

    it "a thread without comments" $
      refused "has no comments" (readArchive (Map.insert "spaces/docs/pages/intro/pages/prn_/comments.json" "[{\"id\": \"t3\", \"createdAt\": \"2026-10-01T00:30:00Z\", \"comments\": []}]" files))

    it "a thread twice, naming both places" $
      refused "There are two of the thread \"t3\", in spaces/docs/pages/intro/pages/prn_/comments.json and in spaces/docs/pages/intro/pages/prn_/pages/deep/comments.json." (readArchive (Map.insert "spaces/docs/pages/intro/pages/prn_/pages/deep/comments.json" (fromMaybe "" (Map.lookup "spaces/docs/pages/intro/pages/prn_/comments.json" files)) files))
