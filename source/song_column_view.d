module song_column_view;

import std.conv : to;
import std.string : icmp;
import std.variant : Variant;

import gettext;
import gio.list_model;
import gio.list_store;
import gobject.object;
import gobject.types : GTypeEnum;
import gtk.bitset;
import gtk.bitset_iter;
import gtk.column_view;
import gtk.column_view_column;
import gtk.custom_sorter;
import gtk.label;
import gtk.list_item;
import gtk.multi_selection;
import gtk.signal_list_item_factory;
import gtk.text;
import gtk.types : FilterChange, Orientation, SortType;

import library : UnknownName;
import library_song;
import prop_iface;
import rating;
import signal;
import utils : formatSongTime, initTextNotEditable;

/// Song column view widget. Used by SongView and PlayQueue
class SongColumnView : ColumnView
{
  this(bool enableSorting)
  {
    addCssClass("data-table");

    _listModel = new ListStore(GTypeEnum.Object);
    _selModel = new MultiSelection(_listModel);
    model = _selModel;
    addColumns;

    if (enableSorting)
      setColumnSorters;

    _selModel.connectSelectionChanged(&onSelectionModelChanged);
    _globalPropChangedHook = propChangedGlobal.connect(&onGlobalPropChanged);
  }

  ~this()
  {
    propChangedGlobal.disconnect(_globalPropChangedHook);
  }

