module rating;

import daphne_includes;

import prop_iface;

class Rating : DrawingArea, PropIface
{
  enum BarCount = 11;
  enum BarWidth = 4;
  enum BarSpacing = 4;

  this()
  {
    setDrawFunc(&drawFunc);
    setSizeRequest(BarCount * BarWidth + ((BarCount - 1) * BarSpacing), -1);
    setCanFocus(true);
    setFocusable(true);

    auto gestureClick = new GestureClick;
    gestureClick.setButton(0);
    gestureClick.connectPressed(&onPressed);
    gestureClick.connectReleased(&onReleased);
    addController(gestureClick);

    auto motionController = new EventControllerMotion;
    motionController.connectMotion(&onMotion);
    addController(motionController);

    auto keyboardController = new EventControllerKey();
    keyboardController.connectKeyPressed(&onKeyPressed);
    addController(keyboardController);
  }

  struct PropDef
  {
    @Desc("Rating value") @RangeValue("0", "BarCount") @UpdateDelegate("updateValue") ubyte value;
  }

  mixin(definePropIface!(PropDef, true));

  private void updateValue()
  {
    _props.value = clamp(_props.value, cast(ubyte)0, cast(ubyte)BarCount);
    queueDraw;
  }

  private void drawFunc(DrawingArea da, Context cr, int width, int height)
  {
    _width = width;
    _height = height;

    auto val = _pressActive ? _valueActive : _props.value;

    if (val > 0)
    {
      foreach (i; 0 .. val)
        cr.rectangle(i * (BarWidth + BarSpacing), 0.0, BarWidth, height);

      auto pat = patternCreateLinear(0.0, 0.0, width, 0.0);
      pat.addColorStopRgb(0.0, 0.0, 0.0, 1.0); // Blue
      pat.addColorStopRgb(0.25, 0.0, 1.0, 0.0); // Green
      pat.addColorStopRgb(0.5, 1.0, 1.0, 0.0); // Yellow
      pat.addColorStopRgb(1.0, 1.0, 0.0, 0.0); // Red
      cr.setSource(pat);
      cr.fill;
    }

    if (val < 11)
    {
      foreach (i; val .. 11)
        cr.rectangle(i * (BarWidth + BarSpacing), 0.0, BarWidth, height);

      cr.setSourceRgb(0.5, 0.5, 0.5);
      cr.setLineWidth(1.0);
      cr.stroke;
    }
  }

  private void onPressed(int nPress, double x, double y, GestureClick gestureClick)
  {
    if (gestureClick.getCurrentButton == 1)
    {
      _pressActive = true;
      _valueActive = _props.value;
    }
  }

  private void onReleased(int nPress, double x, double y, GestureClick gestureClick)
  {
    if (gestureClick.getCurrentButton == 1)
    {
      _pressActive = false;
      value = _valueActive;
    }
  }

  private void onMotion(double x)
  {
    if (_pressActive)
    {
      _valueActive = cast(ubyte)clamp(x / (BarWidth + BarSpacing) + 1, 0, BarCount);
      queueDraw;
    }
  }

  private bool onKeyPressed(uint keyval)
  {
    if (keyval == KEY_Escape)
    {
      _pressActive = false;
      queueDraw;
      return true;
    }

    int newVal = _props.value;

    if (keyval == KEY_Right)
      newVal++;
    else if (keyval == KEY_Left)
      newVal--;
    else
      return false;

    newVal = clamp(newVal, 0, BarCount);

    if (newVal != _props.value)
      value = cast(ubyte)newVal;

    return true;
  }

private:
  int _width; // Cached width of drawing area
  int _height; // Cached height of drawing area
  bool _pressActive; // True if a mouse press is active
  ubyte _valueActive; // Current active value from press (value is set on release)
}