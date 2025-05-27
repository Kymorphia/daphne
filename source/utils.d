module utils;

import std.format : format;

import ddbc : Connection;
import gtk.text;

void executeSql(Connection conn, string sql)
{
  auto stmt = conn.createStatement;
  scope(exit) stmt.close;

  stmt.executeUpdate(sql);
}

/**
  * Format time using the number of digits required to represent the total song time.
  * Params:
  *   timeSecs = The time in seconds
  *   durationSecs = The total duration (to pad timeSecs accordingly), 0 to not pad (default)
  * Returns: String of the form HH:MM:SS where left most quantity only uses as many digits as required and others are 0 padded, total digits used based on the song length
  */
string formatSongTime(uint timeSecs, uint durationSecs = 0)
{
  auto maxval = timeSecs;

  if (durationSecs > maxval)
    maxval = durationSecs;

  if (maxval < 10 * 60)
    return format("%u:%02u", timeSecs / 60, timeSecs % 60);
  else if (maxval < 100 * 60)
    return format("%02u:%02u", timeSecs / 60, timeSecs % 60);
  else
    return format("%u:%02u:%02u", timeSecs / 3600, (timeSecs % 3600) / 60, timeSecs % 60);
}

/**
 * Create a Text widget for use in a ColumnView which is initialized with editing disabled.
 * Params:
 *   text = The text widget
 *   val = String value to assign
 */
void initTextNotEditable(Text text, string val)
{
  text.getBuffer.text = val;
  text.editable = false;
  text.canFocus = false;
  text.canTarget = false;
  text.focusOnClick = false;
}
