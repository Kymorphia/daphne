module indexer;

import std.file : DirEntry, dirEntries, SpanMode;
import std.stdio : writefln, writeln;

import glib.error;
import gobject.global : typeName;
import gobject.types : GTypeEnum;
import gst.buffer;
import gst.date_time;
import gst.element_factory;
import gst.global : filenameToUri;
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

  void indexPath(string path)
  {
    foreach (DirEntry e; dirEntries(path, SpanMode.breadth))
    {
      if (e.isFile)
        getTags(e.name);
    }
  }

  private void getTags(string fileName)
  {
    auto uri = filenameToUri(fileName);
    auto pipe = new Pipeline("pipeline");
    auto dec = ElementFactory.make("uridecodebin");
    dec.setProperty("uri", uri);
    pipe.add(dec);

    auto sink = ElementFactory.make("fakesink");
    pipe.add(sink);

    dec.connectPadAdded((Pad pad) {
      auto sinkPad = sink.getStaticPad("sink");
      if (!sinkPad.isLinked && pad.link(sinkPad) != PadLinkReturn.Ok)
        throw new Exception("Failed to link pads!");
    });

    pipe.setState(State.Paused);

    while (true)
    {
      auto msg = pipe.getBus.timedPopFiltered(CLOCK_TIME_NONE, MessageType.AsyncDone | MessageType.Tag | MessageType.Error);
  
      if (msg.type != MessageType.Tag) // error or async_done
      {
        if (msg.type == MessageType.Error)
        {
          auto err = new ErrorWrap();
          string dbg;
          msg.parseError(err, dbg);
          writeln("Got error: ", err.message);
        }

        break;
      }

      auto tagList = TagList.newEmpty;
      msg.parseTag(tagList);

      writeln("Got tags from file '", fileName, "' element: ", msg.src.name);

      tagList.foreach_((TagList list, string tag) {
        foreach (i; 0 .. list.getTagSize(tag))
        {
          auto val = list.getValueIndex(tag, i);

          if (val.gType == GTypeEnum.String)
            writefln("\t%20s : %s", tag, val.get!string);
          else if (val.gType == GTypeEnum.Uint)
            writefln("\t%20s : %u", tag, val.get!uint);
          else if (val.gType == GTypeEnum.Double)
            writefln("\t%20s : %f", tag, val.get!double);
          else if (val.gType == GTypeEnum.Boolean)
            writefln("\t%20s : %s", tag, val.get!bool);
          else if (val.gType == Buffer._getGType)
            writefln("\t%20s : buffer of size %u", tag, val.get!Buffer.getSize);
          else if (val.gType == DateTime._getGType)
            writefln("\t%20s : %s", tag, val.get!DateTime.toIso8601String);
          else
            writefln("\t%20s : tag of type '%s'", tag, val.gType.typeName);
        }
      });

      writeln;
    }

    pipe.setState(State.Null);
  }
}
