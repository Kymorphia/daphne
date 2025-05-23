module library;

import std.algorithm : canFind, map;
import std.array : assocArray, insertInPlace;
import std.conv : to;
import std.exception : ifThrown;
import std.file : DirEntry, dirEntries, SpanMode;
import std.logger;
import std.path : absolutePath, baseName, buildPath;
import std.parallelism : Task, task;
import std.range : assumeSorted, repeat;
import std.signals;
import std.string : icmp, join;
import std.typecons : tuple;
import std.variant : Variant;

import ddbc : createConnection, Connection, PreparedStatement;
import gdk.texture;
import gettext;
import glib.bytes;
import gobject.object;
import gobject.types : GTypeEnum;
import gobject.value;
import taglib;

import daphne;
import song;

enum UnknownName = "<Unknown>"; /// Name used for unknown artist or album names
enum LibraryDatabaseFile = "daphne-library.db"; /// Library file name

/// Song library object
class Library
{
  immutable string[] defaultExtensions = [
    "aac", "aif", "aiff", "ape", "flac", "m4a", "mp3", "ogg", "opus", "wav", "wma",
  ];

  this(Daphne daphne)
  {
    _daphne = daphne;
    unknownArtist = new LibraryArtist(tr!UnknownName);
    _extFilter = defaultExtensions.dup;
  }

  /**
   * Open the library file, load the data to the library, or initialize it
   */
  void open()
  {
    try
      _dbConn = createConnection("sqlite:" ~ buildPath(_daphne.appDir, LibraryDatabaseFile));
    catch (Exception e)
      throw new Exception("DB connect error", e);

    auto stmt = _dbConn.createStatement;
    scope(exit) stmt.close;

    try
      stmt.executeUpdate("CREATE TABLE IF NOT EXISTS Library (" ~ Song.SqlSchema ~ ")");
    catch (Exception e)
      throw new Exception("DB table create error", e);
    
    try // Load the Library table into library objects
    {
      auto rs = stmt.executeQuery("SELECT " ~ Song.SqlColumns.join(", ") ~ ", id FROM Library"); // Add "id" field to end

      while (rs.next)
        addSong(new Song(rs));
    }
    catch (Exception e)
      throw new Exception("Library DB load error: " ~ e.msg);
  }

  /// Close library
  void close()
  {
    if (_dbConn)
    {
      _dbConn.close;
      _dbConn = null;
    }
  }

  // Data passed to indexer thread
  private struct IndexerData
  {
    Library library; // The library instance
    Connection _dbConn; // Database connection
    string[] mediaPaths; // Duplicated media paths from Prefs
    string[] extensions; // Duplicated file extensions
    bool[string] existingFiles; // Hash of existing song files
  }

  /**
   * Runs the indexer thread which indexes new songs in a separate thread.
   * If the thread is currently running, unhandledIndexerRequest member is set to true.
   * This can be used to rerun the indexer after it is completed.
   * Gets cleared when runIndexerThread() is able to start the indexer.
   */
  void runIndexerThread()
  {
    if (isIndexerRunning)
    {
      unhandledIndexerRequest = true;
      return;
    }

    unhandledIndexerRequest = false;

    synchronized _indexerTotalFiles = IndexerTotalFilesUnset;

    IndexerData data;
    data.library = this;
    data._dbConn = _dbConn;
    data.mediaPaths = _daphne.prefs.mediaPaths.dup;
    data.extensions = _extFilter.dup;
    data.existingFiles = songFiles.keys.map!(k => tuple(k, true)).assocArray;
    _indexerTask = task!indexerThread(data);
    _indexerTask.executeInNewThread;
  }

