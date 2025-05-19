module daphne;

import std.algorithm : sort;
import std.conv : to;
import std.logger;
import std.path : buildPath;
import std.signals;
import std.stdio : writeln;
import std.string : toStringz;

import gda.connection;
import gda.sql_parser;
import gda.types : ConnectionOptions;
import gdk.display;
import gettext;
import gio.menu;
import gio.simple_action;
import gio.types : ApplicationFlags;
import glib.global : getUserConfigDir, timeoutAddSeconds;
import glib.types : OptionArg, OptionEntry, PRIORITY_DEFAULT, SOURCE_CONTINUE;
import glib.variant_dict;
import glib.variant_type;
import gobject.types : GTypeEnum;
import gtk.application;
import gtk.application_window;
import gtk.box;
import gtk.css_provider;
import gtk.label;
import gtk.notebook;
import gtk.paned;
import gtk.popover_menu_bar;
import gtk.progress_bar;
import gtk.spinner;
import gtk.style_context;
import gtk.types : Align, Orientation, STYLE_PROVIDER_PRIORITY_APPLICATION;
import gtk.window;

import library;
import artist_view;
import album_view;
import player;
import play_queue;
import prefs;
import song_display;
import song_view;

enum DaphneVersion = "1.0";

class Daphne : Application
{
  enum LibraryFileName = "daphne-library";
  enum DefaultWidth = 1200;
  enum DefaultHeight = 800;
  enum DefaultArtistViewWidth = 300;
  enum IndexerProgressBarWidth = 50;

	OptionEntry[] cmdLineOptions =
		[
			{"version", 'v', 0, OptionArg.None, null, null, null},
			{null, 0, 0, OptionArg.None, null, null, null}, // Terminator
	];

	enum cmdLineSummary = tr!`Daphne ` ~ DaphneVersion ~ `
Copyright (C) 2025 Kymorphia, PBC
MIT license`;

	this()
	{
		super("com.kymorphia.Daphne", ApplicationFlags.DefaultFlags);

		connectActivate(&onActivate);
		connectStartup(&onStartup);
    connectHandleLocalOptions(&onHandleLocalOptions);

    // Have to translate command line option descriptions at runtime
		static bool cmdLineOptionsInitialized;
    if (!cmdLineOptionsInitialized)
    {
      foreach (i; 0 .. cmdLineOptions.length - 1)
      {
        auto op = cmdLineOptions[i];

        switch (to!string(op.longName))
        {
          case "version":
            op.description = tr!"Print application version and exit".toStringz;
            break;
          default:
            assert(0);
        }
      }

      cmdLineOptionsInitialized = true;
    }

    setOptionContextParameterString(tr!"FILES - Daphne music player");
    setOptionContextSummary(cmdLineSummary);
    addMainOptionEntries(cmdLineOptions);
	}

  private void onStartup()
  {
    auto action = new SimpleAction("preferences", null);
    addAction(action);
    action.connectActivate(() { prefs.showDialog; });

    action = new SimpleAction("quit", null);
    addAction(action);
    action.connectActivate(() { quit; });
  }

	private void onActivate()
	{
    prefs = new Prefs(this);

    try
      prefs.load;
    catch (Exception e)
      info("Failed to load preferences file '", prefs.filename, "': ", e.message);

    // dbConn = Connection.openSqlite(buildPath(getUserConfigDir, "daphne"), LibraryFileName, false);
    dbConn = Connection.openFromString("SQLite", "DB_DIR=" ~ buildPath(getUserConfigDir, "daphne") ~ ";DB_NAME="
      ~ LibraryFileName, null, ConnectionOptions.None);
    assert(dbConn, "Failed to create SQLite database file");
    sqlParser = new SqlParser;
    library = new Library(this);
    library.createTable;
    library.load;

    // Add a monospace font class
    auto provider = new CssProvider;
    provider.loadFromString(".mono-class { font-family: monospace; }");
    StyleContext.addProviderForDisplay(Display.getDefault, provider, STYLE_PROVIDER_PRIORITY_APPLICATION);

		auto mainWindow = new ApplicationWindow(this);
    mainWindow.setDefaultSize(DefaultWidth, DefaultHeight);
    mainWindow.maximize;

    auto vbox = new Box(Orientation.Vertical, 0);
    mainWindow.setChild(vbox);

    auto menuBox = new Box(Orientation.Horizontal, 0);
    vbox.append(menuBox);

    auto menuBar = createMenuBar;
    menuBar.hexpand = true;
    menuBox.append(menuBar);

    _statusLabel = new Label;
    menuBox.append(_statusLabel);

    _indexerProgressBar = new ProgressBar;
    _indexerProgressBar.widthRequest = IndexerProgressBarWidth;
    _indexerProgressBar.visible = false;
    _indexerProgressBar.marginStart = 8;
    _indexerProgressBar.valign = Align.Center;
    menuBox.append(_indexerProgressBar);

    _indexerSpinner = new Spinner;
    _indexerSpinner.visible = false;
    _indexerSpinner.marginStart = 4;
    menuBox.append(_indexerSpinner);

    auto vPaned = new Paned(Orientation.Vertical);
    vPaned.resizeStartChild = true;
    vPaned.resizeEndChild = false;
    vbox.append(vPaned);

    auto hPaned = new Paned(Orientation.Horizontal);
    hPaned.resizeStartChild = false;
    hPaned.resizeEndChild = true;
    vPaned.setStartChild(hPaned);

    artistView = new ArtistView(this);
    hPaned.setStartChild(artistView);
    hPaned.position = DefaultArtistViewWidth;

    auto hPaned2 = new Paned(Orientation.Horizontal);
    hPaned.setEndChild(hPaned2);

    albumView = new AlbumView(this);
    hPaned2.setStartChild(albumView);

    songView = new SongView(this);
    hPaned2.setEndChild(songView);

    auto hpanedPlayer = new Paned(Orientation.Horizontal);
    hpanedPlayer.resizeStartChild = false;
    hpanedPlayer.resizeEndChild = true;
    vPaned.setEndChild(hpanedPlayer);

    songDisplay = new SongDisplay(this);
    hpanedPlayer.setStartChild(songDisplay);

    auto playBox = new Box(Orientation.Vertical, 0);
    hpanedPlayer.setEndChild(playBox);

    playQueue = new PlayQueue(this);
    playBox.append(playQueue);

    player = new Player(this);
    playBox.append(player);

    // FIXME - std.signals doesn't handle lambdas/local functions which would be a lot cleaner here
    artistView.selectionChanged.connect(&onArtistViewSelectionChanged);
    albumView.selectionChanged.connect(&onAlbumViewSelectionChanged);
    songView.queueSongs.connect(&onSongViewQueueSongs);
    playQueue.currentSong.connect(&onPlayQueueCurrentSong);
    player.nextSong.connect(&onPlayerNextSong);
    library.newArtist.connect(&onNewArtist);
    library.newAlbum.connect(&onNewAlbum);
    library.newSong.connect(&onNewSong);

		mainWindow.present;

    timeoutAddSeconds(PRIORITY_DEFAULT, 1, &indexerProgressUpdate);

    library.runIndexerThread; // Re-index the music library on startup
	}

