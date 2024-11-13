package editor

import sdl "vendor:sdl2"
import "base:runtime"
import "core:os"
import "core:c"
import "core:fmt"
import "core:time"
import "core:mem"
import "core:math"

/* DISCLAIMER:
This doesn't do what I want it to do yet!
*/

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

// sdl.SaveBMP() saves to argb for some reason
Color :: struct {
	b: u8,
	g: u8,
	r: u8,
	a: u8,
}

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
	windowWidth: i32,
	windowHeight: i32,
	quit: b32,
	
	drawColor: Color,
	
	gridScale: i32,
	penSize: i32,
	
	bitmap: Bitmap,
	bitmapCapacity: int, // in pixels
	allowBmpResize: b32,
	
	dstRect: i32_rect,
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

DrawBitmapBounds :: proc(editor: ^EditorData)
{
	if editor.bitmap.width > 0 && editor.bitmap.height > 0 {
		thickness : i32 = 2;
		scc(sdl.RenderSetScale(editor.renderer, f32(thickness), f32(thickness)));
		
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
		
		scc(sdl.RenderSetScale(editor.renderer, 1, 1));
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
		
		//fmt.println(loadSurface.format);
		assert(loadSurface.format.Ashift == 24 && loadSurface.format.Rshift == 16 &&
					 loadSurface.format.Gshift == 8 && loadSurface.format.Bshift == 0,
					 "Different formats to argb are not supported for now");
		
		// NOTE: SDL_LoadBMP calls into SDL_CreateSurface which uses SDL_aligned_alloc
    // which probably works differently from SDL_malloc/realloc
		bmpSize := editor.bitmapCapacity;
		// TODO: If px format is not rgba32, change it so it is
		editor.bitmap.bytes = make([]u32, bmpSize);
		mem.copy_non_overlapping(raw_data(editor.bitmap.bytes), 
														 loadSurface.pixels, bmpSize*size_of(editor.bitmap.bytes[0]));
		
		sdl.FreeSurface(loadSurface);
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

CPUFillRect :: proc(bitmap: ^Bitmap, rect: i32_rect, c: Color)
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

RenderFromBitmap :: proc(editor: ^EditorData)
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
			px := transmute(Color)bitmap.bytes[y*bitmap.width + x];
			
			rect = {
				x*pxSize + editor.dstRect.x, y*pxSize + editor.dstRect.y,
				pxSize, pxSize,
			}
			
			scc(sdl.SetRenderDrawColor(editor.renderer, px.r, px.g, px.b, px.a));
			scc(sdl.RenderFillRect(editor.renderer, &rect));
		}
	}
}

EditorInitAll :: proc(editor: ^EditorData)
{
	editor.windowWidth  = 1920*0.75;
	editor.windowHeight = 1080*0.75;
	//sdl.SetHint("SDL_MOUSE_RELATIVE_SYSTEM_SCALE", "1");
	scc(sdl.Init(sdl.INIT_VIDEO));
	editor.window = sdl.CreateWindow("Odin px paint", 40, 60, 
																	 editor.windowWidth, editor.windowHeight, 
																	 sdl.WINDOW_RESIZABLE);
	assert(editor.window != nil, "Could not create window");
	
	editor.renderer = sdl.CreateRenderer(editor.window, -1, sdl.RENDERER_ACCELERATED);
	assert(editor.renderer != nil, "Could not create renderer");
	
	editor.gridScale = 30;
	editor.penSize = 3;
	
	editor.dstRect = {
		editor.gridScale*6, editor.gridScale*4,// editor.gridScale/2, editor.gridScale/2,
		editor.windowWidth, editor.windowHeight,
	}
	
	editor.drawColor.r = 00;
	editor.drawColor.g = 86;
	editor.drawColor.b = 86;
	editor.drawColor.a = 255;
}

