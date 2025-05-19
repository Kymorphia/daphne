module song_display;

import std.exception : ifThrown;

import gdk.texture;
import gettext;
import glib.bytes;
import gtk.box;
import gtk.frame;
import gtk.grid;
import gtk.image;
import gtk.label;
import gtk.picture;
import gtk.types : Orientation;
import pango.types : EllipsizeMode;

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

    auto frame = new Frame;
    frame.marginTop = 4;
    frame.marginBottom = 4;
    frame.marginStart = 4;
    frame.marginEnd = 4;
    append(frame);

    auto box = new Box(Orientation.Vertical, 0);
    box.marginTop = 4;
    box.marginBottom = 4;
    box.marginStart = 4;
    box.marginEnd = 4;
    frame.setChild(box);

    _titleLabel = new Label;
    _titleLabel.ellipsize = EllipsizeMode.End;
    box.append(_titleLabel);

    _artistLabel = new Label;
    _artistLabel.ellipsize = EllipsizeMode.End;
    box.append(_artistLabel);

    _albumLabel = new Label;
    _albumLabel.ellipsize = EllipsizeMode.End;
    box.append(_albumLabel);

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

    _titleLabel.label = _song ? _song.song.title : "";
    _titleLabel.tooltipText = _song ? _song.song.title : "";

    _artistLabel.label = _song ? _song.song.artist : "";
    _artistLabel.tooltipText = _song ? _song.song.title : "";

    _albumLabel.label = _song ? _song.song.album : "";
    _albumLabel.tooltipText = _song ? _song.song.title : "";

    auto texture = _song ? getAlbumCover(_song) : null;

    picture.setPaintable(texture ? texture : _goldRecord);
    picture.queueDraw; // FIXME - Sometimes does not update without this, when same texture size maybe? Seems like a Gtk bug.
  }

  Picture picture;

private:
  Texture _goldRecord;
  Daphne _daphne;
  LibrarySong _song;
  Label _titleLabel;
  Label _artistLabel;
  Label _albumLabel;
}
