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

/* attack-based king-danger (term #1, docs/plans/2026-06-18-eval-rewrite-design.md):
 * attacker units -> SAFETY_TABLE[units] -> centipawns. Units are clamped to the
 * last table index. */
#define KD_TABLE_SIZE 16

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
    /* attack-based king-danger (term #1). Default 0/inert -> bit-exact baseline.
     * Per-side: units = sum of attacker weights (ring_bonus if the attacker also
     * hits a king-neighbor); danger = kd_safety_table[min(units, KD_TABLE_SIZE-1)];
     * gated off when the attacked side's owner has < kd_phase_min_heavy enemy
     * heavy material (queen=2, rook=1). */
    int kd_w_queen, kd_w_rook, kd_w_minor, kd_ring_bonus, kd_phase_min_heavy;
    int kd_safety_table[KD_TABLE_SIZE];
} EvalWeights;

extern EvalWeights g_w;           /* live weights (override target) */
void eval_reset_weights(void);    /* restore baseline into g_w */
void eval_sync_tables(void);      /* rebuild g_w-derived lookup tables; call after
                                   * any direct mutation of g_w (the A/B swap path) */

int eval_full(const Board *b);    /* white-POV centipawns */
int eval_material_pst(const Board *b);  /* lazy stage: material + PST only, white-POV */

/* Incremental material+PST accumulator (eval_material_pst reads b->acc_*). */
void eval_acc_init(Board *b);     /* full rescan -> seed acc_* from current g_w  */
/* Apply one move's material+PST delta to b->acc_* (called by make_move). The
 * mover/captured pieces and cap_sq are passed in explicitly. */
void eval_acc_apply(Board *b, Move m, uint8_t mover, uint8_t captured, int cap_sq);

#endif
