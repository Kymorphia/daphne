module drag_node;

import gobject.object;
import gobject.types : GTypeEnum;

import library;
import song;

/// A ObjectWrap derived class for drag/drop of a LibraryNode/Song
/// Used with DragSource and DropTarget in order to pass through GValue
class DragNode : ObjectWrap
{
  mixin(objectMixin);

  this(Object songOrNode)
  {
    assert(cast(LibraryNode)songOrNode || cast(Song)songOrNode);

    super(GTypeEnum.Object);
    _songOrNode = songOrNode;
  }

  @property Object songOrNode()
  {
    return _songOrNode;
  }

private:
  Object _songOrNode;
}
