module player;

import std.format : format;
import std.algorithm : clamp;

import gettext;
import glib.global : timeoutAdd;
import glib.types : PRIORITY_DEFAULT, SOURCE_CONTINUE;
import gobject.global : signalHandlerBlock, signalHandlerUnblock;
import gst.element;
import gst.element_factory;
import gst.pipeline;
import gst.types : Format, SeekFlags, State, SECOND, USECOND;
import gtk.box;
import gtk.button;
import gtk.label;
import gtk.scale;
import gtk.types : Orientation;

import daphne;
import library;
import prop_iface;
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
    super(Orientation.Horizontal, 0);
    _daphne = daphne;

    _prevBtn = Button.newFromIconName("media-skip-backward");
    append(_prevBtn);

    _playPauseBtn = Button.newFromIconName("media-playback-start");
    append(_playPauseBtn);

    _stopBtn = Button.newFromIconName("media-playback-stop");
    append(_stopBtn);

    _nextBtn = Button.newFromIconName("media-skip-forward");
    append(_nextBtn);

    _timePlayedLabel = new Label;
    _timePlayedLabel.widthChars = TimeWidthChars;
    _timePlayedLabel.addCssClass("mono-class");
    append(_timePlayedLabel);

    _songPosScale = new Scale(Orientation.Horizontal);
    _songPosScale.hexpand = true;
    append(_songPosScale);

    _timeRemainingLabel = new Label;
    _timeRemainingLabel.widthChars = TimeWidthChars;
    _timeRemainingLabel.addCssClass("mono-class");
    append(_timeRemainingLabel);

    _volumeScale = new Scale(Orientation.Horizontal);
    _volumeScale.widthRequest = VolumeScaleWidth;
    _volumeScale.setRange (0.0, 1.0);
    _volumeScale.setValue(_props.volume);
    _volumeScale.tooltipText = tr!"Volume";
    append(_volumeScale);

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

    timeoutAdd(PRIORITY_DEFAULT, RefreshRateMsecs, &refreshPosition);

    updateState;
  }

  struct PropDef
  {
    @Desc("Current playing song") @(PropFlags.ReadOnly) LibrarySong song;
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

  private void updateVolume() // Volume property update method
  {
    _props.volume = clamp(_props.volume, 0.0, 1.0);
    _playbin.setProperty("volume", _props.volume);
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
    canPlay = _state != State.Playing && _daphne.playQueue.songCount > 0;
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
