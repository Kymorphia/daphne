module library;

public import library_item;
public import library_album;
public import library_artist;
public import library_song;

import daphne_includes;

import ddbc : createConnection, Connection, PreparedStatement, Statement;
import gettext;

import daphne;
import prop_iface;
import signal;

enum LibraryDatabaseFile = "daphne-library.db"; /// Library file name
enum UnknownName = "<Unknown>"; /// Name used for unknown artist or album names
enum VariousArtists = "<Various Artists>"; /// Artist name used for albums with various artists

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
    variousArtists = new LibraryArtist(tr!VariousArtists);
    unknownAlbum = new LibraryAlbum(tr!UnknownName, unknownArtist);

    artists[tr!UnknownName] = unknownArtist;
    artists[tr!VariousArtists] = variousArtists;
    albums[tr!UnknownName] = unknownAlbum;

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
      throw new Exception("DB connect error: " ~ e.msg);

    _dbStmt = _dbConn.createStatement; // Just re-use statement.

    try
      _dbStmt.executeUpdate("CREATE TABLE IF NOT EXISTS songs (" ~ LibrarySong.SqlSchema ~ ")");
    catch (Exception e)
      throw new Exception("DB table create error: " ~ e.msg);
    
    try // Load the Library table into library objects
    {
      auto rs = _dbStmt.executeQuery("SELECT " ~ LibrarySong.SqlColumns.join(", ") ~ ", id FROM songs"); // Add "id" field to end

      while (rs.next)
        addSong(new LibrarySong(rs));
    }
    catch (Exception e)
      throw new Exception("Library DB load error: " ~ e.msg);

    _propChangedGlobalHook = propChangedGlobal.connect(&onGlobalPropChanged); // Add global property change signal hook
  }

  // Called when any PropIface property changes
  private void onGlobalPropChanged(PropIface propObj, string propName, StdVariant val, StdVariant oldVal)
  {
    if (auto song = cast(LibrarySong)propObj)
    {
      if (propName != "libAlbum")
      {
        try
          _dbStmt.executeUpdate("UPDATE songs SET " ~ propName ~ "=" ~ val.coerce!string ~ " WHERE id="
            ~ song.id.to!string);
        catch (Exception e)
          throw new Exception("Library DB update error: " ~ e.msg);
      }
    }
  }

  /// Close library
  void close()
  {
    if (_dbConn)
    {
      _dbStmt.close;
      _dbConn.close;
      _dbConn = null;

      propChangedGlobal.disconnect(_propChangedGlobalHook);
    }
  }

  // Data passed to indexer thread
  private struct IndexerData
  {
    Library library; // The library instance
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

    foreach (i; 0 .. newFiles.length) // Loop on new files, get tags, and add songs to the database and new songs array if valid
    {
      auto song = LibrarySong.createFromTagFile(newFiles[i]);

      synchronized
      {
        if (song)
          data.library._indexerNewSongs ~= song;

        data.library._indexerCompletedFiles = cast(int)(i + 1); // Update progress
      }
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

    LibrarySong[] newSongs;
    int total, completed;

    synchronized
    {
      total = _indexerTotalFiles;
      completed = _indexerCompletedFiles;

      newSongs = _indexerNewSongs;
      _indexerNewSongs.length = 0;
    }

    foreach (song; newSongs)
      addNewSong(song);

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
   * Add a new song object to the library and inserts into the database file.
   * Params:
   *   song = The song to add
   */
  void addNewSong(LibrarySong song)
  {
    auto ps = _dbConn.prepareStatement("INSERT INTO songs (" ~ LibrarySong.SqlColumns.join(", ")
      ~ ") VALUES (" ~ "?".repeat(LibrarySong.SqlColumns.length).join(", ") ~ ")");
    scope(exit) ps.close;

    song.storeSqlValues(ps);

    try
    {
      StdVariant outIdVal;
      ps.executeUpdate(outIdVal);
      song.id = outIdVal.coerce!long;
    }
    catch (Exception e)
      warning("Library insert error: " ~ e.msg);

    addSong(song);
  }

  /**
   * Add a song object to the library.
   * Params:
   *   song = The song to add
   */
  void addSong(LibrarySong song)
  {
    songFiles[song.filename] = song;
    songIds[song.id] = song;

    auto artist = song.artist.length > 0 ? artists.require(song.artist, new LibraryArtist(song.artist)) : unknownArtist;
    auto album = song.album.length > 0 ? albums.require(song.album, new LibraryAlbum(song.album, artist)) : unknownAlbum;

    if (album != unknownAlbum && album.artist != variousArtists && album.artist !is artist) // Detect various artist albums (or multiple albums with different artists)
    {
      album.artist = variousArtists;
      variousArtists.albums[song.album] = album;
      variousArtists.songCount += album.songCount; // Add album songs to various artists song count
    }

    if (album != unknownAlbum && album.year == 0 && song.year != 0)
      album.year = song.year;

    song.libAlbum = album;
    album.songs ~= song; // Append song to album songs list
    artist.songCount++;
    album.songCount++;

    if (album.artist == variousArtists) // Songs on various artist albums increment variousArtists.songCount
      variousArtists.songCount++;

    if (album != unknownAlbum && album.songCount == 1) // If this is a new album, add it to the artist's albums map
      artist.albums[song.album] = album;

    if (artist != unknownArtist && artist.songCount == 1)
      newArtist.emit(artist);

    if (album != unknownAlbum && album.songCount == 1)
      newAlbum.emit(album);

    newSong.emit(song);
  }

  mixin Signal!(LibraryArtist) newArtist; /// Signal for when a new artist has been added to the library
  mixin Signal!(LibraryAlbum) newAlbum; /// Signal for when a new album has been added to the library
  mixin Signal!(LibrarySong) newSong; /// Signal for when a new song has been added to the library

  enum IndexerTotalFilesUnset = -1; /// Value for _indexerTotal to indicate that the value has not yet been set by the indexer

  LibrarySong[string] songFiles; /// Map of filenames to Song objects
  LibrarySong[long] songIds; /// Map of song IDs to Song objects
  LibraryArtist[string] artists; /// Map of artist names to LibraryArtist object
  LibraryAlbum[string] albums; /// List of albums by name (FIXME - What about clashes?)

  LibraryArtist unknownArtist; /// Unknown artist object
  LibraryAlbum unknownAlbum; /// Unknown album object
  LibraryArtist variousArtists; /// Artist object used with multi-artist albums

  bool unhandledIndexerRequest; /// Set to true if runIndexerThread() is called when it is already running

private:
  Daphne _daphne; // Daphne app object
  Connection _dbConn; // Library database connection
  Statement _dbStmt; // Database statement (re-used for optimization)
  string[] _extFilter; // File extension filter
  propChangedGlobal.SignalHook* _propChangedGlobalHook; // Hook for global property change signal

  Task!(indexerThread, IndexerData)* _indexerTask; // mediaPaths, extensions, existingFiles

  // These members are synchronized between indexer thread and GUI
  LibrarySong[] _indexerNewSongs; // New collected songs from indexer
  shared int _indexerTotalFiles; // Total files being indexed
  shared int _indexerCompletedFiles; // Files completed
}
