package editor

import sdl "vendor:sdl2"
import mu "vendor:microui"

import "base:runtime"
import "core:strings"
import "core:time"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:c"

/* DISCLAIMER:
This doesn't do what I want it to do yet!
*/

// example code for microui + sdl + odin:
//https://github.com/odin-lang/examples/blob/master/sdl2/microui/microui_sdl_demo.odin

/* TODO:
[x] Handle window resizing
[x] Change texture to cpu bitmap.
[x] Fix bitmap resizing
[x] Infinite moving canvas (lock mouse somehow)
[x] Draw bounds (as thick lines?)
[x] Clamp drawing from CPU to GPU (don't draw offscreen)
[ ] Draw Lines instead of dots? -> 
  .  this requires doing something different from sdl.RenderDrawLines 
.  since it doesn't take line thickness -> it doesn't, it needs sdl.RenderSetScale

[x] basic UI
[ ] an actual color picker
[ ] 
*/

// SdlCheckCode
scc :: proc(code : c.int)
{
	if(code < 0) {
		fmt.eprintf("SDL ERROR: %s\n", sdl.GetErrorString());
		os.exit(1);
	}
}

Event :: sdl.EventType
Key :: sdl.Keycode

v2 :: sdl.FPoint
v2i :: sdl.Point
i32_rect :: sdl.Rect

Button :: struct {
	down:      b32,
	up:        b32,
	timestamp: u32,
}

Input :: struct {
	lmb:  Button,
	mmb:  Button,
	rmb:  Button,
	ctrl: Button,
	scrollY: i32,
	
	mousePos:     v2i,
	prevMousePos: v2i,
	
	timestamp: u32,
	//text: [sdl.TEXTINPUTEVENT_TEXT_SIZE]u8,
}

InitInputForFrame :: proc "contextless" (input : ^Input)
{
	input.lmb.up = false;
	input.mmb.up = false;
	input.rmb.up = false;
	input.ctrl.up = false;
	
	input.scrollY = 0;
}

Bitmap :: struct {
	bytes: []u32,
	width: i32,
	height: i32,
}

EditorData :: struct {
	window: ^sdl.Window,
	renderer: ^sdl.Renderer,
	atlasTexture: ^sdl.Texture,
	uiContext: mu.Context,
	windowWidth: i32,
	windowHeight: i32,
	quit: b32,
	
	bg: mu.Color,
	drawColor: sdl.Color,
	
	gridScale: i32,
	penSize: i32,
	
	bitmap: Bitmap,
	bitmapCapacity: int, // in pixels
	
	allowBmpResize: b32,
	committed: b32,
	drawUncommitted: b32,
	
	dstRect: i32_rect,
	commitRect: i32_rect,
	uncommitRect: i32_rect,
}

DrawGrid :: proc "contextless" (editor: ^EditorData)
{
	// draw debug (?) grid
	
	xIni : i32 = editor.dstRect.x %% editor.gridScale;
	yIni : i32 = editor.dstRect.y %% editor.gridScale;
	for y : i32 = 0; y <= editor.windowHeight; y += editor.gridScale
	{
		sdl.RenderDrawLine(editor.renderer, 0, y + yIni,
											 editor.windowWidth, y + yIni);
	}
	for x : i32 = 0; x <= editor.windowWidth; x += editor.gridScale
	{
		sdl.RenderDrawLine(editor.renderer, x + xIni, 0,
											 x + xIni, editor.windowHeight);
	}
}

DrawBitmapBounds :: proc "contextless"(editor: ^EditorData)
{
	if editor.bitmap.width > 0 && editor.bitmap.height > 0 {
		thickness : i32 = 2;
		sdl.RenderSetScale(editor.renderer, f32(thickness), f32(thickness));
		
		xIni := editor.dstRect.x/thickness;
		yIni := editor.dstRect.y/thickness;
		xEnd := (editor.bitmap.width*editor.gridScale + editor.dstRect.x)/thickness;
		yEnd := (editor.bitmap.height*editor.gridScale + editor.dstRect.y)/thickness;
		
		if xIni >= 0 {
			sdl.RenderDrawLine(editor.renderer, xIni, yIni, xIni, yEnd);
		}
		if yIni >= 0 {
			sdl.RenderDrawLine(editor.renderer, xIni, yIni, xEnd, yIni);
		}
		if xEnd <= editor.windowWidth {
			sdl.RenderDrawLine(editor.renderer, xEnd, yIni, xEnd, yEnd);
		}
		if yEnd <= editor.windowHeight {
			sdl.RenderDrawLine(editor.renderer, xIni, yEnd, xEnd, yEnd);
		}
		
		sdl.RenderSetScale(editor.renderer, 1, 1);
	}
}

