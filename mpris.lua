local ffi = require("ffi")
local bit = require("bit")

ffi.cdef[[
    char* strerror(int errno);

    void *malloc(size_t size);
    void free(void *ptr);

    ssize_t read(int fd, void* buf, size_t count);

    struct pollfd {
        int   fd;
        short events;
        short revents;
    };
    int poll(struct pollfd *fds, unsigned long nfds, int timeout);

    struct timespec {
        long tv_sec;
        long tv_nsec;
    };
    int clock_gettime(int clockid, struct timespec *tp);

    typedef struct sd_bus sd_bus;
    typedef struct sd_bus_message sd_bus_message;
    typedef struct sd_bus_error sd_bus_error;
    typedef struct sd_bus_slot sd_bus_slot;
    typedef int (*sd_bus_message_handler_t)(sd_bus_message *m, void *userdata, sd_bus_error *ret_error);
    typedef int (*sd_bus_property_get_t)(sd_bus *bus, const char *path, const char *interface, const char *property, sd_bus_message *reply, void *userdata, sd_bus_error *ret_error);
    typedef int (*sd_bus_property_set_t)(sd_bus *bus, const char *path, const char *interface, const char *property, sd_bus_message *value, void *userdata, sd_bus_error *ret_error);
    typedef struct sd_bus_vtable {
        uint64_t type_and_flags;
        union {
            struct {
                size_t element_size;
                uint64_t features;
                const unsigned *vtable_format_reference;
            } start;
            struct {
                size_t _reserved;
            } end;
            struct {
                const char *member;
                const char *signature;
                const char *result;
                sd_bus_message_handler_t handler;
                size_t offset;
                const char *names;
            } method;
            struct {
                const char *member;
                const char *signature;
                const char *names;
            } signal;
            struct {
                const char *member;
                const char *signature;
                sd_bus_property_get_t get;
                sd_bus_property_set_t set;
                size_t offset;
            } property;
        } x;
    } sd_bus_vtable;
    int sd_bus_default_user(sd_bus **bus);
    sd_bus *sd_bus_flush_close_unref(sd_bus *bus);
    int sd_bus_add_object_vtable(
        sd_bus *bus,
        sd_bus_slot **slot,
        const char *path,
        const char *interface,
        const sd_bus_vtable *vtable,
        void *userdata
    );
    int sd_bus_request_name(sd_bus *bus, const char *name, uint64_t flags);
    int sd_bus_release_name(sd_bus *bus, const char *name);
    int sd_bus_get_fd(sd_bus *bus);
    int sd_bus_get_events(sd_bus *bus);
    int sd_bus_get_timeout(sd_bus *bus, uint64_t *timeout_usec);
    int sd_bus_process(sd_bus *bus, sd_bus_message **ret);
    int sd_bus_reply_method_return(sd_bus_message *call, const char *types, ...);
    int sd_bus_message_append(sd_bus_message *call, const char *types, ...);
    int sd_bus_message_read(sd_bus_message *call, const char *types, ...);
    int sd_bus_error_set(sd_bus_error *e, const char *name, const char *message);
    int sd_bus_emit_signal(
        sd_bus *bus,
        const char *path,
        const char *interface,
        const char *member,
        const char *types,
        ...
    );
    int sd_bus_emit_properties_changed(
        sd_bus *bus,
        const char *path,
        const char *interface,
        const char *name,
        ...
    );
]]

local c_str_cache = {}

