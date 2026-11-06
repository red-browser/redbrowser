//! Author stylesheets: CSS parsing, selector matching and the cascade order.
//!
//! Covers what real sites lean on: type/class/id/attribute selectors, all four
//! combinators, structural pseudo-classes, :not/:is/:where, @media (evaluated
//! against the viewport at layout time), @supports/@layer blocks, `!important`
//! and custom properties with `var()`. Interactive pseudo-classes (:hover,
//! :focus, …) never match, and pseudo-elements are skipped since there is no
//! generated content.

const std = @import("std");
const dom = @import("dom.zig");

const Allocator = std.mem.Allocator;

pub const Decl = struct { prop: []const u8, val: []const u8, important: bool };

const AttrOp = enum { exists, eq, includes, dash, prefix, suffix, substr };
const AttrSel = struct { name: []const u8, op: AttrOp, val: []const u8, ci: bool };
const Nth = struct { a: i32, b: i32 };

const Pseudo = union(enum) {
    root,
    first_child,
    last_child,
    only_child,
    first_of_type,
    last_of_type,
    empty,
    link,
    checked,
    disabled,
    enabled,
    defined,
    never,
    nth_child: Nth,
    nth_last_child: Nth,
    nth_of_type: Nth,
    not: []const Complex,
    is: []const Complex,
};

const Compound = struct {
    tag: ?[]const u8 = null,
    id: ?[]const u8 = null,
    classes: []const []const u8 = &.{},
    attrs: []const AttrSel = &.{},
    pseudos: []const Pseudo = &.{},
};

const Comb = enum { descendant, child, next, subsequent };

/// A complex selector stored right-to-left: `parts[0]` is the subject and
/// `combs[i]` joins `parts[i]` to `parts[i + 1]` (the compound on its left).
const Complex = struct {
    parts: []const Compound,
    combs: []const Comb,
    spec: u32,
};

pub const Rule = struct {
    sel: Complex,
    order: u32,
    decls: []const Decl,
    /// 0 = unconditional, otherwise an index into `Sheet.media`.
    media: u32,
};

/// Custom properties (`--name: value`) visible to an element; scopes chain to
/// the parent element's, which is how they inherit.
pub const Vars = struct {
    parent: ?*const Vars,
    names: []const []const u8,
    values: []const []const u8,

    pub fn get(self: ?*const Vars, name: []const u8) ?[]const u8 {
        var v = self;
        while (v) |scope| : (v = scope.parent) {
            var i = scope.names.len;
            while (i > 0) {
                i -= 1;
                if (std.mem.eql(u8, scope.names[i], name)) return scope.values[i];
            }
        }
        return null;
    }
};

const Bucket = std.StringHashMapUnmanaged(std.ArrayListUnmanaged(u32));