PenPosFromMouse :: proc(mousePos, gridOffset: v2i, gridScale, drawSize: i32) -> v2i
{
	// Thanks @danwil for the help with this!
	penX := mousePos.x - drawSize/2 - gridOffset.x;
	penY := mousePos.y - drawSize/2 - gridOffset.y;
	
	penGridPos := v2i{
		i32(sdl.floorf(f32(penX + gridScale/2) / f32(gridScale))),
		i32(sdl.floorf(f32(penY + gridScale/2) / f32(gridScale))),
	}
	
	// Ensure pen entirely on grid?
	//penGridPos.x = max(min(penGridPos.x, maxGridX - penSize), 0);
	//penGridPos.y = max(min(penGridPos.y, maxGridY - penSize), 0);
	
	return penGridPos;
}

MakeEmptyBitmap :: proc(cap: int) -> Bitmap
{
	bitmap: Bitmap;
	bitmap.bytes = make([]u32, cap);
	return bitmap;
}

SaveToFile :: proc(editor: ^EditorData, fileName: cstring)
{
	saveSurface := 
		sdl.CreateRGBSurfaceWithFormat(0, 0, 0, 32, u32(sdl.PixelFormatEnum.RGBA32));
	saveSurface.w = editor.bitmap.width;
	saveSurface.h = editor.bitmap.height;
	saveSurface.pitch = editor.bitmap.width*size_of(editor.bitmap.bytes[0]);
	saveSurface.pixels = raw_data(editor.bitmap.bytes);
	
	scc(sdl.SaveBMP(saveSurface, fileName));
}

LoadFromFile :: proc(editor: ^EditorData, fileName: cstring)
{
	loadSurface := sdl.LoadBMP(fileName);
	if(loadSurface != nil) {
		if(editor.bitmap.bytes != nil) {
			// TODO: Save dialog here since we're overwriting?
			delete(editor.bitmap.bytes);
		}
		
		editor.bitmap.width = loadSurface.w;
		editor.bitmap.height = loadSurface.h;
		editor.bitmapCapacity = int(loadSurface.w*loadSurface.h);
		
		// NOTE: If px format is not rgba32, change it so it is
		when ODIN_ENDIAN == .Little {
			format := u32(sdl.PixelFormatEnum.RGBA32);
		}
		else {
			format := u32(sdl.PixelFormatEnum.ABGR32);
		}
		convertedSurface := sdl.ConvertSurfaceFormat(loadSurface, format, 0);
		
		// NOTE: SDL_LoadBMP calls into SDL_CreateSurface which uses SDL_aligned_alloc
    // which probably works differently from SDL_malloc/realloc
		bmpSize := editor.bitmapCapacity;
		editor.bitmap.bytes = make([]u32, bmpSize);
		mem.copy_non_overlapping(raw_data(editor.bitmap.bytes), 
														 convertedSurface.pixels, bmpSize*size_of(editor.bitmap.bytes[0]));
		
		sdl.FreeSurface(loadSurface);
		sdl.FreeSurface(convertedSurface);
	}
}

// oldSize must be in bytes, newSize in u32s
ResizeBitmapMem :: proc(bitmap: ^Bitmap, oldSize, newSize: int, cap: ^int)
{
	if newSize > cap^ {
		cap^ = newSize + int(bitmap.width*8 + bitmap.height*8);
		temp := make([]u32, cap^);
		mem.copy_non_overlapping(raw_data(temp), raw_data(bitmap.bytes), oldSize);
		delete(bitmap.bytes);
		bitmap.bytes = temp;
	}
}

