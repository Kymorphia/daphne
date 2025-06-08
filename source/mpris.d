module mpris;

import daphne_includes;

import daphne;
import library_song;
import prop_iface;

/// Class for handling Media Player Remote Interfacing Specification DBus interface
class Mpris
{
  enum string MprisXml = import("mpris.xml");
  enum BusNamePrefix = "org.mpris.MediaPlayer2";
  enum ObjectName = "/org/mpris/MediaPlayer2";

  enum RootInterface = "org.mpris.MediaPlayer2";
  enum PlayerInterface = "org.mpris.MediaPlayer2.Player";
  enum TracklistInterface = "org.mpris.MediaPlayer2.TrackList";
  enum PlaylistsInterface = "org.mpris.MediaPlayer2.Playlists";

  enum PlayerTrackPrefix = "/com/kymorphia/Daphne/Track/"; /// Prefix used for mpris:trackid metadata field
  enum PlayerTrackNone = "/org/mpris/MediaPlayer2/Track/NoTrack"; /// Value for mpris:trackid metadata field used to indicate no track is active

  /// Supported mime types
  immutable string[] SupportedMimeTypes = [
    "audio/aac", "audio/flac", "audio/mp4", "audio/ogg", "audio/opus", "audio/wav", "audio/x-aiff",
    "audio/x-ape", "audio/x-ms-wma",
  ];

  this(Daphne daphne)
  {
    _daphne = daphne;
  }

  /**
   * Connect to the MPRIS DBus interface for media controls.
   * Throws: DBusException on error
   */
  void connect()
  {
    if (_conn)
      return;

    _conn = busGetSync(BusType.Session);
    auto nodeInfo = DBusNodeInfo.newForXml(MprisXml);

    auto ifaceInfo = nodeInfo.lookupInterface(RootInterface);
    auto rootId = _conn.registerObject(ObjectName, ifaceInfo, new DClosure(&rootMethodCall),
      new DClosure(&rootGetProperty), null);

    ifaceInfo = nodeInfo.lookupInterface(PlayerInterface);
    auto playerId = _conn.registerObject(ObjectName, ifaceInfo, new DClosure(&playerMethodCall),
      new DClosure(&playerGetProperty), new DClosure(&playerSetProperty));

    // ifaceInfo = nodeInfo.lookupInterface(PlaylistsInterface);
    // auto playlistsId = _conn.registerObject(ObjectName, ifaceInfo, methodCallClosure,
      // getPropertyClosure, setPropertyClosure);

    auto nameOwnId = busOwnName(BusType.Session, BusNamePrefix ~ ".daphne", BusNameOwnerFlags.None, null,
      new DClosure((DBusConnection conn, string name) { info("Acquired DBus " ~ name); }),
      new DClosure((DBusConnection conn, string name) { info("Lost DBus " ~ name); }));

    _daphne.player.propChanged.connect((PropIface ifaceObj, string propName, StdVariant val, StdVariant oldVal) {
      _changedPlayerProps[propName] = true;
      if (!_changedPlayerPropsHandler) // Handle property update on idle, to batch additional changes
        _changedPlayerPropsHandler = idleAdd(PRIORITY_DEFAULT_IDLE, &signalEmitIdleCallback);
    });

    _daphne.player.seeked.connect((long posUsecs) {
      _seekedPosition = posUsecs;
      if (!_changedPlayerPropsHandler) // Handle property update on idle, to batch additional changes
        _changedPlayerPropsHandler = idleAdd(PRIORITY_DEFAULT_IDLE, &signalEmitIdleCallback);
    });
  }

  private bool signalEmitIdleCallback() // Idle callback which sends DBus property update signal
  {
    if (_changedPlayerProps.length > 0)
      emitPlayerPropsChangedSignal;

    if (_seekedPosition != SeekedPositionNone)
    {
      trace("MPRIS Seeked signal: " ~ _seekedPosition.to!string);

      try
        _conn.emitSignal(null, ObjectName, PlayerInterface, "Seeked", GLibVariant.newTuple(_seekedPosition));
      catch (Exception e)
        warning("Failed to signal player DBus seek: " ~ e.msg);

      _seekedPosition = SeekedPositionNone;
    }

    _changedPlayerPropsHandler = 0;
    return SOURCE_REMOVE;
  }

