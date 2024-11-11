#include <SDL3/SDL.h>
#include <SDL3/SDL_timer.h>
#include <stdio.h>
#include <string.h>

#ifndef RELEASE_MODE
#define Assert(Expr) if(!(Expr)) {*(int *)0=0;}
#define debug_log(...) printf(__VA_ARGS__)
#else
#define Assert(Expr)
#define debug_log(...)
#endif

#define max(a, b) ((a) > (b)) ? (a) : (b)
#define min(a, b) ((a) > (b)) ? (b) : (a)

typedef Sint8 i8;
typedef Sint16 i16;
typedef Sint32 i32;
typedef Sint64 i64;

typedef Uint8 u8;
typedef Uint16 u16;
typedef Uint32 u32;
typedef Uint64 u64;

typedef i8 b8;
typedef i32 b32;

typedef float f32;
typedef double f64;

#define v2 SDL_FPoint
#define v2i SDL_Point
#define i32_rect SDL_Rect

// SdlCheckCode
void scc(bool ok)
{
  if(!ok) {
    fprintf(stderr, "SDL ERROR: %s\n", SDL_GetError());
    exit(1);
  }
}

// NOTE: Timestamps are in nanoseconds
typedef struct button {
  b32 Down;
  b32 Up;
  u64 Timestamp;
} button;

typedef struct input {
  button Lmb;
  button Mmb;
  button Rmb;
  button Ctrl;
  f32 ScrollY;
  
  v2 MousePos;
  v2 PrevMousePos;
  
  u64 Timestamp;
} input;

typedef struct bitmap {
  u32 *Bytes;
  i32 Width;
  i32 Height;
} bitmap;

typedef struct editor_data {
  SDL_Window *Window;
  SDL_Renderer *Renderer;
  i32 WindowWidth;
  i32 WindowHeight;
  b32 Quit;
  
  SDL_Color DrawColor;
  
  i32 GridScale;
  i32 PenSize;
  
  bitmap Bitmap;
  int BitmapCapacity;
  b32 AllowBmpResize;
  
  i32_rect DstRect;
} editor_data;

void InitInputForFrame(input *Input)
{
  Input->Lmb.Up = false;
	Input->Mmb.Up = false;
	Input->Rmb.Up = false;
	Input->Ctrl.Up = false;
	
	Input->ScrollY = 0.0f;
}

i32 remainder_i32(i32 dividend, i32 divisor) {
  i32 result = dividend % divisor;
  if((result < 0 && divisor > 0) || (result > 0 && divisor < 0)) {
    result += divisor;
  }
  return result;
}

void DrawGrid(editor_data *Editor)
{
  // draw debug (?) grid
  
  i32 XIni = Editor->DstRect.x % Editor->GridScale;
  i32 YIni = Editor->DstRect.y % Editor->GridScale;
  if(Editor->DstRect.x < 0) {
    XIni += Editor->GridScale;
  }
  if(Editor->DstRect.y < 0) {
    YIni += Editor->GridScale;
  }
  
  for(i32 y = 0; y <= Editor->WindowHeight; y += Editor->GridScale)
  {
    scc(SDL_RenderLine(Editor->Renderer, 0, (f32)(y + YIni),
                       (f32)Editor->WindowWidth, (f32)(y + YIni)));
  }
  for(i32 x = 0; x <= Editor->WindowWidth; x += Editor->GridScale)
  {
    scc(SDL_RenderLine(Editor->Renderer, (f32)(x + XIni), 0,
                       (f32)(x + XIni), (f32)Editor->WindowHeight));
  }
}

