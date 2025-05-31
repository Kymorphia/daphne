module play_queue;

import std.algorithm : canFind, endsWith, map, startsWith;
import std.array : array, insertInPlace;
import std.conv : to;
import std.logger;
import std.path : buildPath;
import std.random : randomShuffle;
import std.range : retro;
import std.string : join, toLower;

import ddbc : createConnection, Connection;
import gio.list_store;
import glib.variant : GLibVariant = Variant;
import gobject.object;
import gtk.bitset;
import gtk.bitset_iter;
import gtk.box;
import gtk.button;
import gtk.callback_action;
import gtk.custom_filter;
import gtk.custom_sorter;
import gtk.filter_list_model;
import gtk.multi_selection;
import gtk.scrolled_window;
import gtk.search_entry;
import gtk.shortcut;
import gtk.shortcut_controller;
import gtk.shortcut_trigger;
import gtk.sort_list_model;
import gtk.types : FilterChange, Orientation, ShortcutScope;
import gtk.widget;

import daphne;
import library;
import prop_iface;
import rating;
import song_column_view;
import utils : executeSql;

enum PlayQueueDatabaseFile = "daphne-queue.db"; /// Play queue database filename

/// Play queue widget
class PlayQueue : Box, PropIface
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

    auto shuffleButton = Button.newFromIconName("media-playlist-shuffle");
    shuffleButton.hexpand = false;
    hbox.append(shuffleButton);

    shuffleButton.connectClicked(&onShuffleButtonClicked);

    _scrolledWindow = new ScrolledWindow;
    _scrolledWindow.setVexpand(true);
    _scrolledWindow.setHexpand(true);
    append(_scrolledWindow);

    _songColumnView = new SongColumnView(false);
    _scrolledWindow.setChild(_songColumnView);

    _selModel = cast(MultiSelection)_songColumnView.model;
    _listModel = cast(ListStore)_selModel.model;

    _searchFilter = new CustomFilter(&searchFilterFunc);
    auto filterListModel = new FilterListModel(_listModel, _searchFilter); // Used to filter on search text
    _selModel.model = filterListModel;

    auto shortCtrl = new ShortcutController;
    shortCtrl.setScope(ShortcutScope.Local);
    addController(shortCtrl);

    shortCtrl.addShortcut(new Shortcut(ShortcutTrigger.parseString("Delete"),
      new CallbackAction(&onDeleteKeyCallback)));
  }

  struct PropDef
  {
    @Desc("Count of songs in queue") uint songCount;
  }

  mixin(definePropIface!(PropDef, true));

  private bool onDeleteKeyCallback(Widget widg, GLibVariant args)
  {
    uint[2][] ranges;
    BitsetIter iter;
    uint position;

    if (BitsetIter.initFirst(iter, _selModel.getSelection, position)) // Construct ranges of items to remove
    {
      uint[2] curRange = [position, position];

      while (iter.next(position))
      {
        if (position != curRange[1] + 1)
        {
          ranges ~= curRange;
          curRange = [position, position];
        }
        else
          curRange[1] = position;
      }

      ranges ~= curRange; // Add last range
    }

    long[] qIds;

    // Loop in reverse so that positions don't change as items are removed
    foreach (r; ranges.retro)
    {
      _listModel.splice(r[0], r[1] - r[0] + 1, []);
      qIds ~= _songs[r[0] .. r[1] + 1].map!(x => x.queueId).array;
    }

    // Construct new list by appending the ranges of items not being removed
    uint lastPos = 0;
    SongColumnViewItem[] newSongs;
    foreach (r; ranges)
    {
      newSongs ~= _songs[lastPos .. r[0]];
      lastPos = r[1] + 1;
    }

    _songs = newSongs ~ _songs[lastPos .. $];
    songCount = cast(uint)_songs.length;

    try
      _dbConn.executeSql("DELETE FROM queue WHERE id IN (" ~ qIds.map!(x => x.to!string).join(", ") ~ ")");
    catch (Exception e)
      error("Queue DB delete error: " ~ e.msg);

    return true;
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

  private void onShuffleButtonClicked()
  {
    if (isPlaying && _songs.length <= 1)
      return;

    auto startIndex = isPlaying ? 1 : 0;
    _songs[startIndex .. $] = _songs[startIndex .. $].randomShuffle.array; // Cannot shuffle in place, so create a new array then replace it
    _listModel.removeAll;
    _listModel.splice(0, 0, cast(ObjectWrap[])_songs);

    _nextQueueId = 1;
    foreach (i, song; _songs) // Re-sequence the queue IDs
      song.queueId = _nextQueueId++;

    try
    {
      _dbConn.executeSql("DELETE FROM queue");
      _dbConn.executeSql("INSERT INTO queue (id, song_id) VALUES "
        ~ _songs.map!(x => "(" ~ x.queueId.to!string ~ ", " ~ x.song.id.to!string ~ ")").join(", "));
    }
    catch (Exception e)
      error("Queue DB shuffle error: " ~ e.msg);
  }

  private bool searchFilterFunc(ObjectWrap item)
  {
    return (_searchString.length == 0 || (cast(SongColumnViewItem)item).song.name.toLower.canFind(_searchString)); // No search or search matches?
  }

  /**
   * Open the queue file, load the data to the queue, or initialize it
   */
  void open()
  {
    try
      _dbConn = createConnection("sqlite:" ~ buildPath(_daphne.appDir, PlayQueueDatabaseFile));
    catch (Exception e)
      throw new Exception("DB connect error: " ~ e.msg);

    auto stmt = _dbConn.createStatement;
    scope(exit) stmt.close;

    try
    {
      stmt.executeUpdate("CREATE TABLE IF NOT EXISTS queue (id INTEGER PRIMARY KEY, song_id int)");
      stmt.executeUpdate("CREATE TABLE IF NOT EXISTS history (id INTEGER PRIMARY KEY, song_id int, timestamp int)");
    }
    catch (Exception e)
      throw new Exception("Queue DB table create error: " ~ e.msg);

    try // Load the Queue table
    {
      auto rs = stmt.executeQuery("SELECT id, song_id FROM queue ORDER BY id");

      while (rs.next)
      {
        if (auto song = _daphne.library.songIds.get(rs.getLong(2), null))
        {
          auto id = rs.getLong(2);
          _songs ~= new SongColumnViewItem(song);
          _songs[$ - 1].queueId = rs.getLong(1);

          if (id >= _nextQueueId)
            _nextQueueId = id + 1;
        }
      }
    }
    catch (Exception e)
      throw new Exception("Queue DB load error: " ~ e.msg);

    _listModel.splice(0, 0, cast(ObjectWrap[])_songs);
    songCount = cast(uint)_songs.length;
  }

  /// Close queue database
  void close()
  {
    if (_dbConn)
    {
      _dbConn.close;
      _dbConn = null;
    }
  }

  /**
   * Activate the song at the top of the queue and return it. OK to call if already active, in which case the current song will be returned.
   * Returns: Active song or null if queue is empty
   */
  LibrarySong start()
  {
    if (_songs.length > 0)
    {
      isPlaying = true;
      currentSong.emit(_songs[0].song);
      return _songs[0].song;
    }
    else
      return null;
  }

  /**
   * Deactivates the current song which was activated by a call to start().
   */
  void stop()
  {
    isPlaying = false;
  }

  /**
   * Append songs to the queue.
   * Params:
   *   songs = Songs to append
   */
  void add(LibrarySong[] songs)
  {
    insert(songs, -1);
  }

  /**
   * Insert songs in the queue.
   * Params:
   *   songs = The songs to insert
   *   pos = Position to insert at, -1 appends, 0 is not valid when queue is playing
   */
  void insert(LibrarySong[] songs, int pos)
  {
    if (songs.length == 0)
      return;

    if (pos == 0 && isPlaying)
      pos = 1;

    if (pos < 0 || pos > _songs.length) // Append if negative pos or pos off the end
      pos = cast(int)_songs.length;

    SongColumnViewItem[] qSongs;

    foreach (song; songs)
    {
      qSongs ~= new SongColumnViewItem(song);
      qSongs[$ - 1].queueId = _nextQueueId++;
    }

    _listModel.splice(pos, 0, cast(ObjectWrap[])qSongs);
    _songs.insertInPlace(pos, qSongs);

    try
      _dbConn.executeSql("INSERT INTO queue (id, song_id) VALUES "
        ~ qSongs.map!(x => "(" ~ x.queueId.to!string ~ ", " ~ x.song.id.to!string ~ ")").join(", "));
    catch (Exception e)
      error("Queue DB insert error: " ~ e.msg);

    songCount = cast(uint)_songs.length;
  }

  /**
   * Move the current queue item to the history, making the next song the top of queue.
   */
  void next()
  {
    if (_songs.length > 0)
      remove(0);
  }

  /**
   * Copy last song from history, add it to the top of the queue and activate it.
   */
  void prev()
  {
    // FIXME
  }

  /**
   * Remove a song from the queue.
   * Params:
   *   pos = Position of song to remove
   */
  void remove(int pos)
  {
    if (pos < 0 || pos >= _songs.length)
      return;

    auto qSong = _songs[pos];
    _dbConn.executeSql("DELETE FROM queue WHERE id=" ~ qSong.queueId.to!string);

    _listModel.remove(pos);
    _songs = _songs[0 .. pos] ~ _songs[pos + 1 .. $];

    if (pos == 0) // If the current song was removed, update it
    {
      currentSong.emit(_songs.length > 0 ? _songs[0].song : null);

      if (_songs.length == 0)
        _nextQueueId = 1; // Reset next queue ID when empty
    }

    songCount = cast(uint)_songs.length;
  }

  mixin Signal!(LibrarySong) currentSong;

private:
  Daphne _daphne;
  Connection _dbConn;
  SongColumnViewItem[] _songs;
  long _nextQueueId = 1;
  SearchEntry _searchEntry;
  ulong _searchChangedHandler;
  string _searchString;
  ScrolledWindow _scrolledWindow;
  MultiSelection _selModel;
  ListStore _listModel;
  CustomFilter _searchFilter;
  SongColumnView _songColumnView;
  bool isPlaying;
}