// expand the bitmap to accomodate the rectangle
ExpandMap :: proc(editor: ^EditorData, rect: ^i32_rect)
{
	bitmap := &editor.bitmap;
	
	bmpSize := int(bitmap.width*bitmap.height)*size_of(bitmap.bytes[0]);
	newSize : int = ---;
	
	// NOTE: Order matters! if rect.y < 0 -> rect.y = 0;
	//  must happen before other check
	if rect.y < 0 {
		newSize = int(bitmap.width*(bitmap.height + (-rect.y)));
		ResizeBitmapMem(bitmap, bmpSize, newSize, &editor.bitmapCapacity);
		
		dst := raw_data(bitmap.bytes[(-rect.y)*bitmap.width:]);
		src := raw_data(bitmap.bytes);
		mem.copy(dst, src, bmpSize);
		// NOTE: If I want to clear to a color I'll need my own memset for u32s
		mem.set(src, 0, int((-rect.y)*bitmap.width)*size_of(u32));
		
		bitmap.height += -rect.y;
		editor.dstRect.y += rect.y*editor.gridScale;
		rect.y = 0;
		bmpSize = newSize*size_of(bitmap.bytes[0]);
	}
	
	if rect.y + rect.h > bitmap.height {
		bitmap.height = rect.y + rect.h;
		newSize = int(bitmap.width*bitmap.height);
		ResizeBitmapMem(bitmap, bmpSize, newSize, &editor.bitmapCapacity);
		bmpSize = newSize*size_of(bitmap.bytes[0]);
	}
	
	// NOTE: Order matters! if rect.x < 0 -> rect.x = 0;
	//  must happen before other check
	// This could be wrong, it's pretty much copypasta'd from the next thing
	if rect.x < 0 {
		offset := -rect.x;
		newSize = int((bitmap.width + offset)*bitmap.height);
		ResizeBitmapMem(bitmap, bmpSize, newSize, &editor.bitmapCapacity);
		
		rowSize := int(bitmap.width)*size_of(bitmap.bytes[0]);
		dst : rawptr = ---;
		src : rawptr = ---;
		for y := bitmap.height - 1; y >= 0; y -= 1
		{
			srcLoc := bitmap.width*y;
			dstLoc := (bitmap.width + offset)*y + offset;
			dst = raw_data(bitmap.bytes[dstLoc:]);
			src = raw_data(bitmap.bytes[srcLoc:]);
			mem.copy(dst, src, rowSize);
			if dstLoc - offset >= 0 {
				clearPtr := raw_data(bitmap.bytes[dstLoc - offset:]);
				// NOTE: If I want to clear to a color I'll need my own memset for u32s
				mem.set(clearPtr, 0, int(offset)*size_of(u32));
			}
		}
		
		bitmap.width += -rect.x;
		editor.dstRect.x += rect.x*editor.gridScale;
		rect.x = 0;
		bmpSize = newSize*size_of(bitmap.bytes[0]);
	}
	
	if rect.x + rect.w > bitmap.width {
		offset := rect.x + rect.w - bitmap.width;
		newSize = int((bitmap.width + offset)*bitmap.height);
		ResizeBitmapMem(bitmap, bmpSize, newSize, &editor.bitmapCapacity);
		
		rowSize := int(bitmap.width)*size_of(bitmap.bytes[0]);
		dst : rawptr = ---;
		src : rawptr = ---;
		for y := bitmap.height - 1; y > 0; y -= 1
		{
			srcLoc := bitmap.width*y;
			dstLoc := (bitmap.width + offset)*y;
			dst = raw_data(bitmap.bytes[dstLoc:]);
			src = raw_data(bitmap.bytes[srcLoc:]);
			mem.copy(dst, src, rowSize);
			if dstLoc - offset >= 0 {
				clearPtr := raw_data(bitmap.bytes[dstLoc - offset:]);
				// NOTE: If I want to clear to a color I'll need my own memset for u32s
				mem.set(clearPtr, 0, int(offset)*size_of(u32));
			}
		}
		
		bitmap.width += offset;
		bmpSize = newSize*size_of(bitmap.bytes[0]);
	}
}

CPUFillRect :: proc "contextless"(bitmap: ^Bitmap, rect: i32_rect, c: sdl.Color)
{
	rect := rect;
	
	if rect.x < 0 {
		rect.w += rect.x;
		rect.x = 0;
	}
	
	if rect.y < 0 {
		rect.h += rect.y;
		rect.y = 0;
	}
	
	right := rect.x + rect.w;
	if right > bitmap.width {
		right = bitmap.width;
	}
	
	bot := rect.y + rect.h;
	if bot > bitmap.height {
		bot = bitmap.height;
	}
	
	for y : i32 = rect.y; y < bot; y += 1
	{
		for x : i32 = rect.x; x < right; x += 1
		{
			bitmap.bytes[y*bitmap.width + x] = transmute(u32)c;
		}
	}
}

RenderFromBitmap :: proc "contextless"(editor: ^EditorData)
{
	bitmap := &editor.bitmap;
	pxSize := editor.gridScale;
	
	xIni := max(-editor.dstRect.x/pxSize, 0);
	yIni := max(-editor.dstRect.y/pxSize, 0);
	
	// NOTE(vic): +1 for tiles that aren't fully seen
	xEnd := min(bitmap.width, editor.windowWidth/pxSize + xIni + 1);
	yEnd := min(bitmap.height, editor.windowHeight/pxSize + yIni + 1);
	
	rect : i32_rect = ---;
	
	for y : i32 = yIni; y < yEnd; y += 1
	{
		for x : i32 = xIni; x < xEnd; x += 1
		{
			px := transmute(sdl.Color)bitmap.bytes[y*bitmap.width + x];
			
			rect = {
				x*pxSize + editor.dstRect.x, y*pxSize + editor.dstRect.y,
				pxSize, pxSize,
			}
			
			sdl.SetRenderDrawColor(editor.renderer, px.r, px.g, px.b, px.a);
			sdl.RenderFillRect(editor.renderer, &rect);
		}
	}
}

