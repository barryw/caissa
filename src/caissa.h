/* caissa.h -- the public engine<->UI API.
 *
 * A chess UI uses ONLY this header to run a complete game: set up a position,
 * query whose turn it is + the legal moves + the game state (mate/stalemate/
 * draws), ask the engine for a move, commit real moves (with 50-move + threefold
 * + insufficient-material rules tracked), take moves back, and ponder on the
 * opponent's clock. It is a thin facade over board/movegen/search/eval -- the
 * UI never has to touch engine internals or maintain its own draw bookkeeping.
 *
 * Lifecycle:
 *   caissa_init();                       // once, at startup
 *   CaissaGame g; caissa_new_game(&g, NULL);   // NULL = standard start position
 *   ... loop: caissa_state(), caissa_legal_moves(), caissa_commit(),
 *             caissa_bestmove(), caissa_ponder()/caissa_ponder_hit() ...
 */
#ifndef CAISSA_H
#define CAISSA_H

#include "board.h"
#include "search.h"   /* Move, Board, hash_t, SearchInfo, MAX_PATH */

typedef enum {
    CAISSA_NORMAL = 0,        /* game continues, side to move is not in check    */
    CAISSA_CHECK,             /* game continues, side to move is in check        */
    CAISSA_CHECKMATE,         /* side to move is checkmated (it LOST)            */
    CAISSA_STALEMATE,         /* draw: side to move has no legal move, not in chk */
    CAISSA_DRAW_50MOVE,       /* draw: 100 half-moves without pawn move/capture  */
    CAISSA_DRAW_REPETITION,   /* draw: current position has occurred 3 times     */
    CAISSA_DRAW_INSUFFICIENT  /* draw: neither side has mating material          */
} CaissaState;

/* A live game owned by one UI: the board, the full committed-position history
 * (for repetition + take-back), and a ponder cache. */
typedef struct {
    Board   board;
    hash_t  hist[MAX_PATH];   /* zobrist of every committed position (root incl.) */
    Move    moves[MAX_PATH];  /* committed moves (for take-back)                  */
    Undo    undos[MAX_PATH];  /* per-move undo info (for take-back)               */
    int     hist_len;         /* committed positions = hist_len; moves = hist_len-1 */
    int     ponder_valid;
    Move    ponder_predicted; /* opponent move we pondered                        */
    Move    ponder_reply;     /* cached engine reply if that move occurs          */
} CaissaGame;

/* One-time init: load baseline eval weights + derived tables + default search. */
void caissa_init(void);

/* Start a game from `fen` (NULL = standard start position).
 * Returns 0 on success, -1 on an unparseable FEN. */
int  caissa_new_game(CaissaGame *g, const char *fen);

/* ---- queries (do not mutate the game) ---- */
int  caissa_side_to_move(const CaissaGame *g);            /* 1 = white, 0 = black */
int  caissa_legal_moves(const CaissaGame *g, Move *out, int max); /* -> count     */
int  caissa_is_legal(const CaissaGame *g, Move m);        /* 1 / 0                 */
CaissaState caissa_state(const CaissaGame *g);
int  caissa_eval(const CaissaGame *g);                    /* white-POV centipawns  */
const Board *caissa_board(const CaissaGame *g);           /* read .sq[] to render  */
void caissa_to_fen(const CaissaGame *g, char *out);       /* out >= 90 bytes       */

/* ---- move <-> uci on the current position ---- */
int  caissa_move_from_uci(const CaissaGame *g, const char *uci, Move *out); /* 0 ok */
void caissa_move_to_uci(Move m, char *out);               /* out >= 6 bytes        */

/* ---- play ---- */
/* Engine's chosen move for the current position (repetition-aware). */
Move caissa_bestmove(CaissaGame *g, int depth, SearchInfo *info);
/* Apply a real move + advance clocks/history. Returns 0, or -1 if illegal / the
 * game-history buffer is full. Invalidates any ponder cache. */
int  caissa_commit(CaissaGame *g, Move m);
/* Take back the last committed move. Returns 0, or -1 if at the root. */
int  caissa_undo(CaissaGame *g);

/* ---- ponder (think on the opponent's clock) ----
 * caissa_ponder: assume the opponent will play `predicted`; search our reply and
 *   cache it. Cheap to call right after we move, while the opponent thinks.
 *   Returns 0 if cached, -1 if `predicted` is illegal.
 * caissa_ponder_hit: once the opponent actually plays `actual`, if it matches the
 *   prediction, set *reply to the cached engine move (already legal for the
 *   position after `actual`) and return 1; else return 0 and run caissa_bestmove. */
int  caissa_ponder(CaissaGame *g, Move predicted, int depth);
int  caissa_ponder_hit(CaissaGame *g, Move actual, Move *reply);

#endif /* CAISSA_H */
