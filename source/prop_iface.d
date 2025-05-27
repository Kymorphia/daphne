module prop_iface;

/**
 * Property interface subsystem.
 *
 * Usage:
 *   Add PropIface to the list of class implementations.
 *   Define a structure with the types and names of the desired properties.
 *   Default values define default property values.
 *   Optionally add UDAs to the fields to describe additional property parameters (flags, description, valid range, get/set statements,
 *     read/write delegates, update delegate, etc).
 *
 * Features:
 * Properties can be accessed as property members of the object.
 * Generates property change signals when a property changes value, globally as well as per object.
 * Property values can also be accessed directly by the class as _props.PropName to bypass signal generation.
 * Supports JSON decoding/encoding for loading/storing object state from/to JSON.
 * Supports object duplication using properties.
 */
public import std.algorithm : countUntil;
import std.conv : to;
import std.exception : enforce;
import std.format : format;
public import std.json : JSONValue;
import std.range : retro;
import std.traits : isAggregateType, isArray, isAssociativeArray, isFloatingPoint, isNumeric, isSigned, isUnsigned;
public import std.variant : Variant, VariantException;

public import signal;

/// Global property changed signal
mixin Signal!(PropIface, string, Variant, Variant) propChangedGlobal;

// These attributes are for fields in a PropDef structure
struct Lbl { string label; } /// Attribute used for property labels
struct Desc { string description; } /// Attribute used for property descriptions
struct RangeValue { string minVal, maxVal; } /// Attribute structure for storing default, min and max values
struct GetValue { string statement; } /// Attribute structure for defining a custom get value property statement (result should be in the type of the property)
struct SetValue { string statement; } /// Attribute structure for defining a custom set value property statement ('value' contains the value in the type of the property)
struct ArrayLimits { uint minSize, maxSize; } /// Attribute for minimum array size and max array size (0 for unlimited)

/**
 * Attribute used for assigning a read delegate to a property
 * Delegate type: void delegate()
 */
struct ReadDelegate { string dlg; }

/**
 * Attribute used for assigning a write delegate to a property
 * Delegate type: void delegate(T oldValue)
 */
struct WriteDelegate { string dlg; }

/**
 * Attribute used for assigning an update delegate to a property
 * Delegate type: void delegate()
 */
struct UpdateDelegate { string dlg; }

/** 
 * Attribute structure for defining a custom JSON encoder for a property
 * Delegate type: void delegate(ref JSONValue js, JsonEncoderConfig encoderConfig)
 */
struct JsonEncodeDelegate { string dlg; }

/** 
 * Attribute structure for defining a custom JSON encoder for a property
 * Delegate type: void delegate(const ref JSONValue js, JsonDecoderConfig decoderConfig)
 */
struct JsonDecodeDelegate { string dlg; } /// Attribute structure for defining a custom JSON decoder for a property

/// Property interface
interface PropIface
{
  /**
   * Get property information.
   * Returns: Map of property names to PropInfo
   */
  PropInfo[] getPropInfoArray();

  /**
   * Get information for a property by name.
   * Params:
   *   name = Name of property
   * Returns: Property information or null if not found
   */
  final const(PropInfo)* getPropInfo(string name)
  {
    foreach (ref info; getPropInfoArray)
      if (info.name == name)
        return cast(const)&info;

    return null;
  }

  /**
   * Get property value.
   * Params:
   *   name = Property name
   * Returns: Property value as a Variant
   * Throws: Exception if property not found.
   */
  Variant getProp(string name);

  /**
   * Set property value.
   * Params:
   *   name = Property name
   *   value = Value to assign
   * Throws: Exception if property not found or value type is incompatible.
   */
  void setProp(string name, Variant value);

  /**
   * Template to get a property and convert to a particular type. Supports nested properties with property names separated by periods.
   * Params:
   *   name = Name of property
   * Returns: The property value converted to type
   * Throws: Exception if property not found or value type is incompatible.
   */
  T getPropVal(T)(string name)
  {
    return getProp(name).get!T;
  }

  /**
   * Template to set property value using a specific value type.
   * Params:
   *   name = Property name
   *   value = Value to assign
   * Throws: Exception if property not found or value type is incompatible.
   */
  void setPropVal(T)(string name, T value)
  {
    setProp(name, Variant(value));
  }

  /**
   * Get property value as a JSONValue.
   * Params:
   *   name = Property name
   *   js = JSONValue to store the property value to
   *   encoderConfig = Encoder configuration object (can be null which will result in errors if there are any item references)
   */
  void getPropJson(string name, ref JSONValue js, JsonEncoderConfig encoderConfig);

