module player;

import gtk.box;
import gtk.types : Orientation;

import daphne;

/// Player widget
class Player : Box
{
  this(Daphne daphne)
  {
    super(Orientation.Horizontal, 4);
    _daphne = daphne;
  }

private:
  Daphne _daphne;
}
