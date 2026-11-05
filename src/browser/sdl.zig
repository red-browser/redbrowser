//! Single shared SDL3 import so all browser modules agree on C types.
pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
});
