module song_view;

import daphne_includes;

import daphne;
import library;
import prop_iface;
import rating;
import signal;
import song_column_view;
import utils : formatSongTime;

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

    _selectionClearBtn = Button.newWithLabel("");
    _selectionClearBtn.visible = false;
    hbox.append(_selectionClearBtn);

    _selectionClearBtn.connectClicked(() {
      clearSelection;
    });

    _queueSongsButton = Button.newFromIconName("list-add");
    _queueSongsButton.hexpand = false;
    _queueSongsButton.tooltipText = tr!"Add songs to queue";
    hbox.append(_queueSongsButton);

    _queueSongsButton.connectClicked(&onAddSongsButtonClicked);

    _scrolledWindow = new ScrolledWindow;
    _scrolledWindow.setVexpand(true);
    _scrolledWindow.setHexpand(true);
    append(_scrolledWindow);

    _songColumnView = new SongColumnView(true);
    _scrolledWindow.setChild(_songColumnView);

    _selModel = cast(MultiSelection)_songColumnView.model;
    auto listModel = cast(ListStore)_selModel.model;

    foreach (song; _daphne.library.songFiles.values)
      _songColumnView.addSong(song);

    _searchFilter = new CustomFilter(&searchFilterFunc);
    auto filterListModel = new FilterListModel(listModel, _searchFilter); // Used to filter on search text
    _sortModel = new SortListModel(filterListModel, _songColumnView.getSorter);
    _selModel.model = _sortModel;

    _songColumnView.selectionChanged.connect((LibrarySong[] selection) {
      selectionChanged.emit(selection);

      if (selection.length > 0)
      {
        _selectionClearBtn.label = format(tr!"%d selected", selection.length);
        _selectionClearBtn.visible = true;
      }
      else
        _selectionClearBtn.visible = false;
    });
  }

  @property LibrarySong[] selection()
  {
    return _songColumnView.selection;
  }

  private void onAddSongsButtonClicked() // Callback for when queue songs button is clicked
  {
    if (selection.length == 0) // If no items are selected queue all of them
    {
      LibrarySong[] songs;

      foreach (i; 0 .. _sortModel.getNItems)
        songs ~= (cast(SongColumnViewItem)_sortModel.getItem(cast(uint)i)).song;

      queueSongs.emit(songs);
    }
    else
      queueSongs.emit(selection); // Add selected songs
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
    auto libSong = (cast(SongColumnViewItem)item).song;

    return (_searchString.length == 0 || libSong.name.toLower.canFind(_searchString)) // No search or search matches?
      && (_filterAlbums.length == 0 || _filterAlbums.canFind(libSong.album.toLower)) // And no albums filter or album matches
      && (_filterAlbums.length > 0 || _filterArtists.length == 0 || _filterArtists.canFind(libSong.artist.toLower)); // And albums filter or no artists filter or artist matches
  }

  /**
   * Set the filter of artists to show songs for.
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
   * Set the filter of albums to show songs for.
   * Params:
   *   albums = List of albums to filter by or empty/null to not filter
   */
  void setAlbums(LibraryAlbum[] albums)
  {
    clearSelection; // Make sure to do this before changing the filter or it wont work right
    _filterAlbums = albums.map!(x => x.name.toLower).array;
    _searchFilter.changed(FilterChange.Different);
  }

  /**
   * Add a song to the view.
   */
  void addSong(LibrarySong song)
  {
    _songColumnView.addSong(song);
  }

  /// Clear the selection
  void clearSelection()
  {
    _selModel.unselectAll;
  }

  mixin Signal!(LibrarySong[]) selectionChanged; /// Selected songs changed signal
  mixin Signal!(LibrarySong[]) queueSongs; /// Queue songs action callback

private:
  Daphne _daphne;
  SearchEntry _searchEntry;
  ulong _searchChangedHandler; // connectSearchChanged handler
  string _searchString;
  ScrolledWindow _scrolledWindow;
  CustomFilter _searchFilter;
  SortListModel _sortModel;
  MultiSelection _selModel;
  SongColumnView _songColumnView;
  Button _queueSongsButton;
  Button _selectionClearBtn;
  string[] _filterArtists; // Artist names to filter by
  string[] _filterAlbums; // Album names to filter by
}
