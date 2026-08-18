const std = @import("std");

const fontmod = @import("font.zig");

/// Vertex format the 2D pipeline expects (see shaders/shader_2d.slang and
/// demo_2d.zig's PipelineData). Every widget below draws itself as one or
/// more of these quads; the fragment shader turns each into a crisp or
/// soft-edged, optionally rounded, optionally bordered box via a
/// signed-distance-field, so `local`/`half_size`/`radius`/`border_width`/
/// `blur` are what actually shapes the pixels - `pos` just places the quad
/// on screen (see appendBox).
pub const Vertex = struct {
    pos: [2]f32,
    local: [2]f32,
    half_size: [2]f32,
    radius: f32,
    border_width: f32,
    blur: f32,
    fill_color: [4]f32,
    border_color: [4]f32,
};

/// Screen-space rectangle (pixels, origin top-left) - the basic layout
/// primitive every widget below is built from.
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }
};

pub const BoxStyle = struct {
    radius: f32 = 0,
    border_width: f32 = 0,
    /// Edge softness in pixels. ~1 (the default) reads as a crisp,
    /// antialiased edge; a larger value (with border_width left at 0)
    /// produces a soft blob suitable for a drop shadow - see appendShadow.
    blur: f32 = 1.0,
    fill_color: [4]f32,
    border_color: [4]f32 = .{ 0, 0, 0, 0 },
};

/// Appends one quad (six vertices) covering `rect`, padded out by however
/// much room the shader needs to fade the edge (blur, or a minimum 1px of
/// antialiasing) without that fade getting clipped by the quad itself.
pub fn appendBox(vertices: []Vertex, count: *usize, rect: Rect, style: BoxStyle) void {
    const pad = @max(style.blur, 1.0);
    const cx = rect.x + rect.w / 2;
    const cy = rect.y + rect.h / 2;
    const half_size: [2]f32 = .{ rect.w / 2, rect.h / 2 };
    // Only trust border_color when there's an actual border to draw;
    // otherwise fall back to fill_color so the ~1px antialiased edge
    // fades to the same color it's blending from instead of a stray
    // fringe from an unset field.
    const border_color = if (style.border_width > 0) style.border_color else style.fill_color;

    const corners = [4][2]f32{
        .{ rect.x - pad, rect.y - pad },
        .{ rect.x + rect.w + pad, rect.y - pad },
        .{ rect.x + rect.w + pad, rect.y + rect.h + pad },
        .{ rect.x - pad, rect.y + rect.h + pad },
    };

    var quad: [4]Vertex = undefined;
    for (corners, 0..) |c, i| {
        quad[i] = .{
            .pos = c,
            .local = .{ c[0] - cx, c[1] - cy },
            .half_size = half_size,
            .radius = style.radius,
            .border_width = style.border_width,
            .blur = style.blur,
            .fill_color = style.fill_color,
            .border_color = border_color,
        };
    }

    vertices[count.*] = quad[0];
    count.* += 1;
    vertices[count.*] = quad[1];
    count.* += 1;
    vertices[count.*] = quad[2];
    count.* += 1;
    vertices[count.*] = quad[0];
    count.* += 1;
    vertices[count.*] = quad[2];
    count.* += 1;
    vertices[count.*] = quad[3];
    count.* += 1;
}

/// A soft-edged box drawn `offset` pixels away from `rect`, for a Qt-style
/// drop shadow underneath a widget. Draw this *before* the widget's own
/// appendBox call so it sits behind it.
pub fn appendShadow(vertices: []Vertex, count: *usize, rect: Rect, radius: f32, blur: f32, offset: [2]f32, color: [4]f32) void {
    appendBox(vertices, count, .{
        .x = rect.x + offset[0],
        .y = rect.y + offset[1],
        .w = rect.w,
        .h = rect.h,
    }, .{
        .radius = radius,
        .border_width = 0,
        .blur = blur,
        .fill_color = color,
        .border_color = color,
    });
}

/// Vertex format the text pipeline expects (see shaders/shader_2d_text.slang) -
/// a plain textured quad sampling a glyph atlas, tinted by `color`.
pub const TextVertex = struct {
    pos: [2]f32,
    uv: [2]f32,
    color: [4]f32,
};

