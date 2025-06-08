module artist_view;

import daphne_includes;

import daphne;
import edit_field;
import library;
import signal;

/// Artist view widget
class ArtistView : Box
{
  this(Daphne daphne)
  {
    super(Orientation.Vertical, 0);
    _daphne = daphne;

    auto hbox = new Box(Orientation.Horizontal, 0);
    append(hbox);

    _searchEntry = new SearchEntry;
    _searchEntry.hexpand = true;
    _searchEntry.connectSearchChanged(&onSearchEntryChanged);
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
      _showArtistsWithSingles = showSingleToggle.active;
      _searchFilter.changed(_showArtistsWithSingles ? FilterChange.LessStrict : FilterChange.MoreStrict);
    });

    _scrolledWindow = new ScrolledWindow;
    _scrolledWindow.setVexpand(true);
    _scrolledWindow.setHexpand(true);
    append(_scrolledWindow);

    _listModel = new ListStore(GTypeEnum.Object);

    foreach (artist; _daphne.library.artists)
      _listModel.append(artist);

    _searchFilter = new CustomFilter(&searchFilterFunc);
    auto filterListModel = new FilterListModel(_listModel, _searchFilter); // Used to filter on search text
    _selModel = new MultiSelection(filterListModel);
    _columnView = new ColumnView(_selModel);
    _columnView.addCssClass("data-table");
    _scrolledWindow.setChild(_columnView);

    _sortModel = new SortListModel(filterListModel, _columnView.getSorter);
    _selModel.model = _sortModel;

    _selModel.connectSelectionChanged(&onSelectionModelChanged);

    auto factory = new SignalListItemFactory();
    factory.connectSetup(&onArtistSetup);
    factory.connectBind(&onArtistBind);
    auto col = new ColumnViewColumn(tr!"Artist", factory);
    col.expand = true;
    col.resizable = true;
    _columnView.appendColumn(col);

    col.setSorter(new CustomSorter((ObjectWrap aObj, ObjectWrap bObj) {
      if (aObj !is _daphne.library.unknownArtist && aObj !is _daphne.library.variousArtists
          && bObj !is _daphne.library.unknownArtist && bObj !is _daphne.library.variousArtists)
        return icmp((cast(LibraryArtist)aObj).name, (cast(LibraryArtist)bObj).name);

      if (aObj is bObj)
        return 0;
      else if (aObj is _daphne.library.unknownArtist)
        return -1;
      else if (bObj is _daphne.library.unknownArtist)
        return 1;
      else if (aObj is _daphne.library.variousArtists)
        return -1;
      else // bObj is variousArtists
        return 1;
    }));

    _columnView.sortByColumn(col, SortType.Ascending);

    factory = new SignalListItemFactory();
    factory.connectSetup(&onSongCountSetup);
    factory.connectBind(&onSongCountBind);
    col = new ColumnViewColumn(tr!"Songs", factory);
    col.expand = false;
    col.resizable = true;
    _columnView.appendColumn(col);

    col.setSorter(new CustomSorter((ObjectWrap aObj, ObjectWrap bObj) =>
      (cast(LibraryArtist)aObj).songCount - (cast(LibraryArtist)bObj).songCount
    ));
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
    auto artist = cast(LibraryArtist)item;
    return (_showArtistsWithSingles || artist.songCount > 1 || artist is _daphne.library.variousArtists) // Filter out artists with only one song if toggle button is not active, always show various artists though
      && (_searchString.length == 0 || (cast(LibraryItem)item).name.toLower.canFind(_searchString));
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

    if (selection.length > 0)
    {
      _selectionClearBtn.label = format(tr!"%d selected", selection.length);
      _selectionClearBtn.visible = true;
    }
    else
      _selectionClearBtn.visible = false;

    selectionChanged.emit(selection);
  }

  private void onArtistSetup(ListItem listItem)
  {
    listItem.setChild(new EditField);
  }

  private void onArtistBind(ListItem listItem)
  {
    (cast(EditField)listItem.getChild).content = (cast(LibraryArtist)listItem.getItem).name;
  }

  private void onSongCountSetup(ListItem listItem)
  {
    auto label = new Label;
    label.halign = Align.Start;
    listItem.setChild(label);
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

  /// Clear the selection
  void clearSelection()
  {
    _selModel.unselectAll;
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
  Button _selectionClearBtn;
  bool _showArtistsWithSingles;
}
