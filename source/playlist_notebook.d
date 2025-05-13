module playlist_notebook;

import gtk.notebook;

import daphne;

/// Playlist tabbed notebook
class PlaylistNotebook : Notebook
{
  this(Daphne daphne)
  {
    _daphne = daphne;
  }

private:
  Daphne _daphne;
}
