module player;

import std.format : format;

import glib.global : timeoutAddSeconds;
import glib.types : PRIORITY_DEFAULT, SOURCE_CONTINUE;
import gobject.global : signalHandlerBlock, signalHandlerUnblock;
import gst.element;
import gst.element_factory;
import gst.pipeline;
import gst.types : Format, SeekFlags, State, SECOND;
import gtk.box;
import gtk.button;
import gtk.label;
import gtk.scale;
import gtk.types : Orientation;

import daphne;
import library;
import utils : formatSongTime;

/// Player widget
class Player : Box
{
  enum TimeWidthChars = 8; /// HH:MM:SS

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

    _playbin = ElementFactory.make("playbin", "playbin");

    auto bus = _playbin.getBus;
    bus.addSignalWatch;
    bus.connectMessage("eos", () {
      next;
    });

    _prevBtn.connectClicked(() {
      prev;
    });

    _playPauseBtn.connectClicked(() {
      if (_state == State.Playing)
        pause;
      else
        play;
    });

    _stopBtn.connectClicked(() {
      stop;
    });

    _nextBtn.connectClicked(() {
      next;
    });

    _songPosScaleHandler = _songPosScale.connectValueChanged(() {
      if (_state >= State.Paused)
        _playbin.seekSimple(Format.Time, SeekFlags.Flush | SeekFlags.KeyUnit, cast(long)(_songPosScale.getValue * SECOND));
    });

    timeoutAddSeconds(PRIORITY_DEFAULT, 1, &refreshPosition);
  }

  @property LibrarySong song()
  {
    return _song;
  }

  private bool refreshPosition() // Periodic position refresh callback (also called to immediately update player state)
  {
    if (_state < State.Paused)
      return SOURCE_CONTINUE;

    if (!_durationCalculated)
    {
      long d;

      if (!_playbin.queryDuration(Format.Time, d))
        return SOURCE_CONTINUE;

      auto duration = cast(double)d / SECOND + 0.5;
      _durationSecs = cast(uint)(duration + 0.5);

      signalHandlerBlock(_songPosScale, _songPosScaleHandler);
      _songPosScale.setRange (0, duration);
      signalHandlerUnblock(_songPosScale, _songPosScaleHandler);
    }

    long currentPos;

    if (_playbin.queryPosition(Format.Time, currentPos))
    {
      auto currentPosSecs = cast(double)currentPos / SECOND;

      signalHandlerBlock(_songPosScale, _songPosScaleHandler);
      _songPosScale.setValue(currentPosSecs);
      signalHandlerUnblock(_songPosScale, _songPosScaleHandler);

      auto currentPosSecsInt = cast(uint)(currentPosSecs + 0.5);
      _timePlayedLabel.label = formatSongTime(currentPosSecsInt, _durationSecs);
      _timeRemainingLabel.label = formatSongTime(currentPosSecsInt <= _durationSecs
        ? _durationSecs - currentPosSecsInt : 0, _durationSecs);
    }

    return SOURCE_CONTINUE;
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
      return;
    }

    _song = _daphne.playQueue.start;
    if (!_song)
      return;

    import glib.global : filenameToUri;
    _playbin.setProperty("uri", _song.filename.filenameToUri);

    _durationCalculated = false;
    _durationSecs = _song.length; // Gets updated later to be the real time calculated by GStreamer
    _songPosScale.setRange(0, _durationSecs);
    _timePlayedLabel.label = formatSongTime(0, _durationSecs);
    _timeRemainingLabel.label = formatSongTime(_durationSecs);

    _playbin.setState(State.Playing);
    _playPauseBtn.setIconName("media-playback-pause");
    _state = State.Playing;
  }

  void pause()
  {
    if (_state == State.Playing)
    {
      _playbin.setState(State.Paused);
      _playPauseBtn.setIconName("media-playback-start");
      _state = State.Paused;
    }
  }

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
  }

  void next()
  {
    stop;
    _daphne.playQueue.next;
    play;
  }

  void prev()
  {
    stop;
    _daphne.playQueue.prev;
    play;
  }

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
  Element _playbin;
  State _state;
  bool _durationCalculated;
  uint _durationSecs;
}
