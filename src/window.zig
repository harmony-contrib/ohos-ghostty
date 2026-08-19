const rwh = @import("raw-window-handle");

/// XComponent native window adapted to raw-window-handle.
///
/// The pointer is borrowed from the XComponent surface callback and must stay
/// valid while wgpu uses the corresponding surface.
pub const OhosSurfaceWindow = struct {
    native_window: *anyopaque,

    pub fn fromRaw(native_window: *anyopaque) OhosSurfaceWindow {
        return .{ .native_window = native_window };
    }

    pub fn windowHandle(self: *const @This()) rwh.HandleError!rwh.WindowHandle {
        return .borrowRaw(.{
            .ohos_ndk = rwh.OhosNdkWindowHandle.init(self.native_window),
        });
    }

    pub fn displayHandle(_: *const @This()) rwh.HandleError!rwh.DisplayHandle {
        return .ohos();
    }

    pub fn nativeWindowPtr(self: *const @This()) rwh.HandleError!*anyopaque {
        const handle = try rwh.getWindowHandle(self);
        return switch (handle.asRaw()) {
            .ohos_ndk => |ohos| ohos.native_window,
            else => error.NotSupported,
        };
    }
};