@(require_results)
is_number :: proc(c : u8) -> bool {
	return c >= '0' && c <= '9';
}

// n is the place the last digit was in the string
// if I do need a function which does this with any base
// just go to Odin strconv.parse_i64_maybe_prefixed and delete last 2 lines
@(require_results)
parse_int_prefix :: proc(str : string) -> (val : int = 0, n : int = 0, ok : bool = false)
{
	i := 0;
	sign : int = 1;
	
	if str[0] == '-' {
		if len(str) < 2 {
			return;
		}
		
		i += 1;
		sign = -1;
	}
	if str[0] == '+' {
		if len(str) < 2 {
			return;
		}
		i += 1;
	}
	
	if !is_number(str[i]) {
		return;
	}
	
	for ; i < len(str); i += 1
	{
		if !is_number(str[i]) do break;
		
		val *= 10;
		val += int(str[i] - '0');
	}
	val *= sign;
	n = i;
	ok = true;
	return;
}

Usage :: proc()
{
	fmt.printfln("Usage: %s [file.bmp]", os.args[0]);
	fmt.print("Flags:\n",
						"-h | --help: Show usage and flags\n",
						"-s:w,h | --size:w,h: Set initial width and height. Ignored if image file gets loaded\n");
	os.exit(0);
}

EditorInitAll :: proc() -> ^EditorData
{
	editor := new(EditorData);
	width : i32 = 24;
	height : i32 = 18;
	if len(os.args) != 1 {
		for idx := 1; idx < len(os.args); idx += 1
		{
			arg := os.args[idx];
			if arg[0] == '-' {
				// flag
				arg = arg[1:];
				if arg[0] == '-' {
					// verbose flags
					arg = arg[1:];
					if arg == "help" {
						Usage();
					}
					else if strings.has_prefix(arg, "size:") {
						arg = arg[len("size:"):];
						temp, n, ok := parse_int_prefix(arg);
						if !ok {
							fmt.printfln("Could not parse requested width: %s", arg);
						}
						else {
							width = i32(temp);
							arg = strings.trim_space(arg[n:]);
							if arg[0] == 'x' || arg[0] == ',' {
								arg = strings.trim_space(arg[1:]);
							}
							temp, n, ok = parse_int_prefix(arg);
							if !ok {
								fmt.printfln("Could not parse requested height: %s", arg);
							}
							else {
								height = i32(temp);
							}
						}
					}
					else {
						fmt.printfln("Ignoring unknown flag '%s'", arg);
					}
				}
				else {
					if arg == "h" || arg == "?" {
						Usage();
					}
					else if strings.has_prefix(arg, "s:") {
						arg = arg[len("s:"):];
						temp, n, ok := parse_int_prefix(arg);
						if !ok {
							fmt.printfln("Could not parse requested width: %s", arg);
						}
						else {
							width = i32(temp);
							arg = strings.trim_space(arg[n:]);
							if arg[0] == 'x' || arg[0] == ',' {
								arg = strings.trim_space(arg[1:]);
							}
							temp, n, ok = parse_int_prefix(arg);
							if !ok {
								fmt.printfln("Could not parse requested height: %s", arg);
							}
							else {
								height = i32(temp);
							}
						}
					}
					else {
						fmt.printfln("Ignoring unknown flag '%s'", arg);
					}
				}
			}
			else if arg[0] == '/' {
				if arg[1:] == "?" {
					// windows style '/?'
					Usage();
				}
				else {
					fmt.printfln("Ignoring unknown flag '%s'", arg);
				}
			}
			else {
				if os.is_file(arg) {
					// try to open as bmp
					LoadFromFile(editor, runtime.args__[idx]);
				}
				else {
					fmt.printfln("File '%s' doesn't exist or isn't a file", arg);
				}
			}
		}
	}
	
	if editor.bitmap.bytes == nil {
		editor.bitmapCapacity = 1024*1024;
		editor.bitmap = MakeEmptyBitmap(editor.bitmapCapacity);
		editor.bitmap.width = width;
		editor.bitmap.height = height;
	}
	
	editor.windowWidth  = 1920*0.75;
	editor.windowHeight = 1080*0.75;
	//sdl.SetHint("SDL_MOUSE_RELATIVE_SYSTEM_SCALE", "1");
	scc(sdl.Init(sdl.INIT_VIDEO));
	editor.window = sdl.CreateWindow("Odin px paint", 40, 60, 
																	 editor.windowWidth, editor.windowHeight, 
																	 {.SHOWN, .RESIZABLE});
	assert(editor.window != nil, "Could not create window");
	
	backend_idx: i32 = -1;
	if n := sdl.GetNumRenderDrivers(); n <= 0 {
		fmt.eprintln("No render drivers available");
	}
	else {
		for i : i32 = 0; i < n; i += 1
		{
			info: sdl.RendererInfo;
			if err := sdl.GetRenderDriverInfo(i, &info); err == 0 {
				// NOTE(bill): "direct3d" seems to not work correctly
				if info.name == "opengl" {
					backend_idx = i;
					break;
				}
			}
		}
	}
	
	editor.renderer = sdl.CreateRenderer(editor.window, backend_idx, sdl.RENDERER_ACCELERATED);
	assert(editor.renderer != nil, "Could not create renderer");
	
	editor.atlasTexture = sdl.CreateTexture(editor.renderer, .RGBA32, .TARGET, 
																					mu.DEFAULT_ATLAS_WIDTH, mu.DEFAULT_ATLAS_HEIGHT);
	assert(editor.atlasTexture != nil, "Could not create ui atlas texture");
	if err := sdl.SetTextureBlendMode(editor.atlasTexture, .BLEND); err != 0 {
		fmt.eprintln("sdl.SetTextureBlendMode:", err);
		os.exit(1);
	}
	
	pixels := make([][4]u8, mu.DEFAULT_ATLAS_WIDTH*mu.DEFAULT_ATLAS_HEIGHT);
	defer delete(pixels);
	for alpha, i in mu.default_atlas_alpha {
		pixels[i].rgb = 0xff;
		pixels[i].a   = alpha;
	}
	
	if err := sdl.UpdateTexture(editor.atlasTexture, nil, raw_data(pixels), 4*mu.DEFAULT_ATLAS_WIDTH); err != 0 {
		fmt.eprintln("sdl.UpdateTexture:", err);
		os.exit(1);
	}
	
	mu.init(&editor.uiContext,
					set_clipboard = proc(user_data: rawptr, text: string) -> (ok: bool) {
						cstr := strings.clone_to_cstring(text);
						sdl.SetClipboardText(cstr);
						delete(cstr);
						return true;
					},
					get_clipboard = proc(user_data: rawptr) -> (text: string, ok: bool) {
						if sdl.HasClipboardText() {
							text = string(sdl.GetClipboardText());
							ok = true;
						}
						return;
					},
					);
	
	editor.uiContext.text_width = mu.default_atlas_text_width;
	editor.uiContext.text_height = mu.default_atlas_text_height;
	
	sdl.AddEventWatch(proc "c"(data: rawptr, event: ^sdl.Event) -> c.int {
											if event.type == .WINDOWEVENT && event.window.event == .RESIZED {
												editor := (^EditorData)(data);
												editor.windowWidth = event.window.data1;
												editor.windowHeight = event.window.data2;
												render(editor);
											}
											return 0;
										}, editor);
	
	editor.gridScale = 30;
	editor.penSize = 3;
	
	editor.dstRect = {
		(editor.windowWidth)/4, (editor.windowHeight)/5,
		editor.windowWidth, editor.windowHeight,
	}
	
	editor.drawColor.r = 00;
	editor.drawColor.g = 86;
	editor.drawColor.b = 86;
	editor.drawColor.a = 255;
	
	return editor;
}

