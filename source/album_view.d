module album_view;

import daphne_includes;

import daphne;
import edit_field;
import library;
import signal;

/// Album view widget
class AlbumView : Box
{
  immutable Column[] DefaultSortColumns = [Column.Album, Column.Artist]; // Default column sorting (reverse priority order, last is highest)

  this(Daphne daphne)
  {
    super(Orientation.Vertical, 0);
    _daphne = daphne;

    auto hbox = new Box(Orientation.Horizontal, 0);
    append(hbox);

    _searchEntry = new SearchEntry;
    _searchEntry.hexpand = true;
    _searchChangedHandler = _searchEntry.connectSearchChanged(&onSearchEntryChanged);
    _searchEntry.searchDelay = 500;
    hbox.append(_searchEntry);

    _selectionClearBtn = Button.newWithLabel("");
    _selectionClearBtn.visible = false;
    hbox.append(_selectionClearBtn);

    _selectionClearBtn.connectClicked(() {
      clearSelection;
    });

    auto showSingleToggle = new ToggleButton;
    showSingleToggle.setChild(new Label("1"));
    hbox.append(showSingleToggle);

    showSingleToggle.connectToggled(() {
      _showAlbumSingles = showSingleToggle.active;
      _searchFilter.changed(_showAlbumSingles ? FilterChange.LessStrict : FilterChange.MoreStrict);
    });

    _scrolledWindow = new ScrolledWindow;
    _scrolledWindow.setVexpand(true);
    _scrolledWindow.setHexpand(true);
    append(_scrolledWindow);

    _columnView = new ColumnView(null);
    _columnView.addCssClass("data-table");
    _scrolledWindow.setChild(_columnView);

    _listModel = new ListStore(GTypeEnum.Object);

    foreach (album; _daphne.library.albums)
      _listModel.append(album);

    _searchFilter = new CustomFilter(&searchFilterFunc);
    auto filterListModel = new FilterListModel(_listModel, _searchFilter); // Used to filter on search text
    auto sortModel = new SortListModel(filterListModel, _columnView.getSorter);
    _selModel = new MultiSelection(sortModel);
    _columnView.model = _selModel;

    _selModel.connectSelectionChanged(&onSelectionModelChanged);

    auto factory = new SignalListItemFactory();
    factory.connectSetup(&onAlbumSetup);
    factory.connectBind(&onAlbumBind);
    _columns[Column.Album] = new ColumnViewColumn(tr!"Album", factory);
    _columns[Column.Album].expand = true;
    _columns[Column.Album].resizable = true;
    _columnView.appendColumn(_columns[Column.Album]);

    _columns[Column.Album].setSorter(new CustomSorter((ObjectWrap aObj, ObjectWrap bObj) =>
      icmp((cast(LibraryAlbum)aObj).name, (cast(LibraryAlbum)bObj).name)
    ));

    factory = new SignalListItemFactory();
    factory.connectSetup(&onArtistSetup);
    factory.connectBind(&onArtistBind);
    _columns[Column.Artist] = new ColumnViewColumn(tr!"Artist", factory);
    _columns[Column.Artist].expand = true;
    _columns[Column.Artist].resizable = true;
    _columnView.appendColumn(_columns[Column.Artist]);

    _columns[Column.Artist].setSorter(new CustomSorter((ObjectWrap aObj, ObjectWrap bObj) =>
      icmp((cast(LibraryAlbum)aObj).artist.name, (cast(LibraryAlbum)bObj).artist.name)
    ));

    factory = new SignalListItemFactory();
    factory.connectSetup(&onYearSetup);
    factory.connectBind(&onYearBind);
    _columns[Column.Year] = new ColumnViewColumn(tr!"Year", factory);
    _columns[Column.Year].expand = false;
    _columns[Column.Year].resizable = true;
    _columnView.appendColumn(_columns[Column.Year]);

    _columns[Column.Year].setSorter(new CustomSorter((ObjectWrap aObj, ObjectWrap bObj) =>
      cast(int)(cast(LibraryAlbum)aObj).year - cast(int)(cast(LibraryAlbum)bObj).year
    ));

    factory = new SignalListItemFactory();
    factory.connectSetup(&onSongCountSetup);
    factory.connectBind(&onSongCountBind);
    _columns[Column.SongCount] = new ColumnViewColumn(tr!"Songs", factory);
    _columns[Column.SongCount].expand = false;
    _columns[Column.SongCount].resizable = true;
    _columnView.appendColumn(_columns[Column.SongCount]);

    _columns[Column.SongCount].setSorter(new CustomSorter((ObjectWrap aObj, ObjectWrap bObj) =>
      cast(int)(cast(LibraryAlbum)aObj).songCount - cast(int)(cast(LibraryAlbum)bObj).songCount
    ));

    foreach (colEnum; DefaultSortColumns)
      _columnView.sortByColumn(_columns[colEnum], SortType.Ascending);
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

    return (_showAlbumSingles || album.songCount > 1) // Filter out albums with only 1 song if show singles toggle button is not pressed
      && (_searchString.length == 0 || album.name.toLower.canFind(_searchString))
      && (_filterArtists.length == 0 || _filterArtists.canFind(album.artist.name.toLower));
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

    if (selection.length > 0)
    {
      _selectionClearBtn.label = format(tr!"%d selected", selection.length);
      _selectionClearBtn.visible = true;
    }
    else
      _selectionClearBtn.visible = false;

    selectionChanged.emit(selection);
  }

  private void onAlbumSetup(ListItem listItem)
  {
    listItem.setChild(new EditField);
  }

  private void onAlbumBind(ListItem listItem)
  {
    auto album = cast(LibraryAlbum)listItem.getItem;
    (cast(EditField)listItem.getChild).content = album.name ? album.name : tr!UnknownName;
  }

  private void onArtistSetup(ListItem listItem)
  {
    listItem.setChild(new EditField);
  }

  private void onArtistBind(ListItem listItem)
  {
    auto album = cast(LibraryAlbum)listItem.getItem;
    (cast(EditField)listItem.getChild).content = album.artist.name ? album.artist.name : tr!UnknownName;
  }

  private void onYearSetup(ListItem listItem)
  {
    listItem.setChild(new EditField(cast(uint)LibrarySong.MaxYear.to!string.length));
  }

  private void onYearBind(ListItem listItem)
  {
    auto year = (cast(LibraryAlbum)listItem.getItem).year;
    (cast(EditField)listItem.getChild).content = year > 0 ? year.to!string : "";
  }

  private void onSongCountSetup(ListItem listItem)
  {
    auto label = new Label;
    label.halign = Align.Start;
    listItem.setChild(label);
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
  void filterArtists(LibraryArtist[] artists)
  {
    clearSelection; // Make sure to do this before changing the filter or it wont work right
    _filterArtists = artists.map!(x => x.name.toLower).array;
    _searchFilter.changed(FilterChange.Different);
  }

  /**
   * Add an album to the view.
   */
  void addAlbum(LibraryAlbum album)
  {
    _listModel.append(album);
  }

  /// Clear the selection
  void clearSelection()
  {
    _selModel.unselectAll;
  }

  mixin Signal!(LibraryAlbum[]) selectionChanged; /// Selected albums changed signal

  LibraryAlbum[] selection;

  enum Column
  {
    Album,
    Artist,
    Year,
    SongCount,
  }

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
  ColumnViewColumn[Column.max + 1] _columns;
  string[] _filterArtists;
  Button _selectionClearBtn;
  bool _showAlbumSingles;
}