/// Appends `glyphs` (pre-shaped by fontmod.Font.shape) as textured quads
/// sampling `atlas`, starting at `pos` (baseline-left, in screen pixels).
/// Glyphs the atlas has no entry for (outside the packed char range) are
/// skipped - still advances the pen so later glyphs stay aligned. Returns
/// the text's total advance width in pixels.
pub fn appendText(
    text_vertices: []TextVertex,
    text_count: *usize,
    atlas: *const fontmod.Atlas,
    glyphs: []const fontmod.ShapedGlyph,
    pos: [2]f32,
    color: [4]f32,
) f32 {
    var pen_x = pos[0];
    for (glyphs) |g| {
        if (atlas.glyphs.get(g.glyph_index)) |m| {
            const x0 = pen_x + g.x_offset + m.bearing_x;
            const y0 = pos[1] - g.y_offset - m.bearing_y;
            const x1 = x0 + m.w;
            const y1 = y0 + m.h;

            const tl = TextVertex{ .pos = .{ x0, y0 }, .uv = .{ m.u0, m.v0 }, .color = color };
            const tr = TextVertex{ .pos = .{ x1, y0 }, .uv = .{ m.u1, m.v0 }, .color = color };
            const br = TextVertex{ .pos = .{ x1, y1 }, .uv = .{ m.u1, m.v1 }, .color = color };
            const bl = TextVertex{ .pos = .{ x0, y1 }, .uv = .{ m.u0, m.v1 }, .color = color };

            text_vertices[text_count.*] = tl;
            text_count.* += 1;
            text_vertices[text_count.*] = tr;
            text_count.* += 1;
            text_vertices[text_count.*] = br;
            text_count.* += 1;
            text_vertices[text_count.*] = tl;
            text_count.* += 1;
            text_vertices[text_count.*] = br;
            text_count.* += 1;
            text_vertices[text_count.*] = bl;
            text_count.* += 1;
        }
        pen_x += g.x_advance;
    }
    return pen_x - pos[0];
}

/// Identifies a widget across frames so Ui can track which one is
/// hot/active. Immediate-mode widgets don't have a persistent object to
/// hang that state off, so the caller hands out a small stable id instead
/// (see demo_2d.zig's `Ids` enum) - this demo has no text/label rendering
/// to hash into an id the way Dear ImGui does, so ids are just explicit.
pub const WidgetId = u32;

/// Per-frame UI state: input for this frame in, geometry out. Persistent
/// interaction state that must survive between frames (which widget is
/// mid-press or mid-drag) lives in `active_id`, owned by the caller across
/// frames - see demo_2d.zig's Frame, which copies it in/out of a Ui value
/// each time it builds the UI. Persistent *values* (checked, slider
/// position) are never stored here at all - they're owned by the caller
/// and passed in by pointer, same as Dear ImGui's `Checkbox(label, &v)`.
pub const Ui = struct {
    vertices: []Vertex,
    vertex_count: usize = 0,
    /// Separate sink from `vertices` since text draws through its own
    /// pipeline (textured, sampling a glyph atlas) instead of the SDF box
    /// shader - see demo_2d.zig's TextPipelineData.
    text_vertices: []TextVertex = &.{},
    text_vertex_count: usize = 0,

    mouse_pos: [2]f32 = .{ -1, -1 },
    mouse_down: bool = false,
    /// True only on the one build that immediately follows a
    /// mouse-button-down event - an edge, not a level.
    mouse_pressed: bool = false,
    /// True only on the one build that immediately follows a
    /// mouse-button-up event - an edge, not a level.
    mouse_released: bool = false,
    active_id: ?WidgetId = null,

    fn isActive(self: Ui, id: WidgetId) bool {
        return if (self.active_id) |active| active == id else false;
    }

    fn draw(self: *Ui, rect: Rect, style: BoxStyle) void {
        appendBox(self.vertices, &self.vertex_count, rect, style);
    }

    fn shadow(self: *Ui, rect: Rect, radius: f32, blur: f32, offset: [2]f32, color: [4]f32) void {
        appendShadow(self.vertices, &self.vertex_count, rect, radius, blur, offset, color);
    }

    /// Draws pre-shaped `glyphs` starting at `pos` (baseline-left, screen
    /// pixels). Returns the text's advance width in pixels.
    pub fn text(self: *Ui, atlas: *const fontmod.Atlas, glyphs: []const fontmod.ShapedGlyph, pos: [2]f32, color: [4]f32) f32 {
        return appendText(self.text_vertices, &self.text_vertex_count, atlas, glyphs, pos, color);
    }
};

