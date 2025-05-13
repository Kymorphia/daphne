module music_browser;

import std.algorithm : canFind, endsWith, map, sort, startsWith;
import std.string : toLower;

import gettext;
import gdk.content_provider;
import gdk.rectangle;
import gio.list_model;
import gio.list_store;
import gio.simple_action;
import gio.simple_action_group;
import gobject.object;
import gobject.types : GTypeEnum;
import gobject.value;
import gtk.bitset;
import gtk.bitset_iter;
import gtk.box;
import gtk.column_view;
import gtk.column_view_column;
import gtk.custom_filter;
import gtk.drag_source;
import gtk.event_controller_key;
import gtk.filter_list_model;
import gtk.gesture_click;
import gtk.image;
import gtk.label;
import gtk.list_item;
import gtk.multi_selection;
import gtk.scrolled_window;
import gtk.search_entry;
import gtk.selection_model;
import gtk.signal_list_item_factory;
import gtk.text;
import gtk.tree_expander;
import gtk.tree_list_model;
import gtk.tree_list_row;
import gtk.types : FilterChange, IconSize, Orientation, PickFlags;

import daphne;
import drag_node;
import library;
import song;

/// Music browser tree view
class MusicBrowser : Box
{
  this(Daphne daphne)
  {
    super(Orientation.Vertical, 0);
    _daphne = daphne;

    _searchEntry = new SearchEntry;
    _searchEntry.connectChanged(&onSearchEntryChanged);
    append(_searchEntry);

    _scrolledWindow = new ScrolledWindow;
    _scrolledWindow.setVexpand(true);
    _scrolledWindow.setHexpand(true);
    append(_scrolledWindow);

    _listModelRoot = createListModel(createBrowserItem(_daphne.library.treeRoot));
    _searchFilter = new CustomFilter(&searchFilterFunc);
    auto filterListModel = new FilterListModel(_listModelRoot, _searchFilter); // Used to filter on search text
    _treeListModel = new TreeListModel(filterListModel, false, false, &createListModel); // root, passthrough, autoexpand, createFunc
    _selModel = new MultiSelection(_treeListModel);
    _columnView = new ColumnView(_selModel);
    _scrolledWindow.setChild(_columnView);

    _selModel.connectSelectionChanged(&onSelectionModelChanged);

    auto factory = new SignalListItemFactory();
    factory.connectSetup(&onNameItemSetup);
    factory.connectBind(&onNameItemBind);
    factory.connectUnbind(&onNameItemUnbind);
    auto col = new ColumnViewColumn(tr!"Name", factory);
    _columnView.appendColumn(col);
    col.setExpand(true);

    auto gestureClick = new GestureClick();
    addController(gestureClick);
    gestureClick.setButton(3);
    gestureClick.connectPressed(&onRightClick);
  }

  private void onSearchEntryChanged()
  {
    auto newSearch = _searchEntry.text.toLower;

    if (newSearch == _searchString)
      return;

    auto change = FilterChange.Different;

    if (newSearch.startsWith(_searchString) || newSearch.endsWith(_searchString)) // Was search string appended or prepended to?
      change = FilterChange.MoreStrict;
    else if (_searchString.startsWith(newSearch) || _searchString.endsWith(newSearch)) // Were characters removed from start or beginning?
      change = FilterChange.LessStrict;

    _searchString = newSearch;
    _searchFilter.changed(change);
  }

  private ListModel createListModel(ObjectWrap item)
  {
    auto listStore = new ListStore(GTypeEnum.Object);
    auto listItem = cast(BrowserItem)item;
    listItem.listStore = listStore;

    if (auto libNode = cast(LibraryNode)listItem.songOrNode)
    {
      if (libNode.type == LibraryNode.Type.Root || libNode.type == LibraryNode.Type.Artist) // Children are Artists or Albums
      {
        if (libNode.unknown)
          listStore.append(createBrowserItem(libNode.unknown)); // Unknown Artist/Album comes first

        foreach (childNode; libNode.nodes.keys.sort.map!(k => libNode.nodes[k]))
          listStore.append(createBrowserItem(childNode));
      }
      else // Album children are Songs
      {
        foreach (song; libNode.songs)
          listStore.append(createBrowserItem(song));
      }
    }

    return listStore;
  }

  private BrowserItem createBrowserItem(Object songOrNode)
  {
    assert(cast(LibraryNode)songOrNode || cast(Song)songOrNode);

    if (auto browserItem = songOrNode in browserItemHash)
      return *browserItem;

    auto browserItem = new BrowserItem(songOrNode);
    browserItemHash[songOrNode] = browserItem;
    return browserItem;
  }

  private bool searchFilterFunc(ObjectWrap item)
  {
    return _searchString.length == 0 || (cast(BrowserItem)item).name.toLower.canFind(_searchString);
  }

  private void onSelectionModelChanged(uint position, uint nItems, SelectionModel model)
  {
  }

