module song_view;

import std.algorithm : canFind, cmp, endsWith, map, sort, startsWith;
import std.array : array;
import std.conv : to;
import std.format : format;
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
import gtk.button;
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

/// Song view widget
class SongView : Box
{
  this(Daphne daphne)
  {
    super(Orientation.Vertical, 0);
    _daphne = daphne;

    auto hbox = new Box(Orientation.Horizontal, 0);
    append(hbox);

    _searchEntry = new SearchEntry;
    _searchChangedHandler = _searchEntry.connectSearchChanged(&onSearchEntryChanged);
    _searchEntry.searchDelay = 500;
    _searchEntry.hexpand = true;
    hbox.append(_searchEntry);

    _queueSongsButton = Button.newFromIconName("go-down");
    _queueSongsButton.hexpand = false;
    _queueSongsButton.tooltipText = tr!"Add songs to queue";
    hbox.append(_queueSongsButton);

    _queueSongsButton.connectClicked(&onAddSongsButtonClicked);

    _scrolledWindow = new ScrolledWindow;
    _scrolledWindow.setVexpand(true);
    _scrolledWindow.setHexpand(true);
    append(_scrolledWindow);

    _listModel = new ListStore(GTypeEnum.Object);

    foreach (song; _daphne.library.songFiles.values.sort!((a, b) => a.title < b.title))
      _listModel.append(song);

    _searchFilter = new CustomFilter(&searchFilterFunc);
    auto filterListModel = new FilterListModel(_listModel, _searchFilter); // Used to filter on search text
    _sortModel = new SortListModel(filterListModel, null);
    _selModel = new MultiSelection(_sortModel);
    _columnView = new ColumnView(_selModel);
    _columnView.addCssClass("data-table");
    _scrolledWindow.setChild(_columnView);

    _artistAlbumTrackSorter = new CustomSorter(&artistAlbumTrackSorter);

    _selModel.connectSelectionChanged(&onSelectionModelChanged);

    auto factory = new SignalListItemFactory();
    factory.connectSetup(&onTrackSetup);
    factory.connectBind(&onTrackBind);
    auto col = new ColumnViewColumn(tr!"Track", factory);
    _columnView.appendColumn(col);
    col.expand = false;
    col.resizable = true;

    factory = new SignalListItemFactory();
    factory.connectSetup(&onTitleSetup);
    factory.connectBind(&onTitleBind);
    col = new ColumnViewColumn(tr!"Title", factory);
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
    factory.connectSetup(&onAlbumSetup);
    factory.connectBind(&onAlbumBind);
    col = new ColumnViewColumn(tr!"Album", factory);
    _columnView.appendColumn(col);
    col.expand = true;
    col.resizable = true;

    factory = new SignalListItemFactory();
    factory.connectSetup(&onLengthSetup);
    factory.connectBind(&onLengthBind);
    col = new ColumnViewColumn(tr!"Length", factory);
    _columnView.appendColumn(col);
    col.expand = false;
    col.resizable = true;

    factory = new SignalListItemFactory();
    factory.connectSetup(&onYearSetup);
    factory.connectBind(&onYearBind);
    col = new ColumnViewColumn(tr!"Year", factory);
    _columnView.appendColumn(col);
    col.expand = false;
    col.resizable = true;
  }

  private void onAddSongsButtonClicked() // Callback for when queue songs button is clicked
  {
    if (selection.length == 0) // If no items are selected queue all of them
    {
      LibrarySong[] songs;

      foreach (i; 0 .. _sortModel.getNItems)
        songs ~= cast(LibrarySong)_sortModel.getItem(cast(uint)i);

      queueSongs.emit(songs);
    }
    else
      queueSongs.emit(selection); // Add selected items
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

  private bool searchFilterFunc(ObjectWrap item)
  {
    auto libSong = cast(LibrarySong)item;

    return (_searchString.length == 0 || libSong.name.toLower.canFind(_searchString)) // No search or search matches?
      && (_filterAlbums.length == 0 || _filterAlbums.canFind(libSong.libAlbum)) // And no albums filter or album matches
      && (_filterAlbums.length > 0 || _filterArtists.length == 0 || _filterArtists.canFind(libSong.libAlbum.artist)); // And albums filter or no artists filter or artist matches
  }

  private int artistAlbumTrackSorter(ObjectWrap aObj, ObjectWrap bObj)
  {
    auto aSong = cast(LibrarySong)aObj;
    auto bSong = cast(LibrarySong)bObj;

    if (aSong.artist < bSong.artist)
      return -1;
    else if (aSong.artist > bSong.artist)
      return 1;
    else if (aSong.libAlbum.year > bSong.libAlbum.year) // Reverse order album year (newest first)
      return -1;
    else if (aSong.libAlbum.year < bSong.libAlbum.year) // Reverse order album year (newest first)
      return 1;
    else if (aSong.libAlbum.name < bSong.libAlbum.name)
      return -1;
    else if (aSong.libAlbum.name > bSong.libAlbum.name)
      return 1;
    else if (aSong.track < bSong.track)
      return -1;
    else if (aSong.track > bSong.track)
      return 1;
    else
      return cmp(aSong.name, bSong.name);
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
        selection ~= cast(LibrarySong)_selModel.getItem(position);
      }
      while (iter.next(position));
    }