/// Classic Windows 95/98 "Windows Standard" color scheme (the default
/// COLOR_3DFACE / COLOR_3DHILIGHT / etc. values). Flat, sharp-cornered,
/// no soft shadows - all depth comes from the 2-ring 3D bevel below.
pub const win95 = struct {
    pub const face: [4]f32 = .{ 0.753, 0.753, 0.753, 1.0 }; // #C0C0C0 - button/panel face
    pub const window: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 }; // #FFFFFF - text field / checkbox field
    pub const highlight: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 }; // #FFFFFF - outer raised light edge
    pub const light: [4]f32 = .{ 0.875, 0.875, 0.875, 1.0 }; // #DFDFDF - inner raised light edge
    pub const shadow: [4]f32 = .{ 0.502, 0.502, 0.502, 1.0 }; // #808080 - inner raised dark edge
    pub const dark_shadow: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 }; // #000000 - outer raised dark edge
    pub const text: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 };
    /// The classic Windows 95 desktop teal (#008080).
    pub const desktop: [4]f32 = .{ 0.0, 0.502, 0.502, 1.0 };
};

/// Win32's raised/sunken 3D border (`DrawEdge` with EDGE_RAISED/EDGE_SUNKEN):
/// two 1-2px rings, each with a light top-left / dark bottom-right (raised)
/// or the reverse (sunken), around a flat face fill. No rounding, no blur -
/// the "chunky pixel" look is the point.
pub const BevelKind = enum { raised, sunken };

const bevel_thickness: f32 = 2;

fn appendFlatRect(vertices: []Vertex, count: *usize, rect: Rect, color: [4]f32) void {
    appendBox(vertices, count, rect, .{ .fill_color = color });
}

fn insetRect(r: Rect, amount: f32) Rect {
    return .{ .x = r.x + amount, .y = r.y + amount, .w = r.w - amount * 2, .h = r.h - amount * 2 };
}

/// Draws one 1px-logical-thickness ring: `tl_color` along the top and left
/// edges, `br_color` along the bottom and right - drawn TL-after-BR so TL
/// wins the two ambiguous corner pixels, matching how a light source from
/// the top-left would naturally dominate there.
fn appendEdgeStrips(vertices: []Vertex, count: *usize, rect: Rect, thickness: f32, tl_color: [4]f32, br_color: [4]f32) void {
    appendFlatRect(vertices, count, .{ .x = rect.x, .y = rect.y + rect.h - thickness, .w = rect.w, .h = thickness }, br_color); // bottom
    appendFlatRect(vertices, count, .{ .x = rect.x + rect.w - thickness, .y = rect.y, .w = thickness, .h = rect.h }, br_color); // right
    appendFlatRect(vertices, count, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = thickness }, tl_color); // top
    appendFlatRect(vertices, count, .{ .x = rect.x, .y = rect.y, .w = thickness, .h = rect.h }, tl_color); // left
}

fn appendBevel(vertices: []Vertex, count: *usize, rect: Rect, face_color: [4]f32, kind: BevelKind) void {
    const outer_tl = if (kind == .raised) win95.highlight else win95.dark_shadow;
    const outer_br = if (kind == .raised) win95.dark_shadow else win95.highlight;
    const inner_tl = if (kind == .raised) win95.light else win95.shadow;
    const inner_br = if (kind == .raised) win95.shadow else win95.light;

    appendEdgeStrips(vertices, count, rect, bevel_thickness, outer_tl, outer_br);
    const inner_rect = insetRect(rect, bevel_thickness);
    appendEdgeStrips(vertices, count, inner_rect, bevel_thickness, inner_tl, inner_br);
    appendFlatRect(vertices, count, insetRect(inner_rect, bevel_thickness), face_color);
}

pub const PanelStyle = struct {
    face_color: [4]f32 = win95.face,
    bevel: BevelKind = .sunken,
};

/// Static background container - a sunken "well" by default, like a
/// classic group box or status bar. Purely decorative, takes no input.
pub fn panel(ui: *Ui, rect: Rect, style: PanelStyle) void {
    appendBevel(ui.vertices, &ui.vertex_count, rect, style.face_color, style.bevel);
}

pub const ButtonStyle = struct {
    face_color: [4]f32 = win95.face,
};