main :: proc()
{
	editor := new(EditorData);
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
						fmt.printfln("Usage: %s [file.bmp]", os.args[0]);
						os.exit(0);
					}
					else {
						fmt.printfln("Ignoring unknown flag '%s'", arg);
					}
				}
				else {
					if arg == "h" || arg == "?" {
						fmt.printfln("Usage: %s [file.bmp]", os.args[0]);
						os.exit(0);
					}
					else {
						fmt.printfln("Ignoring unknown flag '%s'", arg);
					}
				}
			}
			else if arg[0] == '/' {
				if arg[1:] == "?" {
					// windows style '/?'
					fmt.printfln("Usage: %s [file.bmp]", os.args[0]);
					os.exit(0);
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
	
	EditorInitAll(editor);
	if editor.bitmap.bytes == nil {
		editor.bitmapCapacity = 1024*1024;
		editor.bitmap = MakeEmptyBitmap(editor.bitmapCapacity);
		editor.bitmap.width = 24;
		editor.bitmap.height = 18;
	}
	
	frameInput : Input;
	
	fileName : cstring = "sketch.bmp";
	
	TargetFPS : f32 = 60.0;
	deltaTime : f32 = 0; // in seconds
	pause : b32 = false;
	for !editor.quit {
		startTick : time.Tick = time.tick_now();
		InitInputForFrame(&frameInput);
		
		event : sdl.Event;
		for sdl.PollEvent(&event)
		{
#partial switch event.type {
			case Event.QUIT: {
				editor.quit = true;
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
		
		case Event.KEYDOWN: {
#partial switch event.key.keysym.sym {
			case Key.p: {
				pause = !pause;
			}
			
			case Key.r: {
				editor.allowBmpResize = !editor.allowBmpResize;
			}
			
			case Key.c: {
				// TODO: Go to center of drawing
			}
			
			case Key.LCTRL: fallthrough;
			case Key.RCTRL: {
				frameInput.ctrl.down = true;
				frameInput.ctrl.timestamp = event.key.timestamp;
			}
		}
	}
	
	case Event.KEYUP: {
#partial switch event.key.keysym.sym {
		case Key.LCTRL: fallthrough;
		case Key.RCTRL: {
			frameInput.ctrl.down = false;
			frameInput.ctrl.up = true;
		}
		
		case Key.s: {
			if(frameInput.ctrl.down) {
				SaveToFile(editor, fileName);
			}
		}
	}
}

case Event.MOUSEBUTTONDOWN: {
	switch event.button.button {
		case sdl.BUTTON_LEFT: {
			frameInput.lmb.down = true;
			frameInput.lmb.timestamp = event.button.timestamp;
		}
		case sdl.BUTTON_MIDDLE: {
			frameInput.mmb.down = true;
			frameInput.mmb.timestamp = event.button.timestamp;
		}
		case sdl.BUTTON_RIGHT: {
			frameInput.rmb.down = true;
			frameInput.rmb.timestamp = event.button.timestamp;
		}
	}
}

case Event.MOUSEBUTTONUP: {
	switch event.button.button {
		case sdl.BUTTON_LEFT: {
			frameInput.lmb.down = false;
			frameInput.lmb.up = true;
		}
		case sdl.BUTTON_MIDDLE: {
			frameInput.mmb.down = false;
			frameInput.mmb.up = true;
		}
		case sdl.BUTTON_RIGHT: {
			frameInput.rmb.down = false;
			frameInput.rmb.up = true;
		}
	}
}

case Event.MOUSEWHEEL: {
	frameInput.scrollY = event.wheel.y;
}
}
}

// NOTE: This returns something that could be useful?
sdl.GetMouseState(&frameInput.mousePos.x, &frameInput.mousePos.y);
frameInput.timestamp = sdl.GetTicks();

if !pause {
	if frameInput.ctrl.down {
		gval := u8(255.0*(1.0 + math.sin(f32(i32(frameInput.timestamp)*frameInput.scrollY)/37.0)));
		editor.drawColor.g = u8(int(gval) + int(editor.drawColor.g) % 255);
		
		rval := u8(255.0*(1.0 + math.sin(f32(i32(frameInput.timestamp)*frameInput.scrollY)/71.0)));
		editor.drawColor.r = u8(int(rval) + int(editor.drawColor.r) % 255);
		
	}
	else {
		editor.penSize = max(editor.penSize + frameInput.scrollY, 1);
	}
	
	if frameInput.mmb.down {
		editor.dstRect.x += frameInput.mousePos.x - frameInput.prevMousePos.x;
		editor.dstRect.y += frameInput.mousePos.y - frameInput.prevMousePos.y;
		
		shouldWarpMouse : b32 = false;
		if frameInput.mousePos.x > editor.windowWidth {
			frameInput.mousePos.x = 0;
			frameInput.prevMousePos.x = 0;
			shouldWarpMouse = true;
		}
		if frameInput.mousePos.y > editor.windowHeight {
			frameInput.mousePos.y = 0;
			frameInput.prevMousePos.y = 0;
			shouldWarpMouse = true;
		}
		if frameInput.mousePos.x < 0 {
			frameInput.mousePos.x = editor.windowWidth;
			frameInput.prevMousePos.x = editor.windowWidth;
			shouldWarpMouse = true;
		}
		if frameInput.mousePos.y < 0 {
			frameInput.mousePos.y = editor.windowHeight;
			frameInput.prevMousePos.y = editor.windowHeight;
			shouldWarpMouse = true;
		}
		
		if shouldWarpMouse {
			sdl.WarpMouseInWindow(editor.window, frameInput.mousePos.x, frameInput.mousePos.y);
		}
	}
	
	drawSize : i32 = editor.gridScale*editor.penSize;
	
	penGridPos := PenPosFromMouse(frameInput.mousePos, 
																{editor.dstRect.x, editor.dstRect.y}, 
																editor.gridScale, drawSize);
	
	commitRect := i32_rect{
		penGridPos.x, penGridPos.y,
		editor.penSize, editor.penSize,
	}
	
	uncommitRect := i32_rect{
		penGridPos.x*editor.gridScale + editor.dstRect.x, 
		penGridPos.y*editor.gridScale + editor.dstRect.y,
		drawSize, drawSize,
	}
	
	////////////////////////////////
	// Render
	////////////////////////////////
	// only push committed graphics onto cpu bitmap
	
	if frameInput.lmb.up {
		if editor.allowBmpResize {
			ExpandMap(editor, &commitRect);
		}
		CPUFillRect(&editor.bitmap, commitRect, editor.drawColor);
	}
	
	//sdl.RenderPresent(editor.renderer);
	//scc(sdl.SetRenderTarget(editor.renderer, nil));
	scc(sdl.SetRenderDrawColor(editor.renderer, 0, 0, 0, 255));
	scc(sdl.RenderClear(editor.renderer));
	//sdl.RenderCopy(editor.renderer, texture, nil, &destRect);
	RenderFromBitmap(editor);
	
	// draw uncommitted graphics here
	if !frameInput.mmb.down {
		scc(sdl.SetRenderDrawColor(editor.renderer, 
															 editor.drawColor.r, editor.drawColor.g, editor.drawColor.b, editor.drawColor.a));
		scc(sdl.RenderFillRect(editor.renderer, &uncommitRect));
	}
	
	scc(sdl.SetRenderDrawColor(editor.renderer, 86, 86, 0, 255));
	DrawGrid(editor);
	scc(sdl.SetRenderDrawColor(editor.renderer, 255, 255, 255, 255));
	DrawBitmapBounds(editor);
	
	sdl.RenderPresent(editor.renderer);
}

frameInput.prevMousePos = frameInput.mousePos;

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

sdl.Quit();
}
