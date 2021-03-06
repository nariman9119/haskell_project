{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections   #-}

module TelegramBot
  ( run
  ) where

import           Data.Bifunctor
import           Data.Hashable              (Hashable)
import           Data.HashMap.Strict        (HashMap)
import qualified Data.HashMap.Strict        as HashMap

import Parser

import           Control.Applicative              ((<|>))
import           Control.Concurrent               (threadDelay)
import           Control.Monad.Trans              (liftIO)
import           Course
import           Data.Text                        (Text)
import           Data.Text                        as T hiding (concat, filter,
                                                        length, map, null, zip,
                                                        zipWith, take)

import Data.Maybe
import qualified Data.Text                        as Text
import           Data.Time
import qualified Telegram.Bot.API                 as Telegram
import           Telegram.Bot.Simple
import           Telegram.Bot.Simple.Debug
import           Telegram.Bot.Simple.UpdateParser
import           Telegram.Bot.Simple.Conversation
import           Control.Lens

import BotDatabase
import Database.HDBC.Sqlite3 (Connection)

-- | Bot conversation state model.
data Model =
  Model
    { electiveCourses   :: [Course] --list of all elective courses
    , myElectiveCourses :: [Course] --elective courses that user will choose
    , currentTime       :: UTCTime  
    , timeZone          :: TimeZone 
    , remindLectures    :: [ToRemindLecture]  -- list of reminders
    , toDoDescription   :: [Text]             -- list of todoitems for user
--    , dbConnection      :: Connection
    }
  deriving (Show)

  -- | An item in a reminder list.
data ToRemindLecture = ToRemindLecture
  { toRemindTitle    :: Text            -- ^ Item title.
  , lecReminder :: Maybe UTCTime   -- ^ Optional notification time.
  } deriving (Show)


-- | Actions bot can perform.
data Action
  = NoAction -- ^ Perform no action.
  | AddItem Text -- ^ Add course to course list.
  | RemoveItem Text -- ^ Remove an item by its title.
  | ShowItems -- ^ Display all items (either with a new message or by updating existing one).
  | ShowAllCourses -- ^ Display the list of courses as inline keyboard 
  | Start -- ^ Display start message.
  | SetTime UTCTime -- ^ Update current time.
  | RevealItemActions Text -- ^ Update list of items to display item actions.
  | SetReminderIn Text -- ^ Set a reminder for an item in a given amount of minutes from now.
  | ShowReminder Text -- ^ Display the reminders  
  | WeekCourses -- ^ Display courses that wil be in the defined week
  | ShowTime Text Text -- ^ Display the info about lecture including time
  | AddToDo Text  -- ^ Add todo item 
  | ShowToDo Text -- ^ Display list of todo items in the defined course
  | ShowAllToDo -- ^ Display list of todo items for the whole courses
  | RemoveToDo Text -- ^ Remove todo item 
  deriving (Show, Read)

-- | Load courses to our model
loadCourses::IO [Maybe Course]
loadCourses = Parser.runParser

-- | Initializing our model
initialModel :: IO Model
initialModel = do
  now <- getCurrentTime
  tz  <-  getCurrentTimeZone
  allCourses <- loadCourses
--  conn <- BotDatabase.initDb
  pure Model { electiveCourses = catMaybes allCourses
             , myElectiveCourses = []
             , currentTime = now
             , timeZone = tz
             , remindLectures = []
             , toDoDescription = []
--             , dbConnection = conn
             }



-- | Create a new lecture reminder item with just a title.
mkToRemindLecture :: Text -> ToRemindLecture
mkToRemindLecture title = ToRemindLecture
  { toRemindTitle    = title
  , lecReminder = Nothing
  }

-- | Add a new reminder lecture to remind list.
addReminder :: ToRemindLecture-> Model -> Model
addReminder item model = model { remindLectures = item : remindLectures model }

-- | Remove an item from remind list
removeLecReminder:: Text -> Model -> Model
removeLecReminder title model = model { remindLectures = filter p (remindLectures model) }
  where
    p item = toRemindTitle item /= title

-- | Set Lecture reminder to reminder list
setLecReminderIn :: Text -> Model -> Integer -> Lecture -> Model
setLecReminderIn courseName model lec_id lecture = setReminder title (startTime $ lecTime lecture) model
    where
        title = T.intercalate " " [courseName, T.pack (show lec_id), T.pack (showLecture lecture (timeZone model))]

-- | Set all lectures reminders to the list 
setLecturesReminder :: Text -> Model -> [(Lecture, Integer)] -> Model
setLecturesReminder courseName model [] = model
setLecturesReminder courseName model (enumLecture: enumLectures) = setLecturesReminder courseName new_model enumLectures
    where
            new_model = setLecReminderIn courseName model lec_id lecture
            lec_id = snd enumLecture
            lecture = fst enumLecture

-- | Set alarm time for an item with a given title
setCourseReminderIn :: Maybe Course -> Model -> Model
setCourseReminderIn Nothing model = model
setCourseReminderIn (Just course) model = setLecturesReminder (T.pack $ name course) model (zip (lectures course) [1..])


-- | Set an absolute alarm time for an item with a given title.
setReminder :: Text -> UTCTime -> Model -> Model
setReminder title datetime model = addReminder  (ToRemindLecture {toRemindTitle = title, lecReminder = Just datetime}) model

-- | Remind user of lectures in regular bot job.
lectureReminder :: Model -> Eff Action Model
lectureReminder model = do
  eff $ SetTime <$> liftIO getCurrentTime  -- updates current model time
  newItems <- mapM itemReminder (remindLectures model)
  pure model { remindLectures = newItems }
  where
    itemReminder item =
      case lecReminder item of
        Just alarmTime | alarmTime <= currentTime model -> do
          eff $ do
            replyText ("Reminder: " <> toRemindTitle item)
            return NoAction
          return item { lecReminder = Nothing }
        _ -> return item

-- Sets reminder on all course lectures.
setReminderIn :: Text -> Model -> Model
setReminderIn title model = setCourseReminderIn course model
  where
    course = findCourse title model

-- | Add course to user`s list from list of all courses.
addCourse :: Maybe Course -> Model -> Model
addCourse (Just course) model = do
  if (isMember course (myElectiveCourses model))
    then model
    else model {myElectiveCourses = course : myElectiveCourses model}
--  BotDatabase.insertToDb (dbConnection model) (show model)
addCourse Nothing model = model



-- | Add ToDo item
addToDo :: Text -> Model -> Model
addToDo item model = model
  { toDoDescription = item : toDoDescription model }

-- | Remove ToDo item
removeToDo :: Text -> Model -> Model
removeToDo title model = model {toDoDescription = filter p (toDoDescription model)}
  where
    p item = item /= title

-- | Show ToDo item for defined course
showToDo:: Text -> Model -> Text
showToDo title model = let list = filter (isInfixOf title) (toDoDescription model)
                        in if null list 
                          then T.pack ("There is nothing todo in " ++ (T.unpack title)) 
                          else intercalate "\n" (list) 
 
-- | Show all ToDo items
showAllToDo:: Model -> Text
showAllToDo model = let list = toDoDescription model 
                      in if null list 
                        then "There is nothing todo"
                        else intercalate "\n" (list) 
      


-- | Ability to remove course from user`s list
removeCourse :: Text -> Model -> Model
removeCourse title model = model {myElectiveCourses = filter p (myElectiveCourses model)}
  where
    p item = (T.pack $ name item) /= title

-- | Copy course from the model by title
copyCourse :: Model -> Text -> Maybe Course
copyCourse model title = (filter (compareCourses title) (electiveCourses model)) ^? element 0

-- | Find course in the model
findCourse :: Text -> Model -> Maybe Course
findCourse title model = (filter equalsItem (myElectiveCourses model))  ^? element 0
  where
    equalsItem item = (T.pack $ name item) == title


-- | Bot application with different conversations
initBot :: IO  (BotApp
                  (HashMap (Maybe Telegram.ChatId) Model)
                  (Maybe Telegram.ChatId, Action))
initBot = do
  model <- initialModel
  print model
  let botjobs = [BotJob {botJobSchedule =  "* * * * *" -- every minute
                     ,  botJobTask = lectureReminder
                     }
                 ]
  let someBot  = BotApp {botInitialModel = model, botAction = flip handleUpdate, botHandler = handleAction, botJobs = botjobs}
  pure (conversationBot Telegram.updateChatId  someBot)


-- | Start message during bot launch
startMessage :: Text
startMessage =
  Text.unlines
    [ "Welcome to Elective course schedule"
    , "/start - show list of all possible courses"
    , "/show - show list of selected courses"
    , "/remove_course - remove course from list of selected courses"
    , "/remove_todo - remove todo item from list of todo items"
    , "/show_week - show courses on this week"
    , "/show_todo - show your todo list"
    ]

-- | Make InlineKeyboard for selected courses
myCoursesAsInlineKeyboard :: Model -> EditMessage
myCoursesAsInlineKeyboard model =
  case myElectiveCourses model of
    [] -> "No courses selected. Please choose something!!)"
    items ->
      (toEditMessage "Your list of selected Elective courses")
        {editMessageReplyMarkup = Just $ Telegram.SomeInlineKeyboardMarkup (myCoursesInlineKeyboard items)}
-- | Make InlineKeyboard for selected courses
myCoursesInlineKeyboard :: [Course] -> Telegram.InlineKeyboardMarkup
myCoursesInlineKeyboard = Telegram.InlineKeyboardMarkup . map (pure . myCourseInlineKeyboardButton)
-- | Make InlineKeyboard for selected courses
myCourseInlineKeyboardButton :: Course -> Telegram.InlineKeyboardButton
myCourseInlineKeyboardButton item = actionButton (T.pack $ title) (RevealItemActions (T.pack title))
  where
    title = name item

-- | Make InlineKeyboard for all courses
coursesAsInlineKeyboard :: Model -> EditMessage
coursesAsInlineKeyboard model =
  case electiveCourses model of
    [] -> "The list of elective courses is not yet available"
    items ->
      (toEditMessage "List of available elective courses")
        {editMessageReplyMarkup = Just $ Telegram.SomeInlineKeyboardMarkup (coursesInlineKeyboard items)}
-- | Make InlineKeyboard for all courses
coursesInlineKeyboard :: [Course] -> Telegram.InlineKeyboardMarkup
coursesInlineKeyboard = Telegram.InlineKeyboardMarkup . map (pure . courseInlineKeyboardButton)
-- | Make InlineKeyboard for all courses
courseInlineKeyboardButton :: Course -> Telegram.InlineKeyboardButton
courseInlineKeyboardButton item = actionButton (T.pack title) (AddItem (T.pack title))
  where
    title = name item

-- | InlineKeyboard of what user can perform with selected course
myCourseActionsMessage :: Model -> Text -> EditMessage
myCourseActionsMessage model title = do
  let course = copyCourse model title
  case course of
    Just course -> (toEditMessage (T.pack $ showCourse course (timeZone model)))
                        {editMessageReplyMarkup = Just $ Telegram.SomeInlineKeyboardMarkup (myCourseActionsKeyboard title)}
    Nothing -> "Nothing to show :("

-- | InlineKeyboard of what user can perform with selected course
myCourseActionsKeyboard :: Text -> Telegram.InlineKeyboardMarkup
myCourseActionsKeyboard title = Telegram.InlineKeyboardMarkup [[btnRemindIn], [btnBack], [btnReminders], [btnToDo]]
  where
    btnReminders = actionButton ("Show all reminders") (ShowReminder title)
    btnBack = actionButton "\x2B05 Back to course list" ShowItems
    btnRemindIn = actionButton ("Set reminder") (SetReminderIn title)
    btnToDo = actionButton (T.pack("ToDo in " ++ (T.unpack title))) (ShowToDo title)


-- | How to process incoming 'Telegram.Update's
-- and turn them into 'Action's.
handleUpdate :: Model -> Telegram.Update -> Maybe Action
handleUpdate _ =
  parseUpdate $ 
  ShowItems <$ command "show" <|> 
  RemoveItem <$> command "remove_course" <|> 
  RemoveToDo <$> command "remove_todo" <|> 
  ShowAllToDo <$ command "show_todo" <|>
  Start <$ command "start" <|>
  WeekCourses <$ command "show_week" <|>
  callbackQueryDataRead
  <|> AddToDo     <$> text

  

-- | Display reminders of selected course as InlineKeyboard
remindersAsInlineKeyboard :: Model -> Text -> EditMessage
remindersAsInlineKeyboard model course =
  case remindLectures model of
    [] -> "The list of reminders is not yet available"
    items ->
      (toEditMessage "List of reminders")
        { editMessageReplyMarkup =
            Just $
            Telegram.SomeInlineKeyboardMarkup (remindersInlineKeyboard (filter (\i -> True) items)) -- (splitOn " " ( toRemindTitle i)) !! 0  == course
        }

-- | Display week lectures as InlineKeyboard
weekLecturesAsInlineKeyboard :: Model -> EditMessage
weekLecturesAsInlineKeyboard model =
  case courses of
    [] -> "You don't have lectures on this week"
    items ->
      (toEditMessage "List of courses")
        {editMessageReplyMarkup = Just $ Telegram.SomeInlineKeyboardMarkup (weekLecturesInlineKeyboard day tz items)}
  where
    courses = thisWeekSchedule (day, tz) (myElectiveCourses model)
    tz = timeZone model
    day = localTimeDayFromUTC (currentTime model) tz
-- | Display week lectures as InlineKeyboard
weekLecturesInlineKeyboard :: Day-> TimeZone -> [Course] -> Telegram.InlineKeyboardMarkup
weekLecturesInlineKeyboard day tz = Telegram.InlineKeyboardMarkup . map (pure . weekLecturesInlineKeyboardButtonTZ)
    where
        weekLecturesInlineKeyboardButtonTZ course = weekLecturesInlineKeyboardButton day tz course
-- | Display week lectures as InlineKeyboard
weekLecturesInlineKeyboardButton :: Day -> TimeZone -> Course -> Telegram.InlineKeyboardButton
weekLecturesInlineKeyboardButton day tz item = actionButton courseName (ShowTime courseName lectureStr) 
  where
    courseName = T.pack $ name item
    lecs = (thisWeekCourseLectures (day, tz) item)
    lectureStr = T.intercalate "\n" ( map (T.pack . showLectureInTimeZone ) $ take 1 lecs) -- TODO need fix
    showLectureInTimeZone l = showLecture l tz
-- | Display reminders of selected course as InlineKeyboard
remindersInlineKeyboard :: [ToRemindLecture] -> Telegram.InlineKeyboardMarkup
remindersInlineKeyboard = Telegram.InlineKeyboardMarkup . map (pure . reminderInlineKeyboardButton)
-- | Display reminders of selected course as InlineKeyboard
reminderInlineKeyboardButton :: ToRemindLecture -> Telegram.InlineKeyboardButton
reminderInlineKeyboardButton item = actionButton title (AddItem title)
  where
    title = toRemindTitle item

-- | How to handle 'Action's.
handleAction :: Action -> Model -> Eff Action Model
handleAction action model =
  case action of
    NoAction -> pure model
    SetTime t -> model {currentTime = t} <# do SetTime <$> liftIO (threadDelay 1000 >> getCurrentTime)
  -- add course by creating new course from selected one
    AddItem title ->
      addCourse (copyCourse model title) model <# do
        replyText "Course in your list"
        pure NoAction
  -- remove course from list of user`s courses
    RemoveItem title ->
      removeCourse title model <# do
        replyText ("Course " <> title <> " removed from your list")
        pure ShowItems
  -- show time of lectures
    ShowTime title time -> model <# do
      replyText (append(append title (T.pack " - "))time)
      pure NoAction
  -- show list of your courses
    ShowItems ->
      model <# do
        replyOrEdit (myCoursesAsInlineKeyboard model)
        pure NoAction
  -- show list of all courses
    ShowAllCourses ->
      model <# do
        replyOrEdit (coursesAsInlineKeyboard model)
        pure NoAction
  -- show course that will be in the defined week
    WeekCourses ->
      model <# do
        replyOrEdit (weekLecturesAsInlineKeyboard model)
        pure NoAction
  -- start telegram bot
    Start -> do
      eff $ do
        reply (toReplyMessage startMessage)
        pure ShowAllCourses
      eff $ SetTime <$> liftIO getCurrentTime
      pure model
  -- show actions that can be performed with the selected course
    RevealItemActions title ->
      model <# do
        editUpdateMessage (myCourseActionsMessage model title)
        pure NoAction
  -- set reminder to the course
    SetReminderIn title ->
      setReminderIn title model <# do
        replyText "Ok, I will remind you."
        pure NoAction
  -- show reminders of the course
    ShowReminder title ->
      model <# do
        replyOrEdit (remindersAsInlineKeyboard model title)
        pure NoAction
  -- add todo item 
    AddToDo title -> 
      addToDo title model <# do
        replyText "ToDo in your list"
        pure NoAction
  -- show todo item of selected course
    ShowToDo title -> model <# do
      replyText (showToDo title model)
      pure NoAction
  -- show all todo items 
    ShowAllToDo -> model  <# do
      replyText (showAllToDo model)
      pure NoAction
  -- remove todo item
    RemoveToDo title ->
      removeToDo title model <# do
        replyText ("ToDo " <> title <> " removed from your list")
        pure NoAction

    
        
-- show actions from course that was selected on user`s list
run :: Telegram.Token -> IO ()
run token = do
  env <- Telegram.defaultTelegramClientEnv token
  bot <- initBot
  startBot_ (useLatestUpdateInJobs (traceBotDefault bot)) env