render :: proc "contextless"(editor: ^EditorData)
{
	// only push committed graphics onto cpu bitmap
	if editor.committed {
		CPUFillRect(&editor.bitmap, editor.commitRect, editor.drawColor);
	}
	
	viewport_rect := &sdl.Rect{};
	sdl.GetRendererOutputSize(editor.renderer, &viewport_rect.w, &viewport_rect.h);
	sdl.RenderSetViewport(editor.renderer, viewport_rect);
	sdl.RenderSetClipRect(editor.renderer, viewport_rect);
	sdl.SetRenderDrawColor(editor.renderer, editor.bg.r, editor.bg.g, editor.bg.b, editor.bg.a);
	sdl.RenderClear(editor.renderer);
	
	RenderFromBitmap(editor);
	// draw uncommitted graphics here
	if editor.drawUncommitted {
		sdl.SetRenderDrawColor(editor.renderer, 
													 editor.drawColor.r, editor.drawColor.g, editor.drawColor.b, editor.drawColor.a);
		sdl.RenderFillRect(editor.renderer, &editor.uncommitRect);
	}
	
	sdl.SetRenderDrawColor(editor.renderer, 86, 86, 0, 255);
	DrawGrid(editor);
	sdl.SetRenderDrawColor(editor.renderer, 255, 255, 255, 255);
	DrawBitmapBounds(editor);
	
	////////////////////////////////
	// Draw UI
	////////////////////////////////
	render_texture :: proc "contextless" (editor: ^EditorData, dst: ^sdl.Rect, src: mu.Rect, color: mu.Color) {
		dst.w = src.w;
		dst.h = src.h;
		
		sdl.SetTextureAlphaMod(editor.atlasTexture, color.a);
		sdl.SetTextureColorMod(editor.atlasTexture, color.r, color.g, color.b);
		sdl.RenderCopy(editor.renderer, editor.atlasTexture, &sdl.Rect{src.x, src.y, src.w, src.h}, dst);
	}
	
	command_backing: ^mu.Command;
	for variant in mu.next_command_iterator(&editor.uiContext, &command_backing) {
		switch cmd in variant {
			case ^mu.Command_Text: {
				dst := sdl.Rect{cmd.pos.x, cmd.pos.y, 0, 0}
				for ch in cmd.str {
					if ch&0xc0 != 0x80 {
						r := min(int(ch), 127)
							src := mu.default_atlas[mu.DEFAULT_ATLAS_FONT + r]
							render_texture(editor, &dst, src, cmd.color)
							dst.x += dst.w
					}
				}
			}
			case ^mu.Command_Rect: {
				sdl.SetRenderDrawColor(editor.renderer, cmd.color.r, cmd.color.g, cmd.color.b, cmd.color.a);
				sdl.RenderFillRect(editor.renderer, &sdl.Rect{cmd.rect.x, cmd.rect.y, cmd.rect.w, cmd.rect.h});
			}
			case ^mu.Command_Icon: {
				src := mu.default_atlas[cmd.id];
				x := cmd.rect.x + (cmd.rect.w - src.w)/2;
				y := cmd.rect.y + (cmd.rect.h - src.h)/2;
				render_texture(editor, &sdl.Rect{x, y, 0, 0}, src, cmd.color);
			}
			case ^mu.Command_Clip: {
				sdl.RenderSetClipRect(editor.renderer, &sdl.Rect{cmd.rect.x, cmd.rect.y, cmd.rect.w, cmd.rect.h});
			}
			case ^mu.Command_Jump: unreachable();
		}
	}
	
	sdl.RenderPresent(editor.renderer);
}

