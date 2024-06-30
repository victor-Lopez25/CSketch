/* Creator: VicThor */
#include "csketch.h"

void InitUndoData(undo_data *UndoData, SDL_Renderer *Renderer, int DrawingWidth, int DrawingHeight)
{
    for(int i = 0; i < DRAW_BITMAP_BUFFER_SIZE; i++)
    {
        UndoData->Bitmaps[i] = 
            SDL_CreateTexture(Renderer, SDL_PIXELFORMAT_ARGB8888, 
                              SDL_TEXTUREACCESS_TARGET, DrawingWidth, DrawingHeight);
    }
    
    UndoData->EarliestBitmap = 
        SDL_CreateTexture(Renderer, SDL_PIXELFORMAT_ARGB8888, 
                          SDL_TEXTUREACCESS_TARGET, DrawingWidth, DrawingHeight);
    
    UndoData->Used = 0;
    UndoData->FirstFreeLine = 0;
    UndoData->FirstDrawOp = 0;
    UndoData->LastDrawOp = 0;
}

void FreeLineOperation(undo_data *UndoData, draw_operation *LineToFree)
{
    for(line_operation *Line = LineToFree->Line.LastLineOp;
        Line;
        Line = Line->Prev)
    {
        Line->Next = UndoData->FirstFreeLine;
        Line->Used = 0;
        UndoData->FirstFreeLine = Line;
    }
}

void GetNewLineOp(undo_data *UndoData, memory_arena **Arena, line_operation *LineOp)
{
    if(UndoData->FirstFreeLine) {
        LineOp->Next = UndoData->FirstFreeLine;
        UndoData->FirstFreeLine = UndoData->FirstFreeLine->Next;
        LineOp->Next = 0;
    }
    else {
        LineOp->Next = PushStruct(Arena, line_operation);
    }
}

void UseDrawOp(SDL_Renderer *Renderer, draw_operation *DrawOp)
{
    scc(SDL_SetRenderDrawColor(Renderer, DrawOp->Color.r, DrawOp->Color.g, DrawOp->Color.b, DrawOp->Color.a));
    switch(DrawOp->Kind) {
        case DrawOp_Line:
        {
            for(line_operation *LineOp = &DrawOp->Line.Operation;
                LineOp;
                LineOp = LineOp->Next)
            {
                for(int i = 0; i < LineOp->Used; i++)
                {
                    line *Line = LineOp->Lines + i;
                    SDL_RenderDrawLine(Renderer, Line->Start.x, Line->Start.y, Line->End.x, Line->End.y);
                }
            }
        } break;
        
        case DrawOp_Point:
        case DrawOp_StraightLine:
        {
            printf("unimplemented");
            Assert(0);
        } break;
    }
}

void PushDrawLine(undo_data *UndoData, memory_arena **Arena, SDL_Renderer *Renderer, line *Line)
{
    draw_operation *CurrentDrawOp = UndoData->DrawOps + UndoData->FirstDrawOp;
    if(CurrentDrawOp->Kind == DrawOp_Line) {
        line_operation *LineOp = &CurrentDrawOp->Line.Operation;
        if(LineOp->Used == LINE_OP_MIN_SIZE) {
            GetNewLineOp(UndoData, Arena, LineOp->Next);
            CurrentDrawOp->Line.LastLineOp = LineOp->Next;
            LineOp->Next->Prev = LineOp;
        }
        else {
            LineOp->Lines[LineOp->Used++] = *Line;
        }
    }
    else {
        UndoData->FirstDrawOp++;
        if(UndoData->FirstDrawOp > DRAW_OPS_QUEUE_SIZE) {
            UndoData->FirstDrawOp = 0;
        }
        if(UndoData->FirstDrawOp == UndoData->LastDrawOp && 
           UndoData->Used != 0) {
            // NOTE(vic): Get rid of last draw op
            SDL_SetRenderTarget(Renderer, UndoData->EarliestBitmap);
            UseDrawOp(Renderer, UndoData->DrawOps + UndoData->LastDrawOp);
            
            UndoData->LastDrawOp++;
            if(UndoData->LastDrawOp > DRAW_OPS_QUEUE_SIZE) {
                UndoData->LastDrawOp = 0;
            }
        }
        
        draw_operation *NewDrawOp = UndoData->DrawOps + UndoData->FirstDrawOp;
        NewDrawOp->Kind = DrawOp_Line;
        GetNewLineOp(UndoData, Arena, &NewDrawOp->Line.Operation);
        
        int nthOp = UndoData->FirstDrawOp - DRAW_BITMAP_BUFFER_SIZE - 1;
        if(nthOp < 0) {
            nthOp = DRAW_OPS_QUEUE_SIZE + nthOp;
        }
        int iterations = MIN(DRAW_BITMAP_BUFFER_SIZE, UndoData->Used);
        for(int i = 0; i < iterations; i++)
        {
            int DrawOpIndex = (nthOp + i) % DRAW_BITMAP_BUFFER_SIZE;
            draw_operation *DrawOp = UndoData->DrawOps + DrawOpIndex;
            SDL_Texture *tex = UndoData->Bitmaps[DRAW_BITMAP_BUFFER_SIZE - i];
            
            SDL_SetRenderTarget(Renderer, tex);
            UseDrawOp(Renderer, DrawOp);
        }
    }
    
    DEC_CLIP_0_S32(UndoData->CurrentUndoIndex);
    UndoData->Used++;
    UndoData->Used = MIN(UndoData->Used, DRAW_BITMAP_BUFFER_SIZE);
    SDL_RenderDrawLine(Renderer, Line->Start.x, Line->Start.y, Line->End.x, Line->End.y);
}

