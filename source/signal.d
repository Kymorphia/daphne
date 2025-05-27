module signal;

/**
 * Mixin for signals.
 * Like std.signal but supports lambdas/embedded function delegates and has disable/enable support.
 */
mixin template Signal(V...)
{
  import std.algorithm : countUntil, remove;

  alias Callback = void delegate(V);
  SignalHook*[] _signalHooks;

  /// A signal callback hook
  struct SignalHook
  {
    Callback callback; /// The hook callback
    bool disabled; /// true if the callback is disabled
    bool active; /// true when signal is currently being emitted (to block loops)
  }

  /**
   * Connect to a signal
   * Params:
   *    callback = The delegate function to call when the signal occurs
   */
  SignalHook* connect(Callback callback)
  {
    _signalHooks ~= new SignalHook(callback);
    return _signalHooks[$ - 1];
  }

  /**
   * Disconnect a signal
   * Params:
   *    hook = The hook pointer returned from connect()
   * Returns: true if a matching callback was removed, false otherwise
   */
  bool disconnect(SignalHook* hook)
  {
    auto hookIndex = _signalHooks.countUntil(hook);

    if (hookIndex != -1)
      _signalHooks = _signalHooks.remove(hookIndex);

    return hookIndex != -1;
  }

  /**
   * Disconnect all signal callbacks
   */
  void disconnectAll()
  {
    _signalHooks = [];
  }

  /**
   * Disable a signal
   * Params:
   *    hook = The hook pointer returned from connect()
   * Returns: true if a matching signal handler was disabled, false otherwise
   */
  bool disable(SignalHook* hook)
  {
    auto hookIndex = _signalHooks.countUntil(hook);

    if (hookIndex != -1)
      _signalHooks[hookIndex].disabled = true;

    return hookIndex != -1;
  }

  /**
   * Disable all signal callbacks
   */
  void disableAll()
  {
    foreach (ref h; _signalHooks)
      h.disabled = true;
  }

  /**
   * Enable a signal
   * Params:
   *    hook = The hook pointer returned from connect()
   * Returns: true if a matching signal handler was enabled, false otherwise
   */
  bool enable(SignalHook* hook)
  {
    auto hookIndex = _signalHooks.countUntil(hook);

    if (hookIndex != -1)
      _signalHooks[hookIndex].disabled = false;

    return hookIndex != -1;
  }

  /**
   * Enable all signal callbacks
   */
  void enableAll()
  {
    foreach (ref h; _signalHooks)
      h.disabled = false;
  }

  /**
   * Emit a signal
   * Params:
   *    values = The values of the signal emission
   */
  void emit(V values)
  {
    foreach (ref hook; _signalHooks)
    {
      if (!hook.disabled && !hook.active) // Block signal loops
      {
        hook.active = true;
        hook.callback(values);
        hook.active = false;
      }
    }
  }
}