  /**
   * Set property value from a JSONValue.
   * Params:
   *   name = Property name
   *   js = JSONValue to store the property value to
   *   decoderConfig = Decoder configuration object (can be null which will result in errors if there are any item references)
   */
  void setPropJson(string name, const ref JSONValue js, JsonDecoderConfig decoderConfig);

  /**
   * Load object state from a JSON object.
   * Params:
   *   js = JSON object to load object state from
   *   decoderConfig = Decoder configuration object (can be null which will result in errors if there are any item references)
   */
  void jsonLoad(const ref JSONValue js, JsonDecoderConfig decoderConfig);

  /**
   * Default handler for jsonLoad().
   * Params:
   *   js = JSON object to load object state from
   *   decoderConfig = Decoder configuration object (can be null which will result in errors if there are any item references)
   */
  final void doJsonLoad(const ref JSONValue js, JsonDecoderConfig decoderConfig)
  {
    foreach (info; getPropInfoArray)
      if (info.isJsonProp) // FIXME - Should a warning be logged or an exception thrown if a non-saveable property is encountered?
        if (auto propJs = info.name in js.object)
          setPropJson(info.name, *propJs, decoderConfig);
  }

  /**
   * Save object state to a JSON object.
   * Params:
   *   js = JSON object to save object state to
   *   encoderConfig = Encoder configuration object (can be null which will result in errors if there are any item references)
   */
  void jsonSave(ref JSONValue js, JsonEncoderConfig encoderConfig);

  /**
   * Default method to save object state to a JSON object.
   * Params:
   *   js = JSON object to save object state to
   *   encoderConfig = Encoder configuration object (can be null which will result in errors if there are any item references)
   */
  final void doJsonSave(ref JSONValue js, JsonEncoderConfig encoderConfig)
  {
    js["type"] = className((cast(Object)this));

    foreach (info; getPropInfoArray)
    {
      if (info.isJsonProp)
      {
        JSONValue propJs;
        getPropJson(info.name, propJs, encoderConfig);

        if (!propJs.isNull) // A null_ JSONValue is used to not set a value (default values for example)
          js[info.name] = propJs;
      }
    }
  }

  /**
   * Method for cloning a PropIface object.
   * Params:
   *   other = The other PropIface object to clone this instance of (must be the same object type)
   */
  void clone(PropIface other);

  /**
   * A default implementation of the clone method which clones an object by copying it's property values.
   * Params:
   *   other = The other PropIface object to clone to this instance.
   */
  final void doClone(PropIface other)
  {
    foreach (info; getPropInfoArray)
    {
      if ((info.flags & (PropFlags.ReadOnly | PropFlags.JsonOnly)) == 0)
        setProp(info.name, other.getProp(info.name));
      else if ((info.flags & (PropFlags.Inline | PropFlags.JsonOnly)) == PropFlags.Inline) // Inline objects use existing instance if it is set
        if (auto srcObj = cast(PropIface)other.getProp(info.name).coerce!Object)
          if (auto destObj = cast(PropIface)getProp(info.name).coerce!Object)
            destObj.clone(srcObj);
    }
  }
}

/**
 * Duplicate an item
 * Returns: New duplicate item
 */
T duplicate(T)(T obj)
{
  auto newObj = cast(T)cast(PropIface)typeid(obj).create;
  newObj.clone(obj);
  return newObj;
}

/// Property interface flags
enum PropIfaceFlags
{
  None = 0, /// No PropIfaceFlags
  JsonLoadOverride = 1 << 0, /// Override jsonLoad method (default is to use doJsonLoad())
  JsonSaveOverride = 1 << 1, /// Override jsonSave method (default is to use doJsonSave())
  CloneOverride = 1 << 2, /// Override clone method (default is to use doClone())
}

/// Property flags
enum PropFlags
{
  None = 0, /// No flags
  ReadOnly = 1 << 0, /// Property is read only
  Hidden = 1 << 1, /// Property is hidden from user interfaces
  Inline = 1 << 2, /// Inline object (for object properties)
  NotSaved = 1 << 3, /// Property is not saved to files
  JsonOnly = 1 << 4, /// Saved/loaded from JSON only (no property setter/getter)
  ThrowOrGc = 1 << 5, /// Property getter is not nothrow @nogc (default)
  Override = 1 << 6, /// For overriding a parent property
}

/// Property information structure
struct PropInfo
{
  string name; /// Name of property
  string label; /// Label of property
  string descr; /// Description of property
  TypeInfo type; /// The property type or the item type for containers
  PropFlags flags; /// Flags

  Variant defVal; /// Default value
  Variant minVal; /// Minimum value
  Variant maxVal; /// Maximum value

