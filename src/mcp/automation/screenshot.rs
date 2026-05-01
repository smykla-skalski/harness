#![cfg_attr(
    target_os = "macos",
    expect(
        unsafe_code,
        reason = "CoreGraphics and ImageIO FFI for native macOS screenshot capture"
    )
)]

use super::error::AutomationError;
#[cfg(target_os = "macos")]
use tokio::task;

#[derive(Debug, Clone, Default)]
pub struct ScreenshotOptions {
    pub window_id: Option<u32>,
    pub display_id: Option<u32>,
    pub include_cursor: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScreenshotTarget {
    MainDisplay,
    Display(u32),
    Window(u32),
}

impl ScreenshotOptions {
    #[must_use]
    pub const fn target(&self) -> ScreenshotTarget {
        if let Some(window_id) = self.window_id {
            ScreenshotTarget::Window(window_id)
        } else if let Some(display_id) = self.display_id {
            ScreenshotTarget::Display(display_id)
        } else {
            ScreenshotTarget::MainDisplay
        }
    }
}

/// Capture a PNG screenshot for the selected target.
///
/// # Errors
///
/// Returns an error when cursor capture is requested, when the platform is not
/// macOS, when native image capture fails, or when PNG encoding fails.
pub async fn screenshot(options: &ScreenshotOptions) -> Result<Vec<u8>, AutomationError> {
    if options.include_cursor {
        return Err(AutomationError::CursorCaptureUnsupported);
    }
    let options = options.clone();
    #[cfg(target_os = "macos")]
    {
        task::spawn_blocking(move || capture_png(&options))
            .await
            .map_err(|error| AutomationError::ScreenshotCaptureFailed {
                detail: format!("screenshot task failed: {error}"),
            })?
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = options;
        Err(AutomationError::ScreenshotCaptureFailed {
            detail: "native screenshot capture is only available on macOS".to_string(),
        })
    }
}

#[cfg(target_os = "macos")]
use std::ffi::c_void;
#[cfg(target_os = "macos")]
use std::ptr::{self, NonNull};

#[cfg(target_os = "macos")]
use core_foundation::base::{CFTypeRef, TCFType};
#[cfg(target_os = "macos")]
use core_foundation::data::{CFData, CFDataRef};
#[cfg(target_os = "macos")]
use core_foundation::string::CFString;
#[cfg(target_os = "macos")]
use core_foundation_sys::base::{CFRelease, kCFAllocatorDefault};
#[cfg(target_os = "macos")]
use core_foundation_sys::data::CFDataCreateMutable;

#[cfg(target_os = "macos")]
const KCG_WINDOW_LIST_OPTION_INCLUDING_WINDOW: u32 = 1 << 3;
#[cfg(target_os = "macos")]
const KCG_WINDOW_IMAGE_BOUNDS_IGNORE_FRAMING: u32 = 1 << 0;
#[cfg(target_os = "macos")]
const KCG_WINDOW_IMAGE_BEST_RESOLUTION: u32 = 1 << 3;
#[cfg(target_os = "macos")]
const KCG_WINDOW_IMAGE_NOMINAL_RESOLUTION: u32 = 1 << 4;

#[cfg(target_os = "macos")]
#[repr(C)]
#[derive(Clone, Copy)]
struct CGPoint {
    x: f64,
    y: f64,
}

#[cfg(target_os = "macos")]
#[repr(C)]
#[derive(Clone, Copy)]
struct CGSize {
    width: f64,
    height: f64,
}

#[cfg(target_os = "macos")]
#[repr(C)]
#[derive(Clone, Copy)]
struct CGRect {
    origin: CGPoint,
    size: CGSize,
}

#[cfg(target_os = "macos")]
type CGDirectDisplayID = u32;
#[cfg(target_os = "macos")]
type CGWindowID = u32;
#[cfg(target_os = "macos")]
type CGImageRef = *mut c_void;
#[cfg(target_os = "macos")]
type CGImageDestinationRef = *mut c_void;

#[cfg(target_os = "macos")]
#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGMainDisplayID() -> CGDirectDisplayID;
    fn CGDisplayCreateImage(display_id: CGDirectDisplayID) -> CGImageRef;
    fn CGWindowListCreateImage(
        screen_bounds: CGRect,
        list_option: u32,
        window_id: CGWindowID,
        image_option: u32,
    ) -> CGImageRef;
    fn CGImageGetWidth(image: CGImageRef) -> usize;
    fn CGImageGetHeight(image: CGImageRef) -> usize;
    fn CGImageRelease(image: CGImageRef);
}

#[cfg(target_os = "macos")]
#[link(name = "ImageIO", kind = "framework")]
unsafe extern "C" {
    fn CGImageDestinationCreateWithData(
        data: CFDataRef,
        image_type: CFTypeRef,
        count: usize,
        options: *const c_void,
    ) -> CGImageDestinationRef;
    fn CGImageDestinationAddImage(
        destination: CGImageDestinationRef,
        image: CGImageRef,
        properties: *const c_void,
    );
    fn CGImageDestinationFinalize(destination: CGImageDestinationRef) -> bool;
}