  private void emitPlayerPropsChangedSignal()
  {
    GLibVariant[string] props;

    foreach (propName; _changedPlayerProps.byKey)
    {
      GLibVariant val;

      switch (propName)
      {
        case "song": propName = "Metadata"; val = getSongMetadata(_daphne.player.song); break;
        case "playbackStatus": val = new GLibVariant(_daphne.player.playbackStatus); break;
        case "volume": val = new GLibVariant(_daphne.player.volume); break;
        case "canGoNext": val = new GLibVariant(_daphne.player.canGoNext); break;
        case "canGoPrevious": val = new GLibVariant(_daphne.player.canGoPrevious); break;
        case "canPlay": val = new GLibVariant(_daphne.player.canPlay); break;
        case "canPause": val = new GLibVariant(_daphne.player.canPause); break;
        case "canSeek": val = new GLibVariant(_daphne.player.canSeek); break;
        default: break;
      }

      if (val)
      {
        auto uPropName = propName[0 .. 1].toUpper ~ propName[1 .. $]; // Uppercase first letter
        props[uPropName] = val;
      }
    }

    if (props.length > 0)
    {
      string[] invalidated;
      auto params = new GLibVariant(PlayerInterface, props, invalidated); // sa{sv}as

      trace("MPRIS PropertiesChanged signal: " ~ props.to!string);

      try
        _conn.emitSignal(null, ObjectName, "org.freedesktop.DBus.Properties", "PropertiesChanged", params);
      catch (Exception e)
        warning("Failed to signal player DBus property changes: " ~ e.msg);
    }

    _changedPlayerProps.clear;
  }

  private void rootMethodCall(DBusConnection conn, string sender, string objectPath, string interfaceName,
    string methodName, GLibVariant params, DBusMethodInvocation invoc)
  {
    trace("MPRIS root method call: " ~ objectPath ~ " " ~ interfaceName ~ " " ~ methodName ~ " " ~ params.to!string);

    if (objectPath == ObjectName && interfaceName == RootInterface)
    {
      switch (methodName)
      {
        case "Raise": _daphne.mainWindow.present; break;
        case "Quit": _daphne.quit; break;
        default: goto err;
      }

      invoc.returnValue(null);
      return;
    }

  err:
    invoc.returnGerror(new DBusException(DBusError.Enum.NotSupported,
      "Method " ~ interfaceName ~ "." ~ methodName ~ " not supported"));
  }

  private GLibVariant rootGetProperty(DBusConnection conn, string sender, string objectPath, string interfaceName,
    string propertyName)
  {
    GLibVariant ret;

    if (objectPath == ObjectName && interfaceName == RootInterface)
    {
      switch (propertyName)
      {
        case "CanQuit": ret = new GLibVariant(true); break;
        case "CanRaise": ret = new GLibVariant(true); break;
        case "HasTrackList": ret = new GLibVariant(false); break;
        case "Identity": ret = new GLibVariant("Daphne"); break;
        case "DesktopEntry": break;
        case "SupportedUriSchemes": ret = new GLibVariant(["file"]); break;
        case "SupportedMimeTypes": ret = new GLibVariant(SupportedMimeTypes); break;
        default: break;
      }
    }

    trace("MPRIS root get property: " ~ objectPath ~ " " ~ interfaceName ~ " " ~ propertyName ~ " " ~ ret.to!string);

    return ret;
  }

  private void playerMethodCall(DBusConnection conn, string sender, string objectPath, string interfaceName,
    string methodName, GLibVariant params, DBusMethodInvocation invoc)
  {
    trace("MPRIS player method call: " ~ objectPath ~ " " ~ interfaceName ~ " " ~ methodName ~ " " ~ params.to!string);

    if (objectPath == ObjectName && interfaceName == PlayerInterface)
    {
      switch (methodName)
      {
        case "Next": _daphne.player.next; break;
        case "OpenUri": writeln("TODO: OpenUri"); break;
        case "Pause": _daphne.player.pause; break;
        case "Play": _daphne.player.play; break;
        case "PlayPause": _daphne.player.togglePlay; break;
        case "Previous": _daphne.player.prev; break;
        case "Seek": _daphne.player.seek(params.getItems!(long)[0]); break;
        case "SetPosition":
          if (!_daphne.player.song)
            break;

          auto vals = params.get!(string, long); // trackid, time_in_us

          if (vals[0].startsWith(PlayerTrackPrefix))
          {
            import std.string : chompPrefix;
            import std.exception : ifThrown;
            auto songId = vals[0].chompPrefix(PlayerTrackPrefix).to!long.ifThrown(cast(long)0);

            if (songId == _daphne.player.song.id) // Only seek if song ID matches current one
              _daphne.player.position = vals[1];
          }

          break;
        case "Stop": _daphne.player.stop; break;
        default: goto err;
      }

      invoc.returnValue(null);
      return;
    }

  err:
    invoc.returnGerror(new DBusException(DBusError.Enum.NotSupported,
      "Method " ~ interfaceName ~ "." ~ methodName ~ " not supported"));
  }

