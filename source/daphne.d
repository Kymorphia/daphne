module daphne;

import std.algorithm : sort;
import std.conv : to;
import std.exception : ifThrown;
import std.file : exists, mkdirRecurse;
import std.format : format;
import std.logger;
import std.path : buildPath;
import std.signals;
import std.stdio : writeln;
import std.string : toStringz;

import gdk.display;
import gdk.texture;
import gettext;
import gio.menu;
import gio.simple_action;
import gio.types : ApplicationFlags;
import glib.bytes;
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
import gtk.link_button;
import gtk.notebook;
import gtk.paned;
import gtk.picture;
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
enum DaphneLogoSvg = import("daphne.svg");

class Daphne : Application
{
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

    appDir = buildPath(getUserConfigDir, "daphne");

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

    action = new SimpleAction("about", null);
    addAction(action);
    action.connectActivate(() { showAbout; });
  }

	private void onActivate()
	{
    try
    {
      if (!exists(appDir)) // Create application config directory if it doesn't exist
        mkdirRecurse(appDir);
    }
    catch (Exception e)
    {
      abort("Failed to create application config directory '" ~ appDir ~ "': " ~ e.msg);
      return;
    }

    prefs = new Prefs(this);

    try
      prefs.load;
    catch (Exception e)
      info("Failed to load preferences file '", prefs.filename, "': ", e.msg);

    library = new Library(this);

    try
      library.open;
    catch (Exception e)
    {
      abort("Error opening library database: " ~ e.msg);
      return;
    }

    // Add a monospace font class
    auto provider = new CssProvider;
    provider.loadFromString(".mono-class { font-family: monospace; }");
    StyleContext.addProviderForDisplay(Display.getDefault, provider, STYLE_PROVIDER_PRIORITY_APPLICATION);

		auto mainWindow = new ApplicationWindow(this);
    mainWindow.title = "Daphne";
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

    try
      playQueue.open;
    catch (Exception e)
    {
      abort("Error opening queue database: " ~ e.msg);
      return;
    }

    player = new Player(this);
    playBox.append(player);

    // std.signals doesn't handle lambdas/local functions which would be a lot cleaner here
    artistView.selectionChanged.connect(&onArtistViewSelectionChanged);
    albumView.selectionChanged.connect(&onAlbumViewSelectionChanged);
    songView.queueSongs.connect(&onSongViewQueueSongs);
    playQueue.currentSong.connect(&onPlayQueueCurrentSong);
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

      if (library.unhandledIndexerRequest) // Start a new index operation if one was unhandled (after adding/changing media path during indexing)
        library.runIndexerThread;
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
    songDisplay.song = song;
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

    auto helpMenu = new Menu;
    menu.appendSubmenu(tr!"Help", helpMenu);
    helpMenu.append(tr!"About", "app.about");

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

  void showAbout() // Create and show the about dialog
  {
    auto aboutDialog = new Window;
    aboutDialog.title = tr!"About Daphne";

    auto vbox = new Box(Orientation.Vertical, 4);
    vbox.marginTop = 4;
    vbox.marginBottom = 4;
    vbox.marginStart = 4;
    vbox.marginEnd = 4;
    aboutDialog.setChild(vbox);

    auto logo = Picture.newForPaintable(Texture.newFromBytes(new Bytes(cast(ubyte[])DaphneLogoSvg)).ifThrown(null));
    vbox.append(logo);

    vbox.append(new Label("Daphne " ~ DaphneVersion));
    vbox.append(LinkButton.newWithLabel("https://www.github.com/Kymorphia/daphne", tr!"Website"));

    auto copyrightLabel = new Label;
    copyrightLabel.setMarkup((tr!`Copyright 2025 <a href="https://www.kymorphia.com">Kymorphia, PBC</a>`));
    vbox.append(copyrightLabel);

    vbox.append(new Label(format(tr!"Author: %s", "Element Green <element@kymorphia.com>")));

    auto licenseLabel = new Label;
    licenseLabel.setMarkup(tr!`Licensed under the <a href="https://opensource.org/licenses/mit-license.php">MIT</a> license.`);
    vbox.append(licenseLabel);
    aboutDialog.present;
  }

  override void quit()
  {
    if (player)
      player.stop;

    if (library)
      library.close;

    if (playQueue)
      playQueue.close;

    super.quit;
  }

  /// Print error message and set aborted boolean, returns from function (does not immediately quit)
  void abort(string msg)
  {
    error(msg);
    aborted = true;
    quit;
  }

  bool aborted; // Set to true if application aborted (should exit with non-zero error code)
  string appDir;
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
