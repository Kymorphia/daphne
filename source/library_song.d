module library_song;

import std.conv : to;
import std.exception : ifThrown;
import std.string : strip;

import ddbc : PreparedStatement, ResultSet;
import gdk.texture;
import glib.bytes;
import taglib;

import library_album;
import library_item;
import prop_iface;

/// A song structure for POD loading from DB
class LibrarySong : LibraryItem, PropIface
{
  enum MinYear = 1000; // Gregorian chants encoded on stone tablets
  enum MaxYear = 3000; // Time traveling tunes
  enum MaxTrack = 999; // That's probably enough tracks per disk
  enum MaxDisc = 999; // 1000 disc box set
  enum MaxLength = 99 * 3600; // 99 hour song length should be good
  enum MaxRating = 11; // Because 11 is better than 10

  struct PropDef
  {
    @Desc("Table ID") long id;
    @Desc("Filename") string filename;
    @Desc("Title") string title;
    @Desc("Artist") string artist;
    @Desc("Album") string album;
    @Desc("Genre") string genre;
    @Desc("Year") uint year;
    @Desc("Track") uint track;
    @Desc("Disc") uint disc;
    @Desc("Length in seconds") uint length;
    @Desc("Rating") @RangeValue("0", "MaxRating") ubyte rating;
    @Desc("Album object") LibraryAlbum libAlbum;
  }

  mixin(definePropIface!(PropDef, true));

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
    _props.filename = rs.getString(1);
    _props.title = rs.getString(2);
    _props.artist = rs.getString(3);
    _props.album = rs.getString(4);
    _props.genre = rs.getString(5);
    _props.year = rs.getUint(6);
    _props.track = rs.getUint(7);
    _props.disc = rs.getUint(8);
    _props.length = rs.getUint(9);
    _props.rating = rs.getUbyte(10);
    _props.id = rs.getLong(11);

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
    song._props.filename = filename;
    song._props.title = tagFile.title.strip;
    song._props.artist = tagFile.artist.strip;
    song._props.album = tagFile.album.strip;
    song._props.genre = tagFile.genre.strip;
    song._props.year = tagFile.year;
    song._props.track = tagFile.track;
    song._props.length = tagFile.length;

    auto discNumberVals = tagFile.getProp("DISCNUMBER");
    song._props.disc = discNumberVals.length > 0 ? discNumberVals[0].strip.to!uint.ifThrown(0) : 0; // FIXME - Seen this in the form of "N / TOTAL"

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
    auto tagFile = new TagFile(_props.filename);
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
    if (_props.year > 0 && (_props.year < MinYear || _props.year > MaxYear))
      year = 0;

    if (_props.track > 0 && _props.track > MaxTrack)
      track = 0;

    if (_props.disc > 0 && _props.disc > MaxDisc)
      disc = 0;

    if (_props.length > 0 && _props.length > MaxLength)
      length = 0;
  }

  /**
   * Store song SQL field values to prepared statement.
   */
  void storeSqlValues(PreparedStatement ps)
  {
    ps.setString(1, _props.filename);
    ps.setString(2, _props.title);
    ps.setString(3, _props.artist);
    ps.setString(4, _props.album);
    ps.setString(5, _props.genre);
    ps.setUint(6, _props.year);
    ps.setUint(7, _props.track);
    ps.setUint(8, _props.disc);
    ps.setUint(9, _props.length);
    ps.setUbyte(10, _props.rating);
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
