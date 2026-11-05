const std = @import("std");
const r4os = @import("r4os");
const access = r4os.server_access;
const bootstrap = @import("bootstrap.zig");

const timeout_ns: u64 = 5_000_000_000;

const NetworkPath = struct {
    local_ip: [4]u8,
    gateway_ip: [4]u8,
    mac: [6]u8,
    adapter_name: [32]u8,
};

const Entry = struct {
    valid: bool = false,
    profile: r4os.server_profile.Profile = .public,
    ip: [4]u8 = .{0} ** 4,
    generation: u32 = 0,
};

const Failed = struct {
    profile: r4os.server_profile.Profile,
    ip: [4]u8,
    response: access.EnsureResponse,
    retry_at: u64,
};

const Runtime = struct {
    app: ?*r4os.App = null,
    last_path: ?NetworkPath = null,
    last_profile: ?r4os.server_profile.Profile = null,
    entries: [3]Entry = .{Entry{}} ** 3,
    next_slot: usize = 0,
    generation: u32 = 0,
    failures: [3]?Failed = .{null} ** 3,
    next_failure: usize = 0,
    scratch: [r4os.app_web.tls_scratch_bytes]u8 = undefined,

    fn clear(self: *Runtime) void {
        self.entries = .{Entry{}} ** 3;
        self.next_slot = 0;
        self.failures = .{null} ** 3;
        self.next_failure = 0;
    }

    fn recentFailure(self: *Runtime, profile: r4os.server_profile.Profile, ip: [4]u8, port: u16, now: u64) ?access.EnsureResponse {
        for (&self.failures) |*slot| if (slot.*) |failure| {
            if (now >= failure.retry_at) {
                slot.* = null;
                continue;
            }
            if (failure.profile == profile and std.mem.eql(u8, &failure.ip, &ip)) {
                var response = failure.response;
                response.attempted = 0;
                response.port = port;
                return response;
            }
        };
        return null;
    }

    fn rememberFailure(self: *Runtime, profile: r4os.server_profile.Profile, ip: [4]u8, response: access.EnsureResponse, retry_at: u64) void {
        self.failures[self.next_failure] = .{ .profile = profile, .ip = ip, .response = response, .retry_at = retry_at };
        self.next_failure = (self.next_failure + 1) % self.failures.len;
    }

    fn nextGeneration(self: *Runtime) u32 {
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        return self.generation;
    }

    fn find(self: *Runtime, profile: r4os.server_profile.Profile, ip: [4]u8) ?*Entry {
        for (&self.entries) |*entry| {
            if (entry.valid and entry.profile == profile and std.mem.eql(u8, &entry.ip, &ip)) return entry;
        }
        return null;
    }

    fn remember(self: *Runtime, profile: r4os.server_profile.Profile, ip: [4]u8) u32 {
        var slot: ?*Entry = null;
        for (&self.entries) |*entry| {
            if (!entry.valid) {
                slot = entry;
                break;
            }
        }
        if (slot == null) {
            slot = &self.entries[self.next_slot];
            self.next_slot = (self.next_slot + 1) % self.entries.len;
        }
        const generation = self.nextGeneration();
        slot.?.* = .{ .valid = true, .profile = profile, .ip = ip, .generation = generation };
        return generation;
    }
};

var runtime: Runtime = .{};

pub fn r4_app_main(app: *r4os.App) i32 {
    const ctx = app.system();
    const services = app.services() orelse return r4os.abi.service_api_result_invalid;
    runtime = .{ .app = app };
    var endpoint = switch (services.register(access.service_name, 0)) {
        .endpoint => |value| value,
        .failure => |raw| return raw,
    };
    ctx.println("R4SRV ready");
    var loop = r4os.ServiceLoop.init(ctx, endpoint.raw, .{});
    while (true) {
        switch (loop.wait(null)) {
            .requests => |pending| {
                const result = loop.drain(pending, handleRequest, .{ &ctx, &endpoint });
                if (result >= 0) continue;
                _ = endpoint.unregister();
                return result;
            },
            .idle, .deadline => {},
            .stop => break,
            .failure => |raw| {
                _ = endpoint.unregister();
                return raw;
            },
        }
    }
    loop.report(std.mem.span(access.service_name));
    _ = endpoint.unregister();
    ctx.println("R4SRV stopped cleanly");
    return 0;
}

fn handleRequest(_: *const r4os.r4sys.Context, endpoint: *r4os.ServiceEndpoint) i32 {
    var payload: [r4os.abi.service_api_max_payload]u8 = undefined;
    const message = switch (endpoint.recv(payload[0..])) {
        .message => |value| value,
        .would_block => return 0,
        .failure => |raw| return raw,
    };
    if (message.header.op != access.op_ensure) {
        return endpoint.replyIfPending(message.header.request_id, r4os.abi.service_api_result_bad_op, "");
    }
    var response: access.EnsureResponse = .{};
    if (message.bytes == @sizeOf(access.EnsureRequest)) {
        var request: access.EnsureRequest = .{};
        @memcpy(std.mem.asBytes(&request), payload[0..message.bytes]);
        response = ensure(&runtime, request);
    }
    return endpoint.replyIfPending(message.header.request_id, r4os.abi.service_api_result_ok, std.mem.asBytes(&response));
}