  private GLibVariant playerGetProperty(DBusConnection conn, string sender, string objectPath, string interfaceName,
    string propertyName)
  {
    GLibVariant ret;

    if (objectPath == ObjectName && interfaceName == PlayerInterface)
    {
      switch (propertyName)
      {
        case "PlaybackStatus": ret = new GLibVariant(_daphne.player.playbackStatus); break;
        case "LoopStatus": ret = new GLibVariant("None"); break;
        case "Rate": ret = new GLibVariant(1.0); break;
        case "Shuffle": ret = new GLibVariant(false); break;
        case "Metadata": ret = getSongMetadata(_daphne.player.song); break;
        case "Volume": ret = new GLibVariant(_daphne.player.volume); break;
        case "Position": ret = new GLibVariant(_daphne.player.position); break; // Position in usecs
        case "MinimumRate": ret = new GLibVariant(1.0); break;
        case "MaximumRate": ret = new GLibVariant(1.0); break;
        case "CanGoNext": ret = new GLibVariant(_daphne.player.canGoNext); break;
        case "CanGoPrevious": ret = new GLibVariant(_daphne.player.canGoPrevious); break;
        case "CanPlay": ret = new GLibVariant(_daphne.player.canPlay); break;
        case "CanPause": ret = new GLibVariant(_daphne.player.canPause); break;
        case "CanSeek": ret = new GLibVariant(_daphne.player.canSeek); break;
        case "CanControl": ret = new GLibVariant(true); break; // Indicates that the other controls can be used
        default: break;
      }
    }

    trace("MPRIS player get property: " ~ objectPath ~ " " ~ interfaceName ~ " " ~ propertyName ~ " " ~ ret.to!string);

    return ret;
  }

  private bool playerSetProperty(DBusConnection conn, string sender, string objectPath, string interfaceName,
    string propertyName, GLibVariant val)
  {
    trace("MPRIS player set property: " ~ objectPath ~ " " ~ interfaceName ~ " " ~ propertyName ~ " " ~ val.to!string);

    if (objectPath == ObjectName && interfaceName == PlayerInterface)
    {
      switch (propertyName)
      {
        case "LoopStatus": return false;
        case "Rate": return false;
        case "Shuffle": return false;
        case "Volume": _daphne.player.volume = val.get!double; return true;
        default: break;
      }
    }

    return false;
  }

  // Get MPRIS metadata dictionary for a song (returns an empty dictionary if song is null)
  private GLibVariant getSongMetadata(LibrarySong song)
  {
    GLibVariant[string] data;

    if (song)
    {
      data["mpris:trackid"] = new GLibVariant(PlayerTrackPrefix ~ song.id.to!string);

      import glib.global : filenameToUri;
      data["xesam:url"] = new GLibVariant(song.filename.filenameToUri);

      if (song.length > 0)
        data["mpris:length"] = new GLibVariant(cast(long)(song.length * 1_000_000)); // Length in microseconds
      if (song.album.length > 0)
        data["xesam:album"] = new GLibVariant(song.album);
      if (song.artist.length > 0)
        data["xesam:artist"] = new GLibVariant([song.artist]); // List of strings
      if (song.disc > 0)
        data["xesam:discNumber"] = new GLibVariant(cast(int)song.disc);
      if (song.genre.length > 0)
        data["xesam:genre"] = new GLibVariant([song.genre]); // List of strings
      if (song.title.length > 0)
        data["xesam:title"] = new GLibVariant(song.title);
      if (song.track > 0)
        data["xesam:trackNumber"] = new GLibVariant(cast(int)song.track);
      if (song.rating > 0)
        data["xesam:userRating"] = new GLibVariant(cast(double)(song.rating - 1) / 10.0); // Convert 1-11 to 0.0-1.0
    }
    else
      data["mpris:trackid"] = new GLibVariant(PlayerTrackNone);

    return new GLibVariant(data);
  }

  enum SeekedPositionNone = -1;

private:
  Daphne _daphne;
  DBusConnection _conn;
  bool[string] _changedPlayerProps; // Map of changed player props, keys are property names, values are dummy bools
  uint _changedPlayerPropsHandler; // Idle handler for sending property change signal
  long _seekedPosition = SeekedPositionNone; // Last seek position to signal update on or SeekedPositionNone
}
