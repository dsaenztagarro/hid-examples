{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}

import Database.HDBC
import Database.HDBC.PostgreSQL
import Data.Convertible.Base (Convertible)

import Prelude hiding (putStr, putStrLn)
import Data.Int (Int64)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text.IO
import TextShow

import FilmInfo

fiFromList :: [SqlValue] -> FilmInfo
fiFromList [fid, ttl, desc, l, r] = FilmInfo {
    filmId = FilmId $ fromSql fid
  , title = fromSql ttl
  , description = Just $ fromSql desc
  , filmLength = FilmLength $ fromSql l
  , rating = toMaybeRating $ (fromSql r :: Text)
  }
fiFromList _ = error "unexpected result (fiFromList)"

allFilms :: Connection -> IO [FilmInfo]
allFilms conn = map fiFromList <$> quickQuery conn select []
  where
    select = "SELECT film_id, title, description, length, rating FROM film"

fetchSingle :: (Monad m, Convertible SqlValue a) =>
               String -> [[SqlValue]] -> m a
fetchSingle _ [[val]] = pure $ fromSql val
fetchSingle what _ = error $ "Unexpected result: " ++ what

totalFilmsNumber :: Connection -> IO Int64
totalFilmsNumber conn = do
  res <- quickQuery conn "SELECT count(*) FROM film" []
  fetchSingle "totalFilmsNumber" res

fetchMaybe :: Monad m => ([SqlValue] -> a) -> [[SqlValue]] -> m (Maybe a)
fetchMaybe fromRow (row:_) = pure $ Just $ fromRow row
fetchMaybe  _ _ = pure Nothing

findFilm :: Connection -> Text -> IO (Maybe FilmInfo)
findFilm conn filmTitle = do
  res <- quickQuery conn select [toSql filmTitle]
  fetchMaybe fiFromList res
  where
    select = "SELECT film_id, title, description, length, rating"
             <> " FROM film"
             <> " WHERE title=?"

filmsLonger :: Connection -> FilmLength -> IO [FilmInfo]
filmsLonger conn (FilmLength len) =
    map fiFromList <$> quickQuery conn select [toSql len]
  where
    select = "SELECT film_id, title, description, length, rating FROM film WHERE length >= ?"

filmsCategories :: Connection -> [Text] -> IO [FilmCategories]
filmsCategories conn films = do
    stmt <- prepare conn select
    catMaybes <$> mapM (runSingle stmt) films
  where
    select = "SELECT category.name FROM film"
             <> " JOIN film_category USING (film_id)"
             <> " JOIN category USING (category_id)"
             <> " WHERE title = ?"
    runSingle stmt filmTitle = do
      mfilm <- findFilm conn filmTitle
      case mfilm of
        Nothing -> pure Nothing
        Just film -> do
          _ <- execute stmt [toSql filmTitle]
          cats <- fetchAllRows' stmt
          pure $ Just $ FilmCategories film $ map (fromSql . head) cats

setRating :: Connection -> Rating -> Text -> IO Integer
setRating conn fRating filmTitle = do
  res <- run conn "UPDATE film SET rating = ? WHERE title = ?"
          [toSql (fromRating fRating :: Text), toSql filmTitle]
  commit conn
  pure res

newCategory :: Connection -> Text -> IO CatId
newCategory conn catName = fmap CatId $ do
  cnt <- run conn "INSERT INTO category (name) VALUES (?)" [toSql catName]
  if cnt /= 1
    then error "Inserting category failed"
    else quickQuery conn "SELECT lastval()" [] >>= fetchSingle "category_id"

catIdByName :: Connection -> Text -> IO (Maybe CatId)
catIdByName conn catName =
  quickQuery conn "SELECT  category_id FROM category WHERE name = ?"
             [toSql catName]
  >>= fetchMaybe (\case
                     [x] -> CatId $ fromSql x
                     _ -> error "not a value")

findOrAddCategory :: Connection -> Text -> IO CatId
findOrAddCategory conn catName = do
  cats <- catIdByName conn catName
  case cats of
    Nothing -> newCategory conn catName
    Just cid -> pure cid

filmIdByTitle :: Connection -> Text -> IO (Maybe FilmId)
filmIdByTitle conn filmTitle =
  quickQuery conn "SELECT film_id FROM film WHERE title=?" [toSql filmTitle]
  >>= fetchMaybe (\case
                     [x] -> FilmId $ fromSql x
                     _ -> error "not a value")

isAssigned :: Connection -> CatId -> FilmId -> IO Bool
isAssigned conn (CatId cid) (FilmId fid) = do
  res <- quickQuery conn ("SELECT count(category_id) FROM film_category"
                            <> " WHERE category_id = ? AND film_id= ?")
                     [toSql cid, toSql fid]
  cnt <- fetchSingle "isAssigned" res
  pure $ cnt > (0 :: Int64)

assignCategory' :: Connection -> CatId -> FilmId -> IO Integer
assignCategory' conn (CatId cid) (FilmId fid) =
  run conn "INSERT INTO film_category (category_id, film_id) VALUES (?, ?)"
          [toSql cid, toSql fid]

assignCategory :: Connection -> Text -> Text -> IO Integer
assignCategory conn catName filmTitle = do
  cid <- findOrAddCategory conn catName
  mFilmId <- filmIdByTitle conn filmTitle
  case mFilmId of
    Nothing -> pure 0
    Just fid -> go cid fid
 where
   go cid fid = do
     b <- isAssigned conn cid fid
     case b of
       True -> pure 0
       False -> assignCategory' conn cid fid

unassignCategory :: Connection -> Text -> Text -> IO Integer
unassignCategory conn catName filmTitle =
  run conn
     ("DELETE FROM film_category"
      <> " USING film, category"
      <> " WHERE category.name = ? AND film.title = ?"
      <> "       AND film_category.film_id=film.film_id"
      <> "       AND film_category.category_id=category.category_id")
     [toSql catName, toSql filmTitle]

demo :: Connection -> IO ()
demo conn = do

  allFilms conn >>= mapM_ printFilm . take 5

  putStr "\nTotal number of films: "
  totalFilmsNumber conn >>= printT

  let film = "MODERN DORADO"
  putStrLn "\nFilm information:"
  findFilm conn film >>= printT

  let len = FilmLength 185
  putStrLn $ "\nFilms of " <> showt len <> " and longer:"
  filmsLonger conn len >>= mapM_ printT

  let films = ["KISSING DOLLS", "ALABAMA DEVIL", film]
  putStrLn "\nFilms categories:"
  filmsCategories conn films >>= mapM_ printT

  let newRating = NC17
  putStr $ "\nSetting rating " <> fromRating newRating
              <>  " for a film (" <> film <> "): "
  setRating conn newRating film >>= printT
  findFilm conn film >>= printT

  let newCat = "Art"
  putStr "\nAssign category to a film: "
  assignCategory conn newCat film >>= print
  filmsCategories conn [film] >>= mapM_ printT

  putStr "\nUnassign category from a film: "
  unassignCategory conn newCat film >>= print
  filmsCategories conn [film] >>= mapM_ printT

main :: IO ()
main = withPostgreSQL connString
       $ \conn -> handleSqlError $ demo conn
 where
   connString = "host=localhost dbname=sakila_films"
