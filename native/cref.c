/* cref.c -- native reference engine CLI + parallel self-play A/B.
 *
 * Subcommands:
 *   cref eval "FEN"                    -> white-POV centipawn eval
 *   cref bestmove "FEN" [depth]        -> best move + search stats
 *   cref selfplay [opts]               -> reference-vs-reference A/B (the goal)
 *
 * selfplay runs color-balanced game pairs over an opening suite, in parallel via
 * fork() (each child owns its own eval weights + TT, no locking), with material
 * adjudication and an end-of-run SPRT verdict -- the same methodology as the
 * python harnesses, at native speed (160 games in seconds).
 */
#include "board.h"
#include "movegen.h"
#include "eval.h"
#include "search.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

/* ---- eval-weight overrides (CLI "key=val,key=val") ---------------------- */
static int set_weight(EvalWeights *w, const char *key, int val) {
    struct { const char *k; int *p; } map[] = {
        {"pawn", &w->pawn}, {"knight", &w->knight}, {"bishop", &w->bishop},
        {"rook", &w->rook}, {"queen", &w->queen},
        {"pawn_attack_minor", &w->pawn_attack_minor}, {"pawn_attack_rook", &w->pawn_attack_rook},
        {"pawn_attack_queen", &w->pawn_attack_queen}, {"queen_attack_minor", &w->queen_attack_minor},
        {"minor_attack_rook", &w->minor_attack_rook}, {"minor_attack_queen", &w->minor_attack_queen},
        {"knight_outpost", &w->knight_outpost},
        {"pinned_pawn", &w->pinned_pawn}, {"pinned_minor", &w->pinned_minor},
        {"pinned_rook", &w->pinned_rook}, {"pinned_queen", &w->pinned_queen},
        {"pinned_attacked", &w->pinned_attacked},
        {"doubled_pawn", &w->doubled_pawn}, {"isolated_pawn", &w->isolated_pawn},
        {"advanced_pawn", &w->advanced_pawn}, {"deep_advanced_pawn", &w->deep_advanced_pawn},
        {"rook_behind_passer", &w->rook_behind_passer}, {"connected_passer", &w->connected_passer},
        {"protected_passer", &w->protected_passer}, {"blockaded_passer", &w->blockaded_passer},
        {"bishop_pair", &w->bishop_pair}, {"rook_open_file", &w->rook_open_file},
        {"rook_semi_open_file", &w->rook_semi_open_file}, {"heavy_seventh_rank", &w->heavy_seventh_rank},
        {"endgame_king_activity", &w->endgame_king_activity},
        {"endgame_rook_open_file", &w->endgame_rook_open_file},
        {"endgame_rook_king_cutoff", &w->endgame_rook_king_cutoff},
        {"castled", &w->castled}, {"pawn_shield", &w->pawn_shield},
        {"open_file_penalty", &w->open_file_penalty}, {"semi_open_file_penalty", &w->semi_open_file_penalty},
        {"king_center", &w->king_center}, {"king_march_base", &w->king_march_base},
        {"king_march_step", &w->king_march_step}, {"king_zone_attack", &w->king_zone_attack},
        {"tempo", &w->tempo}, {"trapped_penalty", &w->trapped_penalty},
        {"king_attack_escalation", &w->king_attack_escalation},
        {"pawn_storm", &w->pawn_storm}, {"queen_attacks_minor", &w->queen_attacks_minor},
        {NULL, NULL}
    };
    for (int i = 0; map[i].k; i++)
        if (!strcmp(map[i].k, key)) { *map[i].p = val; return 0; }
    return -1;
}

