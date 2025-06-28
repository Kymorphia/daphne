module song_view;

import daphne_includes;

import daphne;
import history_column_view;
import library;
import prop_iface;
import rating;
import signal;
import song_column_view;
import utils : formatSongTime;

/**
 * Song view widget. Contains a SongColumnView for song search and a HistoryColumnView for play history,
 * selectable by toggle buttons.
 */
class SongView : Box
{
  this(Daphne daphne)
  {
    super(Orientation.Vertical, 0);
    _daphne = daphne;

    auto hbox = new Box(Orientation.Horizontal, 0);
    append(hbox);

    _searchEntry = new SearchEntry;
    _searchEntry.searchDelay = 500;
    _searchEntry.hexpand = true;
    hbox.append(_searchEntry);

    _selectionClearBtn = Button.newWithLabel("");
    _selectionClearBtn.visible = false;
    hbox.append(_selectionClearBtn);

    auto songsBtn = new ToggleButton;
    songsBtn.setChild(Image.newFromIconName("multimedia-player"));
    songsBtn.tooltipText = tr!"Songs";
    songsBtn.active = true;
    hbox.append(songsBtn);

    auto historyBtn = new ToggleButton;
    historyBtn.setChild(Image.newFromIconName("x-office-calendar"));
    historyBtn.tooltipText = tr!"History";
    historyBtn.setGroup(songsBtn);
    hbox.append(historyBtn);

    _queueSongsButton = Button.newFromIconName("list-add");
    _queueSongsButton.hexpand = false;
    _queueSongsButton.tooltipText = tr!"Add songs to queue";
    hbox.append(_queueSongsButton);

    auto stack = new Stack;
    append(stack);

    _songsScrolledWindow = new ScrolledWindow;
    _songsScrolledWindow.setVexpand(true);
    _songsScrolledWindow.setHexpand(true);
    stack.addChild(_songsScrolledWindow);

    songColumnView = new SongColumnView(true, true);
    songColumnView.searchFilter.setFilterFunc(&songColumnViewFilterFunc); // Override filter method for song view
    _songsScrolledWindow.setChild(songColumnView);

    _historyScrolledWindow = new ScrolledWindow;
    _historyScrolledWindow.setVexpand(true);
    _historyScrolledWindow.setHexpand(true);
    stack.addChild(_historyScrolledWindow);

    historyColumnView = new HistoryColumnView(daphne);
    _historyScrolledWindow.setChild(historyColumnView);

    _activeView = songColumnView;

    // Add all the library songs to the song view
    songColumnView.splice(0, 0, _daphne.library.songFiles.values.map!(song => new SongColumnViewItem(song)).array);

    songsBtn.connectToggled(() {
      if (songsBtn.getActive)
      {
        _activeView = songColumnView;
        stack.visibleChild = _songsScrolledWindow;
      }
      else
      {
        _activeView = historyColumnView;
        stack.visibleChild = _historyScrolledWindow;
      }

      _activeView.searchString = _searchEntry.text;
      updateSelectionClearBtn;
    });

    _searchEntry.connectSearchChanged(() {
      _activeView.searchString = _searchEntry.text.toLower;
    });

    _selectionClearBtn.connectClicked(() {
      _activeView.clearSelection;
    });

    _queueSongsButton.connectClicked(&onQueueSongsButtonClicked);

    songColumnView.propChanged.connect((propObj, propName, val, oldVal) {
      propName == "selection" && updateSelectionClearBtn;
    });

    historyColumnView.propChanged.connect((propObj, propName, val, oldVal) {
      propName == "selection" && updateSelectionClearBtn;
    });
  }

  private bool songColumnViewFilterFunc(ObjectWrap item)
  {
    auto song = (cast(SongColumnViewItem)item).song;

    return songColumnView.searchFilterFunc(item) // Chain to SongColumnView string search method
      && (_filterAlbums.length == 0 || _filterAlbums.canFind(song.album.toLower)) // And no albums filter or album matches
      && (_filterAlbums.length > 0 || _filterArtists.length == 0 || _filterArtists.canFind(song.artist.toLower)); // And albums filter or no artists filter or artist matches
  }

  private void onQueueSongsButtonClicked() // Callback for when queue songs button is clicked
  {
    LibrarySong[] songs = _activeView.selection;

    if (songs.length == 0) // If no items are selected queue all of them
      foreach (i; 0 .. _activeView.sortModel.getNItems)
        songs ~= (cast(SongColumnViewItem)_activeView.sortModel.getItem(cast(uint)i)).song;

    _daphne.playQueue.add(songs);
  }

  private void updateSelectionClearBtn()
  {
    auto selection = _activeView.selection;
    if (selection.length > 0)
    {
      _selectionClearBtn.label = format(tr!"%d selected", selection.length);
      _selectionClearBtn.visible = true;
    }
    else
      _selectionClearBtn.visible = false;
  }

  /// Open history database
  void openHistory()
  {
    historyColumnView.open;
  }

  /**
   * Set the filter of artists to show songs for.
   * Params:
   *   artists = List of artists to filter by or empty/null to not filter
   */
  void filterArtists(LibraryArtist[] artists)
  {
    songColumnView.clearSelection; // Make sure to do this before changing the filter or it wont work right
    _filterArtists = artists.map!(x => x.name.toLower).array;
    songColumnView.searchFilter.changed(FilterChange.Different);
  }

  /**
   * Set the filter of albums to show songs for.
   * Params:
   *   albums = List of albums to filter by or empty/null to not filter
   */
  void filterAlbums(LibraryAlbum[] albums)
  {
    songColumnView.clearSelection; // Make sure to do this before changing the filter or it wont work right
    _filterAlbums = albums.map!(x => x.name.toLower).array;
    songColumnView.searchFilter.changed(FilterChange.Different);
  }

  SongColumnView songColumnView;
  HistoryColumnView historyColumnView;

private:
  Daphne _daphne;

  SearchEntry _searchEntry;
  string _searchString;

  SongColumnView _activeView; // Will be either songColumnView or historyColumnView
  ScrolledWindow _songsScrolledWindow;
  SortListModel _songSortModel;

  ScrolledWindow _historyScrolledWindow;

  Button _queueSongsButton;
  Button _selectionClearBtn;
  string[] _filterArtists; // Artist names to filter by
  string[] _filterAlbums; // Album names to filter by
}
