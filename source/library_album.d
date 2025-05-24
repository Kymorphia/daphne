module library_album;

import library_artist;
import library_item;
import library_song;

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