  private void addColumns() // Add ColumnView columns
  { // Track
    auto factory = new SignalListItemFactory();
    _columns[Column.Track] = new ColumnViewColumn(tr!"Track", factory);
    _columns[Column.Track].expand = false;
    _columns[Column.Track].resizable = true;
    appendColumn(_columns[Column.Track]);

    factory.connectSetup((ListItem listItem) {
      auto text = new Text;
      text.widthChars = cast(int)LibrarySong.MaxTrack.to!string.length;
      text.maxWidthChars = text.widthChars;
      listItem.setChild(text);
    });
    factory.connectBind((ListItem listItem) {
      auto item = cast(SongColumnViewItem)listItem.getItem;
      item.trackText = cast(Text)listItem.getChild;
      auto track = item.song.track;
      item.trackText.initTextNotEditable(track > 0 ? track.to!string : "");
    });
    factory.connectUnbind((ListItem listItem) {
      auto item = cast(SongColumnViewItem)listItem.getItem;
      item.trackText = null;
    });

    // Title
    factory = new SignalListItemFactory();
    _columns[Column.Title] = new ColumnViewColumn(tr!"Title", factory);
    _columns[Column.Title].expand = true;
    _columns[Column.Title].resizable = true;
    appendColumn(_columns[Column.Title]);

    factory.connectSetup((ListItem listItem) {
      auto text = new Text;
      text.hexpand = true;
      listItem.setChild(text);
    });
    factory.connectBind((ListItem listItem) {
      auto item = cast(SongColumnViewItem)listItem.getItem;
      item.titleText = cast(Text)listItem.getChild;
      item.titleText.initTextNotEditable(item.song.title.length > 0 ? item.song.title : tr!UnknownName);
    });
    factory.connectUnbind((ListItem listItem) {
      auto item = cast(SongColumnViewItem)listItem.getItem;
      item.titleText = null;
    });

    // Artist
    factory = new SignalListItemFactory();
    _columns[Column.Artist] = new ColumnViewColumn(tr!"Artist", factory);
    _columns[Column.Artist].expand = true;
    _columns[Column.Artist].resizable = true;
    appendColumn(_columns[Column.Artist]);

    factory.connectSetup((ListItem listItem) {
      auto text = new Text;
      text.hexpand = true;
      listItem.setChild(text);
    });
    factory.connectBind((ListItem listItem) {
      auto item = cast(SongColumnViewItem)listItem.getItem;
      item.artistText = cast(Text)listItem.getChild;
      item.artistText.initTextNotEditable(item.song.artist.length > 0 ? item.song.artist : tr!UnknownName);
    });
    factory.connectUnbind((ListItem listItem) {
      auto item = cast(SongColumnViewItem)listItem.getItem;
      item.artistText = null;
    });

    // Album
    factory = new SignalListItemFactory();
    _columns[Column.Album] = new ColumnViewColumn(tr!"Album", factory);
    _columns[Column.Album].expand = true;
    _columns[Column.Album].resizable = true;
    appendColumn(_columns[Column.Album]);

    factory.connectSetup((ListItem listItem) {
      auto text = new Text;
      text.hexpand = true;
      listItem.setChild(text);
    });
    factory.connectBind((ListItem listItem) {
      auto item = cast(SongColumnViewItem)listItem.getItem;
      item.albumText = cast(Text)listItem.getChild;
      item.albumText.initTextNotEditable(item.song.album.length > 0 ? item.song.album : tr!UnknownName);
    });
    factory.connectUnbind((ListItem listItem) {
      auto item = cast(SongColumnViewItem)listItem.getItem;
      item.albumText = null;
    });

    // Year
    factory = new SignalListItemFactory();
    _columns[Column.Year] = new ColumnViewColumn(tr!"Year", factory);
    _columns[Column.Year].expand = false;
    _columns[Column.Year].resizable = true;
    appendColumn(_columns[Column.Year]);

    factory.connectSetup((ListItem listItem) {
      auto text = new Text;
      text.widthChars = cast(int)LibrarySong.MaxYear.to!string.length;
      text.maxWidthChars = text.widthChars;
      listItem.setChild(text);
    });
    factory.connectBind((ListItem listItem) {
      auto item = cast(SongColumnViewItem)listItem.getItem;
      item.yearText = cast(Text)listItem.getChild;
      item.yearText.initTextNotEditable(item.song.year > 0 ? item.song.year.to!string : "");
    });
    factory.connectUnbind((ListItem listItem) {
      auto item = cast(SongColumnViewItem)listItem.getItem;
      item.yearText = null;
    });

    // Rating
    factory = new SignalListItemFactory();
    _columns[Column.Rating] = new ColumnViewColumn(tr!"Rating", factory);
    _columns[Column.Rating].expand = false;
    _columns[Column.Rating].resizable = false;
    appendColumn(_columns[Column.Rating]);

    factory.connectSetup((ListItem listItem) {
      listItem.setChild(new Rating);
    });
    factory.connectBind((ListItem listItem) {
      auto item = cast(SongColumnViewItem)listItem.getItem;
      item.ratingWidg = cast(Rating)listItem.getChild;
      item.ratingWidg.value = item.song.rating;

      item.ratingWidgChangedHook
          = item.ratingWidg.propChanged.connect((PropIface obj, string propName, Variant val, Variant oldVal) {
        if (propName == "value")
          item.song.rating = val.get!ubyte;
      });
    });
    factory.connectUnbind((ListItem listItem) {
      auto item = cast(SongColumnViewItem)listItem.getItem;
      item.ratingWidg.propChanged.disconnect(item.ratingWidgChangedHook);
      item.ratingWidg = null;
      item.ratingWidgChangedHook = null;
    });

    // Length
    factory = new SignalListItemFactory();
    _columns[Column.Length] = new ColumnViewColumn(tr!"Length", factory);
    _columns[Column.Length].expand = false;
    _columns[Column.Length].resizable = true;
    appendColumn(_columns[Column.Length]);

    factory.connectSetup((ListItem listItem) {
      auto label = new Label;
      label.widthChars = cast(int)LibrarySong.MaxLength.formatSongTime.length;
      label.maxWidthChars = label.widthChars;
      listItem.setChild(label);
    });
    factory.connectBind((ListItem listItem) {
      auto item = cast(SongColumnViewItem)listItem.getItem;
      item.lengthLabel = cast(Label)listItem.getChild;
      item.lengthLabel.label = formatSongTime(item.song.length);
    });
    factory.connectUnbind((ListItem listItem) {
      auto item = cast(SongColumnViewItem)listItem.getItem;
      item.lengthLabel = null;
    });
  }