  uint arrayMinSize; /// Array minimum size
  uint arrayMaxSize; /// Array maximum size (0 for unlimited)

  /**
   * Get property value range information converted to double values.
   * Params:
   *   defVal = Output default value
   *   minVal = Output minimum value
   *   maxVal = Output maximum value
   *   isFloatingPoint = Output if the type is a floating point type (float or double)
   * Returns: true if the property value is convertable to a double range, false otherwise
   */
  bool getDoubleRange(out double defVal, out double minVal, out double maxVal, out bool isFloatingPoint) const
  {
    if (!typeNumericRange(type, minVal, maxVal, isFloatingPoint))
      return false;

    try
    {
      defVal = (cast()this).defVal.coerce!double;

      if (this.minVal.hasValue)
        minVal = (cast()this).minVal.coerce!double;

      if (this.maxVal.hasValue)
        maxVal = (cast()this).maxVal.coerce!double;
    }
    catch (VariantException)
      return false;

    return true;
  }

  /**
   * Check if PropInfo is a json encodable/decodable property.
   * Returns: true if property info is a json serializable property, false otherwise
   */
  bool isJsonProp()
  {
    if ((flags & PropFlags.NotSaved) != 0)
      return false;

    auto isPropIfaceProp = cast(TypeInfo_Class)type || cast(TypeInfo_Interface)type;

    return (isPropIfaceProp && (flags & PropFlags.Inline) != 0) // Inline object
      || (isPropIfaceProp && (flags & PropFlags.ReadOnly) == 0) // Item reference
      || (!isPropIfaceProp && (flags & PropFlags.ReadOnly) == 0); // Regular read/write property?
  }
}

/**
 * Json item reference encoder.
 * Params:
 *   js = Json value to store the item reference to (usually a JSON object of the form {"uuid" : "<UUID>", "id" : <ID>} where uuid is optional for external file references)
 *   item = The item to encode as a json item reference
 *   parent = The parent object which the referenced item is contained in
 *   propName = The property of the parent object which the item reference pertains to
 * Returns: Should return the resolved item reference or null if unresolved (potentially resolved later)
 */
alias JsonItemRefEncoder = void delegate(ref JSONValue js, PropIface item, PropIface parent, string propName);

/**
 * Json item reference decoder.
 * Params:
 *   js = A decoded json value which should be an item reference which was encoded by the related JsonItemRefEncoder
 *   parent = The parent object which the referenced item is contained in
 *   propName = The property of the parent object which the item reference pertains to
 * Returns: Should return the resolved item reference or null if unresolved (potentially resolved later)
 */
alias JsonItemRefDecoder = PropIface delegate(const ref JSONValue, PropIface parent, string propName);

/// Json encoder configuration
class JsonEncoderConfig
{
  this(JsonItemRefEncoder itemRefEncoder = null, bool saveDefaultValues = false)
  {
    this.itemRefEncoder = itemRefEncoder;
    this.saveDefaultValues = saveDefaultValues;
  }

  JsonItemRefEncoder itemRefEncoder; /// Item reference encoder callback delegate
  bool saveDefaultValues; /// Set to true to save default property values (they are usually omitted)
}

/// Json decoder configuration
class JsonDecoderConfig
{
  this(JsonItemRefDecoder itemRefDecoder = null)
  {
    this.itemRefDecoder = itemRefDecoder;
  }

  JsonItemRefDecoder itemRefDecoder; /// Item reference decorder callback delegate
}

/**
 * Convert a JSON value to a D value.
 * Params:
 *   js = JSON value
 *   decoderConfig = Decoder configuration object (can be null which will result in errors if there are any item references)
 * Returns: The decoded value
 */
T jsonDecode(T)(const ref JSONValue js, JsonDecoderConfig decoderConfig)
{
  static if (is(T == string))
    return js.str;
  else static if (is(T == enum))
    return js.str.to!T;
  else static if (is(T == bool))
    return js.boolean;
  else static if (isFloatingPoint!T || isNumeric!T)
    return js.get!T;
  else static if (is(T == E[string], E)) // Associative array with string key?
  {
    T aa;

    foreach (kStr, valJs; js.object)
      aa[kStr] = jsonDecode!E(valJs, decoderConfig);

    return aa;
  }
  else static if (is(T == V[K], K, V)) // Other types of associate arrays are stored as arrays of arrays with first value the key, 2nd the map value
  {
    T aa;

    foreach (kv; js.array)
      aa[jsonDecode!K(kv.array[0], decoderConfig)] = jsonDecode!V(kv.array[1], decoderConfig);

    return aa;
  }
  else static if (is(T == E[], E)) // Array?
  {
    T arr;

    foreach (itemJs; js.array)
      arr ~= jsonDecode!E(itemJs, decoderConfig);

    return arr;
  }
  else static if (is(T : Object) || is(T == interface)) // Object or interface?
  {
    auto itemClass = findClassName(js["type"].str);

    enforce(itemClass !is null, "Failed to resolve node type '" ~ js["type"].str ~ "'");
    enforce(typeid(T).isBaseOf(itemClass), "Type '" ~ js["type"].str ~ "' is not a '" ~ T.stringof ~ "'");

    auto obj = cast(PropIface)itemClass.create;
    obj.jsonLoad(js, decoderConfig);
    return cast(T)obj;
  }
  else static if (__traits(compiles, T("")))
    return T(js.str);
  else
    static assert(false, "Unhandled jsonDecode type " ~ T.stringof);
}

