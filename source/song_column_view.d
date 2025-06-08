module song_column_view;

import daphne_includes;

import edit_field;
import library : UnknownName;
import library_song;
import prop_iface;
import rating;
import signal;
import utils : formatSongTime;

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
      listItem.setChild(new EditField(cast(int)LibrarySong.MaxTrack.to!string.length));
    });
    factory.connectBind((ListItem listItem) {
      auto item = cast(SongColumnViewItem)listItem.getItem;
      item.trackField = cast(EditField)listItem.getChild;
      item.trackField.content(item.song.track > 0 ? item.song.track.to!string : "");
    });
    factory.connectUnbind((ListItem listItem) {
      auto item = cast(SongColumnViewItem)listItem.getItem;
      item.trackField = null;
    });

    // Title
    factory = new SignalListItemFactory();
    _columns[Column.Title] = new ColumnViewColumn(tr!"Title", factory);
    _columns[Column.Title].expand = true;
    _columns[Column.Title].resizable = true;
    appendColumn(_columns[Column.Title]);

    factory.connectSetup((ListItem listItem) {
      listItem.setChild(new EditField);
    });
    factory.connectBind((ListItem listItem) {
      auto item = cast(SongColumnViewItem)listItem.getItem;
      item.titleField = cast(EditField)listItem.getChild;
      item.titleField.content = item.song.title.length > 0 ? item.song.title : tr!UnknownName;
    });
    factory.connectUnbind((ListItem listItem) {
      auto item = cast(SongColumnViewItem)listItem.getItem;
      item.titleField = null;
    });

    // Artist
    factory = new SignalListItemFactory();
    _columns[Column.Artist] = new ColumnViewColumn(tr!"Artist", factory);
    _columns[Column.Artist].expand = true;
    _columns[Column.Artist].resizable = true;
    appendColumn(_columns[Column.Artist]);

    factory.connectSetup((ListItem listItem) {
      listItem.setChild(new EditField);
    });
    factory.connectBind((ListItem listItem) {
      auto item = cast(SongColumnViewItem)listItem.getItem;
      item.artistField = cast(EditField)listItem.getChild;
      item.artistField.content = item.song.artist.length > 0 ? item.song.artist : tr!UnknownName;
    });
    factory.connectUnbind((ListItem listItem) {
      auto item = cast(SongColumnViewItem)listItem.getItem;
      item.artistField = null;
    });

    // Album
    factory = new SignalListItemFactory();
    _columns[Column.Album] = new ColumnViewColumn(tr!"Album", factory);
    _columns[Column.Album].expand = true;
    _columns[Column.Album].resizable = true;
    appendColumn(_columns[Column.Album]);

    factory.connectSetup((ListItem listItem) {
      listItem.setChild(new EditField);
    });
    factory.connectBind((ListItem listItem) {
      auto item = cast(SongColumnViewItem)listItem.getItem;
      item.albumField = cast(EditField)listItem.getChild;
      item.albumField.content = item.song.album.length > 0 ? item.song.album : tr!UnknownName;
    });
    factory.connectUnbind((ListItem listItem) {
      auto item = cast(SongColumnViewItem)listItem.getItem;
      item.albumField = null;
    });

    // Year
    factory = new SignalListItemFactory();
    _columns[Column.Year] = new ColumnViewColumn(tr!"Year", factory);
    _columns[Column.Year].expand = false;
    _columns[Column.Year].resizable = true;
    appendColumn(_columns[Column.Year]);

    factory.connectSetup((ListItem listItem) {
      listItem.setChild(new EditField(cast(int)LibrarySong.MaxYear.to!string.length));
    });
    factory.connectBind((ListItem listItem) {
      auto item = cast(SongColumnViewItem)listItem.getItem;
      item.yearField = cast(EditField)listItem.getChild;
      item.yearField.content = item.song.year > 0 ? item.song.year.to!string : "";
    });
    factory.connectUnbind((ListItem listItem) {
      auto item = cast(SongColumnViewItem)listItem.getItem;
      item.yearField = null;
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
          = item.ratingWidg.propChanged.connect((PropIface obj, string propName, StdVariant val, StdVariant oldVal) {
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
  private void onGlobalPropChanged(PropIface propObj, string propName, StdVariant val, StdVariant oldVal)
  {
    if (auto song = cast(LibrarySong)propObj)
    {
      if (auto item = _songItems.get(song, null))
      {
        switch (propName)
        {
          case "album":
            if (item.albumField)
              item.albumField.content = song.album;
            break;
          case "artist":
            if (item.artistField)
              item.artistField.content = song.artist;
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
            if (item.trackField)
              item.trackField.content = song.track > 0 ? song.track.to!string : null;
            break;
          case "title":
            if (item.titleField)
              item.titleField.content = song.title;
            break;
          case "year":
            if (item.yearField)
              item.yearField.content = song.year > 0 ? song.year.to!string : null;
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
   * Get SongColumnViewItem range for a range of item indexes.
   * Params:
   *   indexes = Range of uint indexes
   *   
   */
  auto getItems(R)(R indexes)
    if (isInputRange!R && isIntegral!(ElementType!R))
  {
    return indexes.map!(n => cast(SongColumnViewItem)_listModel.getItem(n));
  }

  /**
   * Get a range of all items in a song view.
   * Returns: Range of SongColumnViewItem objects.
   */
  auto getItems()()
  {
    return getItems(iota(0, _listModel.getNItems));
  }

  /**
   * Get an item at a given position.
   * Params:
   *   position = Position of item
   * Returns: The item at the given position or null if invalid position
   */
  SongColumnViewItem getItem(uint position)
  {
    return cast(SongColumnViewItem)_listModel.getItem(position);
  }

  /**
   * Get number of items in the song view.
   * Returns: Count of items
   */
  uint getItemCount()
  {
    return _listModel.getNItems;
  }

  /**
   * Add an item to the view.
   */
  void add(SongColumnViewItem item)
  {
    _songItems[item.song] = item;
    _listModel.append(item);
  }

  /**
   * Pop the song off of the end of the view. Removes it from the view and returns it.
   * Returns: Song popped off of the end of the view or null if none
   */
  SongColumnViewItem pop()
  {
    auto nItems = _listModel.getNItems;

    if (nItems > 0)
    {
      auto item = cast(SongColumnViewItem)_listModel.getItem(nItems - 1);
      _listModel.remove(nItems - 1);
      return item;
    }

    return null;
  }

  /**
   * Add and/or remove items from the song view.
   * Params:
   *   position = Position in the list model to add/remove
   *   nRemovals = Number of items to remove
   *   additions = Items to add
   */
  void splice(uint position, uint nRemovals, SongColumnViewItem[] additions)
  {
    foreach (pos; position .. position + nRemovals)
      if (auto item = cast(SongColumnViewItem)_listModel.getItem(pos))
        _songItems.remove(item.song);

    foreach(item; additions)
      _songItems[item.song] = item;

    _listModel.splice(position, nRemovals, cast(ObjectWrap[])additions);
  }

  /**
   * Remove an item from a song view.
   * Params:
   *   position = The position to remove
   */
  void remove(uint position)
  {
    if (auto item = cast(SongColumnViewItem)_listModel.getItem(position))
    {
      _songItems.remove(item.song);
      _listModel.remove(position);
    }
  }

  /// Remove all items from a song view.
  void removeAll()
  {
    _songItems.clear;
    _listModel.removeAll;
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

  this(LibrarySong song, long id)
  {
    super(GTypeEnum.Object);
    this.song = song;
    this.id = id;
  }

  mixin(objectMixin);

  LibrarySong song; // The song
  long id; // Used by queue and history view
  EditField albumField;
  EditField artistField;
  Label lengthLabel;
  Rating ratingWidg;
  Rating.SignalHook* ratingWidgChangedHook;
  EditField trackField;
  EditField titleField;
  EditField yearField;
}
