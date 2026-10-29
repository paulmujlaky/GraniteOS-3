//! HTTP/1.1 requests over the net service, with HTTPS through `tls.zig` trusting the certificate authorities the net service
//! keeps; the TLS session runs in the calling app, apart from every other app's.

const std = @import("std");

const api = @import("root.zig");
const Tls = @import("tls.zig");

const net = api.net;
const Bundle = std.crypto.Certificate.Bundle;

pub const HttpError = net.NetError || error{ Malformed, Unsupported, Redirects, Untrusted, Broken };

pub const Method = std.http.Method;
pub const Header = std.http.Header;

/// An `http://` or `https://` address, split into the parts a request needs.
pub const Url = struct {

    secure: bool,
    host: []const u8,
    port: u16,

    /// The path and query, never empty.
    target: []const u8,

    pub fn parse(text: []const u8) ?Url {

        const secure = std.ascii.startsWithIgnoreCase(text, "https://");
        if (!secure and !std.ascii.startsWithIgnoreCase(text, "http://")) return null;

        const rest = text[if (secure) 8 else 7 ..];
        const split = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
        const authority = rest[0..split];
        const colon = std.mem.lastIndexOfScalar(u8, authority, ':');
        const host = authority[0 .. colon orelse authority.len];

        if (host.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return null;

        const target = rest[split..];
        const fragment = std.mem.indexOfScalar(u8, target, '#') orelse target.len;

        return .{

            .secure = secure,
            .host = host,
            .port = if (colon) |at| std.fmt.parseInt(u16, authority[at + 1 ..], 10) catch return null else if (secure) 443 else 80,
            .target = if (fragment == 0 or target[0] != '/') "/" else target[0..fragment],

        };

    }

};

/// What to ask of an address: GET with no headers and no body unless told otherwise.
pub const Request = struct {

    method: Method = .GET,

    /// Sent after our own; one naming `Accept` or `User-Agent` replaces ours, and one naming `Host`, `Connection`,
    /// `Content-Length`, or an encoding is left out, as the request sets those itself.
    headers: []const Header = &.{},

    body: []const u8 = "",

};

/// Trusted roots, read from the net service on first use and kept for the life of the app.
var bundle: ?Bundle = null;

/// A response whose body is read as it arrives, for one too long to hold or one that never ends, such as a radio station's.
/// It stays where `open` put it until `close`, as its streams point into it.
pub const Response = struct {

    status: u16,

    /// The status line and headers, ending in a blank line; a Shoutcast `ICY` status line reads as HTTP/1.0.
    head: []const u8,

    /// The body, out of its chunks when it came in them.
    body: *std.Io.Reader,

    /// Where the final response sends on to, for a redirect.
    location: ?[]const u8,

    allocator: std.mem.Allocator,
    buffers: []u8,
    socket: net.Socket,
    stream: net.Stream,
    session: Tls,
    reader: std.http.Reader,
    transfer: [64]u8,

    /// The value of header `name`, whatever its case.
    pub fn header(self: *const Response, name: []const u8) ?[]const u8 {

        var lines = std.mem.splitSequence(u8, self.head, "\r\n");

        _ = lines.next();

        while (lines.next()) |line| {

            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;

            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) return std.mem.trim(u8, line[colon + 1 ..], " \t");

        }

        return null;

    }

    /// Why the last read of `body` failed.
    pub fn failure(self: *const Response) HttpError {

        return self.stream.failure orelse error.Broken;

    }

    pub fn close(self: *Response) void {

        self.socket.close();
        self.allocator.free(self.buffers);

    }

};

/// Fetches `url` as `send` does with a plain GET.
pub fn get(allocator: std.mem.Allocator, url: []const u8, sink: *std.Io.Writer) HttpError!u16 {

    return send(allocator, url, .{}, sink, null);

}

/// Sends `request` to `url`, following up to five redirects, and writes the final response's body to `sink` and, when given,
/// its status line and headers to `head`; returns its status. `allocator` must outlive the app, which keeps the trusted roots.
pub fn send(allocator: std.mem.Allocator, url: []const u8, request: Request, sink: *std.Io.Writer, head: ?*std.Io.Writer) HttpError!u16 {

    var response: Response = undefined;

    try open(allocator, url, request, &response);
    defer response.close();

    if (head) |out| out.writeAll(std.mem.trimRight(u8, response.head, "\r\n")) catch return error.Broken;
    if (request.method == .HEAD) return response.status;

    _ = response.body.streamRemaining(sink) catch return response.failure();

    return response.status;

}

