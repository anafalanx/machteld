// Build-only deterministic serializers. No runtime dependency or code evaluation.
using System;
using System.Collections;
using System.Collections.Specialized;
using System.Globalization;
using System.Management.Automation;
using System.Text;

public static class MachteldReferenceData {
    public static void PublishRecord(string source, string target) {
        if (System.IO.File.Exists(target)) System.IO.File.Replace(source, target, null);
        else System.IO.File.Move(source, target);
    }
    static object Base(object value) {
        var wrapped = value as PSObject;
        return wrapped == null ? value : wrapped.BaseObject;
    }
    public static bool HasSurrogates(string value) {
        foreach (char c in value) if (char.IsSurrogate(c)) return true;
        return false;
    }
    public static string Word(string value) {
        if (value.Length == 0) return "{}";
        var b = new StringBuilder(value.Length);
        foreach (char c in value) {
            switch (c) {
                case '\b': b.Append(@"\b"); break;
                case '\t': b.Append(@"\t"); break;
                case '\n': b.Append(@"\n"); break;
                case '\v': b.Append(@"\v"); break;
                case '\f': b.Append(@"\f"); break;
                case '\r': b.Append(@"\r"); break;
                case ' ': case '"': case '$': case ';': case '[': case '\\':
                case ']': case '{': case '}': b.Append('\\').Append(c); break;
                default:
                    if (c < 32 || c == 127 || char.IsWhiteSpace(c))
                        b.Append(@"\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    else b.Append(c);
                    break;
            }
        }
        return b.ToString();
    }
    public static string Tcl(object value) {
        value = Base(value);
        if (value == null) return "";
        var b = new StringBuilder();
        var dict = value as IDictionary;
        if (dict != null) {
            foreach (DictionaryEntry entry in dict) {
                if (b.Length != 0) b.Append(' ');
                b.Append(Word((string)entry.Key)).Append(' ').Append(Word(Tcl(entry.Value)));
            }
            return b.ToString();
        }
        var sequence = value as IEnumerable;
        if (sequence != null && !(value is string)) {
            foreach (object item in sequence) {
                if (b.Length != 0) b.Append(' ');
                b.Append(Word(Tcl(item)));
            }
            return b.ToString();
        }
        if (value is bool) return (bool)value ? "1" : "0";
        return Convert.ToString(value, CultureInfo.InvariantCulture);
    }
    static string JsonString(string value) {
        var b = new StringBuilder(value.Length + 2).Append('"');
        foreach (char c in value) {
            switch (c) {
                case '\b': b.Append(@"\b"); break;
                case '\t': b.Append(@"\t"); break;
                case '\n': b.Append(@"\n"); break;
                case '\f': b.Append(@"\f"); break;
                case '\r': b.Append(@"\r"); break;
                case '"': case '\\': b.Append('\\').Append(c); break;
                default:
                    if (c < 32) b.Append(@"\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    else b.Append(c);
                    break;
            }
        }
        return b.Append('"').ToString();
    }
    public static string Json(object value) {
        value = Base(value);
        if (value == null) return "null";
        var b = new StringBuilder();
        var dict = value as IDictionary;
        if (dict != null) {
            b.Append('{');
            bool first = true;
            foreach (DictionaryEntry entry in dict) {
                if (!first) b.Append(','); first = false;
                b.Append(JsonString((string)entry.Key)).Append(':').Append(Json(entry.Value));
            }
            return b.Append('}').ToString();
        }
        var sequence = value as IEnumerable;
        if (sequence != null && !(value is string)) {
            b.Append('[');
            bool first = true;
            foreach (object item in sequence) {
                if (!first) b.Append(','); first = false;
                b.Append(Json(item));
            }
            return b.Append(']').ToString();
        }
        if (value is bool) return (bool)value ? "true" : "false";
        if (value is byte || value is short || value is int || value is long ||
            value is ushort || value is uint || value is ulong)
            return Convert.ToString(value, CultureInfo.InvariantCulture);
        return JsonString(Convert.ToString(value, CultureInfo.InvariantCulture));
    }
    // ConvertFrom-Json returns inert PSObjects; restore ordered maps without
    // letting data keys shadow adapter properties (notably "keys").
    public static object Ordered(object value) {
        if (value == null) return null;
        var wrapped = value as PSObject;
        if (wrapped != null && wrapped.BaseObject is PSCustomObject) {
            var result = new OrderedDictionary(StringComparer.Ordinal);
            foreach (var property in wrapped.Properties) result.Add(property.Name, Ordered(property.Value));
            return result;
        }
        value = Base(value);
        var sequence = value as IEnumerable;
        if (sequence != null && !(value is string)) {
            var result = new ArrayList();
            foreach (object item in sequence) result.Add(Ordered(item));
            return result.ToArray();
        }
        return value;
    }
}
