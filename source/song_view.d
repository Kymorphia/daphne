module song_view;

import std.algorithm : canFind, endsWith, startsWith;
import std.string : icmp, toLower;

import gettext;
import gio.list_model;
import gio.list_store;
import gobject.object;
import gtk.box;
import gtk.button;
import gtk.custom_filter;
import gtk.custom_sorter;
import gtk.filter_list_model;
import gtk.multi_selection;
import gtk.scrolled_window;
import gtk.search_entry;
import gtk.sort_list_model;
import gtk.types : FilterChange, Orientation;

import daphne;
import library;
import prop_iface;
import rating;
import signal;
import song_column_view;
import utils : formatSongTime, initTextNotEditable;

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

    _songColumnView = new SongColumnView;
    _scrolledWindow.setChild(_songColumnView);

    auto selModel = cast(MultiSelection)_songColumnView.model;
    auto listModel = cast(ListStore)selModel.model;

    foreach (song; _daphne.library.songFiles.values)
      _songColumnView.addSong(song);

    _searchFilter = new CustomFilter(&searchFilterFunc);
    auto filterListModel = new FilterListModel(listModel, _searchFilter); // Used to filter on search text
    _titleSorter = new CustomSorter(&titleSorter);
    _sortModel = new SortListModel(filterListModel, _titleSorter);
    selModel.model = _sortModel;

    _artistAlbumTrackSorter = new CustomSorter(&artistAlbumTrackSorter);

    _songColumnView.selectionChanged.connect((LibrarySong[] selection) {
      selectionChanged.emit(selection);
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
      && (_filterAlbums.length == 0 || _filterAlbums.canFind(libSong.libAlbum)) // And no albums filter or album matches
      && (_filterAlbums.length > 0 || _filterArtists.length == 0 || _filterArtists.canFind(libSong.libAlbum.artist)); // And albums filter or no artists filter or artist matches
  }

  private int titleSorter(ObjectWrap aObj, ObjectWrap bObj)
  {
    auto aSong = (cast(SongColumnViewItem)aObj).song;
    auto bSong = (cast(SongColumnViewItem)bObj).song;
    return icmp(aSong.title, bSong.title);
  }

  private int artistAlbumTrackSorter(ObjectWrap aObj, ObjectWrap bObj)
  {
    auto aSong = (cast(SongColumnViewItem)aObj).song;
    auto bSong = (cast(SongColumnViewItem)bObj).song;

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
      return icmp(aSong.title, bSong.title);
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

    // If no albums are assigned sort by the default (song title), otherwise sort by artist, album, track, title
    _sortModel.sorter = albums.length > 0 ? _artistAlbumTrackSorter : _titleSorter;
  }

  /**
   * Add a song to the view.
   */
  void addSong(LibrarySong song)
  {
    _songColumnView.addSong(song);
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
  CustomSorter _titleSorter;
  CustomSorter _artistAlbumTrackSorter;
  SongColumnView _songColumnView;
  Button _queueSongsButton;

  LibraryArtist[] _filterArtists; // Artists to filter by
  LibraryAlbum[] _filterAlbums; // Albums to filter by
}
