module history_view;

import daphne_includes;

import daphne;
import history_column_view;
import library;
import prop_iface;
import rating;
import signal;
import song_column_view;
import utils : executeSql, getSelectionRanges;

/// History view widget
class HistoryView : Box
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

    _queueSongsButton.connectClicked(&onQueueSongsButtonClicked);

    _scrolledWindow = new ScrolledWindow;
    _scrolledWindow.setVexpand(true);
    _scrolledWindow.setHexpand(true);
    append(_scrolledWindow);

    _historyColumnView = new HistoryColumnView;
    _scrolledWindow.setChild(_historyColumnView);

    _selModel = cast(MultiSelection)_historyColumnView.model;
    auto listModel = cast(ListStore)_selModel.model;

    _searchFilter = new CustomFilter(&searchFilterFunc);
    auto filterListModel = new FilterListModel(listModel, _searchFilter); // Used to filter on search text
    _sortModel = new SortListModel(filterListModel, _historyColumnView.getSorter);
    _selModel.model = _sortModel;

    _historyColumnView.selectionChanged.connect((LibrarySong[] selection) {
      selectionChanged.emit(selection);

      if (selection.length > 0)
      {
        _selectionClearBtn.label = format(tr!"%d selected", selection.length);
        _selectionClearBtn.visible = true;
      }
      else
        _selectionClearBtn.visible = false;
    });

    auto columns = _historyColumnView.columns;
    auto playedCol = cast(ColumnViewColumn)columns.getItem(columns.getNItems - 1);
    _historyColumnView.sortByColumn(playedCol, SortType.Ascending);

    auto shortCtrl = new ShortcutController;
    shortCtrl.setScope(ShortcutScope.Local);
    addController(shortCtrl);

    shortCtrl.addShortcut(new Shortcut(ShortcutTrigger.parseString("Delete"),
      new CallbackAction(&onDeleteKeyCallback)));
  }

  private bool onDeleteKeyCallback(Widget widg, GLibVariant args)
  {
    auto ranges = getSelectionRanges(_selModel);
    long[] hIds;

    // Loop in reverse so that positions don't change as items are removed
    foreach (r; ranges.retro)
    { // Get history IDs for the range of items
      hIds ~= _historyColumnView.getItems(iota(r[0], r[1] + 1)).map!(x => x.id).array;
      _historyColumnView.splice(r[0], r[1] - r[0] + 1, []);
    }

    try
      _daphne.playQueue.dbConn.executeSql("DELETE FROM history WHERE id IN (" ~ hIds.map!(x => x.to!string).join(", ") ~ ")");
    catch (Exception e)
      error("History DB delete error: " ~ e.msg);

    return true;
  }

  @property LibrarySong[] selection()
  {
    return _historyColumnView.selection;
  }

  private void onQueueSongsButtonClicked() // Callback for when queue songs button is clicked
  {
    if (selection.length == 0) // If no items are selected queue all of them
    {
      LibrarySong[] songs;

      foreach (i; 0 .. _sortModel.getNItems)
        songs ~= (cast(HistoryItem)_sortModel.getItem(cast(uint)i)).song;

      _daphne.playQueue.add(songs);
    }
    else
      _daphne.playQueue.add(selection); // Add selected songs
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
    return _searchString.length == 0 || (cast(HistoryItem)item).song.name.toLower.canFind(_searchString); // No search or search matches?
  }

  /**
   * Load the history from the queue database
   */
  void open()
  {
    auto stmt = _daphne.playQueue.dbConn.createStatement;
    scope(exit) stmt.close;

    try
      stmt.executeUpdate("CREATE TABLE IF NOT EXISTS history (id INTEGER PRIMARY KEY, song_id int, timestamp int)");
    catch (Exception e)
      throw new Exception("History DB table create error: " ~ e.msg);

    HistoryItem[] items;

    try // Load the history table
    {
      auto rs = stmt.executeQuery("SELECT id, song_id, timestamp FROM history ORDER BY id");

      while (rs.next)
      {
        if (auto song = _daphne.library.songIds.get(rs.getLong(2), null))
        {
          auto id = rs.getLong(1);
          items ~= new HistoryItem(song, rs.getLong(3), id);

          if (id >= _nextHistoryId)
            _nextHistoryId = id + 1;
        }
      }
    }
    catch (Exception e)
      throw new Exception("History DB load error: " ~ e.msg);

    _historyColumnView.splice(0, 0, cast(SongColumnViewItem[])items);
  }

  /**
   * Add a song to the history.
   */
  void addSong(LibrarySong song)
  {
    auto historyId = _nextHistoryId++;
    auto curTime = Clock.currTime.toUnixTime;
    _historyColumnView.add(new HistoryItem(song, curTime, historyId));

    try
      _daphne.playQueue.dbConn.executeSql("INSERT INTO history (id, song_id, timestamp) VALUES "
        ~ "(" ~ historyId.to!string ~ ", " ~ song.id.to!string ~ ", " ~ curTime.to!string ~ ")");
    catch (Exception e)
      error("History DB insert error: " ~ e.msg);
  }

  /**
   * Pop the current song off of the history. Removes it from the history and returns it.
   * Returns: Song popped off of the end of the history or null if none
   */
  LibrarySong pop()
  {
    auto item = cast(HistoryItem)_historyColumnView.pop;

    try
      _daphne.playQueue.dbConn.executeSql("DELETE FROM history WHERE id=" ~ item.id.to!string);
    catch (Exception e)
      error("History DB delete error: " ~ e.msg);

    return item.song;
  }

  /// Clear the selection
  void clearSelection()
  {
    _selModel.unselectAll;
  }

  mixin Signal!(LibrarySong[]) selectionChanged; /// Selected songs changed signal

private:
  Daphne _daphne;
  SearchEntry _searchEntry;
  ulong _searchChangedHandler; // connectSearchChanged handler
  string _searchString;
  ScrolledWindow _scrolledWindow;
  CustomFilter _searchFilter;
  SortListModel _sortModel;
  MultiSelection _selModel;
  HistoryColumnView _historyColumnView;
  long _nextHistoryId = 1;
  Button _queueSongsButton;
  Button _selectionClearBtn;
}
