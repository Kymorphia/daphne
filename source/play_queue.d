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
class PlayQueue : Box
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

    songColumnView = new SongColumnView(false, true);
    _scrolledWindow.setChild(songColumnView);

    auto shortCtrl = new ShortcutController;
    shortCtrl.setScope(ShortcutScope.Local);
    addController(shortCtrl);

    shortCtrl.addShortcut(new Shortcut(ShortcutTrigger.parseString("Delete"),
      new CallbackAction(&onDeleteKeyCallback)));

    shuffleButton.connectClicked(&onShuffleButtonClicked);

    _searchEntry.connectSearchChanged(() {
      songColumnView.searchString = _searchEntry.text.toLower;
    });
  }

  private bool onDeleteKeyCallback(Widget widg, GLibVariant args)
  {
    auto ranges = getSelectionRanges(cast(MultiSelection)songColumnView.model);
    long[] qIds;

    // Loop in reverse so that positions don't change as items are removed
    foreach (r; ranges.retro)
    { // Get queue IDs for the range of items
      qIds ~= songColumnView.getItems(iota(r[0], r[1] + 1)).map!(x => x.id).array;
      songColumnView.splice(r[0], r[1] - r[0] + 1, []);
    }

    try
      dbConn.executeSql("DELETE FROM queue WHERE id IN (" ~ qIds.map!(x => x.to!string).join(", ") ~ ")");
    catch (Exception e)
      error("Queue DB delete error: " ~ e.msg);

    return true;
  }

  private void onShuffleButtonClicked()
  {
    if (songColumnView.songCount > 0)
    {
      songColumnView.splice(0, songColumnView.songCount, songColumnView.getItems.array.randomShuffle.array);
      reindexQueueTable;
    }
  }

  private void reindexQueueTable() // Sync the queue table with the queue SongColumnView items
  {
    songColumnView.getItems.enumerate(1).each!((t) { t[1].id = t[0]; }); // Re-sequence queue IDs (start from index 1)
    _nextQueueId = songColumnView.songCount + 1;

    try
    {
      dbConn.executeSql("DELETE FROM queue");
      dbConn.executeSql("INSERT INTO queue (id, song_id) VALUES "
        ~ songColumnView.getItems.map!(x => "(" ~ x.id.to!string ~ ", " ~ x.song.id.to!string ~ ")").join(", "));
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

    songColumnView.splice(0, 0, items);
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
   * Pop the song off the top of the queue.
   * Returns: The song or null if queue is empty
   */
  LibrarySong pop()
  {
    if (auto item = songColumnView.getItem(0))
    {
      songColumnView.remove(0);

      if (songColumnView.songCount == 0)
        _nextQueueId = 1; // Reset next queue ID when there are no more items

      try
        dbConn.executeSql("DELETE FROM queue WHERE id=" ~ item.id.to!string);
      catch (Exception e)
        error("Queue delete error: " ~ e.msg);

      return item.song;
    }
    else
      return null;
  }

  /**
   * Push a song onto the top of the queue.
   * Params:
   *   song = Song to insert as top of queue
   */
  void push(LibrarySong song)
  {
    insert([song], 0);
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
   *   pos = Position to insert at, -1 appends
   */
  void insert(LibrarySong[] songs, int pos)
  {
    if (songs.length == 0)
      return;

    if (pos < 0 || pos > songColumnView.songCount) // Append if negative pos or pos off the end
      pos = cast(int)songColumnView.songCount;

    long startId;

    if (pos >= songColumnView.songCount) // Appending?
    {
      startId = _nextQueueId;
      _nextQueueId += songs.length;
    }
    else // Prepending or inserting
    {
      auto nextId = songColumnView.getItem(pos).id;
      auto prevId = pos > 0 ? songColumnView.getItem(pos - 1).id : 0;

      if (prevId + songs.length >= nextId) // Not enough IDs between items before and after insertion point?
      { // IDs are assigned in reindexQueueTable
        songColumnView.splice(pos, 0, songs.map!(x => new SongColumnViewItem(x)).array);
        reindexQueueTable; // Re-index queue
      }

      startId = nextId - songs.length;
    }

    auto qSongs = songs.map!(x => new SongColumnViewItem(x, startId++)).array;
    songColumnView.splice(pos, 0, qSongs);

    try
      dbConn.executeSql("INSERT INTO queue (id, song_id) VALUES "
        ~ qSongs.map!(x => "(" ~ x.id.to!string ~ ", " ~ x.song.id.to!string ~ ")").join(", "));
    catch (Exception e)
      error("Queue DB insert error: " ~ e.msg);
  }

  Connection dbConn;
  SongColumnView songColumnView;

private:
  Daphne _daphne;
  long _nextQueueId = 1;
  SearchEntry _searchEntry;
  ScrolledWindow _scrolledWindow;
  bool isPlaying;
}