pub const Sheet = struct {
    arena: std.heap.ArenaAllocator,
    /// Per-layout scratch (matched rule lists, var scopes); reset by `beginLayout`.
    scratch: std.heap.ArenaAllocator,
    rules: std.ArrayListUnmanaged(Rule) = .{},
    media: std.ArrayListUnmanaged([]const u8) = .{},
    media_ok: []bool = &.{},
    by_id: Bucket = .{},
    by_class: Bucket = .{},
    by_tag: Bucket = .{},
    universal: std.ArrayListUnmanaged(u32) = .{},
    viewport_w: f32 = 1280,
    viewport_h: f32 = 800,

    pub fn create(allocator: Allocator) !*Sheet {
        const self = try allocator.create(Sheet);
        self.* = .{ .arena = std.heap.ArenaAllocator.init(allocator), .scratch = std.heap.ArenaAllocator.init(allocator) };
        self.media.append(self.arena.allocator(), "") catch {};
        return self;
    }

    pub fn destroy(self: *Sheet, allocator: Allocator) void {
        self.scratch.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }

    /// Parse a stylesheet and append its rules (later sheets win ties).
    pub fn addCss(self: *Sheet, text: []const u8) void {
        const a = self.arena.allocator();
        const clean = stripComments(a, text) catch return;
        const before = self.rules.items.len;
        self.parseRules(clean, 0) catch |err| std.log.warn("css: {}", .{err});
        if (std.posix.getenv("REDBROWSER_CSS_DEBUG") != null)
            std.log.info("css: {d} bytes -> {d} rules", .{ text.len, self.rules.items.len - before });
    }

    /// Set the viewport for @media and clear per-layout scratch memory.
    pub fn beginLayout(self: *Sheet, w: f32, h: f32) void {
        _ = self.scratch.reset(.retain_capacity);
        self.viewport_w = w;
        self.viewport_h = h;
        const a = self.scratch.allocator();
        self.media_ok = a.alloc(bool, self.media.items.len) catch &.{};
        for (self.media_ok, 0..) |*ok, i| ok.* = i == 0 or mediaMatches(self.media.items[i], w, h);
    }

    pub fn scratchAllocator(self: *Sheet) Allocator {
        return self.scratch.allocator();
    }

    // ---- parsing -----------------------------------------------------------

    fn parseRules(self: *Sheet, src: []const u8, media: u32) !void {
        const a = self.arena.allocator();
        var i: usize = 0;
        while (i < src.len) {
            i = skipWs(src, i);
            if (i >= src.len) break;
            if (src[i] == '}' or src[i] == ';') {
                i += 1;
                continue;
            }
            if (src[i] == '@') {
                const name_end = identEnd(src, i + 1);
                const name = src[i + 1 .. name_end];
                const stop = findTop(src, name_end, "{;") orelse src.len;
                const prelude = std.mem.trim(u8, src[name_end..stop], " \t\r\n");
                if (stop >= src.len or src[stop] == ';') {
                    i = stop + 1;
                    continue;
                }
                const close = matchBrace(src, stop);
                const body = src[stop + 1 .. close];
                i = close + 1;
                if (std.ascii.eqlIgnoreCase(name, "media")) {
                    // Nested @media: combine by keeping the innermost; outer
                    // already filtered at evaluation via a joined query.
                    const q = if (media != 0)
                        try std.fmt.allocPrint(a, "{s} and {s}", .{ self.media.items[media], prelude })
                    else
                        try std.ascii.allocLowerString(a, prelude);
                    try self.media.append(a, q);
                    try self.parseRules(body, @intCast(self.media.items.len - 1));
                } else if (std.ascii.eqlIgnoreCase(name, "supports") or std.ascii.eqlIgnoreCase(name, "layer") or std.ascii.eqlIgnoreCase(name, "document") or std.ascii.eqlIgnoreCase(name, "scope")) {
                    try self.parseRules(body, media);
                }
                // @font-face, @keyframes, @page, @container, … are ignored.
                continue;
            }
            const open = findTop(src, i, "{") orelse break;
            const close = matchBrace(src, open);
            const prelude = src[i..open];
            const body = src[open + 1 .. close];
            i = close + 1;
            try self.addRule(prelude, body, media);
        }
    }

    fn addRule(self: *Sheet, prelude: []const u8, body: []const u8, media: u32) !void {
        const a = self.arena.allocator();
        var decls = std.ArrayListUnmanaged(Decl){};
        try parseDecls(a, body, &decls);
        if (decls.items.len == 0) return;
        const selectors = parseSelectorList(a, prelude, false) catch {
            if (std.posix.getenv("REDBROWSER_CSS_DEBUG") != null) std.log.info("css: dropped selector '{s}'", .{prelude[0..@min(prelude.len, 120)]});
            return;
        };
        for (selectors) |sel| {
            const id: u32 = @intCast(self.rules.items.len);
            try self.rules.append(a, .{ .sel = sel, .order = id, .decls = decls.items, .media = media });
            const subj = sel.parts[0];
            if (subj.id) |v| {
                try addTo(a, &self.by_id, v, id);
            } else if (subj.classes.len > 0) {
                try addTo(a, &self.by_class, subj.classes[0], id);
            } else if (subj.tag) |t| {
                try addTo(a, &self.by_tag, t, id);
            } else {
                try self.universal.append(a, id);
            }
        }
    }

    // ---- matching ----------------------------------------------------------

    /// Rules matching element `idx`, in cascade order (specificity, then source order).
    pub fn matching(self: *Sheet, doc: *const dom.Document, idx: u32) []const *const Rule {
        const a = self.scratch.allocator();
        var out = std.ArrayListUnmanaged(*const Rule){};
        const node = doc.get(idx);
        if (node.attr("id")) |v| self.collect(&out, a, doc, idx, self.by_id.get(v));
        if (node.attr("class")) |cls| {
            var seen: [32][]const u8 = undefined;
            var n: usize = 0;
            var it = std.mem.tokenizeAny(u8, cls, " \t\r\n\x0c");
            outer: while (it.next()) |c| {
                for (seen[0..n]) |s| if (std.mem.eql(u8, s, c)) continue :outer;
                if (n < seen.len) {
                    seen[n] = c;
                    n += 1;
                }
                self.collect(&out, a, doc, idx, self.by_class.get(c));
            }
        }
        self.collect(&out, a, doc, idx, self.by_tag.get(node.name));
        self.collect(&out, a, doc, idx, self.universal);
        std.sort.pdq(*const Rule, out.items, {}, struct {
            fn lt(_: void, x: *const Rule, y: *const Rule) bool {
                return if (x.sel.spec != y.sel.spec) x.sel.spec < y.sel.spec else x.order < y.order;
            }
        }.lt);
        return out.items;
    }

    fn collect(self: *Sheet, out: *std.ArrayListUnmanaged(*const Rule), a: Allocator, doc: *const dom.Document, idx: u32, list: ?std.ArrayListUnmanaged(u32)) void {
        const l = list orelse return;
        for (l.items) |ri| {
            const r = &self.rules.items[ri];
            if (r.media != 0 and !(r.media < self.media_ok.len and self.media_ok[r.media])) continue;
            if (matchComplex(doc, idx, &r.sel, 0)) out.append(a, r) catch return;
        }
    }
};

fn addTo(a: Allocator, map: *Bucket, key: []const u8, id: u32) !void {
    const gop = try map.getOrPut(a, key);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    try gop.value_ptr.append(a, id);
}

// ---- text helpers -----------------------------------------------------------

