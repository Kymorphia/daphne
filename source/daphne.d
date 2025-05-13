module daphne;

import std.algorithm : sort;
import std.conv : to;
import std.stdio : writeln;
import std.string : toStringz;

import gda.connection;
import gda.sql_parser;
import gda.types : ConnectionOptions;
import gettext;
import gio.menu;
import gio.types : ApplicationFlags;
import glib.types : OptionArg, OptionEntry;
import glib.variant_dict;
import glib.variant_type;
import gobject.types : GTypeEnum;
import gtk.application;
import gtk.application_window;
import gtk.box;
import gtk.notebook;
import gtk.paned;
import gtk.types : Orientation;

import library;
import music_browser;
import player;
import playlist_notebook;

enum DaphneVersion = "1.0";

class Daphne : Application
{
  enum DefaultLibraryTreeWidth = 300;
  enum DefaultPlayerHeight = 200;
  enum LibraryFileName = "library.sqlite";

	OptionEntry[] cmdLineOptions =
		[
			{"index", 'i', 0, OptionArg.String, null, null, null},
			{"version", 'v', 0, OptionArg.None, null, null, null},
			{null, 0, 0, OptionArg.None, null, null, null}, // Terminator
	];

	enum cmdLineSummary = tr!`Daphne ` ~ DaphneVersion ~ `
Copyright (C) 2025 Kymorphia, PBC
MIT license`;

	this()
	{
		super("com.kymorphia.Daphne", ApplicationFlags.DefaultFlags);

    //dbConn = Connection.openSqlite(".", LibraryFileName, false);
    dbConn = Connection.openFromString("SQLite", "DB_DIR=.;DB_NAME=library.sqlite", null, ConnectionOptions.None);
    assert(dbConn, "Failed to create SQLite database file");
    sqlParser = new SqlParser;
    library = new Library(this);
    library.createTable;
    library.load;

		connectActivate(&onActivate);
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
					case "index":
            op.description = tr!"Recursively add a path to the media library".toStringz;
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

	void onActivate()
	{
		auto window = new ApplicationWindow(this);
    window.maximize;
    window.setShowMenubar = true;
    setMenubar(createMenuBar);

    auto vPaned = new Paned(Orientation.Vertical);
    window.setChild(vPaned);

    auto hPaned = new Paned(Orientation.Horizontal);
    hPaned.vexpand = true;
    vPaned.setStartChild(hPaned);

    musicBrowser = new MusicBrowser(this);
    musicBrowser.hexpand = false;
    hPaned.setStartChild(musicBrowser);

    playlistNotebook = new PlaylistNotebook(this);
    playlistNotebook.hexpand = true;
    hPaned.setEndChild(playlistNotebook);
    hPaned.position = DefaultLibraryTreeWidth;

    player = new Player(this);
    player.vexpand = false;
    player.heightRequest = DefaultPlayerHeight;
    vPaned.setEndChild(player);

		window.present;
	}

  private Menu createMenuBar()
  {
    auto menu = new Menu;

    auto fileMenu = new Menu;
    menu.appendSubmenu(tr!"File", fileMenu);

    fileMenu.append(tr!"Quit", "app.quit");

    return menu;
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

		if (auto path = getStringOption("index"))
		{
			library.indexPath(path);
			return 0;
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
  MusicBrowser musicBrowser;
  PlaylistNotebook playlistNotebook;
  Player player;
}
