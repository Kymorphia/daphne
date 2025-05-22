module play_queue;

import std.algorithm : canFind, cmp, endsWith, map, sort, startsWith;
import std.array : array, insertInPlace;
import std.conv : to;
import std.format : format;
import std.random : randomShuffle;
import std.signals;
import std.string : toLower;

import gettext;
import gio.list_model;
import gio.list_store;
import glib.global : timeoutAdd;
import glib.source;
import glib.types : PRIORITY_DEFAULT, SOURCE_REMOVE;
import glib.variant;
import gobject.object;
import gobject.types : GTypeEnum;
import gobject.value;
import gtk.bitset;
import gtk.bitset_iter;
import gtk.box;
import gtk.button;
import gtk.callback_action;
import gtk.column_view;
import gtk.column_view_column;
import gtk.custom_filter;
import gtk.custom_sorter;
import gtk.filter_list_model;
import gtk.label;
import gtk.list_item;
import gtk.multi_selection;
import gtk.scrolled_window;
import gtk.search_entry;
import gtk.selection_model;
import gtk.shortcut;
import gtk.shortcut_controller;
import gtk.shortcut_trigger;
import gtk.signal_list_item_factory;
import gtk.sort_list_model;
import gtk.text;
import gtk.types : FilterChange, Orientation, ShortcutScope;
import gtk.widget;