fn stripComments(a: Allocator, s: []const u8) ![]u8 {
    var out = try std.ArrayListUnmanaged(u8).initCapacity(a, s.len);
    var i: usize = 0;
    var quote: u8 = 0;
    while (i < s.len) {
        const ch = s[i];
        if (quote != 0) {
            out.appendAssumeCapacity(ch);
            if (ch == '\\' and i + 1 < s.len) {
                out.appendAssumeCapacity(s[i + 1]);
                i += 2;
                continue;
            }
            if (ch == quote) quote = 0;
            i += 1;
        } else if (ch == '/' and i + 1 < s.len and s[i + 1] == '*') {
            const end = std.mem.indexOfPos(u8, s, i + 2, "*/") orelse s.len;
            i = @min(s.len, end + 2);
            out.appendAssumeCapacity(' ');
        } else {
            if (ch == '"' or ch == '\'') quote = ch;
            out.appendAssumeCapacity(ch);
            i += 1;
        }
    }
    return out.items;
}

fn skipWs(s: []const u8, from: usize) usize {
    var i = from;
    while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
    return i;
}

fn isIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch >= 0x80;
}

fn identEnd(s: []const u8, from: usize) usize {
    var i = from;
    while (i < s.len) {
        if (isIdentChar(s[i])) {
            i += 1;
        } else if (s[i] == '\\' and i + 1 < s.len) {
            i += 2;
        } else break;
    }
    return i;
}

/// Index of the first char in `stops` at nesting depth 0 (outside strings, (), []).
fn findTop(s: []const u8, from: usize, stops: []const u8) ?usize {
    var depth: i32 = 0;
    var quote: u8 = 0;
    var i = from;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        if (quote != 0) {
            if (ch == '\\') i += 1 else if (ch == quote) quote = 0;
            continue;
        }
        if (depth <= 0 and std.mem.indexOfScalar(u8, stops, ch) != null) return i;
        switch (ch) {
            '"', '\'' => quote = ch,
            '\\' => i += 1,
            '(', '[' => depth += 1,
            ')', ']' => depth -= 1,
            else => {},
        }
    }
    return null;
}

/// Index of the `}` closing the `{` at `open` (or s.len when unbalanced).
fn matchBrace(s: []const u8, open: usize) usize {
    var depth: i32 = 0;
    var quote: u8 = 0;
    var i = open;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        if (quote != 0) {
            if (ch == '\\') i += 1 else if (ch == quote) quote = 0;
            continue;
        }
        switch (ch) {
            '"', '\'' => quote = ch,
            '\\' => i += 1,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return s.len;
}

/// Split `prop: value [!important]; ...` into declarations. Nested rule blocks
/// (CSS nesting) are skipped.
pub fn parseDecls(a: Allocator, body: []const u8, out: *std.ArrayListUnmanaged(Decl)) !void {
    var i: usize = 0;
    while (i < body.len) {
        const end = findTop(body, i, ";{") orelse body.len;
        if (end < body.len and body[end] == '{') {
            // nested rule: skip it and whatever selector text preceded it
            i = matchBrace(body, end) + 1;
            continue;
        }
        const decl = body[i..end];
        i = end + 1;
        const colon = std.mem.indexOfScalar(u8, decl, ':') orelse continue;
        const prop_raw = std.mem.trim(u8, decl[0..colon], " \t\r\n");
        if (prop_raw.len == 0) continue;
        var val = std.mem.trim(u8, decl[colon + 1 ..], " \t\r\n");
        var important = false;
        if (std.mem.lastIndexOfScalar(u8, val, '!')) |bang| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, val[bang + 1 ..], " \t"), "important")) {
                important = true;
                val = std.mem.trim(u8, val[0..bang], " \t\r\n");
            }
        }
        // Custom property names are case-sensitive; everything else is not.
        const prop = if (std.mem.startsWith(u8, prop_raw, "--")) prop_raw else try std.ascii.allocLowerString(a, prop_raw);
        try out.append(a, .{ .prop = prop, .val = val, .important = important });
    }
}

/// Replace `var(--x, fallback)` references. Returns null when a reference
/// can't be resolved (the declaration is then invalid and dropped).
pub fn substitute(a: Allocator, val: []const u8, vars: ?*const Vars) ?[]const u8 {
    return substituteDepth(a, val, vars, 0);
}

fn substituteDepth(a: Allocator, val: []const u8, vars: ?*const Vars, depth: u32) ?[]const u8 {
    if (std.mem.indexOf(u8, val, "var(") == null) return val;
    if (depth > 8) return null;
    var out = std.ArrayListUnmanaged(u8){};
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, val, i, "var(")) |start| {
        out.appendSlice(a, val[i..start]) catch return null;
        const inner_start = start + 4;
        const close = findTop(val, inner_start, ")") orelse return null;
        const inner = val[inner_start..close];
        const comma = findTop(inner, 0, ",");
        const name = std.mem.trim(u8, if (comma) |c| inner[0..c] else inner, " \t\r\n");
        const resolved = Vars.get(vars, name) orelse if (comma) |c| std.mem.trim(u8, inner[c + 1 ..], " \t\r\n") else return null;
        const sub = substituteDepth(a, resolved, vars, depth + 1) orelse return null;
        out.appendSlice(a, sub) catch return null;
        i = close + 1;
    }
    out.appendSlice(a, val[i..]) catch return null;
    return out.items;
}

