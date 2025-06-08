const std = @import("std");
const Window = @import("window").Window;
const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("GL/glcorearb.h");
    @cInclude("GL/glext.h");
});

const Shaders = @import("shaders.zig");

var glCreateShader: *const fn (type: c.GLenum) callconv(.C) c.GLuint = undefined;
var glShaderSource: *const fn (shader: c.GLuint, count: c.GLsizei, string: [*]const [*:0]const u8, length: [*]const c.GLint) callconv(.C) void = undefined;
var glCompileShader: *const fn (shader: c.GLuint) callconv(.C) void = undefined;
var glCreateProgram: *const fn () callconv(.C) c.GLuint = undefined;
var glAttachShader: *const fn (program: c.GLuint, shader: c.GLuint) callconv(.C) void = undefined;
var glLinkProgram: *const fn (program: c.GLuint) callconv(.C) void = undefined;
var glDeleteShader: *const fn (shader: c.GLuint) callconv(.C) void = undefined;
var glUseProgram: *const fn (program: c.GLuint) callconv(.C) void = undefined;
var glGenVertexArrays: *const fn (n: c.GLsizei, arrays: [*]c.GLuint) callconv(.C) void = undefined;
var glGenBuffers: *const fn (n: c.GLsizei, buffers: [*]c.GLuint) callconv(.C) void = undefined;
var glBindVertexArray: *const fn (array: c.GLuint) callconv(.C) void = undefined;
var glBindBuffer: *const fn (target: c.GLenum, buffer: c.GLuint) callconv(.C) void = undefined;
var glBufferData: *const fn (target: c.GLenum, size: c.GLsizeiptr, data: ?*const anyopaque, usage: c.GLenum) callconv(.C) void = undefined;
var glVertexAttribPointer: *const fn (index: c.GLuint, size: c.GLint, type: c.GLenum, normalized: c.GLboolean, stride: c.GLsizei, pointer: ?*const anyopaque) callconv(.C) void = undefined;
var glEnableVertexAttribArray: *const fn (index: c.GLuint) callconv(.C) void = undefined;
var glDrawArrays: *const fn (mode: c.GLenum, first: c.GLint, count: c.GLsizei) callconv(.C) void = undefined;
var glViewport: *const fn (x: c.GLint, y: c.GLint, width: c.GLsizei, height: c.GLsizei) callconv(.C) void = undefined;
var glClearColor: *const fn (red: c.GLfloat, green: c.GLfloat, blue: c.GLfloat, alpha: c.GLfloat) callconv(.C) void = undefined;
var glClear: *const fn (mask: c.GLbitfield) callconv(.C) void = undefined;
var glDeleteVertexArrays: *const fn (n: c.GLsizei, arrays: [*]const c.GLuint) callconv(.C) void = undefined;
var glDeleteBuffers: *const fn (n: c.GLsizei, buffers: [*]const c.GLuint) callconv(.C) void = undefined;
var glDeleteProgram: *const fn (program: c.GLuint) callconv(.C) void = undefined;

fn loadGLFunction(comptime T: type, comptime name: [:0]const u8) T {
    const ptr = c.SDL_GL_GetProcAddress(name.ptr);
    if (ptr == null) {
        @panic("Failed to load OpenGL function");
    }
    return @ptrCast(ptr);
}

fn loadGLFunctions() void {
    glCreateShader = loadGLFunction(@TypeOf(glCreateShader), "glCreateShader");
    glShaderSource = loadGLFunction(@TypeOf(glShaderSource), "glShaderSource");
    glCompileShader = loadGLFunction(@TypeOf(glCompileShader), "glCompileShader");
    glCreateProgram = loadGLFunction(@TypeOf(glCreateProgram), "glCreateProgram");
    glAttachShader = loadGLFunction(@TypeOf(glAttachShader), "glAttachShader");
    glLinkProgram = loadGLFunction(@TypeOf(glLinkProgram), "glLinkProgram");
    glDeleteShader = loadGLFunction(@TypeOf(glDeleteShader), "glDeleteShader");
    glUseProgram = loadGLFunction(@TypeOf(glUseProgram), "glUseProgram");
    glGenVertexArrays = loadGLFunction(@TypeOf(glGenVertexArrays), "glGenVertexArrays");
    glGenBuffers = loadGLFunction(@TypeOf(glGenBuffers), "glGenBuffers");
    glBindVertexArray = loadGLFunction(@TypeOf(glBindVertexArray), "glBindVertexArray");
    glBindBuffer = loadGLFunction(@TypeOf(glBindBuffer), "glBindBuffer");
    glBufferData = loadGLFunction(@TypeOf(glBufferData), "glBufferData");
    glVertexAttribPointer = loadGLFunction(@TypeOf(glVertexAttribPointer), "glVertexAttribPointer");
    glEnableVertexAttribArray = loadGLFunction(@TypeOf(glEnableVertexAttribArray), "glEnableVertexAttribArray");
    glDrawArrays = loadGLFunction(@TypeOf(glDrawArrays), "glDrawArrays");
    glViewport = loadGLFunction(@TypeOf(glViewport), "glViewport");
    glClearColor = loadGLFunction(@TypeOf(glClearColor), "glClearColor");
    glClear = loadGLFunction(@TypeOf(glClear), "glClear");
    glDeleteVertexArrays = loadGLFunction(@TypeOf(glDeleteVertexArrays), "glDeleteVertexArrays");
    glDeleteBuffers = loadGLFunction(@TypeOf(glDeleteBuffers), "glDeleteBuffers");
    glDeleteProgram = loadGLFunction(@TypeOf(glDeleteProgram), "glDeleteProgram");
}

