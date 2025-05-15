module library;

import gettext;
import gobject.object;
import gobject.types : GTypeEnum;
import std.algorithm : map;
import std.array : insertInPlace;
import std.conv : to;
import std.exception : ifThrown;
import std.file : DirEntry, dirEntries, SpanMode;
import std.path : absolutePath, baseName;
import std.range : assumeSorted;
import std.stdio : writeln;
import std.string : icmp, join;
import taglib;

import daphne;
import song;

enum UnknownName = "<Unknown>"; /// Name used for unknown artist or album names

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
   * Recursively index a directory searching for audio files, extracting their tags, and updating the library songs.
   * Params:
   *   path = Path to recursively index
   *   forceUpdate = Set to true to force an update of existing files (defaults to false)
   */
  void indexPath(string path, bool forceUpdate = false)
  {
    auto sqlColumns = Song.getSqlColumns;

    foreach (DirEntry e; dirEntries(path, SpanMode.breadth))
    {
      if (e.isFile && extMatch(e.name))
      {
        auto filename = absolutePath(e.name);

        if (filename !in songFiles)
          if (auto song = getTags(filename))
          {
            addSong(song);
            _daphne.dbConn.insertRowIntoTableV("Library", sqlColumns, song.getSqlValues);
          }
      }
    }
  }

  private bool extMatch(string fileName)
  { // Looping on extensions is probably fast enough vs a hash
    foreach (ext; _extFilter)
      if (fileName.length > ext.length + 1 && fileName[$ - ext.length - 1] == '.'
          && ext.icmp(fileName[$ - ext.length .. $]) == 0)
        return true;

    return false;
  }

  // Get tags using TagLib, returns null if filename is not a valid TagLib supported file
  private Song getTags(string filename)
  {
    auto tagFile = new TagFile(filename);

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

    return song;
  }

  /// Create the Library songs table if it doesn't already exist
  void createTable()
  {
    _daphne.dbConn.executeNonSelectCommand("CREATE TABLE IF NOT EXISTS Library (" ~ Song.SqlSchema ~ ")");
  }

  /// Load songs from database
  void load()
  {
    auto dataModel = _daphne.dbConn.executeSelectCommand("SELECT " ~ Song.getSqlColumns.join(", ") ~ " FROM Library");

    foreach (row; 0 .. dataModel.getNRows)
      addSong(new Song(dataModel, row)); // Create Song object from DataModel and row
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
  }

  LibrarySong[string] songFiles; // Map of filenames to Song objects
  LibraryArtist unknownArtist; // Unknown artist object
  LibraryArtist[string] artists; // Map of artist names to LibraryArtist object

private:
  Daphne _daphne; // Daphne app object
  string[] _extFilter; // File extension filter
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
