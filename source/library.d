module library;

import gettext;
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

/// Song library object
class Library
{
  enum UnknownName = "<Unknown>"; /// Name used for unknown artist or album names

  immutable string[] defaultExtensions = [
    "aac",
    "aif",
    "aiff",
    "ape",
    "flac",
    "m4a",
    "mp3",
    "ogg",
    "opus",
    "wav",
    "wma",
  ];

  this(Daphne daphne)
  {
    _daphne = daphne;
    treeRoot = new LibraryNode(LibraryNode.Type.Root);
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

        if (filename !in _songFiles)
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
    _songFiles[song.filename] = song;

    LibraryNode artistNode;

    if (song.artist.length > 0) // Is Artist set?
    {
      artistNode = treeRoot.nodes.get(song.artist, null);

      if (!artistNode) // No node for Artist?
      { // Create Artist node and add to map
        artistNode = new LibraryNode(LibraryNode.Type.Artist);
        artistNode.name = song.artist;
        treeRoot.nodes[song.artist] = artistNode;
      }
    }
    else // Empty Artist name
    {
      if (!treeRoot.unknown) // Unknown artist node not yet created?
      { // Create unknown artist node
        treeRoot.unknown = new LibraryNode(LibraryNode.Type.Artist);
        treeRoot.unknown.name = tr!UnknownName;
      }

      artistNode = treeRoot.unknown;
    }

    LibraryNode albumNode;

    if (song.album.length > 0) // Is Album set?
    {
      albumNode = artistNode.nodes.get(song.album, null);

      if (!albumNode) // No node for Album?
      { // Create Album node and add to map
        albumNode = new LibraryNode(LibraryNode.Type.Album);
        albumNode.name = song.album;
        artistNode.nodes[song.album] = albumNode;
      }
    }
    else // Empty Album name
    {
      if (!artistNode.unknown) // Unknown album node not yet created?
      { // Create unknown album node
        artistNode.unknown = new LibraryNode(LibraryNode.Type.Album);
        artistNode.unknown.name = tr!UnknownName;
      }

      albumNode = artistNode.unknown;
    }

    bool songSortFunc(Song a, Song b) // Sort album songs by track number, showing songs with track numbers first, falling back to sorting by filename
    {
      auto aTrack = a.track > 0 ? a.track : uint.max;
      auto bTrack = b.track > 0 ? b.track : uint.max;
      return aTrack < bTrack || (aTrack == bTrack && a.filename.baseName < b.filename.baseName);
    }

    auto sortedSongs = assumeSorted!(songSortFunc)(albumNode.songs);
    auto index = sortedSongs.lowerBound(song).length;
    albumNode.songs.insertInPlace(index, song);
  }

  LibraryNode treeRoot; // Library node tree root (Artist->Album->Song)

private:
  Daphne _daphne; // Daphne app object
  Song[string] _songFiles; // Map of filenames to Song objects
  string[] _extFilter; // File extension filter
}

/// A hierarchical node in a Artist->Album->Song tree
class LibraryNode
{
  /// Node type
  enum Type
  {
    Root, /// Root node
    Artist, /// Artist node
    Album, /// Album node
  }

  this(Type type)
  {
    this.type = type;
  }

  Type type; /// Node type
  string name; /// Name of Artist or Album
  LibraryNode unknown; /// Node for unknown names (Root or Artist nodes only, for unknown Artist or Album respectively)
  LibraryNode[string] nodes; /// Map of children nodes keyed by name (Artist or Album) -> LibraryNode (Root or Artist nodes only)
  Song[] songs; /// Songs sorted by track number or filename (for Album nodes only)
}
