module daphne;

import daphne_includes;

import library;
import artist_view;
import album_view;
import mpris;
import player;
import play_queue;
import prefs;
import prop_iface;
import signal;
import cover_display;
import song_view;

enum DaphneVersion = "1.0";
enum DaphneLogoSvg = import("daphne.svg");

/// Custom CSS
enum DaphneCss = `
.mono { font-family: monospace; }
.player-song-info { font-weight: bold; font-size: 24px; }
.player-song-label { text-decoration: underline; font-size: 12px; }
`;

static this()
{
  sharedLog(cast(shared Logger)new DaphneLogger);
}

/// Create our own logger to strip out some of the extra info
class DaphneLogger : Logger
{
  this(LogLevel lv = LogLevel.all) @safe
  {
    super(lv);
  }

  override void writeLogMsg(ref LogEntry entry)
  {
    if (entry.logLevel == LogLevel.info)
      writeln(entry.msg);
    else
      writeln(entry.logLevel.to!string.capitalize ~ ": " ~ entry.msg);
  }
}

class Daphne : Application
{
  enum DefaultWidth = 1200;
  enum DefaultHeight = 800;
  enum DefaultArtistViewWidth = 300;
  enum IndexerProgressBarWidth = 50;
  enum DefaultCoverPictureSize = 360;

	OptionEntry[] cmdLineOptions =
		[
      {"disable-mpris", 0, 0, OptionArg.None, null, null, null},
      {"log-level", 0, 0, OptionArg.String, null, null, null},
			{"version", 'v', 0, OptionArg.None, null, null, null},
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
    connectShutdown(() { quit; });
    connectHandleLocalOptions(&onHandleLocalOptions);

    // Have to translate command line option descriptions at runtime
		static bool cmdLineOptionsInitialized;
    if (!cmdLineOptionsInitialized)
    {
      foreach (i; 0 .. cmdLineOptions.length - 1)
      {
        auto op = &cmdLineOptions[i];

        switch (to!string(op.longName))
        {
          case "disable-mpris":
            op.description = tr!"Disable MPRIS MediaPlayer2 D-Bus server".toStringz;
            break;
          case "log-level":
            op.description = tr!("Log level (" ~ [EnumMembers!LogLevel].map!(x => x.to!string).join(", ") ~ ")").toStringz;
            break;
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
    provider.loadFromString(DaphneCss);
    StyleContext.addProviderForDisplay(Display.getDefault, provider, STYLE_PROVIDER_PRIORITY_APPLICATION);

		mainWindow = new ApplicationWindow(this);
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
    hPaned.marginBottom = 2;
    vPaned.setStartChild(hPaned);

    artistView = new ArtistView(this);
    artistView.marginEnd = 2;
    hPaned.setStartChild(artistView);
    hPaned.position = DefaultArtistViewWidth;

    auto hPaned2 = new Paned(Orientation.Horizontal);
    hPaned.setEndChild(hPaned2);

    albumView = new AlbumView(this);
    albumView.marginStart = 2;
    albumView.marginEnd = 2;
    hPaned2.setStartChild(albumView);

    songView = new SongView(this);
    hPaned2.setEndChild(songView);

    auto hpanedPlayer = new Paned(Orientation.Horizontal);
    hpanedPlayer.resizeStartChild = false;
    hpanedPlayer.resizeEndChild = true;
    hpanedPlayer.marginTop = 2;
    hpanedPlayer.position = DefaultCoverPictureSize;
    vPaned.setEndChild(hpanedPlayer);

    coverDisplay = new CoverDisplay(this);
    hpanedPlayer.setStartChild(coverDisplay);

    idleAdd(PRIORITY_DEFAULT_IDLE, () { // Hack to set vPaned position to set coverDisplay to proper size, without using requestWidth/requestHeight which sets minimum size
      if (vPaned.getAllocatedHeight > DefaultCoverPictureSize)
        vPaned.position = vPaned.getAllocatedHeight - DefaultCoverPictureSize;

      return SOURCE_REMOVE;
    });

    auto playBox = new Box(Orientation.Vertical, 0);
    playBox.marginStart = 2;
    hpanedPlayer.setEndChild(playBox);

    playQueue = new PlayQueue(this);
    playBox.append(playQueue);

    player = new Player(this);
    playBox.append(player);

    try
      playQueue.open;
    catch (Exception e)
    {
      abort("Error opening queue database: " ~ e.msg);
      return;
    }

    try
      songView.openHistory;
    catch (Exception e)
    {
      abort("Error opening history database: " ~ e.msg);
      return;
    }

    artistView.selectionChanged.connect((LibraryArtist[] selectedArtists) {
      albumView.filterArtists(selectedArtists);
      songView.filterArtists(selectedArtists);
    });

    albumView.selectionChanged.connect((LibraryAlbum[] selectedAlbums) {
      songView.filterAlbums(selectedAlbums);
    });

    player.propChanged.connect((propObj, propName, val, oldVal) {
      if (propName == "song")
        if (auto song = val.get!LibrarySong.ifThrown(null))
          coverDisplay.song = song;
    });

    library.newArtist.connect((LibraryArtist artist) {
      artistView.addArtist(artist);
    });

    library.newAlbum.connect((LibraryAlbum album) {
      albumView.addAlbum(album);
    });

    library.newSong.connect((LibrarySong song) {
      songView.songColumnView.addSong(song);
    });

		mainWindow.present;

    mpris = new Mpris(this);

    if (!_disableMpris)
      mpris.connect;

    timeoutAddSeconds(PRIORITY_DEFAULT, 1, &indexerProgressUpdate);

    library.runIndexerThread; // Re-index the music library on startup

    // FIXME - Hack to prevent changing width request of album view from changing the Paned gutter position
    idleAdd(PRIORITY_DEFAULT_IDLE, () {
      auto pos = albumView.getAllocatedWidth;
      if (pos > 0)
      {
        hPaned2.position = pos;
        return SOURCE_REMOVE;
      }

      return SOURCE_CONTINUE;
    });
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

    LogLevel logLevel = LogLevel.warning;

    if (auto logLevelStr = getStringOption("log-level"))
    {
      try
        logLevel = logLevelStr.to!LogLevel;
      catch (ConvException e)
      {
        error("Invalid LogLevel '" ~ logLevelStr ~ "' valid values are: " ~ [EnumMembers!LogLevel]
          .map!(x => x.to!string).join(", "));
        return 1;
      }
    }

    globalLogLevel(logLevel);

    _disableMpris = getBoolOption("disable-mpris");

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
  CoverDisplay coverDisplay;
  PlayQueue playQueue;
  Player player;
  Mpris mpris;

private:
  Label _statusLabel;
  Spinner _indexerSpinner;
  ProgressBar _indexerProgressBar;
  bool _disableMpris;
}
