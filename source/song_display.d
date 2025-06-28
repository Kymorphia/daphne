module song_display;

import daphne_includes;

import daphne;
import library;

enum string goldRecordSvg = import("gold_record.svg");

/// Song display widget (album cover, title, artist, album)
class SongDisplay : Box
{
  enum DefaultPictureSize = 300;

  this(Daphne daphne)
  {
    super(Orientation.Vertical, 0);
    _daphne = daphne;

    if (!_goldRecord)
    {
      auto bytes = new Bytes(cast(ubyte[])goldRecordSvg);
      _goldRecord = Texture.newFromBytes(bytes).ifThrown(null);
    }

    picture = new Picture;
    picture.hexpand = true;
    picture.vexpand = true;
    picture.canShrink = true;
    picture.widthRequest = DefaultPictureSize; // FIXME - Cannot shrink smaller than this
    picture.heightRequest = DefaultPictureSize;
    picture.setPaintable(_goldRecord);
    append(picture);
  }

  @property LibrarySong song()
  {
    return _song;
  }

  @property void song(LibrarySong val)
  {
    _song = val;

    auto texture = _song ? _song.getPicture : null;

    picture.setPaintable(texture ? texture : _goldRecord);
    picture.queueDraw; // FIXME - Sometimes does not update without this, when same texture size maybe? Seems like a Gtk bug.
  }

  Picture picture;

private:
  Texture _goldRecord;
  Daphne _daphne;
  LibrarySong _song;
}