    selectionChanged.emit(selection);
  }

  private void onTrackSetup(ListItem listItem)
  {
    listItem.setChild(new Label);
  }

  private void onTrackBind(ListItem listItem)
  {
    auto track = (cast(LibrarySong)listItem.getItem).track;
    (cast(Label)listItem.getChild).setText(track > 0 ? track.to!string : null);
  }

  private void onTitleSetup(ListItem listItem)
  {
    auto text = new Text;
    text.hexpand = true;
    listItem.setChild(text);
  }

  private void onTitleBind(ListItem listItem)
  {
    auto song = (cast(LibrarySong)listItem.getItem);
    auto text = cast(Text)listItem.getChild;
    text.getBuffer.setText(song.title.length > 0 ? song.title : tr!UnknownName, -1);
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
    auto song = (cast(LibrarySong)listItem.getItem);
    auto text = cast(Text)listItem.getChild;
    text.getBuffer.setText(song.artist.length > 0 ? song.artist : tr!UnknownName, -1);
    text.setEditable(false);
    text.setCanFocus(false);
    text.setCanTarget(false);
    text.setFocusOnClick(false);
  }

  private void onAlbumSetup(ListItem listItem)
  {
    auto text = new Text;
    text.hexpand = true;
    listItem.setChild(text);
  }

  private void onAlbumBind(ListItem listItem)
  {
    auto song = (cast(LibrarySong)listItem.getItem);
    auto text = cast(Text)listItem.getChild;
    text.getBuffer.setText(song.album.length > 0 ? song.album : tr!UnknownName, -1);
    text.setEditable(false);
    text.setCanFocus(false);
    text.setCanTarget(false);
    text.setFocusOnClick(false);
  }

  private void onLengthSetup(ListItem listItem)
  {
    listItem.setChild(new Label);
  }

  private void onLengthBind(ListItem listItem)
  {
    auto length = (cast(LibrarySong)listItem.getItem).length;
    (cast(Label)listItem.getChild).setText(length > 0 ? format("%u:%02u", length / 60, length % 60) : null);
  }

  private void onYearSetup(ListItem listItem)
  {
    listItem.setChild(new Label);
  }

  private void onYearBind(ListItem listItem)
  {
    auto year = (cast(LibrarySong)listItem.getItem).year;
    (cast(Label)listItem.getChild).setText(year > 0 ? year.to!string : null);
  }

  /**
   * Set the filter of artists to show songs for.
   * Params:
   *   artists = List of artists to filter by or empty/null to not filter
   */
  void setArtists(LibraryArtist[] artists)
  {
    _filterArtists = artists;
    _searchFilter.changed(FilterChange.Different);
  }

  /**
   * Set the filter of albums to show songs for.
   * Params:
   *   albums = List of albums to filter by or empty/null to not filter
   */
  void setAlbums(LibraryAlbum[] albums)
  {
    _filterAlbums = albums;
    _searchFilter.changed(FilterChange.Different);

    // If no albums are assigned sort by the default (song name), otherwise sort by artist, album, track, title
    _sortModel.sorter = albums.length > 0 ? _artistAlbumTrackSorter : null;
  }

  /**
   * Add a song to the view.
   */
  void addSong(LibrarySong song)
  {
    _listModel.append(song);
  }

  mixin Signal!(LibrarySong[]) selectionChanged; /// Selected songs changed signal
  mixin Signal!(LibrarySong[]) queueSongs; /// Queue songs action callback

  LibrarySong[] selection;

private:
  Daphne _daphne;
  SearchEntry _searchEntry;
  ulong _searchChangedHandler; // connectSearchChanged handler
  string _searchString;
  ScrolledWindow _scrolledWindow;
  MultiSelection _selModel;
  ListStore _listModel;
  CustomFilter _searchFilter;
  SortListModel _sortModel;
  CustomSorter _artistAlbumTrackSorter;
  ColumnView _columnView;
  Button _queueSongsButton;

  LibraryArtist[] _filterArtists;
  LibraryAlbum[] _filterAlbums;
}