  private void setColumnSorters() // Set sorters on each column
  {
    _columns[Column.Track].setSorter(new CustomSorter((ObjectWrap aObj, ObjectWrap bObj)
      => (cast(SongColumnViewItem)aObj).song.track - (cast(SongColumnViewItem)bObj).song.track));

    _columns[Column.Title].setSorter(new CustomSorter((ObjectWrap aObj, ObjectWrap bObj)
      => icmp((cast(SongColumnViewItem)aObj).song.title, (cast(SongColumnViewItem)bObj).song.title)));

    _columns[Column.Artist].setSorter(new CustomSorter((ObjectWrap aObj, ObjectWrap bObj)
      => icmp((cast(SongColumnViewItem)aObj).song.artist, (cast(SongColumnViewItem)bObj).song.artist)));

    _columns[Column.Album].setSorter(new CustomSorter((ObjectWrap aObj, ObjectWrap bObj)
      => icmp((cast(SongColumnViewItem)aObj).song.album, (cast(SongColumnViewItem)bObj).song.album)));

    _columns[Column.Year].setSorter(new CustomSorter((ObjectWrap aObj, ObjectWrap bObj)
      => (cast(SongColumnViewItem)aObj).song.year - (cast(SongColumnViewItem)bObj).song.year));

    _columns[Column.Rating].setSorter(new CustomSorter((ObjectWrap aObj, ObjectWrap bObj)
      => (cast(SongColumnViewItem)aObj).song.rating - (cast(SongColumnViewItem)bObj).song.rating));

    _columns[Column.Length].setSorter(new CustomSorter((ObjectWrap aObj, ObjectWrap bObj)
      => (cast(SongColumnViewItem)aObj).song.length - (cast(SongColumnViewItem)bObj).song.length));

    sortByColumn(_columns[Column.Title], SortType.Ascending);
  }

  // Callback for global PropIface object property changes
  private void onGlobalPropChanged(PropIface propObj, string propName, Variant val, Variant oldVal)
  {
    if (auto song = cast(LibrarySong)propObj)
    {
      if (auto item = _songItems.get(song, null))
      {
        switch (propName)
        {
          case "album":
            if (item.albumText)
              item.albumText.text = song.album;
            break;
          case "artist":
            if (item.artistText)
              item.artistText.text = song.artist;
            break;
          case "length":
            if (item.lengthLabel)
              item.lengthLabel.label = formatSongTime(song.length);
            break;
          case "rating":
            if (item.ratingWidg)
              item.ratingWidg.value = song.rating;
            break;
          case "track":
            if (item.trackText)
              item.trackText.text = song.track > 0 ? song.track.to!string : null;
            break;
          case "title":
            if (item.titleText)
              item.titleText.text = song.title;
            break;
          case "year":
            if (item.yearText)
              item.yearText.text = song.year > 0 ? song.year.to!string : null;
            break;
          default:
            break;
        }
      }
    }
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
        selection ~= (cast(SongColumnViewItem)_selModel.getItem(position)).song;
      }
      while (iter.next(position));
    }

    selectionChanged.emit(selection);
  }

  /**
   * Add a song to the view.
   */
  void addSong(LibrarySong song)
  {
    auto item = new SongColumnViewItem(song);
    _songItems[song] = item;
    _listModel.append(item);
  }

  mixin Signal!(LibrarySong[]) selectionChanged; /// Selected songs changed signal

  LibrarySong[] selection;

  enum Column
  {
    Track,
    Title,
    Artist,
    Album,
    Year,
    Rating,
    Length,
  }

private:
  ColumnViewColumn[Column.max + 1] _columns;
  string _searchString;
  MultiSelection _selModel;
  ListStore _listModel;
  propChangedGlobal.SignalHook* _globalPropChangedHook; // Global property change signal hook

  SongColumnViewItem[LibrarySong] _songItems; // Map of LibrarySong objects to SongColumnViewItem
}

/// GObject derived class to use in ListModel for ColumnView items
class SongColumnViewItem : ObjectWrap
{
  this(LibrarySong song)
  {
    super(GTypeEnum.Object);
    this.song = song;
  }

  mixin(objectMixin);

  LibrarySong song; // The song
  long queueId; // Queue ID (use by PlayQueue only)
  Text albumText;
  Text artistText;
  Label lengthLabel;
  Rating ratingWidg;
  Rating.SignalHook* ratingWidgChangedHook;
  Text trackText;
  Text titleText;
  Text yearText;
}
