module edit_field;

import gtk.label;
import gtk.types : Align, Justification;
import pango.types : EllipsizeMode;

/// A ColumnView field widget which can be used for editing (not yet editable)
class EditField : Label
{
  enum DefaultWidthChars = 15;

  this(uint widthChars = DefaultWidthChars)
  {
    this.widthChars = widthChars;
    this.maxWidthChars = widthChars;
    xalign = 0.0;
    ellipsize = EllipsizeMode.End;
  }

  @property void content(string val)
  {
    label = val;

    if (widthChars >= DefaultWidthChars) // Don't show tooltips on fixed width fields
      tooltipText = val;
  }
}
