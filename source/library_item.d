module library_item;

import daphne_includes;

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
