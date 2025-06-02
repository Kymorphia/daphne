module library_artist;

import gettext;

import library_album;
import library_item;

/// Artist library node
class LibraryArtist : LibraryItem
{
  this(string name)
  {
    _name = name;
  }

  override @property string name() { return _name; }

  LibraryAlbum[string] albums;
  uint songCount; // Count of songs for artist

private:
  string _name;
}