/// Sends `request` to `url` as `send` does, but leaves the final response in `out` with its body unread; close it after.
pub fn open(allocator: std.mem.Allocator, url: []const u8, request: Request, out: *Response) HttpError!void {

    var location: [2048]u8 = undefined;
    var moved: [2048]u8 = undefined;
    var current = url;
    var asked = request;

    for (0..6) |_| {

        if (current.len > location.len) return error.Malformed;

        // A redirect's address lives in the response it came in, so it moves to `location` first.
        std.mem.copyForwards(u8, location[0..current.len], current);
        current = location[0..current.len];

        const parsed = Url.parse(current) orelse return error.Malformed;

        try connect(allocator, parsed, asked, out);

        const code = out.status;

        if (code < 300 or code >= 400 or code == 304) return;

        const target = out.location orelse return;
        const length = resolve(parsed, target, &moved) catch |err| {

            out.close();
            return err;

        };

        out.close();
        current = moved[0..length];

        // As browsers do, a 303, or a 301 or 302 after a POST, asks again with GET and no body.
        if (code == 303 or (code <= 302 and asked.method == .POST)) asked = .{

            .headers = asked.headers,

        };

    }

    return error.Redirects;

}

/// Writes `text` for a URL's query: letters, digits, and `-._~` as they are, and everything else, spaces and accents too,
/// percent-encoded.
pub fn escape(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {

    for (text) |byte| {

        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~", byte) != null) {

            try writer.writeByte(byte);

        } else {

            try writer.print("%{X:0>2}", .{byte});

        }

    }

}

/// Why a request failed, as a short lowercase phrase to follow a name or a colon.
pub fn reason(err: HttpError) []const u8 {

    return switch (err) {

        error.Offline => "network unavailable",
        error.Refused => "connection refused",
        error.Timeout => "timed out",
        error.Cancelled => "cancelled",
        error.Missing => "not found",
        error.Denied => "permission denied",
        error.Full, error.Exhausted => "out of connections or memory",
        error.Untrusted => "certificate not trusted",
        error.Malformed, error.Unsupported => "unexpected address or response",
        error.Redirects => "too many redirects",
        error.Broken => "connection broken",
        error.Invalid => "invalid argument",
        else => "network service unavailable",

    };

}

/// Connects to `url`, sends `request`, and reads the response's head into `out`, leaving its body to read.
fn connect(allocator: std.mem.Allocator, url: Url, request: Request, out: *Response) HttpError!void {

    const address = try net.resolve(url.host);

    out.socket = try net.Socket.connect(.tcp, address, url.port);
    errdefer out.socket.close();

    // TLS reads whole records, so both directions buffer at least one; the head is kept after them, apart from the body.
    out.allocator = allocator;
    out.buffers = allocator.alloc(u8, 4 * Tls.min_buffer_len + head_most) catch return error.Exhausted;
    errdefer allocator.free(out.buffers);

    out.stream = out.socket.stream(out.buffers[0..Tls.min_buffer_len], out.buffers[Tls.min_buffer_len..][0..Tls.min_buffer_len]);

    var input = &out.stream.reader;
    var output = &out.stream.writer;

    if (url.secure) {

        out.session = Tls.init(input, output, .{

            .host = .{ .explicit = url.host },
            .ca = .{ .bundle = try trust(allocator) },
            .read_buffer = out.buffers[2 * Tls.min_buffer_len ..][0..Tls.min_buffer_len],
            .write_buffer = out.buffers[3 * Tls.min_buffer_len ..][0..Tls.min_buffer_len],
            .now = @intCast(net.utc()),
            .random = api.random,

        }) catch |err| return switch (err) {

            error.TlsCertificateNotVerified, error.CertificateHostMismatch, error.CertificateIssuerMismatch, error.CertificateExpired, error.CertificateNotYetValid, error.CertificateSignatureInvalid => error.Untrusted,
            else => out.failure(),

        };

        input = &out.session.reader;
        output = &out.session.writer;

    }

    ask(output, url, request) catch return out.failure();
    if (url.secure) out.stream.writer.flush() catch return out.failure();

    out.reader = .{

        .in = input,
        .interface = undefined,
        .state = .ready,
        .max_head_len = head_most,

    };

    const received = out.reader.receiveHead() catch return out.stream.failure orelse error.Malformed;
    const head = normal(out.buffers[4 * Tls.min_buffer_len ..], received) orelse return error.Malformed;
    const parsed = std.http.Client.Response.Head.parse(head) catch return error.Malformed;

    out.status = @intFromEnum(parsed.status);
    out.head = head;
    out.location = parsed.location;
    out.body = out.reader.bodyReader(&out.transfer, parsed.transfer_encoding, parsed.content_length);

}

