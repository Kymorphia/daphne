module library_song;

import std.conv : to;
import std.exception : ifThrown;

import ddbc : PreparedStatement, ResultSet;
import gdk.texture;
import glib.bytes;
import taglib;

import library_album;
import library_item;

/// A song structure for POD loading from DB
class LibrarySong : LibraryItem
{
  enum MinYear = 1000; // Gregorian chants encoded on stone tablets
  enum MaxYear = 3000; // Time traveling tunes
  enum MaxTrack = 1000; // That's probably enough tracks per disk
  enum MaxDisc = 1000; // 1000 disc box set
  enum MaxLength = 100 * 3600; // 100 hour song length should be good

  long id;
  string filename;
  string title;
  string artist;
  string album;
  string genre;
  uint year;
  uint track;
  uint disc;
  uint length;
  ubyte rating;
  LibraryAlbum libAlbum;

  this()
  {
  }

  /**
   * Create a new Song object from a ddbc ResultSet.
   * Params:
   *   rs = The result set
   */
  this(ResultSet rs)
  {
    filename = rs.getString(1);
    title = rs.getString(2);
    artist = rs.getString(3);
    album = rs.getString(4);
    genre = rs.getString(5);
    year = rs.getUint(6);
    track = rs.getUint(7);
    disc = rs.getUint(8);
    length = rs.getUint(9);
    rating = rs.getUbyte(10);
    id = rs.getLong(11);

    validate;
  }

  /**
   * Create a song from the tags loaded from a taglib file.
   * Params:
   *   filename = The name of the file to load tags from
   * Returns: The new LibrarySong object or null if filename is not a valid taglib file or an error occurred
   */
  static LibrarySong createFromTagFile(string filename)
  {
    auto tagFile = new TagFile(filename);
    scope(exit) tagFile.close; // Explicitly close the TagFile to free file handle, rather than waiting for it to be GC'd

    if (!tagFile.isValid)
      return null;

    auto song = new LibrarySong;
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

  override @property string name() { return title; }

  /**
    * Get a picture from a song file using TagLib.
    * Returns: Texture of the picture retrieved from the song or null if none/error
    */
  Texture getPicture()
  {
    auto tagFile = new TagFile(filename);
    if (!tagFile.isValid)
      return null;

    auto pictureProps = tagFile.getComplexProp("PICTURE");
    if ("data" !in pictureProps)
      return null;

    auto bytes = new Bytes(cast(ubyte[])pictureProps["data"].getByteArray);
    return Texture.newFromBytes(bytes).ifThrown(null);
  }

  /**
   * Validate the values and set them to defaults if invalid.
   */
  void validate()
  {
    if (year > 0 && (year < MinYear || year > MaxYear))
      year = 0;

    if (track > 0 && track > MaxTrack)
      track = 0;

    if (disc > 0 && disc > MaxDisc)
      disc = 0;

    if (length > 0 && length > MaxLength)
      length = 0;
  }

  /**
   * Store song SQL field values to prepared statement.
   */
  void storeSqlValues(PreparedStatement ps)
  {
    ps.setString(1, filename);
    ps.setString(2, title);
    ps.setString(3, artist);
    ps.setString(4, album);
    ps.setString(5, genre);
    ps.setUint(6, year);
    ps.setUint(7, track);
    ps.setUint(8, disc);
    ps.setUint(9, length);
    ps.setUbyte(10, rating);
  }

  // Get SQL column names for inserts/updates, does not include id column
  static immutable(string[]) SqlColumns = [
    "filename", "title", "artist", "album", "genre", "year", "track", "disc", "length", "rating"
  ];

  // SQL field schema for creating library song table
  enum SqlSchema = "id INTEGER PRIMARY KEY,"
    ~ " filename string NOT NULL UNIQUE,"
    ~ " title string,"
    ~ " artist string,"
    ~ " album string,"
    ~ " genre string,"
    ~ " year int,"
    ~ " track int,"
    ~ " disc int,"
    ~ " length int,"
    ~ " rating int";
}