void DrawBitmapBounds(editor_data *Editor)
{
  if(Editor->Bitmap.Width > 0 && Editor->Bitmap.Height > 0) {
    i32 thickness = 2;
    scc(SDL_SetRenderScale(Editor->Renderer, (f32)thickness, (f32)thickness));
		
		i32 XIni = Editor->DstRect.x/thickness;
		i32 YIni = Editor->DstRect.y/thickness;
		i32 XEnd = (Editor->Bitmap.Width*Editor->GridScale + Editor->DstRect.x)/thickness;
		i32 YEnd = (Editor->Bitmap.Height*Editor->GridScale + Editor->DstRect.y)/thickness;
		
    if(XIni >= 0) {
      SDL_RenderLine(Editor->Renderer, (f32)XIni, (f32)YIni, (f32)XIni, (f32)YEnd);
		}
    if(YIni >= 0) {
      SDL_RenderLine(Editor->Renderer, (f32)XIni, (f32)YIni, (f32)XEnd, (f32)YIni);
		}
		if(XEnd <= Editor->WindowWidth) {
      SDL_RenderLine(Editor->Renderer, (f32)XEnd, (f32)YIni, (f32)XEnd, (f32)YEnd);
		}
    if(YEnd <= Editor->WindowHeight) {
      SDL_RenderLine(Editor->Renderer, (f32)XIni, (f32)YEnd, (f32)XEnd, (f32)YEnd);
		}
		
		scc(SDL_SetRenderScale(Editor->Renderer, 1, 1));
	}
}

v2i PenPosFromMouse(editor_data *Editor, v2 MousePos, i32 DrawSize)
{
  i32 GridScale = Editor->GridScale;
  
  // Thanks @danwil for the help with this!
	i32 PenX = (i32)MousePos.x - DrawSize/2 - Editor->DstRect.x;
	i32 PenY = (i32)MousePos.y - DrawSize/2 - Editor->DstRect.y;
	
	v2i PenGridPos = {
		(i32)SDL_floorf((f32)(PenX + GridScale/2) / (f32)GridScale),
		(i32)SDL_floorf((f32)(PenY + GridScale/2) / (f32)GridScale),
	};
	
	// Ensure pen entirely on grid?
	//penGridPos.x = max(min(penGridPos.x, maxGridX - penSize), 0);
	//penGridPos.y = max(min(penGridPos.y, maxGridY - penSize), 0);
	
	return PenGridPos;
}

bitmap MakeEmptyBitmap(int cap)
{
  bitmap Result;
  Result.Bytes = (u32*)malloc(cap*sizeof(Result.Bytes[0]));
  return Result;
}

void SaveToFile(editor_data *Editor, char *Filename)
{
	(void)Editor; (void)Filename;
  Assert(!"unimplemented");
}

// oldSize must be in bytes, newSize in u32s
void ResizeBitmapMem(bitmap *Bitmap, int NewSize, int *Cap)
{
  if(NewSize > (*Cap*sizeof(Bitmap->Bytes[0]))) {
		*Cap = NewSize + (int)(Bitmap->Width*8 + Bitmap->Height*8);
		
    void *temp = realloc(Bitmap->Bytes, *Cap*sizeof(Bitmap->Bytes[0]));
    // TODO: Handle failure?
    Assert(temp);
    Bitmap->Bytes = (u32*)temp;
	}
}

