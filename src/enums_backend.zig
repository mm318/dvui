/// All the backends we know about.  dvui.backend.kind is this type.
///
/// This lives in its own file because build.zig depends on it, so we keep
/// build.zig from depending on dvui.zig.
pub const Backend = enum {
    custom,
    /// DEPRECATED: Use either sdl3 or sdl3gpu
    sdl,
    /// REMOVED: kept so selecting `-Dbackend=sdl2` can emit a targeted error
    sdl2,
    sdl3,
    sdl3gpu,
    raylib,
    raylib_zig,
    dx11,
    glfw_opengl,
    web,
    /// Does no rendering!
    testing,
};