// ---- selectors ----------------------------------------------------------------

const SelParser = struct {
    s: []const u8,
    i: usize = 0,
    a: Allocator,

    fn peek(p: *SelParser) ?u8 {
        return if (p.i < p.s.len) p.s[p.i] else null;
    }

    fn ws(p: *SelParser) bool {
        const start = p.i;
        p.i = skipWs(p.s, p.i);
        return p.i > start;
    }

    /// Identifier with CSS escapes decoded (e.g. Tailwind's `.md\:flex`).
    fn ident(p: *SelParser) ?[]const u8 {
        const start = p.i;
        const end = identEnd(p.s, p.i);
        if (end == start) return null;
        p.i = end;
        const raw = p.s[start..end];
        if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
        var out = std.ArrayListUnmanaged(u8){};
        var j: usize = 0;
        while (j < raw.len) {
            if (raw[j] == '\\' and j + 1 < raw.len) {
                var k = j + 1;
                while (k < raw.len and k < j + 7 and std.ascii.isHex(raw[k])) k += 1;
                if (k > j + 1) {
                    const cp = std.fmt.parseInt(u21, raw[j + 1 .. k], 16) catch '?';
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch 0;
                    out.appendSlice(p.a, buf[0..n]) catch return null;
                    j = k;
                    if (j < raw.len and raw[j] == ' ') j += 1;
                } else {
                    out.append(p.a, raw[j + 1]) catch return null;
                    j += 2;
                }
            } else {
                out.append(p.a, raw[j]) catch return null;
                j += 1;
            }
        }
        return out.items;
    }
};

const Unsupported = error{ Unsupported, OutOfMemory };

fn parseSelectorList(a: Allocator, text: []const u8, forgiving: bool) Unsupported![]const Complex {
    var list = std.ArrayListUnmanaged(Complex){};
    var i: usize = 0;
    while (i <= text.len) {
        const end = findTop(text, i, ",") orelse text.len;
        const piece = std.mem.trim(u8, text[i..end], " \t\r\n");
        i = end + 1;
        if (piece.len == 0) {
            if (forgiving) continue;
            return error.Unsupported;
        }
        if (parseComplex(a, piece)) |cx| {
            try list.append(a, cx);
        } else |err| switch (err) {
            error.OutOfMemory => return err,
            error.Unsupported => if (!forgiving) {
                // A selector list with one bad selector is invalid as a whole
                // per spec, but keeping the good ones renders real sites better.
                continue;
            },
        }
    }
    if (list.items.len == 0) return error.Unsupported;
    return list.items;
}

fn parseComplex(a: Allocator, text: []const u8) Unsupported!Complex {
    var p = SelParser{ .s = text, .a = a };
    var parts = std.ArrayListUnmanaged(Compound){};
    var combs = std.ArrayListUnmanaged(Comb){};
    _ = p.ws();
    // Relative selectors (`> a` inside :has / nesting) aren't supported.
    while (true) {
        const comp = try parseCompound(&p);
        try parts.append(a, comp);
        const had_ws = p.ws();
        const ch = p.peek() orelse break;
        const comb: Comb = switch (ch) {
            '>' => .child,
            '+' => .next,
            '~' => .subsequent,
            else => if (had_ws) .descendant else return error.Unsupported,
        };
        if (comb != .descendant) {
            p.i += 1;
            _ = p.ws();
        }
        try combs.append(a, comb);
    }
    std.mem.reverse(Compound, parts.items);
    std.mem.reverse(Comb, combs.items);
    var spec: u32 = 0;
    for (parts.items) |c| spec += compoundSpec(c);
    return .{ .parts = parts.items, .combs = combs.items, .spec = spec };
}

fn compoundSpec(c: Compound) u32 {
    var s: u32 = 0;
    if (c.id != null) s += 1 << 20;
    s += @as(u32, @intCast(c.classes.len + c.attrs.len)) << 10;
    if (c.tag != null) s += 1;
    for (c.pseudos) |ps| switch (ps) {
        .is => |list| {
            // :is takes its most specific argument; :where (spec 0) is stored as .is with
            // a zero-specificity marker — see parsePseudo.
            var m: u32 = 0;
            for (list) |cx| m = @max(m, cx.spec);
            s += m;
        },
        .not => |list| {
            var m: u32 = 0;
            for (list) |cx| m = @max(m, cx.spec);
            s += m;
        },
        .defined => {},
        else => s += 1 << 10,
    };
    return s;
}

fn parseCompound(p: *SelParser) Unsupported!Compound {
    const a = p.a;
    var c = Compound{};
    var classes = std.ArrayListUnmanaged([]const u8){};
    var attrs = std.ArrayListUnmanaged(AttrSel){};
    var pseudos = std.ArrayListUnmanaged(Pseudo){};
    var any = false;

    if (p.peek() == '*') {
        p.i += 1;
        any = true;
    } else if (p.peek()) |ch| {
        if (isIdentChar(ch) or ch == '\\') {
            const t = p.ident() orelse return error.Unsupported;
            c.tag = try std.ascii.allocLowerString(a, t);
            any = true;
        } else if (ch == '&') return error.Unsupported;
    }
    if (p.peek() == '|') return error.Unsupported; // namespaces

    while (p.peek()) |ch| {
        switch (ch) {
            '#' => {
                p.i += 1;
                c.id = p.ident() orelse return error.Unsupported;
            },
            '.' => {
                p.i += 1;
                try classes.append(a, p.ident() orelse return error.Unsupported);
            },
            '[' => try attrs.append(a, try parseAttr(p)),
            ':' => try pseudos.append(a, try parsePseudo(p)),
            else => break,
        }
        any = true;
    }
    if (!any) return error.Unsupported;
    c.classes = classes.items;
    c.attrs = attrs.items;
    c.pseudos = pseudos.items;
    return c;
}