// expand the bitmap to accomodate the rectangle
void ExpandMap(editor_data *Editor, i32_rect *Rect)
{
	bitmap *Bitmap = &Editor->Bitmap;
  
  int BmpSize = (int)(Bitmap->Width*Bitmap->Height)*sizeof(Bitmap->Bytes[0]);
	int NewSize;
  
	// NOTE: Order matters! if rect.y < 0 -> rect.y = 0;
	//  must happen before other check
	if(Rect->y < 0) {
    NewSize = (int)(Bitmap->Width*(Bitmap->Height + (-Rect->y)));
		ResizeBitmapMem(Bitmap, NewSize, &Editor->BitmapCapacity);
		
    u32 *Dst = Bitmap->Bytes + ((-Rect->y)*Bitmap->Width);
		u32 *Src = Bitmap->Bytes;
    memmove(Dst, Src, BmpSize);
    // NOTE: If I want to clear to a color I'll need my own memset
		// for u32s, for this tool (map editor) it's not necessary though
		memset(Src, 0, (int)((-Rect->y)*Bitmap->Width)*sizeof(Bitmap->Bytes[0]));
    
		Bitmap->Height += -Rect->y;
		Editor->DstRect.y += Rect->y*Editor->GridScale;
		Rect->y = 0;
		BmpSize = NewSize*sizeof(Bitmap->Bytes[0]);
	}
	
  if(Rect->y + Rect->h > Bitmap->Height) {
    Bitmap->Height = Rect->y + Rect->h;
		NewSize = (int)(Bitmap->Width*Bitmap->Height);
		ResizeBitmapMem(Bitmap, NewSize, &Editor->BitmapCapacity);
		BmpSize = NewSize*sizeof(Bitmap->Bytes[0]);
	}
	
	// NOTE: Order matters! if rect.x < 0 -> rect.x = 0;
	//  must happen before other check
	// This could be wrong, it's pretty much copypasta'd from the next thing
	if(Rect->x < 0) {
		i32 Offset = -Rect->x;
    NewSize = (int)((Bitmap->Width + Offset)*Bitmap->Height);
		ResizeBitmapMem(Bitmap, NewSize, &Editor->BitmapCapacity);
		
    int RowSize = (int)(Bitmap->Width)*sizeof(Bitmap->Bytes[0]);
		u32 *Dst;
    u32 *Src;
    for(i32 y = Bitmap->Height - 1; y >= 0; y--)
		{
			i32 SrcLoc = Bitmap->Width*y;
      i32 DstLoc = (Bitmap->Width + Offset)*y + Offset;
			Dst = Bitmap->Bytes + DstLoc;
			Src = Bitmap->Bytes + SrcLoc;
			memmove(Dst, Src, RowSize);
      if(DstLoc - Offset >= 0) {
        u32 *ClearPtr = Bitmap->Bytes + DstLoc - Offset;
				memset(ClearPtr, 0, (int)Offset*sizeof(Bitmap->Bytes[0]));
			}
		}
		
		Bitmap->Width += -Rect->x;
		Editor->DstRect.x += Rect->x*Editor->GridScale;
		Rect->x = 0;
		BmpSize = NewSize*sizeof(Bitmap->Bytes[0]);
	}
	
  if(Rect->x + Rect->w > Bitmap->Width) {
    i32 Offset = Rect->x + Rect->w - Bitmap->Width;
    NewSize = (int)((Bitmap->Width + Offset)*Bitmap->Height);
		ResizeBitmapMem(Bitmap, NewSize, &Editor->BitmapCapacity);
		
		int RowSize = (int)(Bitmap->Width)*sizeof(Bitmap->Bytes[0]);
		u32 *Dst;
    u32 *Src;
    for(i32 y = Bitmap->Height - 1; y > 0; y--)
    {
			i32 SrcLoc = Bitmap->Width*y;
			i32 DstLoc = (Bitmap->Width + Offset)*y;
			Dst = Bitmap->Bytes + DstLoc;
			Src = Bitmap->Bytes + SrcLoc;
			memmove(Dst, Src, RowSize);
      if(DstLoc - Offset >= 0) {
        u32 *ClearPtr = Bitmap->Bytes + DstLoc - Offset;
				memset(ClearPtr, 0, (int)Offset*sizeof(Bitmap->Bytes[0]));
      }
		}
		
		Bitmap->Width += Offset;
		BmpSize = NewSize*sizeof(Bitmap->Bytes[0]);
	}
}

