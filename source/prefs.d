module prefs;

import std.algorithm : map, remove;
import std.array : array;
import std.exception : ifThrown;
import std.file : exists, mkdirRecurse, readText, write;
import std.json : JSONOptions, JSONValue, parseJSON, toJSON;
import std.logger;
import std.path : buildPath;

import gettext;
import gio.async_result;
import gio.file;
import glib.global : getUserConfigDir;
import gobject.object;
import gtk.box;
import gtk.button;
import gtk.file_dialog;
import gtk.label;
import gtk.list_item;
import gtk.list_view;
import gtk.paned;
import gtk.scrolled_window;
import gtk.signal_list_item_factory;
import gtk.single_selection;
import gtk.stack;
import gtk.stack_sidebar;
import gtk.string_list;
import gtk.string_object;
import gtk.types : INVALID_LIST_POSITION, Orientation;
import gtk.widget;
import gtk.window;

import daphne;

enum PrefsVersion = "1.0";

class Prefs
{
  enum PrefsFilename = "daphne-prefs.json";
  enum DefaultWidth = 600;
  enum DefaultHeight = 400;

  this(Daphne daphne)
  {
    _daphne = daphne;
    appDir = buildPath(getUserConfigDir, "daphne");
    filename = buildPath(appDir, PrefsFilename);
  }

  /**
   * Load preferences from JSON config file.
   * Throws: FileException, UTFException, ConvException, JSONException
   */
  void load()
  {
    if (exists(appDir)) // Ignore case where application directory does not exist yet
    {
      auto js = parseJSON(filename.readText);

      prefsVersion = js["version"].str;

      if ("media-paths" in js)
        mediaPaths = js["media-paths"].array.map!(x => x.str).array;
    }
    else
      warning("Application config directory '" ~ appDir ~ "' not found");
  }

  /**
   * Save preferences configuration to JSON config file.
   * Throws: FileException
   */
  void save()
  {
    if (!exists(appDir))
      mkdirRecurse(appDir);

    auto js = JSONValue.emptyObject;
    js["version"] = PrefsVersion;
    js["media-paths"] = JSONValue(mediaPaths.map!(x => JSONValue(x)).array);

    filename.write(toJSON(js, true /* pretty */, JSONOptions.doNotEscapeSlashes) ~ "\n");
  }

  /**
   * Show the preferences dialog.
   */
  void showDialog()
  {
    auto prefsDialog = new Window;
    prefsDialog.title = tr!"Preferences";
    prefsDialog.defaultWidth = DefaultWidth;
    prefsDialog.defaultHeight = DefaultHeight;
    prefsDialog.modal = true;
    prefsDialog.setTransientFor(_daphne.mainWindow);

    auto paned = new Paned(Orientation.Horizontal);
    paned.resizeStartChild = false;
    paned.resizeEndChild = true;
    prefsDialog.setChild(paned);

    auto stackSidebar = new StackSidebar;
    paned.setStartChild(stackSidebar);

    auto stack = new Stack;
    stackSidebar.stack = stack;
    paned.setEndChild(stack);

    stack.addTitled(createLibraryGroup(prefsDialog), "library", tr!"Library");

    prefsDialog.connectCloseRequest(() {
      save;
      return false; // false allows other handlers to run
    });

    prefsDialog.present;
  }

  private Widget createLibraryGroup(Window prefsDialog)
  {
    auto vbox = new Box(Orientation.Vertical, 4);

    vbox.append(new Label(tr!"Media Paths"));

    auto stringList = new StringList(mediaPaths);
    auto selection = new SingleSelection(stringList);

    auto factory = new SignalListItemFactory;

    factory.connectSetup((ListItem listItem) {
      auto label = new Label;
      label.xalign = 0.0;
      listItem.setChild(label);
    });

    factory.connectBind((ListItem listItem) {
      auto label = cast(Label)listItem.getChild;
      auto item = cast(StringObject)listItem.getItem;
      label.setText(item.getString);
    });

    auto scrollWin = new ScrolledWindow;
    scrollWin.marginStart = 4;
    scrollWin.marginEnd = 4;
    scrollWin.marginTop = 4;
    scrollWin.marginBottom = 4;
    scrollWin.vexpand = true;
    vbox.append(scrollWin);

    auto listView = new ListView(selection, factory);
    scrollWin.setChild(listView);

    auto btnBox = new Box(Orientation.Horizontal, 0);
    vbox.append(btnBox);

    auto addBtn = Button.newFromIconName("list-add");
    btnBox.append(addBtn);

    auto removeBtn = Button.newFromIconName("list-remove");
    removeBtn.sensitive = mediaPaths.length > 0;
    btnBox.append(removeBtn);

    auto folderBtn = Button.newFromIconName("folder");
    folderBtn.sensitive = mediaPaths.length > 0;
    btnBox.append(folderBtn);

    selection.connectSelectionChanged(() {
      auto isSelected = selection.selected != INVALID_LIST_POSITION;
      removeBtn.sensitive = isSelected;
      folderBtn.sensitive = isSelected;
    });

    addBtn.connectClicked(() { // Add media path button clicked
      auto dialog = new FileDialog;
      dialog.selectFolder(prefsDialog, null, (ObjectWrap obj, AsyncResult res) {
        if (auto file = dialog.selectFolderFinish(res).ifThrown(null))
        {
          mediaPaths ~= file.getPath;
          stringList.append(mediaPaths[$ - 1]);
          removeBtn.sensitive = true;
          folderBtn.sensitive = true;

          _daphne.library.runIndexerThread; // Re-run indexer (sets unhandledIndexerRequest if already running, to re-run it again)
        }
      });
    });

    removeBtn.connectClicked(() { // Remove media path button clicked
      auto selected = selection.selected;
      if (selected != INVALID_LIST_POSITION)
      {
        stringList.remove(selected);
        mediaPaths = mediaPaths.remove(selected);
        removeBtn.sensitive = mediaPaths.length > 0;
        folderBtn.sensitive = mediaPaths.length > 0;
      }
    });

    folderBtn.connectClicked(() { // Media path folder selection button clicked
      auto selected = selection.selected;
      if (selected == INVALID_LIST_POSITION)
        return;

      auto dialog = new FileDialog; // Create folder selection dialog and init to current selected path
      dialog.setInitialFolder(File.newForPath(mediaPaths[selected]));
      dialog.selectFolder(prefsDialog, null, (ObjectWrap obj, AsyncResult res) {
        if (auto file = dialog.selectFolderFinish(res).ifThrown(null))
        {
          mediaPaths[selected] = file.getPath;
          stringList.splice(selected, 1, mediaPaths[selected .. selected + 1]);

          _daphne.library.runIndexerThread; // Re-run indexer (sets unhandledIndexerRequest if already running, to re-run it again)
        }
      });
    });

    return vbox;
  }

  string appDir;
  string filename;
  string prefsVersion;
  string[] mediaPaths;

private:
  Daphne _daphne;
}
