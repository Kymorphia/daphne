module library_item;

class library_item;

import gobject.object;
import gobject.types : GTypeEnum;

enum UnknownName = "<Unknown>"; /// Name used for unknown artist or album names

/// An base class for library items (artists, albums and songs)
class LibraryItem : ObjectWrap
{
  this()
  {
    super(GTypeEnum.Object);
  }

  mixin(objectMixin);

  @property string name() { return null; }
}