/* baseline + overrides -> out. Returns 0 ok, -1 on unknown key. */
static int build_weights(EvalWeights *out, const char *spec) {
    eval_reset_weights();
    *out = g_w;
    if (!spec || !*spec) return 0;
    char buf[1024];
    strncpy(buf, spec, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = 0;
    for (char *tok = strtok(buf, ","); tok; tok = strtok(NULL, ",")) {
        char *eq = strchr(tok, '=');
        if (!eq) return -1;
        *eq = 0;
        if (set_weight(out, tok, atoi(eq + 1))) {
            fprintf(stderr, "unknown weight key: %s\n", tok);
            return -1;
        }
    }
    return 0;
}

/* ---- search-feature overrides ("killers=1,nullmove=1,null_r=3") -------- */
static int set_search(SearchConfig *s, const char *key, int val) {
    struct { const char *k; int *p; } map[] = {
        {"killers", &s->killers}, {"history", &s->history}, {"nullmove", &s->nullmove},
        {"null_r", &s->null_r}, {"pvs", &s->pvs}, {"aspiration", &s->aspiration},
        {"asp_delta", &s->asp_delta}, {"check_ext", &s->check_ext}, {"lmr", &s->lmr},
        {NULL, NULL}
    };
    for (int i = 0; map[i].k; i++)
        if (!strcmp(map[i].k, key)) { *map[i].p = val; return 0; }
    return -1;
}

static int build_search(SearchConfig *out, const char *spec) {
    search_reset_config();
    *out = g_sc;
    if (!spec || !*spec) return 0;
    char buf[512];
    strncpy(buf, spec, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = 0;
    for (char *tok = strtok(buf, ","); tok; tok = strtok(NULL, ",")) {
        char *eq = strchr(tok, '=');
        if (!eq) return -1;
        *eq = 0;
        if (set_search(out, tok, atoi(eq + 1))) {
            fprintf(stderr, "unknown search key: %s\n", tok);
            return -1;
        }
    }
    return 0;
}

/* ---- material adjudication (white-POV cp) ------------------------------ */
static int material_cp(const Board *b) {
    static const int val[7] = {0, 100, 320, 330, 500, 900, 0};
    int s = 0;
    for (int i = 0; i < 128; i++) {
        if (i & 0x88) continue;
        uint8_t p = b->sq[i];
        if (!p) continue;
        int v = val[PT(p)];
        s += IS_WHITE(p) ? v : -v;
    }
    return s;
}

/* ---- one game ----------------------------------------------------------- */
/* a_score: 0,1,2 == loss,draw,win for engine A. */
typedef struct { int a_score; int plies; int result; char term[24]; } GResult;

static void play_game(const char *start_fen, int a_white,
                      int depth_a, int depth_b,
                      const EvalWeights *wa, const EvalWeights *wb,
                      const SearchConfig *sca, const SearchConfig *scb, long node_budget,
                      int max_plies, int adj_cp, int adj_streak, GResult *r) {
    Board b;
    board_from_fen(&b, start_fen);
    hash_t hist[1024];
    int hlen = 0;
    hist[hlen++] = b.hash;
    const char *result = "1/2-1/2";
    const char *term = "maxplies";
    int decisive = 0;

    for (;;) {
        if (hlen - 1 >= max_plies) { term = "maxplies"; break; }

        /* terminal? */
        Move list[MAX_MOVES];
        int n = gen_legal(&b, list);
        if (n == 0) {
            if (in_check(&b)) { result = b.wtm ? "0-1" : "1-0"; term = "checkmate"; }
            else { result = "1/2-1/2"; term = "stalemate"; }
            break;
        }
        if (b.halfmove >= 100) { result = "1/2-1/2"; term = "fifty-move"; break; }
        /* threefold */
        int reps = 0;
        for (int i = 0; i < hlen; i++) if (hist[i] == b.hash) reps++;
        if (reps >= 3) { result = "1/2-1/2"; term = "threefold"; break; }

        int use_a = (b.wtm == a_white);
        g_w = use_a ? *wa : *wb;
        g_sc = use_a ? *sca : *scb;
        search_set_budget(node_budget);
        SearchInfo info;
        Move mv = search_bestmove(&b, use_a ? depth_a : depth_b, hist, hlen, &info);

        Undo u;
        make_move(&b, mv, &u);
        hist[hlen++] = b.hash;

        if (adj_streak > 0) {
            int bal = material_cp(&b);
            if (bal >= adj_cp || bal <= -adj_cp) {
                if (++decisive >= adj_streak) {
                    result = (bal >= adj_cp) ? "1-0" : "0-1";
                    term = "adjudicated-early";
                    break;
                }
            } else decisive = 0;
        }
        if (hlen >= 1020) { term = "maxplies"; break; }
    }

    if (!strcmp(term, "maxplies")) {
        int bal = material_cp(&b);
        result = (bal >= adj_cp) ? "1-0" : (bal <= -adj_cp) ? "0-1" : "1/2-1/2";
        term = (bal >= adj_cp || bal <= -adj_cp) ? "adjudicated-material" : "adjudicated-draw";
    }

    r->plies = hlen - 1;
    strncpy(r->term, term, sizeof(r->term) - 1);
    r->term[sizeof(r->term) - 1] = 0;
    if (!strcmp(result, "1/2-1/2")) { r->a_score = 1; r->result = 0; }
    else if ((!strcmp(result, "1-0")) == (a_white)) { r->a_score = 2; r->result = a_white ? 1 : -1; }
    else { r->a_score = 0; r->result = a_white ? -1 : 1; }
}

/* ---- stats -------------------------------------------------------------- */
static double expected_score(double elo) { return 1.0 / (1.0 + pow(10.0, -elo / 400.0)); }

static double sprt_llr(const double *scores, int n, double elo1) {
    if (n < 2) return 0.0;
    double mu0 = 0.5, mu1 = expected_score(elo1);
    double mean = 0; for (int i = 0; i < n; i++) mean += scores[i]; mean /= n;
    double var = 0; for (int i = 0; i < n; i++) { double d = scores[i] - mean; var += d * d; }
    var /= n; if (var < 0.05) var = 0.05;
    double total = 0; for (int i = 0; i < n; i++) total += scores[i];
    return (mu1 - mu0) / var * (total - n * (mu0 + mu1) / 2.0);
}

static void wilson(double s, int n, double *lo, double *hi) {
    if (n == 0) { *lo = 0; *hi = 1; return; }
    double z = 1.96, p = s / n, denom = 1 + z * z / n;
    double center = (p + z * z / (2 * n)) / denom;
    double margin = z * sqrt(p * (1 - p) / n + z * z / (4.0 * n * n)) / denom;
    *lo = center - margin < 0 ? 0 : center - margin;
    *hi = center + margin > 1 ? 1 : center + margin;
}

/* ---- selfplay driver ---------------------------------------------------- */
static int load_fens(const char *path, char fens[][128], int max) {
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return -1; }
    char line[256];
    int n = 0;
    while (n < max && fgets(line, sizeof(line), f)) {
        if (line[0] == '#' || line[0] == '\n') continue;
        size_t L = strlen(line);
        while (L && (line[L-1] == '\n' || line[L-1] == '\r')) line[--L] = 0;
        if (!L) continue;
        strncpy(fens[n], line, 127); fens[n][127] = 0; n++;
    }
    fclose(f);
    return n;
}

static int cmd_selfplay(int argc, char **argv) {
    int games = 40, depth = 4, depth_a = -1, depth_b = -1;
    int max_plies = 160, adj_cp = 300, adj_streak = 6, jobs = 8;
    int use_sprt = 0; double sprt_elo1 = 30.0, sprt_alpha = 0.05;
    const char *wa_spec = "", *wb_spec = "", *label = "A=candidate vs B=baseline";
    const char *sa_spec = "", *sb_spec = "", *openings = "tools/openings_big.txt";
    long node_budget = 0;

    for (int i = 0; i < argc; i++) {
        const char *a = argv[i];
        #define NEXT (i + 1 < argc ? argv[++i] : "")
        if (!strcmp(a, "--games")) games = atoi(NEXT);
        else if (!strcmp(a, "--depth")) depth = atoi(NEXT);
        else if (!strcmp(a, "--depth-a")) depth_a = atoi(NEXT);
        else if (!strcmp(a, "--depth-b")) depth_b = atoi(NEXT);
        else if (!strcmp(a, "--nodes")) node_budget = atol(NEXT);
        else if (!strcmp(a, "--max-plies")) max_plies = atoi(NEXT);
        else if (!strcmp(a, "--adjudicate-win-cp")) adj_cp = atoi(NEXT);
        else if (!strcmp(a, "--adjudicate-streak")) adj_streak = atoi(NEXT);
        else if (!strcmp(a, "--jobs")) jobs = atoi(NEXT);
        else if (!strcmp(a, "--weights-a")) wa_spec = NEXT;
        else if (!strcmp(a, "--weights-b")) wb_spec = NEXT;
        else if (!strcmp(a, "--search-a")) sa_spec = NEXT;
        else if (!strcmp(a, "--search-b")) sb_spec = NEXT;
        else if (!strcmp(a, "--openings")) openings = NEXT;
        else if (!strcmp(a, "--label")) label = NEXT;
        else if (!strcmp(a, "--sprt")) use_sprt = 1;
        else if (!strcmp(a, "--sprt-elo1")) sprt_elo1 = atof(NEXT);
        #undef NEXT
    }
    if (depth_a < 0) depth_a = depth;
    if (depth_b < 0) depth_b = depth;
    if (node_budget) { depth_a = depth_b = 64; }   /* budget-bound: let ID run deep */

    EvalWeights wa, wb;
    if (build_weights(&wa, wa_spec) || build_weights(&wb, wb_spec)) return 2;
    SearchConfig sca, scb;
    if (build_search(&sca, sa_spec) || build_search(&scb, sb_spec)) return 2;

    static char fens[8192][128];
    int nf = load_fens(openings, fens, 8192);
    if (nf <= 0) return 2;

    int pairs = games / 2; if (pairs < 1) pairs = 1;
    int ntasks = pairs * 2;
    if (pairs > nf)
        fprintf(stderr, "WARNING: %d pairs > %d openings -> games will DUPLICATE "
                "(deterministic); add more openings for real statistical power.\n", pairs, nf);

    /* shared results */
    GResult *res = mmap(NULL, sizeof(GResult) * ntasks, PROT_READ | PROT_WRITE,
                        MAP_SHARED | MAP_ANON, -1, 0);

    if (jobs < 1) jobs = 1;
    if (jobs > ntasks) jobs = ntasks;

    printf("%s: %d games, depth A=%d/B=%d, jobs=%d%s\n", label, ntasks, depth_a, depth_b, jobs,
           use_sprt ? " (SPRT verdict at end)" : "");
    fflush(stdout);

    for (int w = 0; w < jobs; w++) {
        pid_t pid = fork();
        if (pid == 0) {
            for (int t = w; t < ntasks; t += jobs) {
                int pi = t / 2, a_white = (t & 1) == 0;
                play_game(fens[pi % nf], a_white, depth_a, depth_b, &wa, &wb,
                          &sca, &scb, node_budget, max_plies, adj_cp, adj_streak, &res[t]);
            }
            _exit(0);
        }
    }
    for (int w = 0; w < jobs; w++) wait(NULL);

    /* aggregate */
    double score = 0; int wins = 0, draws = 0, losses = 0;
    double scores[4096];
    for (int t = 0; t < ntasks; t++) {
        double s = res[t].a_score / 2.0;
        scores[t] = s; score += s;
        if (res[t].a_score == 2) wins++;
        else if (res[t].a_score == 1) draws++;
        else losses++;
    }
    double rate = ntasks ? score / ntasks : 0;
    double lo, hi; wilson(score, ntasks, &lo, &hi);
    double elo = (rate > 0 && rate < 1) ? -400.0 * log10(1.0 / rate - 1.0) : 0;

    printf("\n=== RESULT (engine A perspective) ===\n");
    printf("A: +%d =%d -%d  score %.1f/%d = %.1f%%\n", wins, draws, losses, score, ntasks, 100 * rate);
    printf("Wilson 95%%: [%.1f%%, %.1f%%]   Elo diff ~ %+.0f\n", 100 * lo, 100 * hi, elo);
    printf("Verdict: %s\n", lo > 0.5 ? "A STRONGER (95%)" : hi < 0.5 ? "B STRONGER (95%)" : "inconclusive");
    if (use_sprt) {
        double llr = sprt_llr(scores, ntasks, sprt_elo1);
        double bound = log((1 - sprt_alpha) / sprt_alpha);
        printf("SPRT: LLR=%+.2f bound=±%.2f -> %s\n", llr, bound,
               llr >= bound ? "H1 (A better)" : llr <= -bound ? "H0 (A not better)" : "inconclusive");
    }
    munmap(res, sizeof(GResult) * ntasks);
    return 0;
}

/* ---- single-position commands ------------------------------------------ */
static int cmd_eval(const char *fen, const char *wspec) {
    Board b;
    if (board_from_fen(&b, fen)) { fprintf(stderr, "bad fen\n"); return 2; }
    if (build_weights(&g_w, wspec)) return 2;   /* resets to baseline then applies */
    printf("%d\n", eval_full(&b));
    return 0;
}

static int cmd_bestmove(const char *fen, int depth, long nodes,
                        const char *wspec, const char *scfg) {
    Board b;
    if (board_from_fen(&b, fen)) { fprintf(stderr, "bad fen\n"); return 2; }
    if (build_weights(&g_w, wspec)) return 2;   /* baseline, then optional overrides */
    if (build_search(&g_sc, scfg)) return 2;    /* defaults, then optional overrides */
    search_set_budget(nodes);
    if (nodes) depth = 64;            /* budget-bound: let ID run deep */
    SearchInfo info;
    hash_t hist[1] = { b.hash };
    Move m = search_bestmove(&b, depth, hist, 1, &info);
    char uci[6]; move_to_uci(m, uci);
    printf("bestmove %s  score %+dcp  depth %d  nodes %llu  qnodes %llu  tt_hits %llu\n",
           uci, info.score, info.depth,
           (unsigned long long)info.nodes, (unsigned long long)info.qnodes,
           (unsigned long long)info.tt_hits);
    return 0;
}

/* Texel MSE of eval_full vs SF labels over a TSV (fen\tcp per line).
 * loss = mean( (sigmoid(eval/K) - sigmoid(label/K))^2 ), K=300 (matches texel_tune). */
static int cmd_mse(const char *tsv, const char *wspec) {
    if (build_weights(&g_w, wspec)) return 2;
    FILE *f = fopen(tsv, "r");
    if (!f) { fprintf(stderr, "cannot open %s\n", tsv); return 2; }
    const double K = 300.0;
    double sse = 0.0;
    long n = 0;
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        char *tab = strchr(line, '\t');
        if (!tab) continue;
        *tab = 0;
        int label = atoi(tab + 1);
        Board b;
        if (board_from_fen(&b, line)) continue;
        int ev = eval_full(&b);                 /* white-POV cp */
        double pred = 1.0 / (1.0 + exp(-ev / K));
        double targ = 1.0 / (1.0 + exp(-label / K));
        double d = pred - targ;
        sse += d * d;
        n++;
    }
    fclose(f);
    printf("%.8f %ld\n", n ? sse / n : 0.0, n);   /* MSE  count */
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s eval FEN | bestmove FEN [depth] | selfplay [opts] | mse TSV [weights]\n", argv[0]);
        return 2;
    }
    if (!strcmp(argv[1], "mse") && argc >= 3)
        return cmd_mse(argv[2], argc >= 4 ? argv[3] : NULL);
    if (!strcmp(argv[1], "eval") && argc >= 3)
        return cmd_eval(argv[2], argc >= 4 ? argv[3] : NULL);   /* eval FEN [weights] */
    if (!strcmp(argv[1], "bestmove") && argc >= 3)
        return cmd_bestmove(argv[2], argc >= 4 ? atoi(argv[3]) : 5,
                            argc >= 5 ? atol(argv[4]) : 0,
                            argc >= 6 ? argv[5] : NULL,  /* [weights] */
                            argc >= 7 ? argv[6] : NULL); /* [searchcfg]: FEN depth nodes weights searchcfg */
    if (!strcmp(argv[1], "selfplay")) return cmd_selfplay(argc - 2, argv + 2);
    fprintf(stderr, "unknown subcommand %s\n", argv[1]);
    return 2;
}
