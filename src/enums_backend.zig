/// All the backends we know about.  dvui.backend.kind is this type.
///
/// This lives in its own file because build.zig depends on it, so we keep
/// build.zig from depending on dvui.zig.
pub const Backend = enum {
    custom,
    sdl3,
    web,
    /// Does no rendering!
    testing,
};