/**
 * Convert a value to a JSON value.
 * Params:
 *   val = The value
 *   js = The JSON value to encode to
 *   encoderConfig = Encoder configuration object (can be null which will result in errors if there are any item references)
 */
void jsonEncode(T)(T val, ref JSONValue js, JsonEncoderConfig encoderConfig)
{
  static if (is(T == string))
    js.str = val;
  else static if (is(T == enum))
    js.str = val.to!string;
  else static if (isFloatingPoint!T)
    js.floating = val;
  else static if (isSigned!T)
    js.integer = val;
  else static if (isUnsigned!T)
    js.uinteger = val;
  else static if (is(T == bool))
    js.boolean = val;
  else static if (is(T == E[string], E)) // Associative array with string key?
  {
    js = JSONValue.emptyObject;

    foreach (k, v; val)
    {
      JSONValue itemJs;
      jsonEncode(v, itemJs, encoderConfig);
      js[k] = itemJs;
    }
  }
  else static if (is(T == V[K], K, V)) // Other types of associate arrays are stored as arrays of arrays with first value the key, 2nd the map value
  {
    js = JSONValue.emptyArray;

    foreach (k, v; val)
    {
      JSONValue keyJs, valJs;
      jsonEncode(k, keyJs, encoderConfig);
      jsonEncode(v, valJs, encoderConfig);
      js.array ~= JSONValue([keyJs, valJs]);
    }
  }
  else static if (is(T == E[], E))
  {
    js = JSONValue.emptyArray;

    foreach (item; val)
    {
      js.array ~= JSONValue();
      jsonEncode(item, js.array[$ - 1], encoderConfig);
    }
  }
  else static if (is(T : Object) || is(T == interface)) // Object or interface?
  {
    if (auto propObj = cast(PropIface)val)
    {
      js["type"] = className(cast(Object)propObj);
      propObj.jsonSave(js, encoderConfig);
    }
  }
  else static if (__traits(compiles, val.toString))
    js.str = val.toString;
  else
    static assert(false, "Unhandled jsonEncode type " ~ T.stringof);
}

