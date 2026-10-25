-- | The backups' settings as the API speaks them (WP4.9 of docs/PLAN.md):
-- when the next backup is due, which backups a retention keeps, a change's
-- rclone configuration kept, replaced or cleared, and the checks a change
-- must pass.
module Test.Backups (spec) where

import Data.Aeson (decode, encode)
import Data.Set qualified as Set
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Protolude
import Test.Hspec
import Wiki.Api.Backups

-- | A time on a day of October 2026, at hours, minutes (UTC).
at :: Integer -> Int -> Int -> UTCTime
at day h m = UTCTime (fromGregorian 2026 10 (fromIntegral day)) (secondsToDiffTime (fromIntegral (h * 3600 + m * 60)))

-- | Settings kept with their configuration as text, as the demo would.
type Kept = BackupSettingsOf (Maybe Text)

rclone :: Maybe Text -> Kept
rclone config = defaultBackupSettings {enabled = True, destination = Just (ToRclone "b2:wiki" config)}

spec :: Spec
spec = describe "the backups" $ do
  describe "when the next is due" $ do
    it "is at once for the first, every so many hours after the last after that" $ do
      nextBackup (EveryHours 6) Nothing (at 25 10 0) `shouldBe` at 25 10 0
      nextBackup (EveryHours 6) (Just (at 25 9 0)) (at 25 10 0) `shouldBe` at 25 15 0
      nextBackup (EveryHours 6) (Just (at 24 1 0)) (at 25 10 0) `shouldSatisfy` (<= at 25 10 0)

    it "is at the day's time, and at once when that has passed with no backup after it" $ do
      -- Turned on after the day's time: one now, then tomorrow's.
      nextBackup (DailyAt 3 0) Nothing (at 25 10 0) `shouldBe` at 25 3 0
      nextBackup (DailyAt 3 0) (Just (at 25 10 0)) (at 25 10 5) `shouldBe` at 26 3 0
      -- Before the day's time, with yesterday's made: today's.
      nextBackup (DailyAt 3 0) (Just (at 24 3 0)) (at 25 2 0) `shouldBe` at 25 3 0
      -- Missed while the server was stopped: made when it starts.
      nextBackup (DailyAt 3 0) (Just (at 23 3 0)) (at 25 2 0) `shouldBe` at 24 3 0
      -- One made by hand after the day's time counts for the day.
      nextBackup (DailyAt 3 0) (Just (at 25 9 0)) (at 25 12 0) `shouldBe` at 26 3 0
      nextBackup (DailyAt 23 59) (Just (at 24 23 59)) (at 25 23 59) `shouldBe` at 25 23 59

  describe "which are kept" $ do
    it "keeps the newest of each of the last days and weeks, and the newest of all" $ do
      -- Every six hours for five weeks, the last on Sunday 25 October.
      let made = [addUTCTime (negate (fromIntegral (i * 6 * 3600))) (at 25 18 0) | i <- [0 .. 139 :: Int]]
          kept = retained Retention {daily = 3, weekly = 2} made
      Set.toList kept `shouldBe` [at 18 18 0, at 23 18 0, at 24 18 0, at 25 18 0]

    it "keeps the newest even when told to keep nothing more, and every week asked for" $ do
      retained Retention {daily = 1, weekly = 0} [at 1 0 0, at 2 0 0] `shouldBe` Set.fromList [at 2 0 0]
      retained Retention {daily = 1, weekly = 10} [at 1 0 0, at 12 0 0, at 13 0 0] `shouldBe` Set.fromList [at 1 0 0, at 13 0 0]
      retained Retention {daily = 7, weekly = 4} [] `shouldBe` mempty

  describe "a change" $ do
    it "keeps the rclone configuration it leaves out, replaces one given, and clears an empty one" $ do
      let change remote config = defaultBackupSettings {enabled = True, destination = Just (ToRclone remote config)}
      (applyBackupChange identity (rclone (Just "old")) (change "b2:other" Nothing)).destination `shouldBe` Just (ToRclone "b2:other" (Just "old"))
      (applyBackupChange identity (rclone (Just "old")) (change "b2:wiki" (Just "new"))).destination `shouldBe` Just (ToRclone "b2:wiki" (Just "new"))
      (applyBackupChange identity (rclone (Just "old")) (change "b2:wiki" (Just ""))).destination `shouldBe` Just (ToRclone "b2:wiki" Nothing)
      -- A directory in its place, and then rclone again: nothing kept.
      let directory = applyBackupChange identity (rclone (Just "old")) defaultBackupSettings {destination = Just (ToDirectory "/mnt/b")}
      directory.destination `shouldBe` Just (ToDirectory "/mnt/b")
      (applyBackupChange identity directory (change "b2:wiki" Nothing)).destination `shouldBe` Just (ToRclone "b2:wiki" Nothing)

    it "reads a change that leaves the configuration out as keeping it" $ do
      decode "{\"rclone\":\"b2:wiki\"}" `shouldBe` Just (ToRclone "b2:wiki" (Nothing :: Maybe Text))
      decode (encode (rclone (Just "x"))) `shouldBe` Just (rclone (Just "x"))
      decode (encode (DailyAt 3 5)) `shouldBe` Just (DailyAt 3 5)
      encode (DailyAt 3 5) `shouldBe` "{\"daily\":\"03:05\"}"

  describe "the checks" $ do
    let valid = defaultBackupSettings {enabled = True} :: Kept
        refused :: Kept -> Expectation
        refused s = checkBackupSettings s `shouldSatisfy` isLeft
        trimmed :: Kept -> Kept -> Expectation
        trimmed typed kept = checkBackupSettings typed `shouldBe` Right kept
    it "takes the defaults, and trims what is typed" $ do
      checkBackupSettings valid `shouldBe` Right valid
      trimmed valid {destination = Just (ToDirectory " /mnt/b ")} valid {destination = Just (ToDirectory "/mnt/b")}
      trimmed valid {destination = Just (ToRclone " b2:w " Nothing)} valid {destination = Just (ToRclone "b2:w" Nothing)}
    it "refuses a time, a period or a number to keep out of range" $ do
      refused valid {schedule = DailyAt 24 0}
      refused valid {schedule = DailyAt 3 60}
      refused valid {schedule = EveryHours 0}
      refused valid {schedule = EveryHours 169}
      refused valid {keep = Retention {daily = 0, weekly = 4}}
      refused valid {keep = Retention {daily = 7, weekly = -1}}
    it "refuses a directory that is not a full path, and a remote that is not one" $ do
      refused valid {destination = Just (ToDirectory "")}
      refused valid {destination = Just (ToDirectory "backups")}
      refused valid {destination = Just (ToRclone "no-colon" Nothing)}
      refused valid {destination = Just (ToRclone ":path" Nothing)}
      refused valid {destination = Just (ToRclone "--config=/x:y" Nothing)}