fn parseAttr(p: *SelParser) Unsupported!AttrSel {
    p.i += 1; // [
    _ = p.ws();
    const name = p.ident() orelse return error.Unsupported;
    _ = p.ws();
    var sel = AttrSel{ .name = name, .op = .exists, .val = "", .ci = false };
    const ch = p.peek() orelse return error.Unsupported;
    if (ch == ']') {
        p.i += 1;
        return sel;
    }
    if (ch == '=') {
        sel.op = .eq;
        p.i += 1;
    } else {
        if (p.i + 1 >= p.s.len or p.s[p.i + 1] != '=') return error.Unsupported;
        sel.op = switch (ch) {
            '~' => .includes,
            '|' => .dash,
            '^' => .prefix,
            '$' => .suffix,
            '*' => .substr,
            else => return error.Unsupported,
        };
        p.i += 2;
    }
    _ = p.ws();
    const q = p.peek() orelse return error.Unsupported;
    if (q == '"' or q == '\'') {
        const end = std.mem.indexOfScalarPos(u8, p.s, p.i + 1, q) orelse return error.Unsupported;
        sel.val = p.s[p.i + 1 .. end];
        p.i = end + 1;
    } else {
        sel.val = p.ident() orelse return error.Unsupported;
    }
    _ = p.ws();
    if (p.peek()) |f| {
        if (f == 'i' or f == 'I') {
            sel.ci = true;
            p.i += 1;
        } else if (f == 's' or f == 'S') p.i += 1;
    }
    _ = p.ws();
    if (p.peek() != ']') return error.Unsupported;
    p.i += 1;
    return sel;
}

fn parsePseudo(p: *SelParser) Unsupported!Pseudo {
    p.i += 1; // :
    if (p.peek() == ':') return error.Unsupported; // pseudo-element
    const raw = p.ident() orelse return error.Unsupported;
    var buf: [48]u8 = undefined;
    if (raw.len > buf.len) return error.Unsupported;
    const name = std.ascii.lowerString(&buf, raw);
    var arg: ?[]const u8 = null;
    if (p.peek() == '(') {
        const close = findTop(p.s, p.i + 1, ")") orelse return error.Unsupported;
        arg = p.s[p.i + 1 .. close];
        p.i = close + 1;
    }
    const E = std.mem.eql;
    if (arg) |x| {
        if (E(u8, name, "not")) return .{ .not = try parseSelectorList(p.a, x, false) };
        if (E(u8, name, "is") or E(u8, name, "matches") or E(u8, name, "-webkit-any") or E(u8, name, "any")) {
            return .{ .is = parseSelectorList(p.a, x, true) catch |e| switch (e) {
                error.Unsupported => return .never,
                else => return e,
            } };
        }
        if (E(u8, name, "where")) {
            const list = parseSelectorList(p.a, x, true) catch |e| switch (e) {
                error.Unsupported => return .never,
                else => return e,
            };
            // zero specificity
            const copy = try p.a.alloc(Complex, list.len);
            for (list, copy) |src, *dst| dst.* = .{ .parts = src.parts, .combs = src.combs, .spec = 0 };
            return .{ .is = copy };
        }
        if (E(u8, name, "nth-child")) return .{ .nth_child = try parseNth(x) };
        if (E(u8, name, "nth-last-child")) return .{ .nth_last_child = try parseNth(x) };
        if (E(u8, name, "nth-of-type")) return .{ .nth_of_type = try parseNth(x) };
        return .never; // :has(), :lang(), :dir(), :host(), …
    }
    const simple = .{
        .{ "root", Pseudo.root },               .{ "scope", Pseudo.root },
        .{ "first-child", Pseudo.first_child }, .{ "last-child", Pseudo.last_child },
        .{ "only-child", Pseudo.only_child },   .{ "first-of-type", Pseudo.first_of_type },
        .{ "last-of-type", Pseudo.last_of_type }, .{ "empty", Pseudo.empty },
        .{ "link", Pseudo.link },               .{ "any-link", Pseudo.link },
        .{ "checked", Pseudo.checked },         .{ "disabled", Pseudo.disabled },
        .{ "enabled", Pseudo.enabled },         .{ "defined", Pseudo.defined },
    };
    inline for (simple) |kv| {
        if (E(u8, name, kv[0])) return kv[1];
    }
    // Legacy single-colon pseudo-elements.
    const elems = [_][]const u8{ "before", "after", "first-line", "first-letter", "selection", "placeholder", "marker", "backdrop" };
    for (elems) |e| if (E(u8, name, e)) return error.Unsupported;
    if (std.mem.startsWith(u8, name, "-webkit-") or std.mem.startsWith(u8, name, "-moz-") or std.mem.startsWith(u8, name, "-ms-")) return error.Unsupported;
    return .never; // :hover, :focus, :active, :visited, :target, …
}