/// The most a response's head may hold.
const head_most = 16 * 1024;

/// Copies `head` into `out`, where reading the body cannot move it, with a Shoutcast `ICY` status line read as HTTP/1.0.
fn normal(out: []u8, head: []const u8) ?[]const u8 {

    const icy = std.mem.startsWith(u8, head, "ICY ");
    const prefix = if (icy) "HTTP/1.0 " else "";
    const rest = if (icy) head[4..] else head;

    if (prefix.len + rest.len > out.len) return null;

    @memcpy(out[0..prefix.len], prefix);
    @memcpy(out[prefix.len..][0..rest.len], rest);

    return out[0 .. prefix.len + rest.len];

}

/// Writes `request` for `url`: its line, our headers and the caller's, and its body.
fn ask(output: *std.Io.Writer, url: Url, request: Request) std.Io.Writer.Error!void {

    try output.print("{s} {s} HTTP/1.1\r\nHost: {s}\r\n", .{ @tagName(request.method), url.target, url.host });
    if (!named(request.headers, "user-agent")) try output.writeAll("User-Agent: GraniteOS/3\r\n");
    if (!named(request.headers, "accept")) try output.writeAll("Accept: */*\r\n");
    try output.writeAll("Accept-Encoding: identity\r\nConnection: close\r\n");

    for (request.headers) |header| {

        if (ours(header.name)) continue;
        try output.print("{s}: {s}\r\n", .{ header.name, header.value });

    }

    if (request.body.len != 0 or request.method.requestHasBody()) try output.print("Content-Length: {d}\r\n", .{request.body.len});

    try output.writeAll("\r\n");
    try output.writeAll(request.body);
    try output.flush();

}

fn named(headers: []const Header, name: []const u8) bool {

    for (headers) |header| {

        if (std.ascii.eqlIgnoreCase(header.name, name)) return true;

    }

    return false;

}

/// Whether the request sets header `name` itself, whatever the caller says.
fn ours(name: []const u8) bool {

    for ([_][]const u8{ "host", "connection", "content-length", "transfer-encoding", "accept-encoding" }) |kept| {

        if (std.ascii.eqlIgnoreCase(name, kept)) return true;

    }

    return false;

}

/// Writes where redirect `moved` leads from `url` into `out`, returning its length.
fn resolve(url: Url, moved: []const u8, out: *[2048]u8) HttpError!usize {

    if (Url.parse(moved) != null) {

        if (moved.len > out.len) return error.Malformed;
        std.mem.copyForwards(u8, out[0..moved.len], moved);

        return moved.len;

    }

    // A path on the same server: absolute, or relative to the current one's folder.
    const folder = url.target[0 .. (std.mem.lastIndexOfScalar(u8, url.target, '/') orelse 0) + 1];
    const base = if (moved.len != 0 and moved[0] == '/') "" else folder;

    // `moved` lives in the response, not in `out`, so the two never overlap.
    const text = std.fmt.bufPrint(out, "{s}://{s}:{d}{s}{s}", .{ if (url.secure) "https" else "http", url.host, url.port, base, moved }) catch return error.Malformed;

    return text.len;

}

/// The trusted roots, parsed from the PEM the net service hands out.
fn trust(allocator: std.mem.Allocator) HttpError!Bundle {

    if (bundle) |kept| return kept;

    const pem = try net.roots(allocator);

    defer allocator.free(pem);

    const decoder = std.base64.standard.decoderWithIgnore(" \t\r\n");
    const now: i64 = @intCast(net.utc());
    const begin = "-----BEGIN CERTIFICATE-----";
    const end = "-----END CERTIFICATE-----";

    var result = Bundle{};
    var at: usize = 0;

    while (std.mem.indexOfPos(u8, pem, at, begin)) |found| {

        const start = found + begin.len;
        const stop = std.mem.indexOfPos(u8, pem, start, end) orelse break;
        const encoded = pem[start..stop];
        const decoded: u32 = @intCast(result.bytes.items.len);

        at = stop + end.len;

        result.bytes.ensureUnusedCapacity(allocator, encoded.len) catch return error.Exhausted;
        result.bytes.items.len += decoder.decode(result.bytes.unusedCapacitySlice(), encoded) catch continue;

        // A root that will not parse is left out rather than failing the rest; expired ones are left out anyway.
        result.parseCert(allocator, decoded, now) catch {

            result.bytes.items.len = decoded;

        };

    }

    bundle = result;

    return result;

}
