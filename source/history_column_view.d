module history_column_view;

import daphne_includes;

import daphne;
import library;
import library_song;
import song_column_view;
import utils : executeSql, getSelectionRanges;

/// Play history column view widget
class HistoryColumnView : SongColumnView
{
  this(Daphne daphne)
  {
    super(true, true);
    _daphne = daphne;

    auto factory = new SignalListItemFactory();
    auto col = new ColumnViewColumn(tr!"Played", factory);
    col.expand = false;
    col.resizable = true;
    appendColumn(col);

    factory.connectSetup((ListItem listItem) {
      auto label = new Label;
      label.widthChars = cast(int)"2025-06-03 08:21".length;
      label.maxWidthChars = label.widthChars;
      listItem.setChild(label);
    });
    factory.connectBind((ListItem listItem) {
      auto item = cast(HistoryColumnViewItem)listItem.getItem;
      auto label = cast(Label)listItem.getChild;
      label.label = SysTime.fromUnixTime(item.playedOn).toISOExtString.replace("T", " ");
    });

    col.setSorter(new CustomSorter((ObjectWrap aObj, ObjectWrap bObj)
      => cast(int)(cast(HistoryColumnViewItem)aObj).playedOn - cast(int)(cast(HistoryColumnViewItem)bObj).playedOn));

    sortByColumn(col, SortType.Descending);

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
      hIds ~= getItems(iota(r[0], r[1] + 1)).map!(x => x.id).array;
      splice(r[0], r[1] - r[0] + 1, []);
    }

    try
      _daphne.playQueue.dbConn.executeSql("DELETE FROM history WHERE id IN (" ~ hIds.map!(x => x.to!string).join(", ") ~ ")");
    catch (Exception e)
      error("History DB delete error: " ~ e.msg);

    return true;
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

    HistoryColumnViewItem[] items;

    try // Load the history table
    {
      auto rs = stmt.executeQuery("SELECT id, song_id, timestamp FROM history ORDER BY id");

      while (rs.next)
      {
        if (auto song = _daphne.library.songIds.get(rs.getLong(2), null))
        {
          auto id = rs.getLong(1);
          items ~= new HistoryColumnViewItem(song, rs.getLong(3), id);

          if (id >= _nextHistoryId)
            _nextHistoryId = id + 1;
        }
      }
    }
    catch (Exception e)
      throw new Exception("History DB load error: " ~ e.msg);

    splice(0, 0, cast(SongColumnViewItem[])items);
  }

  /**
   * Add a song to the history.
   */
  override void addSong(LibrarySong song)
  {
    auto historyId = _nextHistoryId++;
    auto curTime = Clock.currTime.toUnixTime;
    super.add(new HistoryColumnViewItem(song, curTime, historyId));

    try
      _daphne.playQueue.dbConn.executeSql("INSERT INTO history (id, song_id, timestamp) VALUES "
        ~ "(" ~ historyId.to!string ~ ", " ~ song.id.to!string ~ ", " ~ curTime.to!string ~ ")");
    catch (Exception e)
      error("History DB insert error: " ~ e.msg);
  }

  alias pop = SongColumnView.pop;

  /**
   * Pop the current song off of the history. Removes it from the history and returns it.
   * Returns: Song popped off of the end of the history or null if none
   */
  LibrarySong pop()
  {
    auto item = cast(HistoryColumnViewItem)super.pop;

    try
      _daphne.playQueue.dbConn.executeSql("DELETE FROM history WHERE id=" ~ item.id.to!string);
    catch (Exception e)
      error("History DB delete error: " ~ e.msg);

    return item.song;
  }

private:
  Daphne _daphne;
  long _nextHistoryId = 1;
}

class HistoryColumnViewItem : SongColumnViewItem
{
  this(LibrarySong song, long playedOn, long id)
  {
    super(song);
    this.playedOn = playedOn;
    this.id = id;
  }

  long playedOn;
}