fn parseNth(raw: []const u8) Unsupported!Nth {
    var buf: [32]u8 = undefined;
    var n: usize = 0;
    for (raw) |ch| {
        if (std.ascii.isWhitespace(ch)) continue;
        if (n == buf.len) return error.Unsupported;
        buf[n] = std.ascii.toLower(ch);
        n += 1;
    }
    const s = buf[0..n];
    if (std.mem.eql(u8, s, "odd")) return .{ .a = 2, .b = 1 };
    if (std.mem.eql(u8, s, "even")) return .{ .a = 2, .b = 0 };
    if (std.mem.indexOf(u8, s, "of") != null) return error.Unsupported;
    if (std.mem.indexOfScalar(u8, s, 'n')) |ni| {
        const as = s[0..ni];
        const a: i32 = if (as.len == 0 or std.mem.eql(u8, as, "+")) 1 else if (std.mem.eql(u8, as, "-")) -1 else std.fmt.parseInt(i32, as, 10) catch return error.Unsupported;
        const bs = s[ni + 1 ..];
        const b: i32 = if (bs.len == 0) 0 else std.fmt.parseInt(i32, if (bs[0] == '+') bs[1..] else bs, 10) catch return error.Unsupported;
        return .{ .a = a, .b = b };
    }
    return .{ .a = 0, .b = std.fmt.parseInt(i32, s, 10) catch return error.Unsupported };
}

fn nthMatches(nth: Nth, k: i32) bool {
    if (nth.a == 0) return k == nth.b;
    const d = k - nth.b;
    return @rem(d, nth.a) == 0 and @divTrunc(d, nth.a) >= 0;
}

// ---- matching -------------------------------------------------------------------

fn parentElement(doc: *const dom.Document, idx: u32) ?u32 {
    const p = doc.get(idx).parent;
    if (p == dom.none or doc.get(p).kind != .element) return null;
    return p;
}

fn prevElement(doc: *const dom.Document, idx: u32) ?u32 {
    const p = doc.get(idx).parent;
    if (p == dom.none) return null;
    var last: ?u32 = null;
    var it = doc.children(p);
    while (it.next()) |c| {
        if (c == idx) return last;
        if (doc.get(c).kind == .element) last = c;
    }
    return null;
}

/// 1-based position among element siblings (optionally of the same type), and the count.
fn position(doc: *const dom.Document, idx: u32, same_type: bool) struct { k: i32, n: i32 } {
    const p = doc.get(idx).parent;
    if (p == dom.none) return .{ .k = 1, .n = 1 };
    const name = doc.get(idx).name;
    var k: i32 = 0;
    var n: i32 = 0;
    var it = doc.children(p);
    while (it.next()) |c| {
        const cn = doc.get(c);
        if (cn.kind != .element) continue;
        if (same_type and !std.mem.eql(u8, cn.name, name)) continue;
        n += 1;
        if (c == idx) k = n;
    }
    return .{ .k = k, .n = n };
}

fn matchComplex(doc: *const dom.Document, idx: u32, cx: *const Complex, i: usize) bool {
    if (!matchCompound(doc, idx, &cx.parts[i])) return false;
    if (i + 1 == cx.parts.len) return true;
    switch (cx.combs[i]) {
        .child => {
            const p = parentElement(doc, idx) orelse return false;
            return matchComplex(doc, p, cx, i + 1);
        },
        .descendant => {
            var p = parentElement(doc, idx);
            while (p) |pi| : (p = parentElement(doc, pi)) {
                if (matchComplex(doc, pi, cx, i + 1)) return true;
            }
            return false;
        },
        .next => {
            const s = prevElement(doc, idx) orelse return false;
            return matchComplex(doc, s, cx, i + 1);
        },
        .subsequent => {
            var s = prevElement(doc, idx);
            while (s) |si| : (s = prevElement(doc, si)) {
                if (matchComplex(doc, si, cx, i + 1)) return true;
            }
            return false;
        },
    }
}

fn hasClass(list: []const u8, c: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, list, " \t\r\n\x0c");
    while (it.next()) |t| if (std.mem.eql(u8, t, c)) return true;
    return false;
}

fn matchCompound(doc: *const dom.Document, idx: u32, c: *const Compound) bool {
    const node = doc.get(idx);
    if (node.kind != .element) return false;
    if (c.tag) |t| if (!std.mem.eql(u8, node.name, t)) return false;
    if (c.id) |id| {
        const v = node.attr("id") orelse return false;
        if (!std.mem.eql(u8, v, id)) return false;
    }
    if (c.classes.len > 0) {
        const cls = node.attr("class") orelse return false;
        for (c.classes) |want| if (!hasClass(cls, want)) return false;
    }
    for (c.attrs) |at| if (!matchAttr(node, at)) return false;
    for (c.pseudos) |ps| if (!matchPseudo(doc, idx, ps)) return false;
    return true;
}