fn ensure(state: *Runtime, request: access.EnsureRequest) access.EnsureResponse {
    var response: access.EnsureResponse = .{};
    if (request.reserved != 0 or request.force > 1) return response;
    const component: r4os.server_targets.Component = switch (request.component) {
        0 => .app_center,
        1 => .updates,
        2 => .benchmarks,
        else => return response,
    };
    const app = state.app orelse return response;
    const ctx = app.system();
    const profile = r4os.server_profile.load(&ctx) catch {
        response.code = @intFromEnum(access.Code.profile);
        return response;
    };
    response.profile = @intFromEnum(profile);
    const target = r4os.server_targets.read(&ctx, component) catch {
        response.code = @intFromEnum(access.Code.target);
        return response;
    };
    response.target_ip = target.ip.octets;
    response.port = target.port;

    var network_config: r4os.abi.NetConfigSnapshot = .{};
    if (app.lowLevel().netConfigGet(&network_config) < 0 or
        std.mem.eql(u8, &network_config.local_ip, &.{ 0, 0, 0, 0 }))
    {
        state.clear();
        state.last_path = null;
        response.code = @intFromEnum(access.Code.network);
        return response;
    }
    const path = NetworkPath{
        .local_ip = network_config.local_ip,
        .gateway_ip = network_config.gateway_ip,
        .mac = network_config.mac,
        .adapter_name = network_config.adapter_name,
    };
    if (state.last_profile == null or state.last_profile.? != profile or
        state.last_path == null or !std.meta.eql(state.last_path.?, path))
    {
        state.clear();
        state.last_profile = profile;
        state.last_path = path;
    }

    if (state.find(profile, target.ip.octets)) |entry| {
        if (request.force == 0 or request.observed_generation != entry.generation) {
            response.code = @intFromEnum(access.Code.ok);
            response.generation = entry.generation;
            return response;
        }
        entry.valid = false;
    }

    if (state.recentFailure(profile, target.ip.octets, target.port, ctx.ticks())) |failed| return failed;
    defer if (response.code != @intFromEnum(access.Code.ok) and response.attempted == 1) {
        state.rememberFailure(profile, target.ip.octets, response, ctx.ticks() +| ctx.monotonicHz() *| 5);
    };
    var secret = switch (bootstrap.load(app, &state.scratch, profile, target, component)) {
        .secret => |value| value,
        .failure => |failed| {
            response.code = failed.code;
            response.detail = failed.detail;
            response.attempted = failed.attempted;
            return response;
        },
    };
    defer secret.clear();
    var web = app.web() orelse {
        response.code = @intFromEnum(access.Code.transport_unavailable);
        return response;
    };
    response.attempted = 1;
    const endpoint = r4os.app_web.RegistrationEndpoint{
        .address = target.ip,
        .hostname = target.host(),
        .port = r4os.server_targets.registration_port,
        .tls = profile.registrationUsesTls(),
    };
    const timeout = r4os.time_contract.timeoutFinite(r4os.time_contract.durationFromNanoseconds(timeout_ns));
    switch (web.registerServer(endpoint, secret.bytes(), &state.scratch, timeout)) {
        .accepted => {
            response.code = @intFromEnum(access.Code.ok);
            response.generation = state.remember(profile, target.ip.octets);
        },
        .invalid_secret => response.code = @intFromEnum(access.Code.invalid_secret),
        .invalid_reply => response.code = @intFromEnum(access.Code.invalid_reply),
        .failure => |failure| {
            response.code = @intFromEnum(access.Code.transport);
            response.detail = @intFromEnum(failure);
        },
    }
    return response;
}

test "registration generations and failed single flight expire or clear on path changes" {
    std.testing.refAllDecls(bootstrap);
    var state: Runtime = .{};
    const ip = [4]u8{ 138, 201, 253, 143 };
    const first = state.remember(.public, ip);
    try std.testing.expect(first != 0);
    try std.testing.expectEqual(first, state.find(.public, ip).?.generation);
    try std.testing.expect(state.find(.lan, ip) == null);
    const response: access.EnsureResponse = .{ .code = @intFromEnum(access.Code.bootstrap), .detail = 429, .attempted = 1, .profile = @intFromEnum(r4os.server_profile.Profile.public), .target_ip = ip, .port = 4022 };
    state.rememberFailure(.public, ip, response, 50);
    try std.testing.expect(state.recentFailure(.lan, ip, 4022, 40) == null);
    try std.testing.expectEqual(@as(u8, 0), state.recentFailure(.public, ip, 4022, 49).?.attempted);
    try std.testing.expectEqual(@as(u16, 429), state.recentFailure(.public, ip, 4022, 49).?.detail);
    try std.testing.expect(state.recentFailure(.public, ip, 4022, 50) == null);
    state.rememberFailure(.public, ip, response, 100);
    try std.testing.expectEqual(@as(u16, 4023), state.recentFailure(.public, ip, 4023, 51).?.port);
    state.clear();
    try std.testing.expect(state.find(.public, ip) == null);
    try std.testing.expect(state.recentFailure(.public, ip, 4022, 51) == null);
    try std.testing.expect(state.remember(.public, ip) != first);
}
