module artist_view;

import std.algorithm : canFind, endsWith, map, sort, startsWith;
import std.array : array;
import std.conv : to;
import std.signals;
import std.string : cmp, toLower;

import gettext;
import gio.list_model;
import gio.list_store;
import gobject.object;
import gobject.types : GTypeEnum;
import gobject.value;
import gtk.bitset;
import gtk.bitset_iter;
import gtk.box;
import gtk.column_view;
import gtk.column_view_column;
import gtk.custom_filter;
import gtk.custom_sorter;
import gtk.filter_list_model;
import gtk.label;
import gtk.list_item;
import gtk.multi_selection;
import gtk.scrolled_window;
import gtk.search_entry;
import gtk.selection_model;
import gtk.signal_list_item_factory;
import gtk.sort_list_model;
import gtk.text;
import gtk.types : FilterChange, Orientation;

import daphne;
import library;
import song;

/// Artist view widget
class ArtistView : Box
{
  this(Daphne daphne)
  {
    super(Orientation.Vertical, 0);
    _daphne = daphne;

    _searchEntry = new SearchEntry;
    _searchEntry.connectSearchChanged(&onSearchEntryChanged);
    _searchEntry.searchDelay = 500;
    append(_searchEntry);

    _scrolledWindow = new ScrolledWindow;
    _scrolledWindow.setVexpand(true);
    _scrolledWindow.setHexpand(true);
    append(_scrolledWindow);

    _listModel = new ListStore(GTypeEnum.Object);

    foreach (artist; _daphne.library.artists)
      _listModel.append(artist);

    _searchFilter = new CustomFilter(&searchFilterFunc);
    auto filterListModel = new FilterListModel(_listModel, _searchFilter); // Used to filter on search text
    _sortModel = new SortListModel(filterListModel, new CustomSorter(&artistSorter));
    _selModel = new MultiSelection(_sortModel);
    _columnView = new ColumnView(_selModel);
    _scrolledWindow.setChild(_columnView);

    _selModel.connectSelectionChanged(&onSelectionModelChanged);

    auto factory = new SignalListItemFactory();
    factory.connectSetup(&onArtistSetup);
    factory.connectBind(&onArtistBind);
    auto col = new ColumnViewColumn(tr!"Artist", factory);
    _columnView.appendColumn(col);
    col.expand = true;
    col.resizable = true;

    factory = new SignalListItemFactory();
    factory.connectSetup(&onSongCountSetup);
    factory.connectBind(&onSongCountBind);
    col = new ColumnViewColumn(tr!"Songs", factory);
    _columnView.appendColumn(col);
    col.expand = false;
    col.resizable = true;
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

    if (change != FilterChange.LessStrict)
      onSelectionModelChanged; // Force the selection to update to unselect any items which got hidden
  }

  private bool searchFilterFunc(ObjectWrap item)
  {
    auto artist = cast (LibraryArtist)item;
    return artist.songCount > 1 // Filter out songs with only 1 song
      && (_searchString.length == 0 || (cast(LibraryItem)item).name.toLower.canFind(_searchString));
  }

  private int artistSorter(ObjectWrap aObj, ObjectWrap bObj)
  {
    auto artistA = cast(LibraryArtist)aObj;
    auto artistB = cast(LibraryArtist)bObj;
    return cmp(artistA.name, artistB.name);
  }

  private void onSelectionModelChanged()
  {
    selection = [];
    BitsetIter iter;
    uint position;

    if (BitsetIter.initFirst(iter, _selModel.getSelection, position))
    {
      do
      {
        selection ~= cast(LibraryArtist)_selModel.getItem(position);
      }
      while (iter.next(position));
    }

    selectionChanged.emit(selection);
  }

  private void onArtistSetup(ListItem listItem)
  {
    auto text = new Text;
    text.hexpand = true;
    listItem.setChild(text);
  }

  private void onArtistBind(ListItem listItem)
  {
    auto artist = cast(LibraryArtist)listItem.getItem;
    auto text = cast(Text)listItem.getChild;
    text.getBuffer.setText(artist.name, -1);
    text.setEditable(false);
    text.setCanFocus(false);
    text.setCanTarget(false);
    text.setFocusOnClick(false);
  }

  private void onSongCountSetup(ListItem listItem)
  {
    listItem.setChild(new Label);
  }

  private void onSongCountBind(ListItem listItem)
  {
    (cast(Label)listItem.getChild).setText((cast(LibraryArtist)listItem.getItem).songCount.to!string);
  }

  /**
   * Add an artist to the view.
   */
  void addArtist(LibraryArtist artist)
  {
    _listModel.append(artist);
  }

  mixin Signal!(LibraryArtist[]) selectionChanged; /// Selected artists changed signal

  LibraryArtist[] selection;

private:
  Daphne _daphne;
  SearchEntry _searchEntry;
  string _searchString;
  ScrolledWindow _scrolledWindow;
  ListStore _listModel;
  SortListModel _sortModel;
  MultiSelection _selModel;
  CustomFilter _searchFilter;
  ColumnView _columnView;
}