import daphne;
import library;
import song;

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

    _listModel = new ListStore(GTypeEnum.Object);

    _searchFilter = new CustomFilter(&searchFilterFunc);
    auto filterListModel = new FilterListModel(_listModel, _searchFilter); // Used to filter on search text
    _selModel = new MultiSelection(filterListModel);
    _columnView = new ColumnView(_selModel);
    _columnView.addCssClass("data-table");
    _scrolledWindow.setChild(_columnView);

    auto factory = new SignalListItemFactory();
    factory.connectSetup(&onTrackSetup);
    factory.connectBind(&onTrackBind);
    auto col = new ColumnViewColumn(tr!"Track", factory);
    _columnView.appendColumn(col);
    col.expand = false;
    col.resizable = true;

    factory = new SignalListItemFactory();
    factory.connectSetup(&onTitleSetup);
    factory.connectBind(&onTitleBind);
    col = new ColumnViewColumn(tr!"Title", factory);
    _columnView.appendColumn(col);
    col.expand = true;
    col.resizable = true;

    factory = new SignalListItemFactory();
    factory.connectSetup(&onArtistSetup);
    factory.connectBind(&onArtistBind);
    col = new ColumnViewColumn(tr!"Artist", factory);
    _columnView.appendColumn(col);
    col.expand = true;
    col.resizable = true;

    factory = new SignalListItemFactory();
    factory.connectSetup(&onAlbumSetup);
    factory.connectBind(&onAlbumBind);
    col = new ColumnViewColumn(tr!"Album", factory);
    _columnView.appendColumn(col);
    col.expand = true;
    col.resizable = true;

    factory = new SignalListItemFactory();
    factory.connectSetup(&onLengthSetup);
    factory.connectBind(&onLengthBind);
    col = new ColumnViewColumn(tr!"Length", factory);
    _columnView.appendColumn(col);
    col.expand = false;
    col.resizable = true;

    factory = new SignalListItemFactory();
    factory.connectSetup(&onYearSetup);
    factory.connectBind(&onYearBind);
    col = new ColumnViewColumn(tr!"Year", factory);
    _columnView.appendColumn(col);
    col.expand = false;
    col.resizable = true;

    auto shortCtrl = new ShortcutController;
    shortCtrl.setScope(ShortcutScope.Local);
    addController(shortCtrl);

    shortCtrl.addShortcut(new Shortcut(ShortcutTrigger.parseString("Delete"),
      new CallbackAction(&onDeleteKeyCallback)));
  }

  private bool onDeleteKeyCallback(Widget widg, Variant args)
  {
    BitsetIter iter;
    uint position;

    if (BitsetIter.initLast(iter, _selModel.getSelection, position)) // Loop over selection backwards so positions don't change as they are deleted
    {
      do
      {
        _listModel.remove(position);
      }
      while (iter.previous(position));
    }

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
  }

  private bool searchFilterFunc(ObjectWrap item)
  {
    return (_searchString.length == 0 || (cast(LibrarySong)item).name.toLower.canFind(_searchString)); // No search or search matches?
  }

  private void onTrackSetup(ListItem listItem)
  {
    listItem.setChild(new Label);
  }

  private void onTrackBind(ListItem listItem)
  {
    auto track = (cast(LibrarySong)listItem.getItem).song.track;
    (cast(Label)listItem.getChild).setText(track > 0 ? track.to!string : null);
  }

  private void onTitleSetup(ListItem listItem)
  {
    auto text = new Text;
    text.hexpand = true;
    listItem.setChild(text);
  }

  private void onTitleBind(ListItem listItem)
  {
    auto song = (cast(LibrarySong)listItem.getItem).song;
    auto text = cast(Text)listItem.getChild;
    text.getBuffer.setText(song.title.length > 0 ? song.title : tr!UnknownName, -1);
    text.setEditable(false);
    text.setCanFocus(false);
    text.setCanTarget(false);
    text.setFocusOnClick(false);
  }

  private void onArtistSetup(ListItem listItem)
  {
    auto text = new Text;
    text.hexpand = true;
    listItem.setChild(text);
  }

  private void onArtistBind(ListItem listItem)
  {
    auto song = (cast(LibrarySong)listItem.getItem).song;
    auto text = cast(Text)listItem.getChild;
    text.getBuffer.setText(song.artist.length > 0 ? song.artist : tr!UnknownName, -1);
    text.setEditable(false);
    text.setCanFocus(false);
    text.setCanTarget(false);
    text.setFocusOnClick(false);
  }

  private void onAlbumSetup(ListItem listItem)
  {
    auto text = new Text;
    text.hexpand = true;
    listItem.setChild(text);
  }

  private void onAlbumBind(ListItem listItem)
  {
    auto song = (cast(LibrarySong)listItem.getItem).song;
    auto text = cast(Text)listItem.getChild;
    text.getBuffer.setText(song.album.length > 0 ? song.album : tr!UnknownName, -1);
    text.setEditable(false);
    text.setCanFocus(false);
    text.setCanTarget(false);
    text.setFocusOnClick(false);
  }

  private void onLengthSetup(ListItem listItem)
  {
    listItem.setChild(new Label);
  }

  private void onLengthBind(ListItem listItem)
  {
    auto length = (cast(LibrarySong)listItem.getItem).song.length;
    (cast(Label)listItem.getChild).setText(length > 0 ? format("%u:%02u", length / 60, length % 60) : null);
  }

  private void onYearSetup(ListItem listItem)
  {
    listItem.setChild(new Label);
  }

  private void onYearBind(ListItem listItem)
  {
    auto year = (cast(LibrarySong)listItem.getItem).song.year;
    (cast(Label)listItem.getChild).setText(year > 0 ? year.to!string : null);
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
      currentSong.emit(_songs[0]);
      return _songs[0];
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

    _listModel.splice(pos, 0, cast(ObjectWrap[])songs);
    _songs.insertInPlace(pos, songs);

    if (_songs.length == songs.length)
      currentSong.emit(_songs[0]);
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

    _listModel.remove(pos);
    _songs = _songs[0 .. pos] ~ _songs[pos + 1 .. $];

    if (pos == 0) // If the current song was removed, update it
      currentSong.emit(_songs.length > 0 ? _songs[0] : null);
  }

  mixin Signal!(LibrarySong) currentSong;

private:
  Daphne _daphne;
  LibrarySong[] _songs;
  SearchEntry _searchEntry;
  ulong _searchChangedHandler;
  string _searchString;
  ScrolledWindow _scrolledWindow;
  MultiSelection _selModel;
  ListStore _listModel;
  CustomFilter _searchFilter;
  ColumnView _columnView;
  bool isPlaying;
}