update :: proc(editor: ^EditorData, input: ^Input)
{
	editor.penSize = max(editor.penSize + input.scrollY, 1);
	
	if input.mmb.down {
		editor.dstRect.x += input.mousePos.x - input.prevMousePos.x;
		editor.dstRect.y += input.mousePos.y - input.prevMousePos.y;
		
		shouldWarpMouse : b32 = false;
		if input.mousePos.x > editor.windowWidth {
			input.mousePos.x = 0;
			input.prevMousePos.x = 0;
			shouldWarpMouse = true;
		}
		if input.mousePos.y > editor.windowHeight {
			input.mousePos.y = 0;
			input.prevMousePos.y = 0;
			shouldWarpMouse = true;
		}
		if input.mousePos.x < 0 {
			input.mousePos.x = editor.windowWidth;
			input.prevMousePos.x = editor.windowWidth;
			shouldWarpMouse = true;
		}
		if input.mousePos.y < 0 {
			input.mousePos.y = editor.windowHeight;
			input.prevMousePos.y = editor.windowHeight;
			shouldWarpMouse = true;
		}
		
		if shouldWarpMouse {
			sdl.WarpMouseInWindow(editor.window, input.mousePos.x, input.mousePos.y);
		}
	}
	
	drawSize : i32 = editor.gridScale*editor.penSize;
	
	penGridPos := PenPosFromMouse(input.mousePos, 
																{editor.dstRect.x, editor.dstRect.y}, 
																editor.gridScale, drawSize);
	
	editor.commitRect = i32_rect{
		penGridPos.x, penGridPos.y,
		editor.penSize, editor.penSize,
	}
	
	editor.uncommitRect = i32_rect{
		penGridPos.x*editor.gridScale + editor.dstRect.x, 
		penGridPos.y*editor.gridScale + editor.dstRect.y,
		drawSize, drawSize,
	}
	
	if input.lmb.up {
		if editor.allowBmpResize {
			ExpandMap(editor, &editor.commitRect);
		}
		editor.committed = true;
	}
	
	editor.drawUncommitted = !input.mmb.down;
}

