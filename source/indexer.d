module indexer;

import std.algorithm : map;
import std.array : assocArray;
import std.file : DirEntry, dirEntries, SpanMode;
import std.path : absolutePath;
import std.stdio : writefln, writeln;
import std.string : icmp, toLower;
import std.typecons : tuple;

import glib.error;
import gobject.global : typeName;
import gobject.types : GTypeEnum;
import gobject.value;
import gst.buffer;
import gst.date_time;
import gst.element;
import gst.element_factory;
import gst.global : parseLaunch;
import gst.pad;
import gst.pipeline;
import gst.tag_list;
import gst.types : CLOCK_TIME_NONE, ClockTime, MessageType, PadLinkReturn, State;

class Indexer
{
  immutable string[] defaultTags = [
    "album",
    "album-artist",
    "album-disc-count", // uint
    "album-disc-number", // uint
    "artist",
    "artist-sortname",
    "date", // GDate
    "datetime",
    "duration", // ulong
    "genre",
    "language-code",
    "maximum-bitrate", // uint
    "nominal-bitrate", // uint
    "replaygain-album-gain", // double
    "replaygain-album-peak", // double
    "replaygain-track-gain", // double
    "replaygain-track-peak", // double
    "title",
    "track-count", // uint
    "track-number", // uint
  ];

  immutable string[] defaultExtensions = [
    "aac",
    "aif",
    "aiff",
    "ape",
    "flac",
    "m4a",
    "mp3",
    "ogg",
    "opus",
    "wav",
    "wma",
  ];

  this()
  {
    _extFilter = defaultExtensions.dup;
    _tagFilter = defaultTags.map!(x => tuple(x, true)).assocArray;
  }

  /**
   * Recursively index a directory searching for audio files, extracting their tags, and returning a map of filenames to tags.
   * Params:
   *   path = Path to recursively index
   * Returns: Map of filename -> Value[string] tag value hash
   */
  Value[string][string] indexPath(string path)
  {
    Value[string][string] fileTags;

    foreach (DirEntry e; dirEntries(path, SpanMode.breadth))
    {
      if (e.isFile && extMatch(e.name))
      {
        writeln(e.name);
        auto fileName = absolutePath(e.name);
        fileTags[fileName] = getTags(fileName);
      }
    }

    return fileTags;
  }

  private bool extMatch(string fileName)
  { // Looping on extensions is probably fast enough vs a hash
    foreach (ext; _extFilter)
      if (fileName.length > ext.length + 1 && fileName[$ - ext.length - 1] == '.'
          && ext.icmp(fileName[$ - ext.length .. $]) == 0)
        return true;

    return false;
  }

  private Value[string] getTags(string fileName)
  {
    bool isMp3 = fileName.length > 4 && fileName[$ - 4 .. $].toLower == ".mp3";
    Value[string] tags;
    Element pipe;

    if (isMp3)
      pipe = parseLaunch("filesrc name=filesrc ! id3demux ! fakesink"); // id3demux is fastest for mp3
    else
      pipe = parseLaunch("filesrc name=filesrc ! parsebin ! fakesink"); // Fallback to decodebin for everything else

    auto fileSrc = (cast(Pipeline)pipe).getByName("filesrc");
    assert(fileSrc);
    fileSrc.setProperty("location", fileName);

    pipe.setState(State.Paused);

    while (true)
    {
      auto msg = pipe.getBus.timedPopFiltered(CLOCK_TIME_NONE, MessageType.AsyncDone | MessageType.Tag
        | MessageType.Error);

      if (msg.type == MessageType.Error) // Error?
      {
        ErrorWrap err;
        string dbg;
        msg.parseError(err, dbg);
        writeln("Tag decoding error for file '" ~ fileName ~ "': ", err.message);
        break;
      }
      else if (msg.type != MessageType.Tag) // Not a tag?  AsyncDone
        break;

      auto tagList = TagList.newEmpty;
      msg.parseTag(tagList);

      tagList.foreach_((TagList list, string tag) {
        foreach (i; 0 .. list.getTagSize(tag))
        {
          if (tag in _tagFilter)
            tags[tag] = list.getValueIndex(tag, i);
        }
      });

      if ("title" in tags) // Wait until we get basic tags (some formats, like m4a present multiple tag lists)
        break;
    }

    pipe.setState(State.Null);

    return tags;
  }

private:
  string[] _extFilter;
  bool[string] _tagFilter;
}
