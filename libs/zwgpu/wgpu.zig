const std = @import("std");

pub const WgpuInstance = opaque {};
pub const WgpuSurface = opaque {};
pub const WgpuDevice = opaque {};
pub const WgpuRenderPipeline = opaque {};
pub const WgpuBuffer = opaque {};
pub const WgpuSwapChain = opaque {};
pub const WgpuCommandEncoder = opaque {};

pub extern "c" fn create_instance() ?*WgpuInstance;
pub extern "c" fn destroy_instance(instance: ?*WgpuInstance) void;
pub extern "c" fn create_surface(instance: ?*WgpuInstance, window_handle: *const anyopaque) ?*WgpuSurface;
pub extern "c" fn destroy_surface(surface: ?*WgpuSurface) void;
pub extern "c" fn create_device(surface: ?*WgpuSurface) ?*WgpuDevice;
pub extern "c" fn destroy_device(device: ?*WgpuDevice) void;
pub extern "c" fn create_render_pipeline(device: ?*WgpuDevice, shader_source: [*]const u8, shader_len: usize) ?*WgpuRenderPipeline;
pub extern "c" fn destroy_render_pipeline(pipeline: ?*WgpuRenderPipeline) void;
pub extern "c" fn create_vertex_buffer(device: ?*WgpuDevice, vertices: [*]const f32, vertex_count: usize) ?*WgpuBuffer;
pub extern "c" fn destroy_buffer(buffer: ?*WgpuBuffer) void;
pub extern "c" fn create_swap_chain(device: ?*WgpuDevice, surface: ?*WgpuSurface, width: u32, height: u32) ?*WgpuSwapChain;
pub extern "c" fn destroy_swap_chain(swap_chain: ?*WgpuSwapChain) void;
pub extern "c" fn create_command_encoder(device: ?*WgpuDevice) ?*WgpuCommandEncoder;
pub extern "c" fn destroy_command_encoder(encoder: ?*WgpuCommandEncoder) void;
pub extern "c" fn begin_render_pass(encoder: ?*WgpuCommandEncoder, swap_chain: ?*WgpuSwapChain, pipeline: ?*WgpuRenderPipeline, vertex_buffer: ?*WgpuBuffer, clear_color: [*]const f32) void;
pub extern "c" fn submit_commands(device: ?*WgpuDevice, encoder: ?*WgpuCommandEncoder) void;
pub extern "c" fn present_frame(swap_chain: ?*WgpuSwapChain) void;

pub const Instance = struct {
    ptr: ?*WgpuInstance,

    pub fn init() !Instance {
        const ptr = create_instance() orelse return error.FailedToCreateInstance;
        return Instance{ .ptr = ptr };
    }

    pub fn deinit(self: *Instance) void {
        if (self.ptr) |ptr| {
            destroy_instance(ptr);
            self.ptr = null;
        }
    }

    pub fn createSurface(self: *Instance, window_handle: *const anyopaque) !Surface {
        const ptr = create_surface(self.ptr, window_handle) orelse return error.FailedToCreateSurface;
        return Surface{ .ptr = ptr };
    }
};

pub const Surface = struct {
    ptr: ?*WgpuSurface,

    pub fn deinit(self: *Surface) void {
        if (self.ptr) |ptr| {
            destroy_surface(ptr);
            self.ptr = null;
        }
    }

    pub fn createDevice(self: *Surface) !Device {
        const ptr = create_device(self.ptr) orelse return error.FailedToCreateDevice;
        return Device{ .ptr = ptr };
    }
};

pub const Device = struct {
    ptr: ?*WgpuDevice,

    pub fn deinit(self: *Device) void {
        if (self.ptr) |ptr| {
            destroy_device(ptr);
            self.ptr = null;
        }
    }

    pub fn createRenderPipeline(self: *Device, shader_source: []const u8) !RenderPipeline {
        const ptr = create_render_pipeline(self.ptr, shader_source.ptr, shader_source.len) orelse return error.FailedToCreatePipeline;
        return RenderPipeline{ .ptr = ptr };
    }

    pub fn createVertexBuffer(self: *Device, vertices: []const f32) !Buffer {
        const ptr = create_vertex_buffer(self.ptr, vertices.ptr, vertices.len) orelse return error.FailedToCreateBuffer;
        return Buffer{ .ptr = ptr };
    }

    pub fn createSwapChain(self: *Device, surface: *Surface, width: u32, height: u32) !SwapChain {
        const ptr = create_swap_chain(self.ptr, surface.ptr, width, height) orelse return error.FailedToCreateSwapChain;
        return SwapChain{ .ptr = ptr };
    }

    pub fn createCommandEncoder(self: *Device) !CommandEncoder {
        const ptr = create_command_encoder(self.ptr) orelse return error.FailedToCreateCommandEncoder;
        return CommandEncoder{ .ptr = ptr };
    }
};

pub const RenderPipeline = struct {
    ptr: ?*WgpuRenderPipeline,

    pub fn deinit(self: *RenderPipeline) void {
        if (self.ptr) |ptr| {
            destroy_render_pipeline(ptr);
            self.ptr = null;
        }
    }
};

pub const Buffer = struct {
    ptr: ?*WgpuBuffer,

    pub fn deinit(self: *Buffer) void {
        if (self.ptr) |ptr| {
            destroy_buffer(ptr);
            self.ptr = null;
        }
    }
};

pub const SwapChain = struct {
    ptr: ?*WgpuSwapChain,

    pub fn deinit(self: *SwapChain) void {
        if (self.ptr) |ptr| {
            destroy_swap_chain(ptr);
            self.ptr = null;
        }
    }
};

pub const CommandEncoder = struct {
    ptr: ?*WgpuCommandEncoder,

    pub fn deinit(self: *CommandEncoder) void {
        if (self.ptr) |ptr| {
            destroy_command_encoder(ptr);
            self.ptr = null;
        }
    }

    pub fn beginRenderPass(self: *CommandEncoder, swap_chain: *SwapChain, pipeline: *RenderPipeline, vertex_buffer: *Buffer, clear_color: [4]f32) void {
        begin_render_pass(self.ptr, swap_chain.ptr, pipeline.ptr, vertex_buffer.ptr, &clear_color);
    }
}; 