fn matchAttr(node: *const dom.Node, at: AttrSel) bool {
    const v = node.attr(at.name) orelse return false;
    const same = struct {
        fn f(ci: bool, x: []const u8, y: []const u8) bool {
            return if (ci) std.ascii.eqlIgnoreCase(x, y) else std.mem.eql(u8, x, y);
        }
    }.f;
    return switch (at.op) {
        .exists => true,
        .eq => same(at.ci, v, at.val),
        .includes => blk: {
            var it = std.mem.tokenizeAny(u8, v, " \t\r\n");
            while (it.next()) |t| if (same(at.ci, t, at.val)) break :blk true;
            break :blk false;
        },
        .dash => same(at.ci, v, at.val) or (v.len > at.val.len and v[at.val.len] == '-' and same(at.ci, v[0..at.val.len], at.val)),
        .prefix => at.val.len > 0 and v.len >= at.val.len and same(at.ci, v[0..at.val.len], at.val),
        .suffix => at.val.len > 0 and v.len >= at.val.len and same(at.ci, v[v.len - at.val.len ..], at.val),
        .substr => at.val.len > 0 and (if (at.ci) std.ascii.indexOfIgnoreCase(v, at.val) != null else std.mem.indexOf(u8, v, at.val) != null),
    };
}

fn matchPseudo(doc: *const dom.Document, idx: u32, ps: Pseudo) bool {
    const node = doc.get(idx);
    return switch (ps) {
        .root => node.is("html"),
        .first_child => position(doc, idx, false).k == 1,
        .last_child => blk: {
            const p = position(doc, idx, false);
            break :blk p.k == p.n;
        },
        .only_child => position(doc, idx, false).n == 1,
        .first_of_type => position(doc, idx, true).k == 1,
        .last_of_type => blk: {
            const p = position(doc, idx, true);
            break :blk p.k == p.n;
        },
        .nth_child => |n| nthMatches(n, position(doc, idx, false).k),
        .nth_last_child => |n| blk: {
            const p = position(doc, idx, false);
            break :blk nthMatches(n, p.n - p.k + 1);
        },
        .nth_of_type => |n| nthMatches(n, position(doc, idx, true).k),
        .empty => blk: {
            var it = doc.children(idx);
            while (it.next()) |c| {
                const cn = doc.get(c);
                if (cn.kind == .element or (cn.kind == .text and cn.text.len > 0)) break :blk false;
            }
            break :blk true;
        },
        .link => (node.is("a") or node.is("area")) and node.attr("href") != null,
        .checked => node.attr("checked") != null or node.attr("selected") != null,
        .disabled => node.attr("disabled") != null,
        .enabled => node.attr("disabled") == null and (node.is("input") or node.is("button") or node.is("select") or node.is("textarea")),
        // Without scripts no custom element is ever defined.
        .defined => std.mem.indexOfScalar(u8, node.name, '-') == null,
        .never => false,
        .not => |list| blk: {
            for (list) |*cx| if (matchComplex(doc, idx, cx, 0)) break :blk false;
            break :blk true;
        },
        .is => |list| blk: {
            for (list) |*cx| if (matchComplex(doc, idx, cx, 0)) break :blk true;
            break :blk false;
        },
    };
}

// ---- @media ---------------------------------------------------------------------

/// Evaluate a (lower-cased) media query list against the viewport.
pub fn mediaMatches(query: []const u8, w: f32, h: f32) bool {
    var any = false;
    var list = std.mem.splitScalar(u8, query, ',');
    while (list.next()) |q_raw| {
        any = true;
        var q = std.mem.trim(u8, q_raw, " \t\r\n");
        var negate = false;
        if (std.mem.startsWith(u8, q, "not ")) {
            negate = true;
            q = q[4..];
        }
        if (std.mem.startsWith(u8, q, "only ")) q = q[5..];
        if (queryMatches(q, w, h) != negate) return true;
    }
    return !any;
}

fn queryMatches(q: []const u8, w: f32, h: f32) bool {
    var parts = std.mem.splitSequence(u8, q, " and ");
    while (parts.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t\r\n()");
        if (p.len == 0) continue;
        if (std.mem.eql(u8, p, "screen") or std.mem.eql(u8, p, "all")) continue;
        if (std.mem.eql(u8, p, "print") or std.mem.eql(u8, p, "speech")) return false;
        if (!featureMatches(p, w, h)) return false;
    }
    return true;
}

fn lengthPx(v: []const u8) ?f32 {
    const t = std.mem.trim(u8, v, " ");
    if (std.mem.endsWith(u8, t, "px")) return std.fmt.parseFloat(f32, t[0 .. t.len - 2]) catch null;
    if (std.mem.endsWith(u8, t, "rem")) return (std.fmt.parseFloat(f32, t[0 .. t.len - 3]) catch return null) * 16;
    if (std.mem.endsWith(u8, t, "em")) return (std.fmt.parseFloat(f32, t[0 .. t.len - 2]) catch return null) * 16;
    return std.fmt.parseFloat(f32, t) catch null;
}