main :: proc()
{
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator;
		mem.tracking_allocator_init(&track, context.allocator);
		context.allocator = mem.tracking_allocator(&track);
		
		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map));
				for _, entry in track.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location);
				}
			}
			if len(track.bad_free_array) > 0 {
				fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array));
				for entry in track.bad_free_array {
					fmt.eprintf("- %p @ %v\n", entry.memory, entry.location);
				}
			}
			mem.tracking_allocator_destroy(&track);
		}
	}
	
	editor := EditorInitAll();
	
	frameInput: Input;
	
	fileName : cstring = "sketch.bmp";
	
	TargetFPS : f32 = 60.0;
	deltaTime : f32 = 0; // in seconds
	pause : b32 = false;
	for !editor.quit {
		free_all(context.temp_allocator);
		startTick : time.Tick = time.tick_now();
		InitInputForFrame(&frameInput);
		
		event: sdl.Event;
		for sdl.PollEvent(&event)
		{
#partial switch event.type {
			case Event.QUIT: {
				editor.quit = true;
			}
			
			case Event.TEXTINPUT: {
				//mem.copy_non_overlapping(&frameInput.text[0], &event.text.text[0], sdl.TEXTINPUTEVENT_TEXT_SIZE);
				mu.input_text(&editor.uiContext, string(cstring(&event.text.text[0])));
			}
			
			case Event.WINDOWEVENT: {
#partial switch event.window.event {
				case sdl.WindowEventID.RESIZED: fallthrough;
				case sdl.WindowEventID.SIZE_CHANGED: {
					editor.windowWidth = event.window.data1;
					editor.windowHeight = event.window.data2;
				}
			}
		}
		
		case Event.KEYDOWN, Event.KEYUP: {
			if event.type == Event.KEYDOWN {
#partial switch event.key.keysym.sym {
				case Key.p: {
					pause = !pause;
				}
				
				case Key.r: {
					editor.allowBmpResize = !editor.allowBmpResize;
				}
				
				case Key.LCTRL, Key.RCTRL: {
					frameInput.ctrl.down = true;
					frameInput.ctrl.timestamp = event.key.timestamp;
				}
			}
		}
		else { // keyup
#partial switch event.key.keysym.sym {
			case Key.s: {
				if(frameInput.ctrl.down) {
					SaveToFile(editor, fileName);
				}
			}
			
			case Key.LCTRL, Key.RCTRL: {
				frameInput.ctrl.down = false;
				frameInput.ctrl.up = true;
			}
		}
	}
	
	fn := mu.input_key_down if event.type == .KEYDOWN else mu.input_key_up;
	
#partial switch event.key.keysym.sym {
	case .LSHIFT:    fn(&editor.uiContext, .SHIFT);
	case .RSHIFT:    fn(&editor.uiContext, .SHIFT);
	case .LCTRL:     fn(&editor.uiContext, .CTRL);
	case .RCTRL:     fn(&editor.uiContext, .CTRL);
	case .LALT:      fn(&editor.uiContext, .ALT);
	case .RALT:      fn(&editor.uiContext, .ALT);
	case .RETURN:    fn(&editor.uiContext, .RETURN);
	case .KP_ENTER:  fn(&editor.uiContext, .RETURN);
	case .BACKSPACE: fn(&editor.uiContext, .BACKSPACE);
	
	case .LEFT:  fn(&editor.uiContext, .LEFT);
	case .RIGHT: fn(&editor.uiContext, .RIGHT);
	case .HOME:  fn(&editor.uiContext, .HOME);
	case .END:   fn(&editor.uiContext, .END);
	case .A:     fn(&editor.uiContext, .A);
	case .X:     fn(&editor.uiContext, .X);
	case .C:     fn(&editor.uiContext, .C);
	case .V:     fn(&editor.uiContext, .V);
}
}

case Event.MOUSEBUTTONDOWN: {
	switch event.button.button {
		case sdl.BUTTON_LEFT: {
			mu.input_mouse_down(&editor.uiContext, event.button.x, event.button.y, .LEFT);
			frameInput.lmb.down = true;
			frameInput.lmb.timestamp = event.button.timestamp;
		}
		case sdl.BUTTON_MIDDLE: {
			mu.input_mouse_down(&editor.uiContext, event.button.x, event.button.y, .MIDDLE);
			frameInput.mmb.down = true;
			frameInput.mmb.timestamp = event.button.timestamp;
		}
		case sdl.BUTTON_RIGHT: {
			mu.input_mouse_down(&editor.uiContext, event.button.x, event.button.y, .RIGHT);
			frameInput.rmb.down = true;
			frameInput.rmb.timestamp = event.button.timestamp;
		}
	}
}

case Event.MOUSEBUTTONUP: {
	switch event.button.button {
		case sdl.BUTTON_LEFT: {
			mu.input_mouse_up(&editor.uiContext, event.button.x, event.button.y, .LEFT);
			frameInput.lmb.down = false;
			frameInput.lmb.up = true;
		}
		case sdl.BUTTON_MIDDLE: {
			mu.input_mouse_up(&editor.uiContext, event.button.x, event.button.y, .MIDDLE);
			frameInput.mmb.down = false;
			frameInput.mmb.up = true;
		}
		case sdl.BUTTON_RIGHT: {
			mu.input_mouse_up(&editor.uiContext, event.button.x, event.button.y, .RIGHT);
			frameInput.rmb.down = false;
			frameInput.rmb.up = true;
		}
	}
}

case Event.MOUSEWHEEL: {
	frameInput.scrollY = event.wheel.y;
	mu.input_scroll(&editor.uiContext, event.wheel.x * 30, event.wheel.y * -30);
}
}
}