local c = function(s)
    local p = c_str_cache[s]
    if p ~= nil then return p end
    p = ffi.gc(ffi.C.malloc(#s + 1), ffi.C.free)
    ffi.copy(p, s)
    c_str_cache[s] = p
    return p
end

local callbacks = {}

local method = function(f)
    f = ffi.cast("sd_bus_message_handler_t", f)
    table.insert(callbacks, f)
    return f
end

local getter = function(f)
    f = ffi.cast("sd_bus_property_get_t", f)
    table.insert(callbacks, f)
    return f
end

local setter = function(f)
    f = ffi.cast("sd_bus_property_set_t", f)
    table.insert(callbacks, f)
    return f
end

local POLLIN = 1
local EINTR = 4
local INT_MAX = 2147483647
local CLOCK_MONOTONIC = 1
local BUS_ERROR_FAILED = c"org.freedesktop.DBus.Error.Failed"

local fatal = function(msg, errno)
    if errno ~= nil then
        msg = msg .. ": " .. ffi.string(ffi.C.strerror(errno))
    end
    error(msg)
end

local sd = ffi.load("/usr/lib/x86_64-linux-gnu/libsystemd.so.0")
local sd_vtable_format_reference = ffi.new("unsigned[1]")
sd_vtable_format_reference[0] = 242

local empty_reply = function(m)
    return sd.sd_bus_reply_method_return(m, "")
end
local error_reply = function(e, msg)
    return sd.sd_bus_error_set(e, BUS_ERROR_FAILED, msg)
end
local message_append = sd.sd_bus_message_append
local message_read = sd.sd_bus_message_read

local bus = ffi.new("sd_bus*[1]")
local r = sd.sd_bus_default_user(bus)
if r < 0 then
    fatal("sd_bus_default_user failed", -r)
end
bus = bus[0]

local make_vtable = function(t)
    local vt = ffi.new("sd_bus_vtable[?]", #t)
    for i, entry in ipairs(t) do
        local ventry = vt[i - 1]
        local tp = entry[1]
        ventry.type_and_flags = string.byte(tp)
        if tp == "<" then
            local start = ventry.x.start
            start.element_size = ffi.sizeof("sd_bus_vtable")
            start.features = 1
            start.vtable_format_reference = sd_vtable_format_reference
        elseif tp == ">" then
            ventry.x["end"]._reserved = 0
        elseif tp == "M" then
            local method = ventry.x.method
            method.member = entry[2]
            method.signature = entry[3]
            method.result = entry[4]
            method.handler = entry[5]
            method.offset = 0
            method.names = entry[6]
        elseif tp == "P" then
            local property = ventry.x.property
            ventry.type_and_flags = bit.bor(8192, ventry.type_and_flags)
            property.member = entry[2]
            property.signature = entry[3]
            property.get = entry[4]
            property.set = nil
            property.offset = 0
        elseif tp == "W" then
            local property = ventry.x.property
            ventry.type_and_flags = bit.bor(8192, ventry.type_and_flags)
            property.member = entry[2]
            property.signature = entry[3]
            property.get = entry[4]
            property.set = entry[5]
            property.offset = 0
        elseif tp == "S" then
            local signal = ventry.x.signal
            signal.member = entry[2]
            signal.signature = entry[3]
            signal.names = entry[4]
        else
            fatal("unknown vtable entry type")
        end
    end
    return vt
end

local mpris_def = {
    {"<"},
    {"M", c"Raise", c"", c"", method(function(m, ud, e)
        return error_reply(e, "not supported")
    end)},
    {"M", c"Quit", c"", c"", method(function(m, ud, e)
        local suc, err = mp.command("quit")
        if not suc then
            return error_reply(e, err)
        end
        return empty_reply(m)
    end)},
    {"P", c"CanQuit", c"b", getter(function(b, p, i, pp, m)
        return message_append(m, "b", ffi.cast("int", true))
    end)},
    {"W", c"Fullscreen", c"b", getter(function(b, p, i, pp, m)
        local v = mp.get_property_bool("fullscreen", false)
        return message_append(m, "b", ffi.cast("int", v))
    end), setter(function(b, p, i, pp, m, ud, e)
        local b = ffi.new("int[1]")
        local r = message_read(m, "b", b)
        if r < 0 then return r end
        local suc, err = mp.set_property_bool("fullscreen", b[0] ~= 0)
        if not suc then
            return error_reply(e, err)
        end
        return 0
    end)},
    {"P", c"CanSetFullscreen", c"b", getter(function(b, p, i, pp, m)
        local v = mp.get_property_bool("vo-configured", false)
        return message_append(m, "b", ffi.cast("int", v))
    end)},
    {"P", c"CanRaise", c"b", getter(function(b, p, i, pp, m)
        return message_append(m, "b", ffi.cast("int", false))
    end)},
    {"P", c"HasTrackList", c"b", getter(function(b, p, i, pp, m)
        return message_append(m, "b", ffi.cast("int", false))
    end)},
    {"P", c"Identity", c"s", getter(function(b, p, i, pp, m)
        return message_append(m, "s", "mpv")
    end)},
    {"P", c"DesktopEntry", c"s", getter(function(b, p, i, pp, m)
        return message_append(m, "s", "mpv")
    end)},
    {"P", c"SupportedUriSchemes", c"as", getter(function(b, p, i, pp, m)
        local schemes = {
            "ftp",
            "http",
            "https",
            "mms",
            "rtmp",
            "rtsp",
            "sftp",
            "smb"
        }
        return message_append(m, "as", ffi.cast("int", #schemes), unpack(schemes))
    end)},
    {"P", c"SupportedMimeTypes", c"as", getter(function(b, p, i, pp, m)
        local types = {}
        return message_append(m, "as", ffi.cast("int", #types), unpack(types))
    end)},
    {">"}
}
local mpris_vt = make_vtable(mpris_def)

local r = sd.sd_bus_add_object_vtable(
    bus,
    nil,
    "/org/mpris/MediaPlayer2",
    "org.mpris.MediaPlayer2",
    mpris_vt,
    nil
)
if r < 0 then
    fatal("sd_bus_add_object_vtable failed", -r)
end

local player_def = {
    {"<"},
    {"M", c"Next", c"", c"", method(function(m, ud, e)
        local suc, err = mp.command("playlist_next")
        if not suc then
            return error_reply(e, err)
        end
        return empty_reply(m)
    end)},
    {"M", c"Previous", c"", c"", method(function(m, ud, e)
        local suc, err = mp.command("playlist_prev")
        if not suc then
            return error_reply(e, err)
        end
        return empty_reply(m)
    end)},
    {"M", c"Pause", c"", c"", method(function(m, ud, e)
        local suc, err = mp.set_property_bool("pause", true)
        if not suc then
            return error_reply(e, err)
        end
        return empty_reply(m)
    end)},
    {"M", c"PlayPause", c"", c"", method(function(m, ud, e)
        local v, err = mp.get_property_bool("pause")
        if v == nil then
            return error_reply(e, err)
        end
        local suc, err = mp.set_property_bool("pause", not v)
        if not suc then
            return error_reply(e, err)
        end
        return empty_reply(m)
    end)},
    {"M", c"Stop", c"", c"", method(function(m, ud, e)
        local suc, err = mp.command("stop")
        if not suc then
            return error_reply(e, err)
        end
        return empty_reply(m)
    end)},
    {"M", c"Play", c"", c"", method(function(m, ud, e)
        local suc, err = mp.set_property_bool("pause", false)
        if not suc then
            return error_reply(e, err)
        end
        return empty_reply(m)
    end)},
    {"M", c"Seek", c"x", c"", method(function(m, ud, e)
        local x = ffi.new("int64_t[1]")
        local r = message_read(m, "x", x)
        if r < 0 then return r end
        local suc, err = mp.commandv("seek", tostring(tonumber(x[0]) / 1000000))
        if not suc then
            return error_reply(e, err)
        end
        return empty_reply(m)
    end), c"Offset\0"},
    {"M", c"SetPosition", c"ox", c"", method(function(m, ud, e)
        local o = ffi.new("char*[1]")
        local x = ffi.new("int64_t[1]")
        local r = message_read(m, "ox", o, x)
        if r < 0 then return r end
        local suc, err = mp.set_property_number("time-pos", tonumber(x[0]) / 1000000)
        if not suc then
            return error_reply(e, err)
        end
        return empty_reply(m)
    end), c"TrackId\0Offset\0"},
    {"M", c"OpenUri", c"s", c"", method(function(m, ud, e)
        local s = ffi.new("char*[1]")
        local r = message_read(m, "s", s)
        if r < 0 then return r end
        local suc, err = mp.commandv("loadfile", ffi.string(s[0]))
        if not suc then
            return error_reply(e, err)
        end
        return empty_reply(m)
    end), c"Uri\0"},
    {"S", c"Seeked", c"x", c"Position\0"},
    {"P", c"PlaybackStatus", c"s", getter(function(b, p, i, pp, m)
        local v = mp.get_property_bool("idle-active", true)
        if v then
            return message_append(m, "s", "Stopped")
        end
        local v = mp.get_property_bool("pause", false)
        if v then
            return message_append(m, "s", "Paused")
        end
        return message_append(m, "s", "Playing")
    end)},
    {"W", c"LoopStatus", c"s", getter(function(b, p, i, pp, m)
        local v = mp.get_property_bool("loop-file", false)
        if v then
            return message_append(m, "s", "Track")
        end
        local v = mp.get_property_bool("loop-playlist", false)
        if v then
            return message_append(m, "s", "Playlist")
        end
        return message_append(m, "s", "None")
    end), setter(function(b, p, i, pp, m, ud, e)
        local s = ffi.new("char*[1]")
        local r = message_read(m, "s", s)
        if r < 0 then return r end
        s = ffi.string(s[0])
        if s == "Track" then
            local suc, err = mp.set_property_bool("loop-file", true)
            if not suc then
                return error_reply(e, err)
            end
        elseif s == "Playlist" then
            local suc, err = mp.set_property_bool("loop-file", false)
            if not suc then
                return error_reply(e, err)
            end
            local suc, err = mp.set_property_bool("loop-playlist", true)
            if not suc then
                return error_reply(e, err)
            end
        else
            local suc, err = mp.set_property_bool("loop-file", false)
            if not suc then
                return error_reply(e, err)
            end
            local suc, err = mp.set_property_bool("loop-playlist", false)
            if not suc then
                return error_reply(e, err)
            end
        end
        return 0
    end)},
    {"W", c"Rate", c"d", getter(function(b, p, i, pp, m)
        local v = mp.get_property_number("speed", 1)
        return message_append(m, "d", v)
    end), setter(function(b, p, i, pp, m, ud, e)
        local d = ffi.new("double[1]")
        local r = message_read(m, "d", d)
        if r < 0 then return r end
        local suc, err = mp.set_property_number("speed", d[0])
        if not suc then
            return error_reply(e, err)
        end
        return 0
    end)},
    {"W", c"Shuffle", c"b", getter(function(b, p, i, pp, m)
        local v = mp.get_property_bool("shuffle", false)
        return message_append(m, "b", ffi.cast("int", v))
    end), setter(function(b, p, i, pp, m, ud, e)
        local b = ffi.new("int[1]")
        local r = message_read(m, "b", b)
        if r < 0 then return r end
        local shuffle = b[0] ~= 0
        local suc, err = mp.set_property_bool("shuffle", shuffle)
        if not suc then
            return error_reply(e, err)
        end
        if shuffle then
            suc, err = mp.command("playlist-shuffle")
        else
            suc, err = mp.command("playlist-unshuffle")
        end
        if not suc then
            return error_reply(e, err)
        end
        return 0
    end)},
    {"P", c"Metadata", c"a{sv}", getter(function(b, p, i, pp, m)
        local pos = mp.get_property("playlist-pos", "0")
        local title = mp.get_property("media-title", "Unknown Title")
        local duration = mp.get_property_number("duration")
        local dict = {
            ["mpris:trackid"] = {"o", "/" .. pos},
            ["xesam:title"] = {"s", title},
        }
        if duration ~= nil then
            dict["mpris:length"] = {"x", ffi.cast("int64_t", duration * 1000000)}
        end
        local args = {}
        local n = 0
        for key, value in pairs(dict) do
            table.insert(args, key)
            table.insert(args, value[1])
            table.insert(args, value[2])
            n = n + 1
        end
        return message_append(m, "a{sv}", ffi.cast("int", n), unpack(args))
    end)},
    {"W", c"Volume", c"d", getter(function(b, p, i, pp, m)
        local v = mp.get_property_number("volume", 100)
        local av = mp.get_property_number("ao-volume", 100)
        v = v * av / 10000
        return message_append(m, "d", v)
    end), setter(function(b, p, i, pp, m, ud, e)
        local d = ffi.new("double[1]")
        local r = message_read(m, "d", d)
        if r < 0 then return r end
        local av = math.max(d[0], 0)
        local suc = mp.set_property_number("ao-volume", av * 100)
        local v = 1
        if not suc then
            v = av
        end
        local suc, err = mp.set_property_number("volume", v * 100)
        if not suc then
            return error_reply(e, err)
        end
        return 0
    end)},
    {"P", c"Position", c"x", getter(function(b, p, i, pp, m)
        local v = mp.get_property_number("time-pos", 0)
        return message_append(m, "x", ffi.cast("int64_t", v * 1000000))
    end)},
    {"P", c"MinimumRate", c"d", getter(function(b, p, i, pp, m)
        return message_append(m, "d", 0.01)
    end)},
    {"P", c"MaximumRate", c"d", getter(function(b, p, i, pp, m)
        return message_append(m, "d", 100)
    end)},
    {"P", c"CanGoNext", c"b", getter(function(b, p, i, pp, m)
        return message_append(m, "b", ffi.cast("int", true))
    end)},
    {"P", c"CanGoPrevious", c"b", getter(function(b, p, i, pp, m)
        return message_append(m, "b", ffi.cast("int", true))
    end)},
    {"P", c"CanPlay", c"b", getter(function(b, p, i, pp, m)
        return message_append(m, "b", ffi.cast("int", true))
    end)},
    {"P", c"CanPause", c"b", getter(function(b, p, i, pp, m)
        return message_append(m, "b", ffi.cast("int", true))
    end)},
    {"P", c"CanSeek", c"b", getter(function(b, p, i, pp, m)
        return message_append(m, "b", ffi.cast("int", true))
    end)},
    {"P", c"CanControl", c"b", getter(function(b, p, i, pp, m)
        return message_append(m, "b", ffi.cast("int", true))
    end)},
    {">"}
}

local player_vt = make_vtable(player_def)

local r = sd.sd_bus_add_object_vtable(
    bus,
    nil,
    "/org/mpris/MediaPlayer2",
    "org.mpris.MediaPlayer2.Player",
    player_vt,
    nil
)
if r < 0 then
    fatal("sd_bus_add_object_vtable failed", -r)
end

local r = sd.sd_bus_request_name(bus, "org.mpris.MediaPlayer2.mpv", 0)
if r < 0 then
    fatal("sd_bus_request_name failed", -r)
end

local cleanup = function()
    sd.sd_bus_release_name(bus, "org.mpris.MediaPlayer2.mpv")
    sd.sd_bus_flush_close_unref(bus)
    for _, callback in ipairs(callbacks) do
        callback:free()
    end
end

_G.mp_event_loop = function()
    local buflen = 256
    local buf = ffi.new("char[256]")

    local sd_timeout_buf = ffi.new("uint64_t[1]")
    local timespec = ffi.new("struct timespec[1]")

    local nfds = 2
    local fds = ffi.new("struct pollfd[2]")

    while mp.keep_running do
        local mp_fd = mp.get_wakeup_pipe()
        fds[0].fd = mp_fd
        fds[0].events = POLLIN

        local sd_fd = sd.sd_bus_get_fd(bus)
        fds[1].fd = sd_fd
        fds[1].events = sd.sd_bus_get_events(bus)

        local mp_timeout = mp.get_next_timeout()
        if mp_timeout == nil then
            mp_timeout = INT_MAX
        else
            mp_timeout = math.ceil(mp_timeout * 1000)
        end
        sd_timeout_buf[0] = INT_MAX
        sd.sd_bus_get_timeout(bus, sd_timeout_buf)
        local sd_timeout = tonumber(sd_timeout_buf[0]) / 1000000
        ffi.C.clock_gettime(CLOCK_MONOTONIC, timespec)
        sd_timeout = math.ceil(sd_timeout - tonumber(timespec[0].tv_sec) * 1000 - tonumber(timespec[0].tv_nsec) / 1000000)
        local timeout = math.max(math.min(mp_timeout, sd_timeout), 0)

        if ffi.C.poll(fds, nfds, timeout) == -1 then
            local errno = ffi.errno()
            if errno ~= EINTR then
                fatal("poll failed", errno)
            end
        else
            ffi.C.read(mp_fd, buf, buflen)
            local r = sd.sd_bus_process(bus, nil)
            if r < 0 then
                fatal("sd_bus_process failed", -r)
            end
            mp.dispatch_events(false)
        end
    end

    cleanup()
end

local seeking = true

mp.register_event("seek", function()
    seeking = true
end)

mp.register_event("playback-restart", function()
    if not seeking then return end
    seeking = false
    local v, err = mp.get_property_number("time-pos")
    if v ~= nil then
        sd.sd_bus_emit_signal(bus, "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player", "Seeked", "x", ffi.cast("int64_t", v * 1000000))
    end
end)

local emit_changed = function(interface, prop)
    sd.sd_bus_emit_properties_changed(bus, "/org/mpris/MediaPlayer2", interface, prop, nil)
end

mp.observe_property("fullscreen", nil, function()
    emit_changed("org.mpris.MediaPlayer2", "Fullscreen")
end)

mp.observe_property("vo-configured", nil, function()
    emit_changed("org.mpris.MediaPlayer2", "CanSetFullscreen")
end)

local play_state_observer = function()
    emit_changed("org.mpris.MediaPlayer2.Player", "PlaybackStatus")
end
mp.observe_property("pause", nil, play_state_observer)
mp.observe_property("idle-active", nil, play_state_observer)

local loop_state_observer = function()
    emit_changed("org.mpris.MediaPlayer2.Player", "LoopStatus")
end
mp.observe_property("loop-file", nil, loop_state_observer)
mp.observe_property("loop-playlist", nil, loop_state_observer)

mp.observe_property("speed", nil, function()
    emit_changed("org.mpris.MediaPlayer2.Player", "Rate")
end)

mp.observe_property("shuffle", nil, function()
    emit_changed("org.mpris.MediaPlayer2.Player", "Shuffle")
end)

local metadata_observer = function()
    emit_changed("org.mpris.MediaPlayer2.Player", "Metadata")
end
mp.observe_property("playlist-pos", nil, metadata_observer)
mp.observe_property("media-title", nil, metadata_observer)
mp.observe_property("duration", nil, metadata_observer)

local volume_observer = function()
    emit_changed("org.mpris.MediaPlayer2.Player", "Volume")
end
mp.observe_property("volume", nil, volume_observer)
mp.observe_property("ao-volume", nil, volume_observer)
