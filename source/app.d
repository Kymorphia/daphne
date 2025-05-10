import std.algorithm : sort;
import std.conv : to;
import std.stdio : writeln;
import std.string : toStringz;

import gettext;
import gio.types : ApplicationFlags;
import glib.types : OptionArg, OptionEntry;
import glib.variant_dict;
import glib.variant_type;
import gobject.types : GTypeEnum;
import gst.global : gstInit = init_;
import gtk.application;
import gtk.application_window;

import indexer;

enum DaphneVersion = "1.0";

class DaphneApp : Application
{
	enum DefaultWidth = 1200;
	enum DefaultHeight = 800;

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
    window.setDefaultSize(DefaultWidth, DefaultHeight);
    window.setShowMenubar = true;
		window.present();
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
			auto indexer = new Indexer;
			auto fileTags = indexer.indexPath(path);

			import std.json;
			import glib.date;
			auto fileArray = JSONValue.emptyArray;

			foreach (fileName; fileTags.keys.sort)
			{
				auto tagObj = JSONValue(["filename": fileName]);

				foreach (k, v; fileTags[fileName])
				{
					if (v.gType == GTypeEnum.String)
						tagObj[k] = v.get!string;
					else if (v.gType == GTypeEnum.Uint)
						tagObj[k] = v.get!uint;
					else if (v.gType == GTypeEnum.Uint64)
						tagObj[k] = v.get!ulong;
					else if (v.gType == GTypeEnum.Double)
						tagObj[k] = v.get!double;
					else if (v.gType == Date._getGType)
						tagObj[k] = v.get!Date.strftime("%Y-%m-%d");
				}

				fileArray.array ~= tagObj;
			}

			import std.file : write;
			write("Library.json", toJSON(fileArray, true));

			return 0;
		}

    if (getBoolOption("version"))
    {
      writeln(cmdLineSummary);
      return 0;
    }

    return -1; // Activate application
  }
}

int main(string[] args)
{
	gstInit(args);

  auto daphne = new DaphneApp;
  daphne.run(args);

  return 0;
}