  // Indexer thread function
  private static void indexerThread(IndexerData data)
  {
    string[] newFiles;

    bool extMatches(string ext, string filename)
    {
      return filename.length > ext.length + 1 && filename[$ - ext.length - 1] == '.'
        && ext.icmp(filename[$ - ext.length .. $]) == 0;
    }

    foreach (path; data.mediaPaths) // Create list of all files which have not been indexed
      foreach (DirEntry e; dirEntries(path, SpanMode.breadth))
        if (e.isFile && e.name !in data.existingFiles && data.extensions.canFind!(extMatches)(e.name))
          newFiles ~= e.name;

    synchronized data.library._indexerTotalFiles = cast(int)newFiles.length;

    PreparedStatement ps;

    try
    {
      ps = data._dbConn.prepareStatement("INSERT INTO Library (" ~ Song.SqlColumns.join(", ")
        ~ ") VALUES (" ~ "?".repeat(Song.SqlColumns.length).join(", ") ~ ")");
    }
    catch (Exception e)
    {
      error("Library insert prepare error: " ~ e.msg);
      return;
    }

    scope(exit) ps.close;

    foreach (i; 0 .. newFiles.length) // Loop on new files, get tags, and add songs to the database and new songs array if valid
    {
      if (auto song = getTags(newFiles[i]))
      {
        song.storeSqlValues(ps);

        try
        {
          Variant outIdVal;
          ps.executeUpdate(outIdVal);
          song.id = outIdVal.coerce!long;
        }
        catch (Exception e)
          warning("Library insert error: " ~ e.msg);

        synchronized data.library._indexerNewSongs ~= song;
      }

      synchronized data.library._indexerCompletedFiles = cast(int)(i + 1); // Update progress
    }
  }

  /**
   * Process indexer thread results from GUI thread.
   * Returns: Indexer progress (nan if still counting files, 0.0 - < 1.0 for progress, 1.0 when completed)
   */
  double processIndexerResults()
  {
    if (!_indexerTask)
      return double.nan;

    Song[] newSongs;
    int total, completed;

    synchronized
    {
      total = _indexerTotalFiles;
      completed = _indexerCompletedFiles;

      newSongs = _indexerNewSongs;
      _indexerNewSongs.length = 0;
    }

    foreach (song; newSongs)
      addSong(song);

    if (completed == total)
    {
      _indexerTask.yieldForce;
      _indexerTask = null;
    }

    if (total == IndexerTotalFilesUnset)
      return double.nan;
    else if (total == 0)
      return 1.0;
    else
      return cast(float)completed / total;
  }

  /// Returns true if indexer is currently running, false otherwise.
  bool isIndexerRunning()
  {
    return _indexerTask != null;
  }

  /**
   * Add a song object to the library.
   * Params:
   *   song = The song to add
   */
  void addSong(Song song)
  {
    auto libSong = new LibrarySong(song);
    songFiles[song.filename] = libSong;
    songIds[song.id] = libSong;

    auto artist = song.artist.length > 0 ? artists.require(song.artist, new LibraryArtist(song.artist)) : unknownArtist;
    auto album = song.album.length > 0 ? artist.albums.require(song.album, new LibraryAlbum(song.album, artist))
      : artist.unknownAlbum;

    bool songSortFunc(LibrarySong a, LibrarySong b) // Sort album songs by track number, showing songs with track numbers first, falling back to sorting by filename
    {
      auto aTrack = a.song.track > 0 ? a.song.track : uint.max;
      auto bTrack = b.song.track > 0 ? b.song.track : uint.max;
      return aTrack < bTrack || (aTrack == bTrack && a.song.filename.baseName < b.song.filename.baseName);
    }

    if (album != artist.unknownAlbum) // If not unknown artist, use normal sorting function
    {
      auto sortedSongs = assumeSorted!(songSortFunc)(album.songs);
      auto index = sortedSongs.lowerBound(libSong).length;
      album.songs.insertInPlace(index, libSong);

      if (album.year == 0 && song.year != 0)
        album.year = song.year;
    }
    else
    {
      auto sortedSongs = assumeSorted!((a, b) => a.song.title < b.song.title)(album.songs); // Sort unknown album songs by title
      auto index = sortedSongs.lowerBound(libSong).length;
      album.songs.insertInPlace(index, libSong);
    }

    libSong.album = album;

    artist.songCount++;
    album.songCount++;

    if (artist != unknownArtist && artist.songCount == 2) // Don't consider an Artist object active until at least 2 songs
      newArtist.emit(artist);

    if (album != artist.unknownAlbum && album.songCount == 2) // Don't consider an Album object active until at least 2 songs
      newAlbum.emit(album);

    newSong.emit(libSong);
  }

