module play_queue;

import daphne_includes;

import daphne;
import library;
import prop_iface;
import rating;
import song_column_view;
import utils : executeSql, getSelectionRanges;

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
    _searchEntry.searchDelay = 500;
    _searchEntry.hexpand = true;
    hbox.append(_searchEntry);

    auto shuffleButton = Button.newFromIconName("media-playlist-shuffle");
    shuffleButton.tooltipText = tr!"Shuffle items in queue";
    shuffleButton.hexpand = false;
    hbox.append(shuffleButton);

    _scrolledWindow = new ScrolledWindow;
    _scrolledWindow.setVexpand(true);
    _scrolledWindow.setHexpand(true);
    append(_scrolledWindow);

    _songColumnView = new SongColumnView(false, true);
    _scrolledWindow.setChild(_songColumnView);

    auto shortCtrl = new ShortcutController;
    shortCtrl.setScope(ShortcutScope.Local);
    addController(shortCtrl);

    shortCtrl.addShortcut(new Shortcut(ShortcutTrigger.parseString("Delete"),
      new CallbackAction(&onDeleteKeyCallback)));

    shuffleButton.connectClicked(&onShuffleButtonClicked);

    _searchEntry.connectSearchChanged(() {
      _songColumnView.searchString = _searchEntry.text.toLower;
    });
  }

  struct PropDef
  {
    @Desc("Count of songs in queue") uint songCount;
    @Desc("Current song at the top of the queue") LibrarySong currentSong;
  }

  mixin(definePropIface!(PropDef, true));

  private bool onDeleteKeyCallback(Widget widg, GLibVariant args)
  {
    auto ranges = getSelectionRanges(cast(MultiSelection)_songColumnView.model);
    long[] qIds;

    // Loop in reverse so that positions don't change as items are removed
    foreach (r; ranges.retro)
    { // Get queue IDs for the range of items
      qIds ~= _songColumnView.getItems(iota(r[0], r[1] + 1)).map!(x => x.id).array;
      _songColumnView.splice(r[0], r[1] - r[0] + 1, []);
    }

    songCount = _songColumnView.getItemCount;
    currentSong = _songColumnView.getItemCount > 0 ? _songColumnView.getItem(0).song : null;

    try
      dbConn.executeSql("DELETE FROM queue WHERE id IN (" ~ qIds.map!(x => x.to!string).join(", ") ~ ")");
    catch (Exception e)
      error("Queue DB delete error: " ~ e.msg);

    return true;
  }

  private void onShuffleButtonClicked()
  {
    auto startIndex = isPlaying ? 1 : 0;

    if (_props.songCount <= startIndex)
      return;

    auto shuffledSongs = _songColumnView.getItems(iota(startIndex, _props.songCount)).array.randomShuffle.array;
    _songColumnView.splice(startIndex, _props.songCount - startIndex, shuffledSongs);

    _songColumnView.getItems.enumerate(1).each!((t) { t[1].id = t[0]; }); // Re-sequence queue IDs
    _nextQueueId = _props.songCount + 1;

    try
    {
      dbConn.executeSql("DELETE FROM queue");
      dbConn.executeSql("INSERT INTO queue (id, song_id) VALUES "
        ~ _songColumnView.getItems.map!(x => "(" ~ x.id.to!string ~ ", " ~ x.song.id.to!string ~ ")").join(", "));
    }
    catch (Exception e)
      error("Queue DB shuffle error: " ~ e.msg);
  }

  /**
   * Open the queue file, load the data to the queue, or initialize it
   */
  void open()
  {
    try
      dbConn = createConnection("sqlite:" ~ buildPath(_daphne.appDir, PlayQueueDatabaseFile));
    catch (Exception e)
      throw new Exception("DB connect error: " ~ e.msg);

    auto stmt = dbConn.createStatement;
    scope(exit) stmt.close;

    try
      stmt.executeUpdate("CREATE TABLE IF NOT EXISTS queue (id INTEGER PRIMARY KEY, song_id int)");
    catch (Exception e)
      throw new Exception("Queue DB table create error: " ~ e.msg);

    SongColumnViewItem[] items;

    try // Load the queue table
    {
      auto rs = stmt.executeQuery("SELECT id, song_id FROM queue ORDER BY id");

      while (rs.next)
      {
        if (auto song = _daphne.library.songIds.get(rs.getLong(2), null))
        {
          auto id = rs.getLong(2);
          items ~= new SongColumnViewItem(song, rs.getLong(1));

          if (id >= _nextQueueId)
            _nextQueueId = id + 1;
        }
      }
    }
    catch (Exception e)
      throw new Exception("Queue DB load error: " ~ e.msg);

    _songColumnView.splice(0, 0, items);
    songCount = cast(uint)items.length;
  }

  /// Close queue database
  void close()
  {
    if (dbConn)
    {
      dbConn.close;
      dbConn = null;
    }
  }

  /**
   * Activate the song at the top of the queue and return it. OK to call if already active, in which case the current song will be returned.
   * Returns: Active song or null if queue is empty
   */
  LibrarySong start()
  {
    if (auto item = _songColumnView.getItem(0))
    {
      isPlaying = true;
      currentSong = item.song;
      return item.song;
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

    if (pos < 0 || pos > _props.songCount) // Append if negative pos or pos off the end
      pos = cast(int)_props.songCount;

    auto qSongs = songs.map!(x => new SongColumnViewItem(x, _nextQueueId++)).array;

    _songColumnView.splice(pos, 0, qSongs);

    try
      dbConn.executeSql("INSERT INTO queue (id, song_id) VALUES "
        ~ qSongs.map!(x => "(" ~ x.id.to!string ~ ", " ~ x.song.id.to!string ~ ")").join(", "));
    catch (Exception e)
      error("Queue DB insert error: " ~ e.msg);

    songCount = _props.songCount + cast(uint)songs.length;
  }

  /**
   * Move the current queue item to the history, making the next song the top of queue.
   */
  void next()
  {
    if (auto item = _songColumnView.getItem(0))
    {
      _daphne.songView.historyColumnView.addSong(item.song);
      remove(0);
    }
  }

  /**
   * Copy last song from history, add it to the top of the queue and activate it.
   */
  void prev()
  {
    if (auto song = _daphne.songView.historyColumnView.pop)
    {
      stop;
      insert([song], 0);
    }
  }

  /**
   * Remove a song from the queue.
   * Params:
   *   pos = Position of song to remove
   */
  void remove(uint pos)
  {
    if (auto item = _songColumnView.getItem(pos))
    {
      dbConn.executeSql("DELETE FROM queue WHERE id=" ~ item.id.to!string);

      _songColumnView.remove(pos);

      if (pos == 0) // If the current song was removed, update it
      {
        currentSong = _props.songCount > 1 ? _songColumnView.getItem(0).song : null;

        if (_props.songCount == 1)
          _nextQueueId = 1; // Reset next queue ID when empty
      }

      songCount = _props.songCount - 1;
    }
  }

  Connection dbConn;

private:
  Daphne _daphne;
  long _nextQueueId = 1;
  SearchEntry _searchEntry;
  ScrolledWindow _scrolledWindow;
  SongColumnView _songColumnView;
  bool isPlaying;
}
