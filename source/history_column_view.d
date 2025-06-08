module history_column_view;

import daphne_includes;

import library_song;
import song_column_view;

/// Play history column view widget
class HistoryColumnView : SongColumnView
{
  this()
  {
    super(true);

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
      auto item = cast(HistoryItem)listItem.getItem;
      auto label = cast(Label)listItem.getChild;
      label.label = SysTime.fromUnixTime(item.playedOn).toISOExtString.replace("T", " ");
    });

    col.setSorter(new CustomSorter((ObjectWrap aObj, ObjectWrap bObj)
      => cast(int)(cast(HistoryItem)aObj).playedOn - cast(int)(cast(HistoryItem)bObj).playedOn));

    sortByColumn(col, SortType.Descending);
  }
}

class HistoryItem : SongColumnViewItem
{
  this(LibrarySong song, long playedOn, long id)
  {
    super(song);
    this.playedOn = playedOn;
    this.id = id;
  }

  long playedOn;
}
