use std::ffi::c_void;
use std::sync::Arc;
use piston_window::{PistonWindow, WindowSettings, OpenGL};
use piston2d_graphics::{Graphics, Context as GraphicsContext, Transformed};
use piston2d_opengl_graphics::{GlGraphics, OpenGL as GlOpenGL};
use glfw::Context as GlfwContext;

#[repr(C)]
pub struct PistonGraphics {
    window: Arc<PistonWindow>,
    gl: GlGraphics,
}

#[repr(C)]
pub struct PistonCommandBuffer {
    commands: Vec<Box<dyn Fn(&mut GlGraphics, &GraphicsContext)>>,
}

pub fn add(left: u64, right: u64) -> u64 {
    left + right
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_works() {
        let result = add(2, 2);
        assert_eq!(result, 4);
    }
}

#[no_mangle]
pub extern "C" fn create_window(width: u32, height: u32) -> *mut c_void {
    let opengl = OpenGL::V3_2;
    let window: PistonWindow = WindowSettings::new("Red Browser", [width, height])
        .exit_on_esc(true)
        .graphics_api(opengl)
        .build()
        .unwrap();

    let gl = GlGraphics::new(GlOpenGL::V3_2);
    let graphics = PistonGraphics {
        window: Arc::new(window),
        gl,
    };
    Box::into_raw(Box::new(graphics)) as *mut c_void
}

#[no_mangle]
pub extern "C" fn destroy_window(ptr: *mut c_void) {
    if !ptr.is_null() {
        unsafe {
            let _ = Box::from_raw(ptr as *mut PistonGraphics);
        }
    }
}

#[no_mangle]
pub extern "C" fn create_command_buffer() -> *mut c_void {
    let buffer = PistonCommandBuffer {
        commands: Vec::new(),
    };
    Box::into_raw(Box::new(buffer)) as *mut c_void
}

#[no_mangle]
pub extern "C" fn destroy_command_buffer(ptr: *mut c_void) {
    if !ptr.is_null() {
        unsafe {
            let _ = Box::from_raw(ptr as *mut PistonCommandBuffer);
        }
    }
}

#[no_mangle]
pub extern "C" fn clear_color(
    buffer_ptr: *mut c_void,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
) {
    let buffer = unsafe { &mut *(buffer_ptr as *mut PistonCommandBuffer) };
    let color = [r, g, b, a];
    buffer.commands.push(Box::new(move |gl, c| {
        piston2d_graphics::clear(color, gl);
    }));
}

#[no_mangle]
pub extern "C" fn draw_rectangle(
    buffer_ptr: *mut c_void,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
) {
    let buffer = unsafe { &mut *(buffer_ptr as *mut PistonCommandBuffer) };
    let color = [r, g, b, a];
    let rect = [x, y, width, height];
    buffer.commands.push(Box::new(move |gl, c| {
        piston2d_graphics::rectangle(color, rect, c.transform, gl);
    }));
}

#[no_mangle]
pub extern "C" fn submit_commands(
    graphics_ptr: *mut c_void,
    buffer_ptr: *mut c_void,
) {
    let graphics = unsafe { &mut *(graphics_ptr as *mut PistonGraphics) };
    let buffer = unsafe { &*(buffer_ptr as *const PistonCommandBuffer) };
    
    let mut context = GraphicsContext::new_abs(1.0, 1.0);
    for command in &buffer.commands {
        command(&mut graphics.gl, &context);
    }
}

#[no_mangle]
pub extern "C" fn present_frame(graphics_ptr: *mut c_void) {
    let _graphics = unsafe { &mut *(graphics_ptr as *mut PistonGraphics) };
}

