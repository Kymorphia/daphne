module song;

import std.algorithm : map;
import std.array : array;
import std.conv : to;
import std.exception : ifThrown;
import std.range : iota;

import gda.data_model;
import gda.global : valueIsNull;
import gobject.types : GTypeEnum;
import gobject.value;

/// A song object
class Song
{
  enum MinYear = 1000; // Gregorian chants encoded on stone tablets
  enum MaxYear = 3000; // Time traveling tunes
  enum MaxTrack = 1000; // That's probably enough tracks per disk
  enum MaxDisc = 1000; // 1000 disc box set
  enum MaxLength = 100 * 3600; // 100 hour song length should be good

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

  this()
  {
  }

  /**
   * Create a song from a row in a DataModel (as returned from an SQL select statement).
   * Params:
   *   model = The data model
   *   row = The row index
   */
  this(DataModel model, int row)
  { // Get the column values for the row
    auto r = getSqlColumns.length.iota.map!(col => model.getValueAt(cast(int)col, row))
      .map!(v => !v.valueIsNull ? v : null).array; // GTypeEnum.Invalid is used for null

    filename = r[0] ? r[0].get!string : null;
    title = r[1] ? r[1].get!string : null;
    artist = r[2] ? r[2].get!string : null;
    album = r[3] ? r[3].get!string : null;
    genre = r[4] ? r[4].get!string : null;
    year = r[5] ? r[5].get!int : 0;
    track = r[6] ? r[6].get!int : 0;
    disc = r[7] ? r[7].get!int : 0;
    length = r[8] ? r[8].get!int : 0;
    rating = r[9] ? r[9].get!int.to!ubyte.ifThrown(cast(ubyte)0) : 0;

    validate;
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

  // Get SQL column names for inserts/updates
  static string[] getSqlColumns()
  {
    return ["filename", "title", "artist", "album", "genre", "year", "track", "disc", "length", "rating"];
  }

  // Get SQL field values for inserts/updates
  Value[] getSqlValues()
  {
    return [
      new Value(filename),
      new Value(title),
      new Value(artist),
      new Value(album),
      new Value(genre),
      new Value(year),
      new Value(track),
      new Value(disc),
      new Value(length),
      new Value(rating),
    ];
  }

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
