/* eval.h -- eval contract (implemented in eval.c).
 *
 * eval_full() must be BIT-EXACT to tools/texel_eval.py eval_full(): WHITE-POV
 * centipawns, full (non-lazy) static eval. Verified by comparing against the
 * python oracle over the 22k-position dataset.
 *
 * The eval reads its tunable weights from the global EvalWeights instance so the
 * self-play A/B harness can override them per side (mirrors the python
 * apply_eval_overrides mechanism). eval.c defines the baseline values.
 */
#ifndef CREF_EVAL_H
#define CREF_EVAL_H

#include "board.h"

typedef struct {
    int pawn, knight, bishop, rook, queen, king;            /* material */
    int pawn_attack_minor, pawn_attack_rook, pawn_attack_queen;
    int queen_attack_minor, minor_attack_rook, minor_attack_queen;
    int knight_outpost;
    int pinned_pawn, pinned_minor, pinned_rook, pinned_queen, pinned_attacked;
    int doubled_pawn, isolated_pawn, advanced_pawn, deep_advanced_pawn;
    int rook_behind_passer, connected_passer, protected_passer, blockaded_passer;
    int bishop_pair, rook_open_file, rook_semi_open_file, heavy_seventh_rank;
    int endgame_nonpawn_limit, endgame_king_activity, endgame_rook_open_file,
        endgame_rook_king_cutoff;
    int passed_pawn_bonus[8];
    int castled, pawn_shield, open_file_penalty, semi_open_file_penalty,
        king_center, king_march_base, king_march_step, king_zone_attack;
    /* New A/B eval terms (default 0 -> bit-exact to baseline until enabled). */
    int tempo, trapped_penalty, king_attack_escalation, pawn_storm,
        queen_attacks_minor;
    /* king_taper: when 1, king square value is phase-tapered MG<->EG (PST_KING_MID
     * <-> PST_KING_END) instead of MG-only + the binary endgame_king_activity. */
    int king_taper;
} EvalWeights;

extern EvalWeights g_w;           /* live weights (override target) */
void eval_reset_weights(void);    /* restore baseline into g_w */

int eval_full(const Board *b);    /* white-POV centipawns */
int eval_material_pst(const Board *b);  /* lazy stage: material + PST only, white-POV */

#endif
