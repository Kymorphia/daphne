module album_view;

import std.algorithm : canFind, endsWith, map, sort, startsWith;
import std.array : array;
import std.conv : to;
import std.signals;
import std.string : toLower;

import gettext;
import gio.list_model;
import gio.list_store;
import glib.global : timeoutAdd;
import glib.source;
import glib.types : PRIORITY_DEFAULT, SOURCE_REMOVE;
import gobject.object;
import gobject.types : GTypeEnum;
import gobject.value;
import gtk.bitset;
import gtk.bitset_iter;
import gtk.box;
import gtk.column_view;
import gtk.column_view_column;
import gtk.custom_filter;
import gtk.filter_list_model;
import gtk.label;
import gtk.list_item;
import gtk.multi_selection;
import gtk.scrolled_window;
import gtk.search_entry;
import gtk.selection_model;
import gtk.signal_list_item_factory;
import gtk.text;
import gtk.types : FilterChange, Orientation;

import daphne;
import library;
import song;

/// Album view widget
class AlbumView : Box
{
  this(Daphne daphne)
  {
    super(Orientation.Vertical, 0);
    _daphne = daphne;

    _searchEntry = new SearchEntry;
    _searchChangedHandler = _searchEntry.connectSearchChanged(&onSearchEntryChanged);
    _searchEntry.searchDelay = 500;
    append(_searchEntry);

    _scrolledWindow = new ScrolledWindow;
    _scrolledWindow.setVexpand(true);
    _scrolledWindow.setHexpand(true);
    append(_scrolledWindow);

    _listModel = new ListStore(GTypeEnum.Object);

    foreach (artistName; _daphne.library.artists.keys.array.sort)
    {
      auto artist = _daphne.library.artists[artistName];
      foreach (albumName; artist.albums.keys.array.sort)
      {
        auto album = artist.albums[albumName];
        if (album.songCount > 1) // Filter out albums with only 1 song
          _listModel.append(album);
      }
    }

    _searchFilter = new CustomFilter(&searchFilterFunc);
    auto filterListModel = new FilterListModel(_listModel, _searchFilter); // Used to filter on search text
    _selModel = new MultiSelection(filterListModel);
    _columnView = new ColumnView(_selModel);
    _scrolledWindow.setChild(_columnView);

    _selModel.connectSelectionChanged(&onSelectionModelChanged);

    auto factory = new SignalListItemFactory();
    factory.connectSetup(&onAlbumSetup);
    factory.connectBind(&onAlbumBind);
    auto col = new ColumnViewColumn(tr!"Album", factory);
    _columnView.appendColumn(col);
    col.expand = true;
    col.resizable = true;

    factory = new SignalListItemFactory();
    factory.connectSetup(&onArtistSetup);
    factory.connectBind(&onArtistBind);
    col = new ColumnViewColumn(tr!"Artist", factory);
    _columnView.appendColumn(col);
    col.expand = true;
    col.resizable = true;

    factory = new SignalListItemFactory();
    factory.connectSetup(&onYearSetup);
    factory.connectBind(&onYearBind);
    col = new ColumnViewColumn(tr!"Year", factory);
    _columnView.appendColumn(col);
    col.expand = false;
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
    else if (_searchString.startsWith(newSearch) || _searchString.endsWith(newSearch)) // Were characters removed from start or end?
      change = FilterChange.LessStrict;

    _searchString = newSearch;
    _searchFilter.changed(change);

    if (change != FilterChange.LessStrict)
      onSelectionModelChanged; // Force the selection to update to unselect any items which got hidden
  }

  private bool searchFilterFunc(ObjectWrap item)
  {
    auto album = cast(LibraryAlbum)item;

    return (_searchString.length == 0 || album.name.toLower.canFind(_searchString))
      && (_filterArtists.length == 0 || _filterArtists.canFind(album.artist));
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
        selection ~= cast(LibraryAlbum)_selModel.getItem(position);
      }
      while (iter.next(position));
    }

    selectionChanged.emit(selection);
  }

  private void onAlbumSetup(ListItem listItem)
  {
    auto text = new Text;
    text.hexpand = true;
    listItem.setChild(text);
  }

  private void onAlbumBind(ListItem listItem)
  {
    auto album = cast(LibraryAlbum)listItem.getItem;
    auto text = cast(Text)listItem.getChild;
    text.getBuffer.setText(album.name, -1);
    text.setEditable(false);
    text.setCanFocus(false);
    text.setCanTarget(false);
    text.setFocusOnClick(false);
  }

  private void onArtistSetup(ListItem listItem)
  {
    auto text = new Text;
    text.hexpand = true;
    listItem.setChild(text);
  }

  private void onArtistBind(ListItem listItem)
  {
    auto album = cast(LibraryAlbum)listItem.getItem;
    auto text = cast(Text)listItem.getChild;
    text.getBuffer.setText(album.artist.name, -1);
    text.setEditable(false);
    text.setCanFocus(false);
    text.setCanTarget(false);
    text.setFocusOnClick(false);
  }

  private void onYearSetup(ListItem listItem)
  {
    listItem.setChild(new Label);
  }

  private void onYearBind(ListItem listItem)
  {
    auto year = (cast(LibraryAlbum)listItem.getItem).year;
    (cast(Label)listItem.getChild).setText(year > 0 ? year.to!string : null);
  }

  private void onSongCountSetup(ListItem listItem)
  {
    listItem.setChild(new Label);
  }

  private void onSongCountBind(ListItem listItem)
  {
    (cast(Label)listItem.getChild).setText((cast(LibraryAlbum)listItem.getItem).songCount.to!string);
  }

  /**
   * Set the filter of artists to show albums for.
   * Params:
   *   artists = List of artists to filter by or empty/null to not filter
   */
  void setArtists(LibraryArtist[] artists)
  {
    _filterArtists = artists;
    _searchFilter.changed(FilterChange.Different);
    // _selModel.selectionChanged(0, )
  }

  mixin Signal!(LibraryAlbum[]) selectionChanged; /// Selected albums changed signal

  LibraryAlbum[] selection;

private:
  Daphne _daphne;
  SearchEntry _searchEntry;
  ulong _searchChangedHandler; // connectSearchChanged handler
  string _searchString;
  ScrolledWindow _scrolledWindow;
  MultiSelection _selModel;
  ListStore _listModel;
  CustomFilter _searchFilter;
  ColumnView _columnView;

  LibraryArtist[] _filterArtists;
}