  private void onNameItemSetup(ObjectWrap obj, SignalListItemFactory factory)
  {
    auto treeExpander = new TreeExpander();
    auto listItem = cast(ListItem)obj;
    listItem.setChild(treeExpander);

    auto box = new Box(Orientation.Horizontal, 4);
    treeExpander.setChild(box);

    auto image = new Image;
    box.append(image);
    image.setIconSize(IconSize.Normal);

    auto text = new Text;
    text.hexpand = true;
    box.append(text);
  }

  private void onNameItemBind(ObjectWrap obj, SignalListItemFactory factory)
  {
    auto listItem = cast(ListItem)obj;
    auto treeListRow = cast(TreeListRow)listItem.getItem;
    auto browserItem = cast(BrowserItem)treeListRow.getItem;

    auto treeExpander = cast(TreeExpander)listItem.getChild;
    auto image = cast(Image)treeExpander.getChild.getFirstChild; // Get first widget of Box
    auto text = cast(Text)image.getNextSibling;

    browserItem.treeExpander = treeExpander;
    treeExpanderPosHash[treeExpander] = listItem.getPosition;

    treeExpander.setListRow(treeListRow);
    treeExpander.setHideExpander(!browserItem.hasChildren);
    image.setFromIconName(browserItem.iconName);
    text.getBuffer.setText(browserItem.name, -1);
    text.setEditable(false);
    text.setCanFocus(false);
    text.setCanTarget(false);
    text.setFocusOnClick(false);

    browserItem.dragSource = new DragSource;
    browserItem.dragSource.setContent(ContentProvider.newForValue(new Value(new DragNode(browserItem.songOrNode))));
    treeExpander.addController(browserItem.dragSource);
  }

  private void onNameItemUnbind(ObjectWrap obj, SignalListItemFactory factory)
  {
    auto listItem = cast(ListItem)obj;
    auto treeListRow = cast(TreeListRow)listItem.getItem;
    auto browserItem = cast(BrowserItem)treeListRow.getItem;

    if (browserItem.treeExpander)
    {
      treeExpanderPosHash.remove(browserItem.treeExpander);
      browserItem.treeExpander.removeController(browserItem.dragSource);
    }

    browserItem.dragSource = null;
    browserItem.treeExpander = null;
  }

  private void onRightClick(int n_press, double x, double y, GestureClick gestureClick)
  {
    // Check if right click is on a selected item, if not make it the new selection
    auto clickedWidget = gestureClick.getWidget.pick(x, y, PickFlags.Default);

    for (auto widg = clickedWidget; widg; widg = widg.getParent)
    {
      if (auto treeExpander = cast(TreeExpander)widg)
      {
        auto pos = treeExpanderPosHash[treeExpander];

        if (!_selModel.isSelected(pos))
          _selModel.selectItem(pos, true);

        break;
      }
    }
  }

private:
  Daphne _daphne;
  SearchEntry _searchEntry;
  string _searchString;
  ScrolledWindow _scrolledWindow;
  MultiSelection _selModel;
  ListModel _listModelRoot;
  CustomFilter _searchFilter;
  TreeListModel _treeListModel;
  ColumnView _columnView;
  BrowserItem[Object] browserItemHash;
  uint[TreeExpander] treeExpanderPosHash;
}

/// GObject wrapper for a library tree item for use with GListModel in a ColumnView
class BrowserItem : ObjectWrap
{
  mixin(objectMixin);

  this()
  {
    super(GTypeEnum.Object);
  }

  this(Object songOrNode)
  {
    super(GTypeEnum.Object);
    this.songOrNode = songOrNode;
  }

  @property Text text()
  {
    if (!treeExpander)
      return null;

    return cast(Text)treeExpander.getChild.getFirstChild.getNextSibling;
  }

  // Get name of item
  @property string name()
  {
    if (!songOrNode)
      return null;
    else if (auto libNode = cast(LibraryNode)songOrNode)
      return libNode.name;
    else // Song
      return (cast(Song)songOrNode).title;
  }

  // Check if a BrowserItem has any children
  @property bool hasChildren()
  {
    if (!songOrNode)
      return false;
    else if (auto libNode = cast(LibraryNode)songOrNode)
      return libNode.unknown || libNode.nodes.length > 0 || libNode.songs.length > 0;
    else // Song
      return false;
  }

  // Get icon name for item
  @property string iconName()
  {
    if (auto libNode = cast(LibraryNode)songOrNode)
    {
      if (libNode.type == LibraryNode.Type.Artist)
        return "audio-input-microphone";
      else if (libNode.type == LibraryNode.Type.Album)
        return "media-optical";
    }
    else if (songOrNode) // Song
      return "multimedia-player";

    return null;
  }

  Object songOrNode; // LibraryNode (Artist or Album) or Song
  ListStore listStore;
  TreeExpander treeExpander;
  DragSource dragSource;
}
