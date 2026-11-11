//! R4SRV alone owns first-installation credentials and the bounded HTTPS job.
const std = @import("std");
const r = @import("r4os");
const credentials = r.server_credentials;
const empty_body_headers = "content-length:0\n";
pub const Result = union(enum) { secret: credentials.Secret, failure: r.server_access.EnsureResponse };

pub fn load(app: *const r.App2, scratch: []u8, profile: r.server_profile.Profile, target: r.server_targets.Target, component: r.server_targets.Component, budget: *r.rpc_budget.Budget) Result {
    const ctx = app.system();
    var failure: r.server_access.EnsureResponse = .{ .code = @intFromEnum(r.server_access.Code.credentials) };
    // An explicit operator file wins; malformed data is never silently replaced.
    if (credentials.load(&ctx, .registration)) |secret| return .{ .secret = secret } else |err| switch (err) {
        error.CredentialsMissing, error.SecretMissing => {},
        else => return .{ .failure = failure },
    }
    if (!credentials.publicBootstrapAllowed(profile, target, component)) return .{ .failure = failure };
    if (credentials.loadPublic(&ctx)) |secret| return .{ .secret = secret } else |err| {
        if (err != error.CredentialsMissing) return .{ .failure = failure };
    }
    failure.code = @intFromEnum(r.server_access.Code.transport_unavailable);
    var web = app.web() orelse return .{ .failure = failure };
    failure.attempted = 1;
    var raw: [2048]u8 = undefined;
    var body: [512]u8 = undefined;
    defer std.crypto.secureZero(u8, &raw);
    defer std.crypto.secureZero(u8, &body);
    defer std.crypto.secureZero(u8, scratch);
    var timeout = r.rpc_budget.remainingTimeout(budget) catch return .{ .failure = failure };
    timeout.nanoseconds = @min(timeout.nanoseconds, 5_000_000_000);
    const result = web.fetch(credentials.bootstrap_url, &raw, &body, scratch, .{
        .method = .post,
        // The bootstrap contract requires a declared empty body.
        .headers = empty_body_headers,
        .timeout = timeout,
        .progress = ownerRunning,
        .progress_context = @constCast(&ctx),
        .redirect = .error_mode,
        .redirect_limit = 0,
    });
    const response = switch (result) {
        .response => |value| value,
        .failure => |cause| {
            failure.code = @intFromEnum(r.server_access.Code.transport);
            failure.detail = @intFromEnum(cause);
            return .{ .failure = failure };
        },
    };
    failure.code = @intFromEnum(r.server_access.Code.bootstrap);
    failure.detail = response.status;
    if (!response.secure or !std.mem.eql(u8, response.final_url.bytes(), credentials.bootstrap_url) or
        response.status != 201 or response.content_type == null or
        !std.mem.eql(u8, response.content_type.?, credentials.bootstrap_content_type)) return .{ .failure = failure };
    var secret = credentials.parsePublic(response.body) catch return .{ .failure = failure };
    const files = app.files() orelse {
        secret.clear();
        failure.code = @intFromEnum(r.server_access.Code.credentials_write);
        return .{ .failure = failure };
    };
    credentials.persistPublic(&files, response.body, ctx.ticks()) catch {
        secret.clear();
        // A concurrent creator may have won the create-only atomic publish.
        if (credentials.loadPublic(&ctx)) |existing| return .{ .secret = existing } else |_| {}
        failure.code = @intFromEnum(r.server_access.Code.credentials_write);
        return .{ .failure = failure };
    };
    return .{ .secret = secret };
}

fn ownerRunning(raw: ?*anyopaque) callconv(.c) bool {
    const sys: *const r.r4sys.Context = @ptrCast(@alignCast(raw orelse return false));
    return !sys.programShouldClose();
}

test "bootstrap serializes one explicit empty POST length" {
    var output: [1024]u8 = undefined;
    const url = r.http.parseUrl(credentials.bootstrap_url).value;
    const request = r.http.buildRequest(&output, .post, url, .{ .headers = empty_body_headers }).bytes;
    try std.testing.expect(std.mem.startsWith(u8, request, "POST /api/v1/registration/bootstrap HTTP/1.1\r\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, request, "content-length: 0\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, request, "Transfer-Encoding:") == null);
    try std.testing.expect(std.mem.endsWith(u8, request, "\r\n\r\n"));
}