void UndoOperation(undo_data *UndoData, SDL_Renderer *Renderer)
{
    // TODO(vic): First try, look into this because it's likely buggy
    if(UndoData->Used > 0) {
        if(UndoData->CurrentUndoIndex < DRAW_BITMAP_BUFFER_SIZE) {
            // TODO(vic): Only copy the parts that changed from the previous bitmap
            SDL_RenderCopy(Renderer, UndoData->Bitmaps[UndoData->CurrentUndoIndex], 
                           NULL, NULL);
        }
        else {
            SDL_RenderCopy(Renderer, UndoData->EarliestBitmap, NULL, NULL);
            for(int i = 0; i < (DRAW_OPS_QUEUE_SIZE - UndoData->CurrentUndoIndex); i++)
            {
                int DrawOpIndex = (UndoData->LastDrawOp + i) % DRAW_OPS_QUEUE_SIZE;
                draw_operation *DrawOp = UndoData->DrawOps + DrawOpIndex;
                UseDrawOp(Renderer, DrawOp);
            }
        }
        
        UndoData->CurrentUndoIndex++;
    }
}

void Usage(char *ProgramName)
{
    printf("Usage: %s [bmp file]\n", ProgramName);
}

int main(int argc, char **argv)
{
    SDL_Surface *ReadSurface = 0;
    if(argc == 1) {
        Usage(argv[0]);
    }
    else {
        char *BmpFilename = argv[1];
        ReadSurface = SDL_LoadBMP(BmpFilename);
    }
    
    SDL_Window *Window = 
        SDL_CreateWindow("cdraw", 
                         0, 30, 
                         INIT_WINDOW_WIDTH, INIT_WINDOW_HEIGHT,
                         SDL_WINDOW_RESIZABLE);
    if(!Window) {
        fprintf(stderr, "Could not create SDL window: %s\n", SDL_GetError());
        exit(1);
    }
    
    SDL_Renderer *Renderer =
        SDL_CreateRenderer(Window, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_TARGETTEXTURE);
    if(!Renderer) {
        fprintf(stderr, "Could not create SDL Renderer: %s\n", SDL_GetError());
        exit(1);
    }
    
    //SDL_Surface *WindowSurface = SDL_GetWindowSurface(Window);
    if(ReadSurface) {
        SDL_Texture *ImageTexture = SDL_CreateTextureFromSurface(Renderer, ReadSurface);
        if(!ImageTexture) {
            fprintf(stderr, "Could not create sdl texture: %s\n", SDL_GetError());
            exit(1);
        }
        
        SDL_RenderCopy(Renderer, ImageTexture, 
                       &ReadSurface->clip_rect, &ReadSurface->clip_rect);
        SDL_FreeSurface(ReadSurface);
        SDL_DestroyTexture(ImageTexture);
    }
    
    s32 PrevX = -1;
    s32 PrevY = -1;
    bool MouseIsDown = false;
    int WindowWidth = INIT_WINDOW_WIDTH;
    int WindowHeight = INIT_WINDOW_HEIGHT;
    SDL_Color PenL = {255, 255, 255, 255};
    SDL_Color PenR = {0, 0, 0, 0};
    
    scc(SDL_SetRenderDrawColor(Renderer, PenL.r, PenL.g, PenL.b, PenL.a));
    
    memory_arena _Arena;
    memory_arena *Arena = &_Arena;
    {
        void *Mem = malloc(ARENA_MEMORY_SIZE);
        memset(Mem, 0, ARENA_MEMORY_SIZE);
        if(!Mem) fprintf(stderr, "ERROR: Could not allocate memory\n");
        InitializeArena(Arena, ARENA_MEMORY_SIZE, Mem);
    }
    
    undo_data *UndoData = PushStruct(&Arena, undo_data);
    InitUndoData(UndoData, Renderer, INIT_WINDOW_WIDTH, INIT_WINDOW_HEIGHT);
    
    bool Draw = false;
    SDL_Point DrawDotBuffer[10];
    bool quit = false;
    while(!quit)
    {
        const Uint32 start = SDL_GetTicks();
        bool ShouldDrawDot = false;
        int DrawDotIndex = 0;
        
        SDL_Event Event = {0};
        while(SDL_PollEvent(&Event))
        {
            switch(Event.type) {
                case SDL_QUIT:
                {
                    quit = true;
                } break;
                
                case SDL_WINDOWEVENT_RESIZED:
                case SDL_WINDOWEVENT_SIZE_CHANGED:
                {
                    SDL_GetWindowSize(Window, &WindowWidth, &WindowHeight);
                    // TODO(vic): Do something else probably
                } break;
                
                case SDL_KEYDOWN:
                {
                    switch(Event.key.keysym.sym) {
                        case 'c':
                        {
                            scc(SDL_SetRenderDrawColor(Renderer, 0, 0, 0, 0));
                            scc(SDL_RenderClear(Renderer));
                        } break;
                        
                        case 's':
                        {
                            u32 Format = SDL_PIXELFORMAT_ARGB8888;
                            SDL_Surface *Surface =
                                SDL_CreateRGBSurfaceWithFormat(0, WindowWidth, WindowHeight, 32, Format);
                            SDL_RenderReadPixels(Renderer, NULL, Format, Surface->pixels, Surface->pitch);
                            SDL_SaveBMP(Surface, "drawing.bmp");
                            SDL_FreeSurface(Surface);
                        } break;
                    }
                } break;
                
                case SDL_MOUSEMOTION:
                {
                    s32 x = Event.motion.x;
                    s32 y = Event.motion.y;
                    if(MouseIsDown && Draw) {
                        if(ShouldDrawDot) {
                            ShouldDrawDot = false;
                            DrawDotIndex--;
                        }
                        SDL_RenderDrawLine(Renderer, PrevX, PrevY, x, y);
                    }
                    PrevX = x;
                    PrevY = y;
                } break;
                
                case SDL_MOUSEBUTTONDOWN:
                {
                    Assert(Event.button.state == SDL_PRESSED);
                    if(Event.button.button == SDL_BUTTON_LEFT) {
                        scc(SDL_SetRenderDrawColor(Renderer, PenL.r, PenL.g, PenL.b, PenL.a));
                    }
                    else if(Event.button.button == SDL_BUTTON_RIGHT) {
                        scc(SDL_SetRenderDrawColor(Renderer, PenR.r, PenR.g, PenR.b, PenR.a));
                    }
                    
                    Draw = true;
                    MouseIsDown = true;
                    
                    s32 x = Event.button.x;
                    s32 y = Event.button.y;
                    DrawDotBuffer[DrawDotIndex++] = {x, y};
                    PrevX = x;
                    PrevY = y;
                } break;
                
                case SDL_MOUSEBUTTONUP:
                {
                    MouseIsDown = false;
                    ShouldDrawDot = true;
                    // commit undo?
                } break;
            }
        }
        
        SDL_RenderDrawPoints(Renderer, DrawDotBuffer, DrawDotIndex);
        
#if 0
        scc(SDL_SetRenderDrawColor(Renderer, 0, 0, 0, 0));
        scc(SDL_RenderClear(Renderer));
#endif
        
        SDL_RenderPresent(Renderer);
        
        const Uint32 duration = SDL_GetTicks() - start;
        const Uint32 delta_time_ms = 1000 / FPS;
        if(duration < delta_time_ms) {
            SDL_Delay(delta_time_ms - duration);
        }
    }
    
    SDL_Quit();
    return 0;
}