void CPUFillRect(bitmap *Bitmap, i32_rect Rect, SDL_Color c)
{
	if(Rect.x < 0) {
    Rect.w += Rect.x;
    Rect.x = 0;
  }
  
  if(Rect.y < 0) {
    Rect.h += Rect.y;
		Rect.y = 0;
	}
	
  i32 Right = Rect.x + Rect.w;
	if(Right > Bitmap->Width) {
    Right = Bitmap->Width;
	}
	
	i32 Bot = Rect.y + Rect.h;
	if(Bot > Bitmap->Height) {
    Bot = Bitmap->Height;
	}
	
  for(i32 y = Rect.y; y < Bot; y++)
	{
		for(i32 x = Rect.x; x < Right; x++)
		{
			Bitmap->Bytes[y*Bitmap->Width + x] = *((u32*)&c);
		}
	}
}

void RenderFromBitmap(editor_data *Editor)
{
	bitmap *Bitmap = &Editor->Bitmap;
  i32 PxSize = Editor->GridScale;
  
	i32 XIni = max(-Editor->DstRect.x/PxSize, 0);
	i32 YIni = max(-Editor->DstRect.y/PxSize, 0);
	
	// NOTE(vic): +1 for tiles that can be half seen only
	i32 XEnd = min(Bitmap->Width, Editor->WindowWidth/PxSize + XIni + 1);
	i32 YEnd = min(Bitmap->Height, Editor->WindowHeight/PxSize + YIni + 1);
	
  SDL_FRect Rect;
	Rect.w = (f32)PxSize;
  Rect.h = (f32)PxSize;
  
  for(i32 y = YIni; y < YEnd; y++)
	{
		for(i32 x = XIni; x < XEnd; x++)
		{
      SDL_Color px = *((SDL_Color*)&Bitmap->Bytes[y*Bitmap->Width + x]);
			
			Rect.x = (f32)(x*PxSize + Editor->DstRect.x);
      Rect.y = (f32)(y*PxSize + Editor->DstRect.y);
			
			scc(SDL_SetRenderDrawColor(Editor->Renderer, px.r, px.g, px.b, px.a));
			scc(SDL_RenderFillRect(Editor->Renderer, &Rect));
		}
	}
}

editor_data *EditorInitAll()
{
	editor_data *Editor = (editor_data*)malloc(sizeof(editor_data));
	Editor->WindowWidth  = (i32)(1920*0.75);
	Editor->WindowHeight = (i32)(1080*0.75);
	//sdl.SetHint("SDL_MOUSE_RELATIVE_SYSTEM_SCALE", "1");
	scc(SDL_Init(SDL_INIT_VIDEO));
	Editor->Window = SDL_CreateWindow("PixelSketch", Editor->WindowWidth, Editor->WindowHeight, 
                                    SDL_WINDOW_RESIZABLE);
	if(!Editor->Window) {
    fprintf(stderr, "Could not create window");
    exit(1);
  }
  
  // Name of the rendering driver to initialize or 0 to let sdl choose
	Editor->Renderer = SDL_CreateRenderer(Editor->Window, 0);
	if(!Editor->Renderer) {
    fprintf(stderr, "Could not create renderer");
    exit(1);
  }
  
	Editor->GridScale = 30;
	Editor->PenSize = 3;
	
	Editor->DstRect.x = Editor->GridScale*6;
  Editor->DstRect.y = Editor->GridScale*4;
  Editor->DstRect.w = Editor->WindowWidth;
  Editor->DstRect.h = Editor->WindowHeight;
	
	Editor->DrawColor.r = 00;
	Editor->DrawColor.g = 86;
	Editor->DrawColor.b = 86;
	Editor->DrawColor.a = 255;
	
	return Editor;
}

