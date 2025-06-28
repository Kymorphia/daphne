module player;

import daphne_includes;

import gst.element;
import gst.element_factory;
import gst.pipeline;
import gst.types : Format, SeekFlags, State, SECOND, USECOND;

import daphne;
import edit_field;
import library;
import prop_iface;
import rating;
import signal;
import utils : formatSongTime;

/// Player widget
final class Player : Box, PropIface
{
  enum TimeWidthChars = 8; /// HH:MM:SS
  enum VolumeScaleWidth = 160; // Width of volume scale widget in pixels
  enum RefreshRateMsecs = 100; // Player refresh time in milliseconds

  this(Daphne daphne)
  {
    super(Orientation.Vertical, 0);
    _daphne = daphne;

    auto songGrid = new Grid;
    songGrid.columnSpacing = 10;
    songGrid.rowSpacing = 2;
    songGrid.marginStart = 4;
    songGrid.marginEnd = 4;
    songGrid.marginTop = 4;
    songGrid.marginBottom = 4;
    songGrid.hexpand = true;
    append(songGrid);

    foreach (i, txt; [tr!"Rating", tr!"Track", tr!"Title", tr!"Artist", tr!"Album", tr!"Year"])
    {
      auto lbl = new Label(txt);
      lbl.addCssClass("player-song-label");
      lbl.xalign = 0.0;
      songGrid.attach(lbl, cast(int)i, 0, 1, 1);
    }

    auto sizeGroup = new SizeGroup(SizeGroupMode.Horizontal);

    _ratingWidg = new Rating;
    _ratingWidg.marginEnd = 4;
    songGrid.attach(_ratingWidg, 0, 1, 1, 1);
    sizeGroup.addWidget(_ratingWidg);

    _trackWidg = new PlayerInfo(LibrarySong.MaxTrack.to!string.length);
    songGrid.attach(_trackWidg, 1, 1, 1, 1);

    _titleWidg = new PlayerInfo;
    songGrid.attach(_titleWidg, 2, 1, 1, 1);

    _artistWidg = new PlayerInfo;
    songGrid.attach(_artistWidg, 3, 1, 1, 1);

    _albumWidg = new PlayerInfo;
    songGrid.attach(_albumWidg, 4, 1, 1, 1);

    _yearWidg = new PlayerInfo(LibrarySong.MaxYear.to!string.length);
    songGrid.attach(_yearWidg, 5, 1, 1, 1);

    auto ctrlBox = new Box(Orientation.Horizontal, 0);
    append(ctrlBox);

    auto btnBox = new Box(Orientation.Horizontal, 0);
    ctrlBox.marginStart = 4;
    ctrlBox.marginEnd = 4;
    ctrlBox.append(btnBox);
    sizeGroup.addWidget(btnBox);

    _prevBtn = Button.newFromIconName("media-skip-backward");
    btnBox.append(_prevBtn);

    _playPauseBtn = Button.newFromIconName("media-playback-start");
    btnBox.append(_playPauseBtn);

    _stopBtn = Button.newFromIconName("media-playback-stop");
    btnBox.append(_stopBtn);

    _nextBtn = Button.newFromIconName("media-skip-forward");
    btnBox.append(_nextBtn);

    _timePlayedLabel = new Label;
    _timePlayedLabel.widthChars = TimeWidthChars;
    _timePlayedLabel.addCssClass("mono");
    ctrlBox.append(_timePlayedLabel);

    _songPosScale = new Scale(Orientation.Horizontal);
    _songPosScale.hexpand = true;
    ctrlBox.append(_songPosScale);

    _timeRemainingLabel = new Label;
    _timeRemainingLabel.widthChars = TimeWidthChars;
    _timeRemainingLabel.addCssClass("mono");
    ctrlBox.append(_timeRemainingLabel);

    _volumeScale = new Scale(Orientation.Horizontal);
    _volumeScale.widthRequest = VolumeScaleWidth;
    _volumeScale.setRange (0.0, 1.0);
    _volumeScale.setValue(_props.volume);
    _volumeScale.tooltipText = tr!"Volume";
    ctrlBox.append(_volumeScale);

    _playbin = ElementFactory.make("playbin3", "playbin");

    // GstPlayFlags which is a runtime GFlags type https://gstreamer.freedesktop.org/documentation/playback/playsink.html#GstPlayFlags
    // Just define the flags we want
    enum PlayFlags : uint
    {
      Audio = 0x02, // Audio
      SoftVolume = 0x10, // Software volume control
    }

    _playbin.setProperty("flags", PlayFlags.Audio | PlayFlags.SoftVolume);

    auto bus = _playbin.getBus;
    bus.addSignalWatch;
    bus.connectMessage("eos", () { next; });

    _ratingWidg.propChanged.connect((PropIface propObj, string propName, StdVariant val, StdVariant oldVal) {
      if (propName == "value" && _props.song)
        _props.song.rating = _ratingWidg.value;
    });

    _prevBtn.connectClicked(() { prev; });
    _stopBtn.connectClicked(() { stop; });
    _nextBtn.connectClicked(() { next; });
    _volumeScale.connectValueChanged(() { volume = _volumeScale.getValue; });

    _playPauseBtn.connectClicked(() {
      if (_state == State.Playing)
        pause;
      else
        play;
    });

    _songPosScaleHandler = _songPosScale.connectValueChanged(() {
      setPosition(cast(long)(_songPosScale.getValue * 1_000_000));
    });

    _daphne.playQueue.propChanged.connect((PropIface propObj, string propName, StdVariant val, StdVariant oldVal) {
      if (propName == "songCount" && (val.get!uint == 0) != (oldVal.get!uint == 0)) // Only update state when changing queue song count from 0 to nonzero or nonzero to 0
        updateState;
      else if (propName == "currentSong" && _state == State.Playing) // If current queue song changes while playing (deleted), stop and play
      {
        stop;
        play;
      }
    });

    timeoutAdd(PRIORITY_DEFAULT, RefreshRateMsecs, &refreshPosition);

    updateState;
    updateSong;

    _globalPropChangedHook = propChangedGlobal.connect((PropIface propObj, string propName, StdVariant val,
        StdVariant oldVal) {
      if (propObj is _props.song)
        updateSong;
    });
  }

