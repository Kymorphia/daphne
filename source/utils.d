module utils;

import daphne_includes;

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
 * Get number ranges for selected items in a SelectionModel.
 * Params:
 *   selModel = The selection model
 * Returns: An array of arrays with 2 uint values for the start and end (inclusive) values of the range
 */
uint[2][] getSelectionRanges(SelectionModel selModel)
{
  uint[2][] ranges;
  BitsetIter iter;
  uint position;

  if (BitsetIter.initFirst(iter, selModel.getSelection, position)) // Construct ranges of items to remove
  {
    uint[2] curRange = [position, position];

    while (iter.next(position))
    {
      if (position != curRange[1] + 1)
      {
        ranges ~= curRange;
        curRange = [position, position];
      }
      else
        curRange[1] = position;
    }

    ranges ~= curRange; // Add last range
  }

  return ranges;
}
