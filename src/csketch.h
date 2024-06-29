/* date = June 29th 2024 1:12 pm */
/* TODO(vic):
Short term:
 - undo:
Idea 1: pretty bad I think
- Have a big circular queue of things to draw which when you undo
everything in the big circular buffer gets redrawn until 
one less than where the last one was

Idea 2: pretty good but hard to do - maybe not so much...
- Think of an inverse operation for each command
- Have a circular queue of things to draw
- It should just pop the last element when undo is called and 
do the inverse operation

Idea 3: Combining idea 1 and 0
- small buffer of bimaps for single or a small amount of undos (this was idea 0)
- big buffer of operations for a lot of undos:
-   big buffer redraws all the operations if there's no small buffer

 -   use opengl to access render draw buffer
 
Long term:
- stop using sdl

*/

#ifndef CDRAW_H
#define CDRAW_H

#include <stdio.h>
#include <string.h>
#include <errno.h>

#include <SDL.h>

#define FPS 60
#define INIT_WINDOW_WIDTH 600
#define INIT_WINDOW_HEIGHT 540

#if BUILD_RELEASE
#define Assert(Expr)
#else
#define Assert(Expr) if(!(Expr)) *(int*)0=0;
#endif

typedef Uint64 u64;
typedef Uint32 u32;
typedef Uint16 u16;
typedef Uint8 u8;

typedef Sint64 s64;
typedef Sint32 s32;
typedef Sint16 s16;
typedef Sint8 s8;

#define ARENA_MEMORY_SIZE 1024*1024*1024 + sizeof(memory_arena)
struct memory_arena {
    size_t Size;
    u8 *Base;
    size_t Used;
    memory_arena *Next;
};

void InitializeArena(memory_arena *Arena, size_t Size, void *Base)
{
    Arena->Size = Size - sizeof(memory_arena);
    Arena->Base = (u8 *)Base;
    Arena->Used = 0;
    Arena->Next = 0;
}

#define PushStruct(Arena, type) (type *)PushSize_(Arena, sizeof(type))
#define PushArray(Arena, Count, type) (type *)PushSize_(Arena, (Count)*sizeof(type))
#define PushSize(Arena, Size) PushSize_(Arena, Size_)
void *PushSize_(memory_arena **Arena, size_t SizeInit)
{
    size_t Size = SizeInit;
    
    if(((*Arena)->Used + Size) > (*Arena)->Size) {
        void *Memory = malloc(ARENA_MEMORY_SIZE);
        memset(Memory, 0, ARENA_MEMORY_SIZE);
        (*Arena)->Next = (memory_arena *)(*Arena)->Base;
        InitializeArena((*Arena)->Next, ARENA_MEMORY_SIZE, Memory);
        *Arena = (*Arena)->Next;
    }
    
    void *Result = (*Arena)->Base + (*Arena)->Used;
    (*Arena)->Used += Size;
    
    Assert(Size >= SizeInit);
    
    return(Result);
}

enum draw_operation_kind
{
    DrawOp_Line,
};

struct line {
    SDL_Point Start;
    SDL_Point End;
};

#define LINE_OP_MIN_SIZE 10
struct line_operation {
    line Lines[LINE_OP_MIN_SIZE];
    int Used;
    
    line_operation *Prev;
    line_operation *Next;
};

struct draw_operation
{
    draw_operation_kind Kind;
    union {
        struct {
            line_operation Operation;
            line_operation *LastLineOp;
        } Line;
    };
};

#define DRAW_BITMAP_BUFFER_SIZE 16
#define DRAW_OPS_QUEUE_SIZE 256
struct undo_data
{
    SDL_Texture *Bitmaps[DRAW_BITMAP_BUFFER_SIZE];
    int Used;
    
    draw_operation DrawOps[DRAW_OPS_QUEUE_SIZE];
    int FirstDrawOp;
    int LastDrawOp;
    
    line_operation *FirstFreeLine;
};

#endif //CDRAW_H