int main()
{
  editor_data *Editor = EditorInitAll();
  Editor->BitmapCapacity = 1024*1024;
  Editor->Bitmap = MakeEmptyBitmap(Editor->BitmapCapacity);
  Editor->Bitmap.Width = 24;
  Editor->Bitmap.Height = 18;
  
  input FrameInput = {0};
  
  f32 TargetFPS = 60.0f;
  f32 DeltaTime = 0;
  b32 Pause = false;
  while(!Editor->Quit)
  {
    u64 StartTicks = SDL_GetTicksNS();
    InitInputForFrame(&FrameInput);
    
    SDL_Event Event;
    while(SDL_PollEvent(&Event))
    {
      switch(Event.type) {
        case SDL_EVENT_QUIT: {
          Editor->Quit = true;
        } break;
        
        case SDL_EVENT_WINDOW_RESIZED: {
          Editor->WindowWidth = Event.window.data1;
          Editor->WindowHeight = Event.window.data2;
        } break;
        
        case SDL_EVENT_KEY_DOWN: {
          switch(Event.key.key) {
            case SDLK_P: {
              Pause = !Pause;
            } break;
            
            case SDLK_R: {
              Editor->AllowBmpResize = !Editor->AllowBmpResize;
            } break;
            
            case SDLK_C: {
              // TODO: Go to center of drawing
            } break;
            
            case SDLK_LCTRL:
            case SDLK_RCTRL: {
              FrameInput.Ctrl.Down = true;
              FrameInput.Ctrl.Timestamp = Event.key.timestamp;
            } break;
          }
        } break;
        
        case SDL_EVENT_KEY_UP: {
          case SDLK_LCTRL:
          case SDLK_RCTRL: {
            FrameInput.Ctrl.Down = false;
            FrameInput.Ctrl.Up = true;
          } break;
        } break;
        
        case SDL_EVENT_MOUSE_BUTTON_DOWN: {
          switch(Event.button.button) {
            case SDL_BUTTON_LEFT: {
              FrameInput.Lmb.Down = true;
              FrameInput.Lmb.Timestamp = Event.button.timestamp;
            } break;
            case SDL_BUTTON_MIDDLE: {
              FrameInput.Mmb.Down = true;
              FrameInput.Mmb.Timestamp = Event.button.timestamp;
            } break;
            case SDL_BUTTON_RIGHT: {
              FrameInput.Rmb.Down = true;
              FrameInput.Rmb.Timestamp = Event.button.timestamp;
            } break;
          }
        } break;
        
        case SDL_EVENT_MOUSE_BUTTON_UP: {
          switch(Event.button.button) {
            case SDL_BUTTON_LEFT: {
              FrameInput.Lmb.Down = false;
              FrameInput.Lmb.Up = true;
            } break;
            case SDL_BUTTON_MIDDLE: {
              FrameInput.Mmb.Down = false;
              FrameInput.Mmb.Up = true;
            } break;
            case SDL_BUTTON_RIGHT: {
              FrameInput.Rmb.Down = false;
              FrameInput.Rmb.Up = true;
            } break;
          }
        } break;
        
        case SDL_EVENT_MOUSE_WHEEL: {
          FrameInput.ScrollY = Event.wheel.y;
        } break;
      }
    }
    
    SDL_GetMouseState(&FrameInput.MousePos.x, &FrameInput.MousePos.y);
    FrameInput.Timestamp = SDL_GetTicksNS();
    
    if(!Pause) {
      if(FrameInput.Ctrl.Down) {
        // Change color somehow
        u8 gval = (u8)(255.0f*(1.0f + SDL_sinf(((f32)FrameInput.Timestamp*FrameInput.ScrollY)/37.0f)));
        Editor->DrawColor.g = (u8)((int)gval + (int)Editor->DrawColor.g % 255);
        
        u8 rval = (u8)(255.0f*(1.0f + SDL_sinf(((f32)FrameInput.Timestamp*FrameInput.ScrollY)/71.0f)));
        Editor->DrawColor.r = (u8)((int)rval + (int)Editor->DrawColor.r % 255);
      }
      else {
        Editor->PenSize = max(Editor->PenSize + (i32)SDL_roundf(FrameInput.ScrollY), 1);
      }
      
      if(FrameInput.Mmb.Down) {
        Editor->DstRect.x += (i32)SDL_roundf(FrameInput.MousePos.x - FrameInput.PrevMousePos.x);
        Editor->DstRect.y += (i32)SDL_roundf(FrameInput.MousePos.y - FrameInput.PrevMousePos.y);
        
        b32 ShouldWarpMouse = false;
        if(FrameInput.MousePos.x > (f32)Editor->WindowWidth) {
          FrameInput.MousePos.x = 0;
          FrameInput.PrevMousePos.x = 0;
          ShouldWarpMouse = true;
        }
        if(FrameInput.MousePos.y > (f32)Editor->WindowHeight) {
          FrameInput.MousePos.y = 0;
          FrameInput.PrevMousePos.y = 0;
          ShouldWarpMouse = true;
        }
        if(FrameInput.MousePos.x < 0.0f) {
          FrameInput.MousePos.x = (f32)Editor->WindowWidth;
          FrameInput.PrevMousePos.x = (f32)Editor->WindowWidth;
          ShouldWarpMouse = true;
        }
        if(FrameInput.MousePos.y < 0.0f) {
          FrameInput.MousePos.y = (f32)Editor->WindowHeight;
          FrameInput.PrevMousePos.y = (f32)Editor->WindowHeight;
          ShouldWarpMouse = true;
        }
        
        if(ShouldWarpMouse) {
          SDL_WarpMouseInWindow(Editor->Window, FrameInput.MousePos.x, FrameInput.MousePos.y);
        }
      }
      
      i32 DrawSize = Editor->GridScale*Editor->PenSize;
      
      v2i PenGridPos = PenPosFromMouse(Editor, FrameInput.MousePos, DrawSize);
      
      i32_rect CommitRect = {
        PenGridPos.x, PenGridPos.y,
        Editor->PenSize, Editor->PenSize
      };
      
      SDL_FRect UncommitRect = {
        (f32)(PenGridPos.x*Editor->GridScale + Editor->DstRect.x),
        (f32)(PenGridPos.y*Editor->GridScale + Editor->DstRect.y),
        (f32)DrawSize, (f32)DrawSize
      };
      
      ////////////////////////////////
      // Render
      ////////////////////////////////
      // Only push committed graphics onto cpu bitmap
      
      if(FrameInput.Lmb.Up) {
        if(Editor->AllowBmpResize) {
          ExpandMap(Editor, &CommitRect);
        }
        CPUFillRect(&Editor->Bitmap, CommitRect, Editor->DrawColor);
      }
      
      scc(SDL_SetRenderDrawColor(Editor->Renderer, 0, 0, 0, 255));
      scc(SDL_RenderClear(Editor->Renderer));
      RenderFromBitmap(Editor);
      
      if(!FrameInput.Mmb.Down) {
        scc(SDL_SetRenderDrawColor(Editor->Renderer,
                                   Editor->DrawColor.r, Editor->DrawColor.g, Editor->DrawColor.b, Editor->DrawColor.a));
        scc(SDL_RenderFillRect(Editor->Renderer, &UncommitRect));
      }
      
      scc(SDL_SetRenderDrawColor(Editor->Renderer, 86, 86, 0, 255));
      DrawGrid(Editor);
      scc(SDL_SetRenderDrawColor(Editor->Renderer, 255, 255, 255, 255));
      DrawBitmapBounds(Editor);
      
      SDL_RenderPresent(Editor->Renderer);
    }
    
    FrameInput.PrevMousePos = FrameInput.MousePos;
    
    ////////////////////////////////
    // End frame
    u64 Duration = SDL_GetTicksNS() - StartTicks;
    u64 TargetTimeNS = 1000000000/(u64)TargetFPS;
    if(Duration < TargetTimeNS) {
      Duration = TargetTimeNS - Duration;
      SDL_DelayPrecise(Duration);
    }
    else {
      debug_log("Missed target fps: %I64u\n", Duration/1000000);
    }
    Duration = SDL_GetTicksNS() - StartTicks;
    DeltaTime = (f32)Duration / 1000000000.0f;
    //debug_log("Frame time: %fs\n", DeltaTime);
  }
  
  return 0;
}