  ~this()
  {
    propChangedGlobal.disconnect(_globalPropChangedHook);
  }

  struct PropDef
  {
    @Desc("Current playing song") @UpdateDelegate("updateSong") @(PropFlags.ReadOnly) LibrarySong song;
    @Desc("Playback status") @(PropFlags.ReadOnly) string playbackStatus = "Stopped";
    @Desc("Volume (0.0 to 1.0)") @UpdateDelegate("updateVolume") double volume = 1.0;
    @Desc("Position in microsecond") @UpdateDelegate("updatePosition") @(PropFlags.ThrowOrGc) long position;
    @Desc("Is 'Next' action valid?") @(PropFlags.ReadOnly) bool canGoNext;
    @Desc("Is 'Previous' action valid?") @(PropFlags.ReadOnly) bool canGoPrevious;
    @Desc("Is 'Play' action valid?") @(PropFlags.ReadOnly) bool canPlay;
    @Desc("Is 'Pause' action valid?") @(PropFlags.ReadOnly) bool canPause;
    @Desc("Is 'Seek' action valid?") @(PropFlags.ReadOnly) bool canSeek;
  }

  mixin(definePropIface!(PropDef, true));

  private bool refreshPosition() // Periodic position refresh callback (also called to immediately update player state)
  {
    if (_state != State.Playing && _state != State.Paused)
      return SOURCE_CONTINUE;

    if (!_durationCalculated)
    {
      long d;

      if (!_playbin.queryDuration(Format.Time, d))
        return SOURCE_CONTINUE;

      _durationUsecs = d / USECOND;
      _durationSecs = cast(double)d / SECOND + 0.5;

      signalHandlerBlock(_songPosScale, _songPosScaleHandler);
      _songPosScale.setRange(0, _durationSecs);
      signalHandlerUnblock(_songPosScale, _songPosScaleHandler);

      _durationCalculated = true;
      updateState;
    }

    long posNsecs;
    if (_playbin.queryPosition(Format.Time, posNsecs))
      position = posNsecs / USECOND;

    return SOURCE_CONTINUE;
  }