string definePropIface(Def, bool toplevel = false)()
{
  auto props = "private " ~ Def.stringof ~ " _props;\nmixin Signal!(PropIface, string, Variant, Variant) propChanged;\n\n";
  auto propInfo = "static protected PropInfo[] _propInfo;\n"
    ~ (toplevel ? "" : "override ") ~ "PropInfo[] getPropInfoArray()\n{\nif (_propInfo.length == 0)\n{\n"
    ~ Def.stringof ~ " st;\nPropInfo info;\nlong ndx;\n";
  auto getProp = (toplevel ? "" : "override ") ~ "Variant getProp(string _propName)\n{\nswitch (_propName)\n{\n";
  auto setProp = (toplevel ? "" : "override ") ~ "void setProp(string _propName, Variant value)\n{\nswitch (_propName)\n{\n";
  auto getJson = (toplevel ? "" : "override ") ~ "void getPropJson(string _propName, ref JSONValue _js, "
    ~ "JsonEncoderConfig _encoderConfig)\n{\nswitch (_propName)\n{\n";
  auto setJson = (toplevel ? "" : "override ") ~ "void setPropJson(string _propName, const ref JSONValue _js, "
    ~ "JsonDecoderConfig _decoderConfig)\n{\nswitch (_propName)\n{\n";

  if (!toplevel)
    propInfo ~= "_propInfo = super.getPropInfoArray.dup;\n";

  PropIfaceFlags propIfaceFlags;

  static foreach (attrib; __traits(getAttributes, Def))
  {
    static if (is(typeof(attrib) == PropIfaceFlags))
      propIfaceFlags |= attrib;
  }

  props ~= (propIfaceFlags & PropIfaceFlags.CloneOverride) == 0
    ? ((toplevel ? "" : "override ") ~ "void clone(PropIface other)\n"
    ~ "{\n  doClone(other);\n}\n") : "";

  auto jsonLoad = (propIfaceFlags & PropIfaceFlags.JsonLoadOverride) == 0 ? ((toplevel ? "" : "override ")
    ~ "void jsonLoad(const ref JSONValue js, JsonDecoderConfig _decoderConfig)\n"
    ~ "{\n  doJsonLoad(js, _decoderConfig);\n}\n") : "";
  auto jsonSave = (propIfaceFlags & PropIfaceFlags.JsonSaveOverride) == 0
    ? ((toplevel ? "" : "override ") ~ "void jsonSave(ref JSONValue js, JsonEncoderConfig _encoderConfig)\n"
    ~ "{\n  doJsonSave(js, _encoderConfig);\n}\n") : "";

  string desc;
  string label;
  string getValue;
  string setValue;
  string readDelegate;
  string writeDelegate;
  string updateDelegate;
  string jsonEncodeDelegate;
  string jsonDecodeDelegate;
  PropFlags propFlags;
  string overrideStr;
  string minVal, maxVal;
  string fieldType;
  string fieldName;
  uint arrayMinSize, arrayMaxSize;

  static foreach (field; Def.tupleof)
  {
    desc = null;
    label = null;
    getValue = null;
    setValue = null;
    readDelegate = null;
    writeDelegate = null;
    updateDelegate = null;
    jsonEncodeDelegate = null;
    jsonDecodeDelegate = null;
    propFlags = PropFlags.None;
    overrideStr = null;
    minVal = "Variant.init";
    maxVal = "Variant.init";
    fieldType = typeof(field).stringof;
    fieldName = field.stringof;
    arrayMinSize = arrayMaxSize = 0;

    static foreach (attrib; __traits(getAttributes, field))
    {
      static if (is(typeof(attrib) == Desc))
        desc = attrib.description;
      else static if (is(typeof(attrib) == Lbl))
        label = attrib.label;
      else static if (is(typeof(attrib) == PropFlags))
        propFlags |= attrib;
      else static if (is(typeof(attrib) == GetValue))
        getValue = attrib.statement;
      else static if (is(typeof(attrib) == SetValue))
        setValue = attrib.statement;
      else static if (is(typeof(attrib) == ReadDelegate))
        readDelegate = attrib.dlg;
      else static if (is(typeof(attrib) == WriteDelegate))
        writeDelegate = attrib.dlg;
      else static if (is(typeof(attrib) == UpdateDelegate))
        updateDelegate = attrib.dlg;
      else static if (is(typeof(attrib) == JsonEncodeDelegate))
        jsonEncodeDelegate = attrib.dlg;
      else static if (is(typeof(attrib) == JsonDecodeDelegate))
        jsonDecodeDelegate = attrib.dlg;
      else static if (is(typeof(attrib) == RangeValue))
      {
        minVal = "Variant(" ~ attrib.minVal ~ ")";
        maxVal = "Variant(" ~ attrib.maxVal ~ ")";
      }
      else static if (is(typeof(attrib) == ArrayLimits))
      {
        arrayMinSize = attrib.minSize;
        arrayMaxSize = attrib.maxSize;
      }
    }

    if (propFlags & PropFlags.Override)
      overrideStr = "override ";

    if ((propFlags & PropFlags.JsonOnly) == 0) // Read property
    {
      props ~= "public " ~ overrideStr ~ "@property ";

      if (!(propFlags & PropFlags.ThrowOrGc))
        props ~= "nothrow @nogc ";

      props ~= fieldType ~ " " ~ fieldName ~ "() {\n";

      if (readDelegate)
        props ~= readDelegate ~ ";\n";

      if (getValue)
        props ~= "return " ~ getValue ~ ";\n}\n";
      else
        props ~= "return _props." ~ fieldName ~ ";\n}\n";

      getProp ~= "case \"" ~ fieldName ~ "\":\nreturn Variant(" ~ (is(typeof(field) == enum) ? "cast(int)" : "")
        ~ fieldName ~ ");\n";
    }

    if ((propFlags & (PropFlags.ReadOnly | PropFlags.JsonOnly)) == 0) // Write property
    {
      props ~= "public " ~ overrideStr ~ "@property void " ~ fieldName ~ "(" ~ fieldType ~ " value)\n{\n";
      props ~= "if (_props." ~ fieldName ~ " == value)\nreturn;\n";
      props ~= "auto oldValue = _props." ~ fieldName ~ ";\n";

      if (setValue)
        props ~= setValue ~ ";\n";
      else if (is(typeof(field) : E[], E)) // Duplicate arrays
        props ~= "_props." ~ fieldName ~ " = value.dup;\n";
      else
        props ~= "_props." ~ fieldName ~ " = value;\n";

      if (writeDelegate)
        props ~= writeDelegate ~ "(oldValue);\n";

      if (updateDelegate)
        props ~= updateDelegate ~ "();\n";

      if (is(typeof(field) == enum)) // Cast to int for enum types
        props ~= "propChangedGlobal.emit(this, \"" ~ fieldName ~ "\", Variant(cast(int)value), Variant(cast(int)oldValue));\n"
          ~"propChanged.emit(this, \"" ~ fieldName ~ "\", Variant(cast(int)value), Variant(cast(int)oldValue));\n}\n";
      else
        props ~= "propChangedGlobal.emit(this, \"" ~ fieldName ~ "\", Variant(value), Variant(oldValue));\n"
          ~ "propChanged.emit(this, \"" ~ fieldName ~ "\", Variant(value), Variant(oldValue));\n}\n";

      setProp ~= "case \"" ~ fieldName ~ "\":\n" ~ fieldName ~ " = value."
        ~ ((is(typeof(field) == struct) || isArray!(typeof(field)) || isAssociativeArray!(typeof(field)))
        ? "get" : "coerce") ~ "!(" ~ fieldType ~ ");\nbreak;\n";
    }

    propInfo ~= "info = PropInfo(\"" ~ fieldName ~ "\", \"" ~ label ~ "\", \"" ~ desc
      ~ "\", typeid(" ~ fieldType ~ "), cast(PropFlags)" ~ (cast(uint)propFlags).to!string
      ~ ", Variant(st." ~ fieldName ~ ")" ~ ", " ~ minVal ~ ", " ~ maxVal ~ ", "
      ~ arrayMinSize.to!string ~ ", " ~ arrayMaxSize.to!string ~ ");\n";

    propInfo ~= "ndx = _propInfo.countUntil!(x => x.name == \"" ~ fieldName ~ "\");\n"; // Check for property info overrides
    propInfo ~= "if (ndx != -1)\n_propInfo[ndx] = info;\nelse\n_propInfo ~= info;\n\n";

    if ((propFlags & PropFlags.NotSaved) == 0)
    {
      if (jsonEncodeDelegate)
        getJson ~= "case \"" ~ fieldName ~ "\":\n" ~ jsonEncodeDelegate ~ "(_js, _encoderConfig);\nbreak;\n";
      else if ((is(typeof(field) : PropIface) && (propFlags & PropFlags.Inline) != 0) // Inline object?
          || (!is(typeof(field) : PropIface) && (propFlags & PropFlags.ReadOnly) == 0)) // Regular read/write property?
        getJson ~= "case \"" ~ fieldName ~ "\":\nif (_encoderConfig.saveDefaultValues || " ~ fieldName
          ~ (__traits(compiles, field.init is null) ? " !is " : " != ") // Need to use !is for comparing with null
          ~ Def.stringof ~ "()." ~ fieldName ~ ")" ~ "jsonEncode(" ~ fieldName ~ ", _js, _encoderConfig);\nbreak;\n";
      else if (is(typeof(field) : PropIface) && (propFlags & PropFlags.ReadOnly) == 0) // Item reference
        getJson ~= "case \"" ~ fieldName
          ~ "\":\nassert(_encoderConfig && _encoderConfig.itemRefEncoder, \"No json item reference encoder\");\n"
          ~ "_encoderConfig.itemRefEncoder(_js, " ~ fieldName ~ ", this, \"" ~ fieldName ~ "\");\nbreak;\n";

      if (jsonDecodeDelegate)
        setJson ~= "case \"" ~ fieldName ~ "\":\n" ~ jsonDecodeDelegate ~ "(_js, _decoderConfig);\nbreak;\n";
      else if (is(typeof(field) : PropIface))
      {
        if ((propFlags & PropFlags.Inline) != 0) // Inline item (use existing item if set)
        {
          if ((propFlags & PropFlags.ReadOnly) == 0)
            setJson ~= "case \"" ~ fieldName ~ "\":\nif (!" ~ fieldName ~ ")\n" ~ fieldName ~ " = new " ~ fieldType
              ~ ";\n" ~ fieldName ~ ".jsonLoad(_js, _decoderConfig);\nbreak;\n";
          else // Read only inline objects load the item state into the existing object
            setJson ~= "case \"" ~ fieldName ~ "\":\nassert(" ~ fieldName ~ ", \"Null read only inline item property"
              ~ " cannot be loaded from json\");\n" ~ fieldName ~ ".jsonLoad(_js, _decoderConfig);\nbreak;\n";
        }
        else if ((propFlags & PropFlags.ReadOnly) == 0) // Item reference
          setJson ~= "case \"" ~ fieldName
            ~ "\":\nassert(_decoderConfig && _decoderConfig.itemRefDecoder, \"No json item reference decoder\");\n"
            ~ fieldName ~ " = cast(" ~ fieldType ~ ")_decoderConfig.itemRefDecoder(_js, this, \"" ~ fieldName
            ~ "\");\nbreak;\n";
      }
      else if ((propFlags & PropFlags.ReadOnly) == 0)
        setJson ~= "case \"" ~ fieldName ~ "\":\n" ~ fieldName ~ " = jsonDecode!(" ~ fieldType
          ~ ")(_js, _decoderConfig);\nbreak;\n";
    }
  }

  propInfo ~= "}\nreturn _propInfo;\n }\n";

  if (toplevel)
  {
    getProp ~= "default:\nthrow new Exception(\"Readable property '\" ~ _propName ~ \"' not found\");\n}\n}\n\n";
    setProp ~= "default:\nthrow new Exception(\"Writable property '\" ~ _propName ~ \"' not found\");\n}\n}\n\n";
    getJson ~= "default:\nthrow new Exception(\"JSON encodable property '\" ~ _propName ~ \"' not found\");\n}\n}\n\n";
    setJson ~= "default:\nthrow new Exception(\"JSON decodable property '\" ~ _propName ~ \"' not found\");\n}\n}\n\n";
  }
  else
  {
    getProp ~= "default:\nreturn super.getProp(_propName);\n}\n}\n\n";
    setProp ~= "default:\nsuper.setProp(_propName, value);\nbreak;\n}\n}\n\n";
    getJson ~= "default:\nsuper.getPropJson(_propName, _js, _encoderConfig);\n}\n}\n\n";
    setJson ~= "default:\nsuper.setPropJson(_propName, _js, _decoderConfig);\nbreak;\n}\n}\n\n";
  }

  return props ~ propInfo ~ getProp ~ setProp ~ jsonLoad ~ jsonSave ~ getJson ~ setJson;
}