pub const Renderer = struct {
    window: *Window,
    allocator: std.mem.Allocator,
    shader_program: c.GLuint,
    vao: c.GLuint,
    vbo: c.GLuint,

    pub fn init(allocator: std.mem.Allocator, window: *Window) !Renderer {
        loadGLFunctions();

        const vertex_shader = glCreateShader(c.GL_VERTEX_SHADER);
        const vertex_source = @as([*:0]const u8, @ptrCast(Shaders.vertex_shader_source));
        const vertex_source_array = [_][*:0]const u8{vertex_source};
        const vertex_length = [_]c.GLint{-1};
        glShaderSource(vertex_shader, 1, &vertex_source_array, &vertex_length);
        glCompileShader(vertex_shader);

        const fragment_shader = glCreateShader(c.GL_FRAGMENT_SHADER);
        const fragment_source = @as([*:0]const u8, @ptrCast(Shaders.fragment_shader_source));
        const fragment_source_array = [_][*:0]const u8{fragment_source};
        const fragment_length = [_]c.GLint{-1};
        glShaderSource(fragment_shader, 1, &fragment_source_array, &fragment_length);
        glCompileShader(fragment_shader);

        const shader_program = glCreateProgram();
        glAttachShader(shader_program, vertex_shader);
        glAttachShader(shader_program, fragment_shader);
        glLinkProgram(shader_program);

        glDeleteShader(vertex_shader);
        glDeleteShader(fragment_shader);

        const vertices = [_]f32{
            -0.5, -0.5, 0.0, 1.0, 0.0, 0.0, // bottom left
            0.5, -0.5, 0.0, 0.0, 1.0, 0.0, // bottom right
            0.0, 0.5, 0.0, 0.0, 0.0, 1.0, // top
        };

        var vao: c.GLuint = undefined;
        var vbo: c.GLuint = undefined;
        glGenVertexArrays(1, @as([*]c.GLuint, @ptrCast(&vao)));
        glGenBuffers(1, @as([*]c.GLuint, @ptrCast(&vbo)));

        glBindVertexArray(vao);
        glBindBuffer(c.GL_ARRAY_BUFFER, vbo);
        glBufferData(c.GL_ARRAY_BUFFER, @sizeOf(f32) * vertices.len, &vertices, c.GL_STATIC_DRAW);

        glVertexAttribPointer(0, 3, c.GL_FLOAT, c.GL_FALSE, 6 * @sizeOf(f32), null);
        glEnableVertexAttribArray(0);

        glVertexAttribPointer(1, 3, c.GL_FLOAT, c.GL_FALSE, 6 * @sizeOf(f32), @ptrFromInt(3 * @sizeOf(f32)));
        glEnableVertexAttribArray(1);

        return Renderer{
            .window = window,
            .allocator = allocator,
            .shader_program = shader_program,
            .vao = vao,
            .vbo = vbo,
        };
    }

    pub fn deinit(self: *Renderer) void {
        glDeleteVertexArrays(1, @as([*]const c.GLuint, @ptrCast(&self.vao)));
        glDeleteBuffers(1, @as([*]const c.GLuint, @ptrCast(&self.vbo)));
        glDeleteProgram(self.shader_program);
    }

    pub fn beginFrame(self: *Renderer) void {
        const size = self.window.getSize();
        glViewport(0, 0, size.width, size.height);
        glClearColor(0.2, 0.3, 0.3, 1.0);
        glClear(c.GL_COLOR_BUFFER_BIT);
    }

    pub fn endFrame(self: *Renderer) void {
        self.window.swapBuffers();
    }

    pub fn drawTriangle(self: *Renderer) void {
        glUseProgram(self.shader_program);
        glBindVertexArray(self.vao);
        glDrawArrays(c.GL_TRIANGLES, 0, 3);
    }

    pub fn drawRectangle(self: *Renderer, x: f32, y: f32, width: f32, height: f32, color: [4]f32) void {
        _ = self;
        _ = x;
        _ = y;
        _ = width;
        _ = height;
        _ = color;
    }

    pub fn drawText(self: *Renderer, text: []const u8, x: f32, y: f32, color: [4]f32) void {
        _ = self;
        _ = text;
        _ = x;
        _ = y;
        _ = color;
    }
};