  private void updateSong() // Update song
  {
    _trackWidg.content = (_props.song && _props.song.track != 0) ? _props.song.track.to!string : "--";
    _titleWidg.content = _props.song ? _props.song.title : "-";
    _artistWidg.content = _props.song ? _props.song.artist : "-";
    _albumWidg.content = _props.song ? _props.song.album : "-";
    _yearWidg.content = (_props.song && _props.song.year != 0) ? _props.song.year.to!string : "----";
    _ratingWidg.value = _props.song ? _props.song.rating : 0;
    _ratingWidg.sensitive = _props.song !is null;
  }

  private void updateVolume() // Volume property update method
  {
    _props.volume = clamp(_props.volume, 0.0, 1.0);
    _playbin.setProperty("volume", _props.volume ^^ 3);
    _volumeScale.setValue(_props.volume);
  }

  private void updatePosition() // Position property update method
  {
    if ((_state == State.Playing || _state == State.Paused) && _durationCalculated)
    {
      auto posSecs = cast(double)_props.position / 1_000_000;

      signalHandlerBlock(_songPosScale, _songPosScaleHandler);
      _songPosScale.setValue(posSecs);
      signalHandlerUnblock(_songPosScale, _songPosScaleHandler);

      auto posIntSecs = cast(uint)(posSecs + 0.5);
      _timePlayedLabel.label = formatSongTime(posIntSecs, cast(uint)(_durationSecs + 0.5));
      _timeRemainingLabel.label = formatSongTime(posSecs <= _durationSecs
        ? cast(uint)(_durationSecs - posSecs + 0.5) : 0, cast(uint)(_durationSecs + 0.5));
    }
  }

  // Should be called after state changes which affect properties, so that listeners are notified.
  // This currently includes: _song, _state, playQueue.songCount, and _durationCalculated.
  private void updateState()
  {
    song = _song;
    playbackStatus = _state == State.Playing ? "Playing" : (_state == State.Paused ? "Paused" : "Stopped");
    canGoNext = _daphne.playQueue.songCount > 0;
    canGoPrevious = false; // TODO
    canPlay = _daphne.playQueue.songCount > 0;
    canPause = _state == State.Playing;
    canSeek = (_state == State.Playing || _state == State.Paused) && _durationCalculated;
  }

  /**
   * Seek the current song by the given number of signed microseconds.
   * Seeking past the beginning of the song, resets position to 0.
   * Seeking past the end of the song, advances to the next one.
   * Params:
   *   ofsUsecs = Offset in microseconds (negative values seek backwards)
   * Returns: true on success (may have been clamped), false if seek cannot be performed currently
   */
  bool seek(long ofsUsecs)
  {
    if (!canSeek)
      return false;

    long currentPosNsecs;
    if (!_playbin.queryPosition(Format.Time, currentPosNsecs))
      return false;

    auto newPos = (currentPosNsecs / USECOND) + ofsUsecs; // Convert current position from nanoseconds to microseconds (don't care about rounding)
    if (newPos < 0)
      newPos = 0;

    if (newPos < _durationUsecs)
      setPosition(newPos);
    else
      next;

    return true;
  }

  /**
   * Set the song position in microseconds.
   * Params:
   *   posUsecs = The song position (clamped to song duration)
   * Returns: true on success (may have been clamped), false if seek cannot be performed currently
   */
  bool setPosition(long posUsecs)
  {
    if (!canSeek)
      return false;

    posUsecs = clamp (posUsecs, 0, _durationUsecs);

    if (_state == State.Playing || _state == State.Paused)
    {
      position = posUsecs;

      _playbin.seekSimple(Format.Time, SeekFlags.Flush | SeekFlags.KeyUnit, posUsecs * USECOND);
      seeked.emit(posUsecs);
      return true;
    }

    return false;
  }