/// Momentary push button. Call every frame; returns true on the one frame
/// a press and release both landed inside `rect` - the caller reacts to
/// that return value the same way it would to Dear ImGui's `if
/// (Button(...))`, with no widget object of its own to hold onto. Unlike a
/// modern button, there's no hover state (95/98 didn't have one) - the
/// only feedback is the bevel inverting to sunken while held down.
pub fn button(ui: *Ui, id: WidgetId, rect: Rect, style: ButtonStyle) bool {
    const hovered = rect.contains(ui.mouse_pos[0], ui.mouse_pos[1]);

    if (ui.mouse_pressed and hovered) ui.active_id = id;
    const active = ui.isActive(id);

    var clicked = false;
    if (ui.mouse_released and active) {
        clicked = hovered;
        ui.active_id = null;
    }

    const pressed_in = active and hovered;
    appendBevel(ui.vertices, &ui.vertex_count, rect, style.face_color, if (pressed_in) .sunken else .raised);

    return clicked;
}

pub const CheckboxStyle = struct {
    /// The field color behind the checkmark - white, like a classic
    /// checkbox or text field, not the gray button face.
    field_color: [4]f32 = win95.window,
};

/// Click-to-toggle switch: a sunken white field, always - the caller draws
/// a checkmark glyph on top when `checked.*` is true (see demo_2d.zig),
/// same as how a caption is drawn on top of a button. `checked` is
/// caller-owned and persists across frames on its own (Ui holds no widget
/// state beyond the transient press tracking in active_id).
pub fn checkbox(ui: *Ui, id: WidgetId, rect: Rect, checked: *bool, style: CheckboxStyle) void {
    const hovered = rect.contains(ui.mouse_pos[0], ui.mouse_pos[1]);

    if (ui.mouse_pressed and hovered) ui.active_id = id;
    const active = ui.isActive(id);

    if (ui.mouse_released and active) {
        if (hovered) checked.* = !checked.*;
        ui.active_id = null;
    }

    appendBevel(ui.vertices, &ui.vertex_count, rect, style.field_color, .sunken);
}

pub const SliderStyle = struct {
    groove_color: [4]f32 = win95.window,
    handle_face_color: [4]f32 = win95.face,
};

fn sliderHandleRect(track: Rect, handle_w: f32, value: f32) Rect {
    const usable_w = track.w - handle_w;
    return .{
        .x = track.x + value * usable_w,
        .y = track.y - (handle_w - track.h) / 2,
        .w = handle_w,
        .h = handle_w,
    };
}

fn setSliderValueFromX(track: Rect, handle_w: f32, value: *f32, x: f32) void {
    const usable_w = track.w - handle_w;
    const rel = (x - track.x - handle_w / 2) / usable_w;
    value.* = std.math.clamp(rel, 0.0, 1.0);
}

/// Horizontal drag slider (a "trackbar" in Win32 terms) over `*value` in
/// [0, 1]: a thin sunken groove with a raised rectangular thumb - classic
/// trackbars have no colored fill/progress indicator, just the groove and
/// thumb. Unlike Button/Checkbox, once a drag starts on the track or
/// handle, pointer motion keeps updating `*value` regardless of whether
/// the pointer is still over the widget - active_id is what makes that
/// possible in an immediate-mode widget with no persistent object of its
/// own: it's still "this slider's" drag on every subsequent frame until
/// mouse-up, even off-widget.
pub fn slider(ui: *Ui, id: WidgetId, track: Rect, value: *f32, handle_w: f32, style: SliderStyle) void {
    const handle_rect = sliderHandleRect(track, handle_w, value.*);
    const hovered = handle_rect.contains(ui.mouse_pos[0], ui.mouse_pos[1]) or track.contains(ui.mouse_pos[0], ui.mouse_pos[1]);

    if (ui.mouse_pressed and hovered) {
        ui.active_id = id;
        setSliderValueFromX(track, handle_w, value, ui.mouse_pos[0]);
    }
    const active = ui.isActive(id);
    if (active and ui.mouse_down) {
        setSliderValueFromX(track, handle_w, value, ui.mouse_pos[0]);
    }
    if (ui.mouse_released and active) ui.active_id = null;

    const drawn_handle = sliderHandleRect(track, handle_w, value.*);

    const groove: Rect = .{ .x = track.x, .y = track.y + track.h / 2 - 2, .w = track.w, .h = 4 };
    appendBevel(ui.vertices, &ui.vertex_count, groove, style.groove_color, .sunken);
    appendBevel(ui.vertices, &ui.vertex_count, drawn_handle, style.handle_face_color, .raised);
}
