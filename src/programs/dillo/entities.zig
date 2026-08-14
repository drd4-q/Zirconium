const std = @import("std");

pub fn decode(entity: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(entity, "nbsp")) return " ";
    if (std.ascii.eqlIgnoreCase(entity, "amp")) return "&";
    if (std.ascii.eqlIgnoreCase(entity, "lt")) return "<";
    if (std.ascii.eqlIgnoreCase(entity, "gt")) return ">";
    if (std.ascii.eqlIgnoreCase(entity, "quot")) return "\"";
    if (std.ascii.eqlIgnoreCase(entity, "#39") or std.ascii.eqlIgnoreCase(entity, "apos")) return "'";
    if (std.ascii.eqlIgnoreCase(entity, "copy")) return "(c)";
    if (std.ascii.eqlIgnoreCase(entity, "reg")) return "(R)";
    if (std.ascii.eqlIgnoreCase(entity, "trade")) return "(TM)";
    if (std.ascii.eqlIgnoreCase(entity, "mdash")) return "—";
    if (std.ascii.eqlIgnoreCase(entity, "ndash")) return "-";
    if (std.ascii.eqlIgnoreCase(entity, "bull")) return "•";
    if (std.ascii.eqlIgnoreCase(entity, "hellip")) return "...";
    if (std.ascii.eqlIgnoreCase(entity, "laquo")) return "«";
    if (std.ascii.eqlIgnoreCase(entity, "raquo")) return "»";
    if (std.ascii.eqlIgnoreCase(entity, "times")) return "x";
    if (std.ascii.eqlIgnoreCase(entity, "divide")) return "/";
    if (std.ascii.eqlIgnoreCase(entity, "plusmn")) return "+/-";
    if (std.ascii.eqlIgnoreCase(entity, "deg")) return "°";
    if (std.ascii.eqlIgnoreCase(entity, "euro")) return "EUR";
    if (std.ascii.eqlIgnoreCase(entity, "pound")) return "GBP";
    if (std.ascii.eqlIgnoreCase(entity, "yen")) return "JPY";
    if (std.ascii.eqlIgnoreCase(entity, "cent")) return "c";
    return "";
}