#[cfg(target_os = "macos")]
fn capture_png(options: &ScreenshotOptions) -> Result<Vec<u8>, AutomationError> {
    let image = match options.target() {
        ScreenshotTarget::Window(window_id) => capture_window_image(window_id)?,
        ScreenshotTarget::Display(display_id) => capture_display_image(display_id)?,
        ScreenshotTarget::MainDisplay => capture_display_image(main_display_id())?,
    };
    encode_png(&image)
}

#[cfg(target_os = "macos")]
fn capture_window_image(window_id: u32) -> Result<OwnedCGImage, AutomationError> {
    let image_options = KCG_WINDOW_IMAGE_BOUNDS_IGNORE_FRAMING
        | KCG_WINDOW_IMAGE_BEST_RESOLUTION
        | KCG_WINDOW_IMAGE_NOMINAL_RESOLUTION;
    let raw_image = unsafe {
        CGWindowListCreateImage(
            cg_rect_null(),
            KCG_WINDOW_LIST_OPTION_INCLUDING_WINDOW,
            window_id,
            image_options,
        )
    };
    let image =
        OwnedCGImage::new(raw_image).ok_or_else(|| AutomationError::ScreenshotCaptureFailed {
            detail: format!("could not create image from window {window_id}"),
        })?;
    if image.is_empty() {
        return Err(AutomationError::ScreenshotCaptureFailed {
            detail: format!("window {window_id} produced an empty image"),
        });
    }
    Ok(image)
}

#[cfg(target_os = "macos")]
fn capture_display_image(display_id: u32) -> Result<OwnedCGImage, AutomationError> {
    let raw_image = unsafe { CGDisplayCreateImage(display_id) };
    let image =
        OwnedCGImage::new(raw_image).ok_or_else(|| AutomationError::ScreenshotCaptureFailed {
            detail: format!("could not create image from display {display_id}"),
        })?;
    if image.is_empty() {
        return Err(AutomationError::ScreenshotCaptureFailed {
            detail: format!("display {display_id} produced an empty image"),
        });
    }
    Ok(image)
}

#[cfg(target_os = "macos")]
fn encode_png(image: &OwnedCGImage) -> Result<Vec<u8>, AutomationError> {
    let data_ref = unsafe { CFDataCreateMutable(kCFAllocatorDefault, 0) };
    let data = NonNull::new(data_ref).ok_or_else(|| AutomationError::ScreenshotIo {
        detail: "could not allocate PNG buffer".to_string(),
    })?;
    let data = unsafe { CFData::wrap_under_create_rule(data.as_ptr().cast_const()) };
    let png_type = CFString::new("public.png");
    let destination = unsafe {
        CGImageDestinationCreateWithData(
            data.as_concrete_TypeRef(),
            png_type.as_concrete_TypeRef() as CFTypeRef,
            1,
            ptr::null(),
        )
    };
    let destination =
        OwnedCFType::new(destination).ok_or_else(|| AutomationError::ScreenshotIo {
            detail: "could not create PNG destination".to_string(),
        })?;
    unsafe {
        CGImageDestinationAddImage(destination.as_ptr(), image.as_ptr(), ptr::null());
    }
    if !unsafe { CGImageDestinationFinalize(destination.as_ptr()) } {
        return Err(AutomationError::ScreenshotCaptureFailed {
            detail: "could not encode PNG image".to_string(),
        });
    }
    let bytes = data.bytes().to_vec();
    if bytes.is_empty() {
        return Err(AutomationError::ScreenshotCaptureFailed {
            detail: "native screenshot encoder returned no bytes".to_string(),
        });
    }
    Ok(bytes)
}

#[cfg(target_os = "macos")]
const fn cg_rect_null() -> CGRect {
    CGRect {
        origin: CGPoint {
            x: f64::INFINITY,
            y: f64::INFINITY,
        },
        size: CGSize {
            width: 0.0,
            height: 0.0,
        },
    }
}

#[cfg(target_os = "macos")]
fn main_display_id() -> u32 {
    unsafe { CGMainDisplayID() }
}

#[cfg(target_os = "macos")]
struct OwnedCGImage(NonNull<c_void>);

#[cfg(target_os = "macos")]
impl OwnedCGImage {
    fn new(image: CGImageRef) -> Option<Self> {
        NonNull::new(image).map(Self)
    }

    const fn as_ptr(&self) -> CGImageRef {
        self.0.as_ptr()
    }

    fn is_empty(&self) -> bool {
        unsafe { CGImageGetWidth(self.as_ptr()) == 0 || CGImageGetHeight(self.as_ptr()) == 0 }
    }
}

#[cfg(target_os = "macos")]
impl Drop for OwnedCGImage {
    fn drop(&mut self) {
        unsafe {
            CGImageRelease(self.as_ptr());
        }
    }
}

#[cfg(target_os = "macos")]
struct OwnedCFType(NonNull<c_void>);

#[cfg(target_os = "macos")]
impl OwnedCFType {
    fn new(reference: *mut c_void) -> Option<Self> {
        NonNull::new(reference).map(Self)
    }

    const fn as_ptr(&self) -> *mut c_void {
        self.0.as_ptr()
    }
}

#[cfg(target_os = "macos")]
impl Drop for OwnedCFType {
    fn drop(&mut self) {
        unsafe {
            CFRelease(self.as_ptr().cast_const());
        }
    }
}