  private bool indexerProgressUpdate() // Called periodically to process background indexer updates
  {
    if (library.isIndexerRunning)
    {
      if (!_indexerSpinner.visible) // Show spinner if it hasn't been
      {
        _statusLabel.label = tr!"Updating library";
        _indexerSpinner.visible = true;
        _indexerSpinner.start;
      }

      auto progress = library.processIndexerResults; // Process indexer results and get progress value

      if (progress !is double.nan) // Progress will be nan if indexer is still calculating new files
      {
        _indexerProgressBar.fraction = progress;

        if (!_indexerProgressBar.visible) // If progress bar is not yet visible, make it visible
          _indexerProgressBar.visible = true;
      }
    }
    else
    {
      if (_indexerProgressBar.visible)
        _indexerProgressBar.visible = false;

      if (_indexerSpinner.visible)
      {
        _indexerSpinner.visible = false;
        _indexerSpinner.stop;
        _statusLabel.label = null;
      }
    }

    return SOURCE_CONTINUE;
  }

  private void onArtistViewSelectionChanged(LibraryArtist[] selectedArtists)
  {
    albumView.setArtists(selectedArtists);
    songView.setArtists(selectedArtists);
  }

  private void onAlbumViewSelectionChanged(LibraryAlbum[] selectedAlbums)
  {
    songView.setAlbums(selectedAlbums);
  }

  private void onSongViewQueueSongs(LibrarySong[] songs)
  {
    playQueue.add(songs);
  }

  private void onPlayQueueCurrentSong(LibrarySong song)
  {
    player.song = song;
    songDisplay.song = song;
  }

  private void onPlayerNextSong()
  {
    playQueue.next;
  }

  private void onNewArtist(LibraryArtist artist)
  {
    artistView.addArtist(artist);
  }

  private void onNewAlbum(LibraryAlbum album)
  {
    albumView.addAlbum(album);
  }

  private void onNewSong(LibrarySong song)
  {
    songView.addSong(song);
  }

  private PopoverMenuBar createMenuBar()
  {
    auto menu = new Menu;

    auto fileMenu = new Menu;
    menu.appendSubmenu(tr!"File", fileMenu);
    fileMenu.append(tr!"Quit", "app.quit");

    auto editMenu = new Menu;
    menu.appendSubmenu(tr!"Edit", editMenu);
    editMenu.append(tr!"Preferences", "app.preferences");

    return PopoverMenuBar.newFromModel(menu);
  }

  // Handle local command line options
  private int onHandleLocalOptions(VariantDict vDict)
  {
    bool getBoolOption(string name)
    {
      auto option = vDict.lookupValue(name, new VariantType("b"));
      return option && option.getBoolean();
    }

    bool getIntOption(string name, int outInt)
    {
      if (auto option = vDict.lookupValue(name, new VariantType("i")))
      {
        outInt = option.getInt32;
        return true;
      }

      return false;
    }

    string getStringOption(string name)
    {
      auto option = vDict.lookupValue(name, new VariantType("s"));
      return option ? option.getString() : null;
    }

    if (getBoolOption("version"))
    {
      writeln(cmdLineSummary);
      return 0;
    }

    return -1; // Activate application
  }

  Connection dbConn;
  SqlParser sqlParser;
  Library library;
  Prefs prefs;

  Window mainWindow;
  ArtistView artistView;
  AlbumView albumView;
  SongView songView;
  SongDisplay songDisplay;
  PlayQueue playQueue;
  Player player;

private:
  Label _statusLabel;
  Spinner _indexerSpinner;
  ProgressBar _indexerProgressBar;
}