/**
 * Get the range of a numeric type.
 * Params:
 *   ti = Type info
 *   min = Output minimum value
 *   max = Output maximum value
 *   isFloatingPoint = Output boolean true if it is a floating type (double/float)
 * Returns: true if ti is a numeric type (min/max/isFloatingPoint are set), false otherwise
 */
bool typeNumericRange(const(TypeInfo) ti, out double min, out double max, out bool isFloatingPoint)
{
  if (ti == typeid(double))
  {
    isFloatingPoint = true;
    min = -double.max;
    max = double.max;
  }
  else if (ti == typeid(float))
  {
    isFloatingPoint = true;
    min = -float.max;
    max = float.max;
  }
  else if (ti == typeid(long))
  {
    min = long.min;
    max = cast(double)long.max;
  }
  else if (ti == typeid(ulong))
  {
    min = ulong.min;
    max = cast(double)ulong.max;
  }
  else if (ti == typeid(int))
  {
    min = int.min;
    max = int.max;
  }
  else if (ti == typeid(uint))
  {
    min = uint.min;
    max = uint.max;
  }
  else if (ti == typeid(short))
  {
    min = short.min;
    max = short.max;
  }
  else if (ti == typeid(ushort))
  {
    min = ushort.min;
    max = ushort.max;
  }
  else if (ti == typeid(byte))
  {
    min = byte.min;
    max = byte.max;
  }
  else if (ti == typeid(ubyte))
  {
    min = ubyte.min;
    max = ubyte.max;
  }
  else
    return false;

  return true;
}

