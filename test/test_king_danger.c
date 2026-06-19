/* test_king_danger.c -- structural contract tests for the attack-based
 * king-danger eval term (docs/plans/2026-06-18-eval-rewrite-design.md, term #1).
 *
 * The term's MAGNITUDES come from SF-supervised calibration, so these tests pin
 * the STRUCTURE only (independent of the tuned table values):
 *   1. attack-side sign: enabling the term rewards the side attacking the bare
 *      enemy king.
 *   2. color symmetry: mirroring a position negates the eval (the king_center
 *      "cancels for both sides" bug must not recur).
 *   3. phase gate: with no enemy heavy material, the term contributes 0.
 *   4. disabled-inert: with the default (zero) weights, eval is unchanged.
 *
 * board.o references gen_legal via move_from_uci; the eval path never calls it,
 * so provide a stub (same pattern as test_eval.c).
 */
#include "board.h"
#include "movegen.h"
#include "eval.h"
#include <stdio.h>
#include <string.h>

int gen_legal(const Board *b, Move *list) { (void)b; (void)list; return 0; }

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s\n", msg); failures++; } \
    else { printf("ok: %s\n", msg); } \
} while (0)

static int eval_fen(const char *fen) {
    Board b;
    if (board_from_fen(&b, fen)) { printf("ERR parsing %s\n", fen); failures++; return 0; }
    return eval_full(&b);
}

/* A simple nonzero king-danger config used for the structural tests. Exact
 * numbers are arbitrary here; calibration sets the shipping values. */
static void enable_king_danger(void) {
    int i;
    eval_reset_weights();
    g_w.kd_w_queen   = 4;
    g_w.kd_w_rook    = 2;
    g_w.kd_w_minor   = 2;
    g_w.kd_ring_bonus = 1;
    g_w.kd_phase_min_heavy = 0;            /* gate open: term always active */
    for (i = 0; i < KD_TABLE_SIZE; i++)    /* quadratic-ish ramp, capped */
        g_w.kd_safety_table[i] = i * i;
    eval_sync_tables();
}

int main(void) {
    /* Black king stranded on e6, raked by White Ra6 (rank ray) + Qe2 (file ray);
     * White king tucked on g1 behind f2/g2/h2 -- no black attackers. */
    const char *attack = "8/8/R3k3/8/8/8/4QPPP/6K1 w - - 0 1";

    /* TEST 1: attack-side sign. Enabling king-danger must make the position
     * MORE favorable to White (the attacker), vs the term disabled. */
    eval_reset_weights();
    int disabled = eval_fen(attack);
    enable_king_danger();
    int enabled = eval_fen(attack);
    CHECK(enabled > disabled,
          "enabling king-danger rewards the side attacking the bare enemy king");

    /* TEST 2: phase gate. Black king raked by a lone White rook (White heavy
     * material = 1). With the gate threshold ABOVE the attacker's heavy material
     * the term must vanish (== disabled baseline); at/below it the term is live. */
    const char *rook_only = "8/8/R3k3/8/8/8/5PPP/6K1 w - - 0 1";
    eval_reset_weights();
    int rook_baseline = eval_fen(rook_only);

    enable_king_danger();
    g_w.kd_phase_min_heavy = 2;            /* White heavy(=1) < 2 -> gated off */
    int gated = eval_fen(rook_only);
    CHECK(gated == rook_baseline,
          "phase gate suppresses king-danger when enemy heavy material is below threshold");

    enable_king_danger();
    g_w.kd_phase_min_heavy = 1;            /* White heavy(=1) >= 1 -> active */
    int active = eval_fen(rook_only);
    CHECK(active > rook_baseline,
          "king-danger is live when enemy heavy material meets the threshold");

    /* TEST 3: color symmetry (guards against the king_center "cancels for both
     * sides" bug). Mirroring the attack position vertically + swapping colors
     * must NEGATE the white-POV eval. (tempo=0 -> eval is side-to-move neutral.) */
    const char *mirror = "6k1/4qppp/8/8/8/r3K3/8/8 b - - 0 1";
    enable_king_danger();
    int orig = eval_fen(attack);
    int refl = eval_fen(mirror);
    CHECK(refl == -orig, "king-danger is color-symmetric (mirror negates the eval)");

    /* TEST 4: disabled-inert. The default (zero) weights must leave eval
     * bit-identical to the baseline on the attack position. */
    eval_reset_weights();
    int def = eval_fen(attack);
    CHECK(def == disabled, "default weights keep king-danger inert (bit-exact baseline)");

    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("all king-danger contract tests passed\n");
    return 0;
}