  /// Play top of queue or unpause if paused.
  void play()
  {
    if (_state == State.Playing) // Already playing?  Return
      return;

    if (_state == State.Paused) // Unpause if currently paused
    {
      _playbin.setState(State.Playing);
      _playPauseBtn.setIconName("media-playback-pause");
      _state = State.Playing;
      updateState;
      return;
    }

    _song = _daphne.playQueue.start;
    if (!_song)
    {
      updateState;
      return;
    }

    import glib.global : filenameToUri;
    _playbin.setProperty("uri", _song.filename.filenameToUri);

    _durationCalculated = false;
    _durationSecs = _song.length; // Gets updated later to be the real time calculated by GStreamer
    _songPosScale.setRange(0, _durationSecs);
    _timePlayedLabel.label = formatSongTime(0, cast(uint)_durationSecs);
    _timeRemainingLabel.label = formatSongTime(cast(uint)_durationSecs);

    _playbin.setState(State.Playing);
    _playPauseBtn.setIconName("media-playback-pause");
    _state = State.Playing;

    updateState;
  }

  void pause()
  {
    if (_state == State.Playing)
    {
      _playbin.setState(State.Paused);
      _playPauseBtn.setIconName("media-playback-start");
      _state = State.Paused;
      updateState;
    }
  }

  /// Toggle playback (pause if playing, play if paused/stopped)
  void togglePlay()
  {
    if (_state == State.Playing)
      pause;
    else
      play;
  }

  /// Stop playing
  void stop()
  {
    if (_state <= State.Ready)
      return;

    _playbin.setState(State.Ready);
    _playbin.setProperty("uri", "");
    _state = State.Ready;

    _playPauseBtn.setIconName("media-playback-start");
    _timePlayedLabel.label = "";
    _timeRemainingLabel.label = "";

    signalHandlerBlock(_songPosScale, _songPosScaleHandler);
    _songPosScale.setRange(0, 0);
    _songPosScale.setValue(0);
    signalHandlerUnblock(_songPosScale, _songPosScaleHandler);

    _daphne.playQueue.stop;
    updateState;
  }

  /// Next track
  void next()
  {
    stop;
    _daphne.playQueue.next;
    play;
  }

  /// Previous track
  void prev()
  {
    stop;
    _daphne.playQueue.prev;
    play;
  }

  mixin Signal!(long) seeked;

private:
  Daphne _daphne;
  LibrarySong _song;
  propChangedGlobal.SignalHook* _globalPropChangedHook; // Global property change signal hook

  PlayerInfo _trackWidg;
  PlayerInfo _titleWidg;
  PlayerInfo _artistWidg;
  PlayerInfo _albumWidg;
  PlayerInfo _yearWidg;
  Rating _ratingWidg;

  Button _prevBtn;
  Button _playPauseBtn;
  Button _stopBtn;
  Button _nextBtn;
  Scale _songPosScale;
  ulong _songPosScaleHandler;
  Label _timePlayedLabel;
  Label _timeRemainingLabel;
  Scale _volumeScale;
  Element _playbin;
  State _state;
  bool _durationCalculated;
  double _durationSecs;
  long _durationUsecs;
}

/// Player song information label widget
class PlayerInfo : Label
{
  this(long width = 0)
  {
    xalign = 0.0;
    addCssClass("player-song-info");

    if (widthChars > 0)
    {
      widthChars = cast(uint)width;
      maxWidthChars = cast(uint)width;
    }
    else
    {
      hexpand = true;
      ellipsize = EllipsizeMode.End;
    }
  }

  @property void content(string val)
  {
    label = val;

    if (hexpand)
      tooltipText = val;
  }
}