/**
  * Get the base name of a class.
  * Params:
  *   obj = The object to get the base class name of
  * Returns: Base class name (last dot '.' separated component of a class type symbol)
  */
string className(Object obj)
{
  return obj.classinfo.name;
}

/// Find a class by name
const(TypeInfo_Class) findClassName(string classname)
{
  shared TypeInfo_Class[string] classNameTypes;
  shared bool initialized;

  if (!initialized)
  {
    synchronized
    {
      if (!initialized)
        foreach (m; ModuleInfo)
          if (m)
            foreach (c; m.localClasses)
              classNameTypes[c.name] = cast(shared)c;

      initialized = true;
    }
  }

  if (auto pTypeInfo = classname in classNameTypes)
    return cast(const)*pTypeInfo;

  return null;
}

unittest
{
  import std.exception : assertThrown;

  class TestPropObject {} // A test object type to use for object property

  class TestPropIface : PropIface
  {
    enum TestEnum
    {
      Val1,
      Val2,
      Val3,
    }

    struct PropDef
    {
      @Desc("Bool value") bool boolVal = true;
      @Desc("Read only bool value") @(PropFlags.ReadOnly) @(PropFlags.NotSaved) bool readOnlyBoolVal;
      @Desc("Enum value") TestEnum enumVal = TestEnum.Val2;
      @Desc("Int value") @RangeValue("int.min", "int.max") @(PropFlags.ThrowOrGc)
        @ReadDelegate("intValRead") @WriteDelegate("intValWrite") @UpdateDelegate("intValUpdate") int intVal = 42;
      @Desc("Double value") @RangeValue("-double.max", "double.max") double dblVal = 1.0;
      @Desc("String value") string strVal = "Default";
      @Desc("Array value") @RangeValue("1", "256") @ArrayLimits(1, 4) int[] intArrayVal = [1, 2, 3];
      @Desc("Object value") TestPropObject objVal;
    }

    mixin(definePropIface!(PropDef, true));

    void intValRead()
    {
      intValReadCalled = true;
    }

    void intValWrite(int oldVal)
    {
      oldIntVal = oldVal;
    }

    void intValUpdate()
    {
      intValUpdated = true;
    }

    bool intValReadCalled;
    int oldIntVal;
    bool intValUpdated;
  }

  auto testObj = new TestPropIface;
  assert(testObj.boolVal);
  assert(!testObj.readOnlyBoolVal);
  assertCmp(testObj.enumVal, TestPropIface.TestEnum.Val2);
  assertCmp(testObj.intVal, 42);
  assert(testObj.intValReadCalled);
  assertCmp(testObj.dblVal, 1.0);
  assertCmp(testObj.strVal, "Default");
  assertCmp(testObj.intArrayVal, [1, 2, 3]);

  auto info = testObj.getPropInfo("boolVal");
  assertCmp(info.name, "boolVal");
  assertCmp(info.descr, "Bool value");
  assert(info.type is typeid(bool));
  assertCmp(info.flags, PropFlags.None);
  assertCmp(info.defVal.get!bool, true);
  assert(!info.minVal.hasValue);
  assert(!info.maxVal.hasValue);

  info = testObj.getPropInfo("readOnlyBoolVal");
  assertCmp(info.flags, (PropFlags.ReadOnly | PropFlags.NotSaved));

  info = testObj.getPropInfo("intVal");
  assertCmp(info.defVal, 42);
  assertCmp(info.minVal, int.min);
  assertCmp(info.maxVal, int.max);

  info = testObj.getPropInfo("dblVal");
  assert(info.type is typeid(double));
  assertCmp(info.defVal, 1.0);
  assertCmp(info.minVal, -double.max);
  assertCmp(info.maxVal, double.max);

  info = testObj.getPropInfo("strVal");
  assert(info.defVal == "Default");

  info = testObj.getPropInfo("intArrayVal");
  assert(info.type is typeid(int[]));
  assertCmp(info.defVal, [1, 2, 3]);
  assertCmp(info.minVal, 1);
  assertCmp(info.maxVal, 256);
  assertCmp(info.arrayMinSize, 1);
  assertCmp(info.arrayMaxSize, 4);

  testObj.boolVal = false;
  assert(!testObj.boolVal);

  assert(!__traits(compiles, testObj.readOnlyBoolVal = true)); // Assignment to read only property should be invalid statement

  testObj.enumVal = TestPropIface.TestEnum.Val3;
  assertCmp(testObj.enumVal, TestPropIface.TestEnum.Val3);

  testObj.intVal = 69;
  assertCmp(testObj.intVal, 69);
  assertCmp(testObj.oldIntVal, 42); // Gets set by intValWrite to previous value
  assert(testObj.intValUpdated);

  testObj.dblVal = 13.0;
  assertCmp(testObj.dblVal, 13.0);

  testObj.strVal = "Beautiful";
  assertCmp(testObj.strVal, "Beautiful");

  testObj.intArrayVal = [5, 4, 3, 2];
  assertCmp(testObj.intArrayVal, [5, 4, 3, 2]);

  auto propObj = new TestPropObject;
  testObj.objVal = propObj;
  assert(testObj.objVal is propObj);

  // Ensure an exception is thrown for invalid properties
  assertThrown(testObj.getProp("invalid-prop"));
  assertThrown(testObj.setProp("invalid-prop", Variant("bogus")));

  // Make sure null is returned for getPropInfo() with an invalid property
  assert(testObj.getPropInfo("invalid-prop") is null);
}