  mixin Signal!(LibraryArtist) newArtist; /// Signal for when a new artist has been added to the library
  mixin Signal!(LibraryAlbum) newAlbum; /// Signal for when a new album has been added to the library
  mixin Signal!(LibrarySong) newSong; /// Signal for when a new song has been added to the library

  enum IndexerTotalFilesUnset = -1; /// Value for _indexerTotal to indicate that the value has not yet been set by the indexer

  LibrarySong[string] songFiles; /// Map of filenames to Song objects
  LibrarySong[long] songIds; /// Map of song IDs to Song objects
  LibraryArtist unknownArtist; /// Unknown artist object
  LibraryArtist[string] artists; /// Map of artist names to LibraryArtist object
  bool unhandledIndexerRequest; /// Set to true if runIndexerThread() is called when it is already running

private:
  Daphne _daphne; // Daphne app object
  Connection _dbConn; // Library database connection
  string[] _extFilter; // File extension filter

  Task!(indexerThread, IndexerData)* _indexerTask; // mediaPaths, extensions, existingFiles

  // These members are synchronized between indexer thread and GUI
  Song[] _indexerNewSongs; // New collected songs from indexer
  shared int _indexerTotalFiles; // Total files being indexed
  shared int _indexerCompletedFiles; // Files completed
}

/// An base class for library items (artists, albums and songs)
class LibraryItem : ObjectWrap
{
  this()
  {
    super(GTypeEnum.Object);
  }

  mixin(objectMixin);

  @property string name() { return null; }
}

/// Artist library node
class LibraryArtist : LibraryItem
{
  this(string name)
  {
    unknownAlbum = new LibraryAlbum(tr!UnknownName, this);
    _name = name;
  }

  override @property string name() { return _name; }

  LibraryAlbum unknownAlbum;
  LibraryAlbum[string] albums;
  uint songCount; // Count of songs for artist

private:
  string _name;
}

/// Album library node
class LibraryAlbum : LibraryItem
{
  this(string name, LibraryArtist artist)
  {
    _name = name;
    this.artist = artist;
  }

  override @property string name() { return _name; }

  LibraryArtist artist; // Artist of the album
  LibrarySong[] songs; // Songs sorted by track number followed by filename
  uint year; // Album year (aggregate from songs), 0 if not set, just gets first valid year at the moment
  uint songCount; // Count of album songs

private:
  string _name;
}

// Song library node (just a simple wrapper to Song at the moment)
class LibrarySong : LibraryItem
{
  this(Song song)
  {
    this.song = song;
  }

  override @property string name() { return song.title; }

  Song song;
  LibraryAlbum album;
}

/**
  * Get an album cover from a song file.
  * Params:
  *   song = The song to get the album cover from
  * Returns: Texture of the album cover or null if none/error
  */
Texture getAlbumCover(LibrarySong libSong)
{
  auto tagFile = new TagFile(libSong.song.filename);
  if (!tagFile.isValid)
    return null;

  auto pictureProps = tagFile.getComplexProp("PICTURE");
  if ("data" !in pictureProps)
    return null;

  auto bytes = new Bytes(cast(ubyte[])pictureProps["data"].getByteArray);
  return Texture.newFromBytes(bytes).ifThrown(null);
}

// Get tags using TagLib, returns null if filename is not a valid TagLib supported file
private Song getTags(string filename)
{
  auto tagFile = new TagFile(filename);
  scope(exit) tagFile.close; // Explicitly close the TagFile to free file handle, rather than waiting for it to be GC'd

  if (!tagFile.isValid)
    return null;

  auto song = new Song;
  song.filename = filename;
  song.title = tagFile.title;
  song.artist = tagFile.artist;
  song.album = tagFile.album;
  song.genre = tagFile.genre;
  song.year = tagFile.year;
  song.track = tagFile.track;
  song.length = tagFile.length;

  auto discNumberVals = tagFile.getProp("DISCNUMBER");
  song.disc = discNumberVals.length > 0 ? discNumberVals[0].to!uint.ifThrown(0) : 0;

  song.validate;

  return song;
}