fn featureMatches(f: []const u8, w: f32, h: f32) bool {
    if (std.mem.indexOfScalar(u8, f, ':')) |colon| {
        const name = std.mem.trim(u8, f[0..colon], " ");
        const val = std.mem.trim(u8, f[colon + 1 ..], " ");
        const E = std.mem.eql;
        if (E(u8, name, "min-width")) return w >= (lengthPx(val) orelse return false);
        if (E(u8, name, "max-width")) return w <= (lengthPx(val) orelse return false);
        if (E(u8, name, "min-height")) return h >= (lengthPx(val) orelse return false);
        if (E(u8, name, "max-height")) return h <= (lengthPx(val) orelse return false);
        if (E(u8, name, "prefers-color-scheme")) return E(u8, val, "light");
        if (E(u8, name, "prefers-reduced-motion")) return E(u8, val, "no-preference");
        if (E(u8, name, "prefers-contrast")) return E(u8, val, "no-preference");
        if (E(u8, name, "hover") or E(u8, name, "any-hover")) return E(u8, val, "hover");
        if (E(u8, name, "pointer") or E(u8, name, "any-pointer")) return E(u8, val, "fine");
        if (E(u8, name, "orientation")) return E(u8, val, if (w >= h) "landscape" else "portrait");
        if (E(u8, name, "min-resolution") or E(u8, name, "-webkit-min-device-pixel-ratio")) return true;
        return false;
    }
    // Range syntax: `width >= 600px`, `600px < width`, `400px <= width <= 700px`.
    if (std.mem.indexOf(u8, f, "width") != null or std.mem.indexOf(u8, f, "height") != null) {
        const dim: f32 = if (std.mem.indexOf(u8, f, "width") != null) w else h;
        const name = if (std.mem.indexOf(u8, f, "width") != null) "width" else "height";
        const at = std.mem.indexOf(u8, f, name).?;
        const left = std.mem.trim(u8, f[0..at], " ");
        const right = std.mem.trim(u8, f[at + name.len ..], " ");
        if (right.len > 0 and !rangeOk(dim, right, false)) return false;
        if (left.len > 0 and !rangeOk(dim, left, true)) return false;
        return true;
    }
    return std.mem.eql(u8, f, "color");
}

/// `side` is "OP value" (right of the feature) or "value OP" (left, flipped).
fn rangeOk(dim: f32, side: []const u8, flipped: bool) bool {
    const ops = [_][]const u8{ ">=", "<=", ">", "<", "=" };
    for (ops) |op| {
        if (flipped) {
            if (std.mem.endsWith(u8, side, op)) {
                const v = lengthPx(side[0 .. side.len - op.len]) orelse return false;
                return cmp(v, op, dim);
            }
        } else if (std.mem.startsWith(u8, side, op)) {
            const v = lengthPx(side[op.len..]) orelse return false;
            return cmp(dim, op, v);
        }
    }
    return false;
}

fn cmp(x: f32, op: []const u8, y: f32) bool {
    if (std.mem.eql(u8, op, ">=")) return x >= y;
    if (std.mem.eql(u8, op, "<=")) return x <= y;
    if (std.mem.eql(u8, op, ">")) return x > y;
    if (std.mem.eql(u8, op, "<")) return x < y;
    return x == y;
}

test "selector matching basics" {
    const t = std.testing;
    try t.expect(mediaMatches("screen and (min-width: 600px)", 1000, 800));
    try t.expect(!mediaMatches("(max-width: 600px)", 1000, 800));
    try t.expect(mediaMatches("(width >= 600px)", 1000, 800));
    try t.expect(!mediaMatches("print", 1000, 800));
    try t.expect(nthMatches(.{ .a = 2, .b = 1 }, 3));
    try t.expect(!nthMatches(.{ .a = 2, .b = 1 }, 4));
    const n = try parseNth("-n+3");
    try t.expect(nthMatches(n, 3) and !nthMatches(n, 4));
}

// ---- DOM API: querySelector / matches -----------------------------------------------

pub const SelectorError = error{ SyntaxError, OutOfMemory };

fn compile(a: Allocator, selector: []const u8) SelectorError![]const Complex {
    const clean = stripComments(a, selector) catch return error.OutOfMemory;
    return parseSelectorList(a, std.mem.trim(u8, clean, " \t\r\n"), false) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Unsupported => error.SyntaxError,
    };
}

/// Descendants of `root` (in document order) matching `selector`.
pub fn select(a: Allocator, doc: *const dom.Document, root: u32, selector: []const u8, first_only: bool, out: *std.ArrayList(u32)) SelectorError!void {
    const list = try compile(a, selector);
    try selectIn(doc, root, list, first_only, out, 0);
}

fn selectIn(doc: *const dom.Document, i: u32, list: []const Complex, first_only: bool, out: *std.ArrayList(u32), depth: u32) SelectorError!void {
    if (depth > 512) return;
    var it = doc.children(i);
    while (it.next()) |c| {
        if (doc.get(c).kind == .element) {
            for (list) |*cx| {
                if (matchComplex(doc, c, cx, 0)) {
                    try out.append(c);
                    if (first_only) return;
                    break;
                }
            }
        }
        try selectIn(doc, c, list, first_only, out, depth + 1);
        if (first_only and out.items.len > 0) return;
    }
}

pub fn matches(a: Allocator, doc: *const dom.Document, i: u32, selector: []const u8) SelectorError!bool {
    if (doc.get(i).kind != .element) return false;
    const list = try compile(a, selector);
    for (list) |*cx| if (matchComplex(doc, i, cx, 0)) return true;
    return false;
}