// NOTE: This returns something that could be useful?
sdl.GetMouseState(&frameInput.mousePos.x, &frameInput.mousePos.y);
frameInput.timestamp = sdl.GetTicks();
mu.input_mouse_move(&editor.uiContext, frameInput.mousePos.x, frameInput.mousePos.y);

if !pause {
	update(editor, &frameInput);
	
	mu.begin(&editor.uiContext);
	ui_update(editor);
	mu.end(&editor.uiContext);
	
	render(editor);
}

frameInput.prevMousePos = frameInput.mousePos;
editor.committed = false;

////////////////////////////////
// end frame
duration : time.Duration = time.tick_since(startTick);
deltaTime = 1000.0 / TargetFPS;
durationMS := f32(time.duration_milliseconds(duration));
if(durationMS < deltaTime) {
	duration = time.Duration(1000000000 / u64(TargetFPS)) - duration;
	//fmt.println("time sleep duration:", duration);
	time.accurate_sleep(duration);
}
else {
	fmt.println("Missed target fps:", duration);
}
duration = time.tick_since(startTick);
deltaTime = f32(time.duration_seconds(duration));
//fmt.printf("frame time: %f\n", deltaTime*1000.0);
}

delete(editor.bitmap.bytes);
sdl.DestroyWindow(editor.window);
sdl.DestroyRenderer(editor.renderer);
free(editor);
sdl.Quit();
}

u8_slider :: proc(ctx: ^mu.Context, val: ^u8, lo, hi: u8) -> (res: mu.Result_Set)
{
	mu.push_id(ctx, uintptr(val));
	
	@static tmp: mu.Real;
	tmp = mu.Real(val^);
	res = mu.slider(ctx, &tmp, mu.Real(lo), mu.Real(hi), 0, "%.0f", {.ALIGN_CENTER});
	val^ = u8(tmp);
	mu.pop_id(ctx);
	return;
}

ui_update :: proc(editor: ^EditorData) {
	opts := mu.Options{.NO_CLOSE, .NO_SCROLL, .NO_RESIZE}
	
	ctx := &editor.uiContext;
	
	if mu.window(ctx, "Demo Window", {40, 260, 200, 224}, opts) {
		win := mu.get_current_container(ctx);
		winRect := mu.Rect{win.rect.x, win.rect.y - ctx.style.title_height, win.rect.w, win.rect.h + 2*ctx.style.title_height};
		if mu.rect_overlaps_vec2(winRect, ctx.mouse_pos) {
			editor.committed = false;
			editor.drawUncommitted = false;
		}
		
		if .ACTIVE in mu.header(ctx, "Draw Colour", {.EXPANDED}) {
			mu.layout_row(ctx, {-78, -1}, 68);
			mu.layout_begin_column(ctx);
			{
				mu.layout_row(ctx, {46, -1}, 0);
				mu.label(ctx, "Red:");   u8_slider(ctx, &editor.drawColor.r, 0, 255);
				mu.label(ctx, "Green:"); u8_slider(ctx, &editor.drawColor.g, 0, 255);
				mu.label(ctx, "Blue:");  u8_slider(ctx, &editor.drawColor.b, 0, 255);
			}
			mu.layout_end_column(ctx);
			
			r := mu.layout_next(ctx);
			mu.draw_rect(ctx, r, mu.Color(editor.drawColor));
			mu.draw_box(ctx, mu.expand_rect(r, 1), ctx.style.colors[.BORDER]);
			mu.draw_control_text(ctx, fmt.tprintf("#%02x%02x%02x", editor.drawColor.r, editor.drawColor.g, editor.drawColor.b), r, .TEXT, {.ALIGN_CENTER});
		}
		
		if .ACTIVE in mu.header(ctx, "Background Colour", {.EXPANDED}) {
			mu.layout_row(ctx, {-78, -1}, 68);
			mu.layout_begin_column(ctx);
			{
				mu.layout_row(ctx, {46, -1}, 0);
				mu.label(ctx, "Red:");   u8_slider(ctx, &editor.bg.r, 0, 255);
				mu.label(ctx, "Green:"); u8_slider(ctx, &editor.bg.g, 0, 255);
				mu.label(ctx, "Blue:");  u8_slider(ctx, &editor.bg.b, 0, 255);
			}
			mu.layout_end_column(ctx);
			
			r := mu.layout_next(ctx);
			mu.draw_rect(ctx, r, editor.bg);
			mu.draw_box(ctx, mu.expand_rect(r, 1), ctx.style.colors[.BORDER]);
			mu.draw_control_text(ctx, fmt.tprintf("#%02x%02x%02x", editor.bg.r, editor.bg.g, editor.bg.b), r, .TEXT, {.ALIGN_CENTER});
		}
	}
}