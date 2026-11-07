// fanpilot-helper : petit utilitaire root (setuid) qui écrit UNIQUEMENT les clés
// de ventilateurs du SMC. L'app l'appelle pour passer un ventilateur en manuel/auto.
//
//   fanpilot-helper set <ventilo> <rpm>   -> mode manuel à <rpm> (borné min..max)
//   fanpilot-helper auto <ventilo>        -> rend le ventilateur à macOS
//   fanpilot-helper auto-all              -> rend tous les ventilateurs à macOS
//   fanpilot-helper procs                 -> (lecture seule) temps CPU + énergie de tous
//                                            les processus, y compris ceux du système
#include "smc.h"
#include "procs.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>

static io_connect_t conn;

static int fan_count(void) {
    SMCValue v; double d;
    if (smc_read(conn, "FNum", &v) != KERN_SUCCESS || !smc_value_to_double(&v, &d)) return 0;
    return (int)d;
}

static bool read_num(const char *key, double *out) {
    SMCValue v;
    return smc_read(conn, key, &v) == KERN_SUCCESS && smc_value_to_double(&v, out);
}

static bool write_num(const char *key, double val) {
    SMCValue v;
    if (smc_read(conn, key, &v) != KERN_SUCCESS) return false;
    if (!smc_value_from_double(&v, val)) return false;
    return smc_write(conn, &v) == KERN_SUCCESS;
}

static bool has_key(const char *key) { SMCValue v; return smc_read(conn, key, &v) == KERN_SUCCESS; }

// Sur Apple Silicon, thermalmonitord garde la main sur les ventilateurs :
// il faut écrire Ftst=1 pour la "débloquer", puis le mode manuel peut mettre
// quelques instants à être accepté -> on réessaie.
static bool set_manual(int fan) {
    char key[5];
    snprintf(key, sizeof key, "F%dMd", fan);
    if (has_key("Ftst")) write_num("Ftst", 1);
    for (int i = 0; i < 100; i++) {   // jusqu'à 10 s
        write_num(key, 1);
        double m;
        if (read_num(key, &m) && (int)m == 1) return true;
        usleep(100 * 1000);
    }
    return false;
}

static bool any_manual(void) {
    int n = fan_count();
    for (int i = 0; i < n; i++) {
        char key[5]; double m;
        snprintf(key, sizeof key, "F%dMd", i);
        if (read_num(key, &m) && (int)m == 1) return true;
    }
    return false;
}

static int cmd_auto(int fan) {
    char key[5];
    snprintf(key, sizeof key, "F%dMd", fan);
    bool ok = write_num(key, 0);
    if (!any_manual() && has_key("Ftst")) write_num("Ftst", 0);
    return ok ? 0 : 1;
}

static int cmd_set(int fan, double rpm) {
    char kMn[5], kMx[5], kTg[5];
    snprintf(kMn, sizeof kMn, "F%dMn", fan);
    snprintf(kMx, sizeof kMx, "F%dMx", fan);
    snprintf(kTg, sizeof kTg, "F%dTg", fan);
    double mn = 0, mx = 0;
    if (!read_num(kMn, &mn) || !read_num(kMx, &mx) || mx <= 0) {
        fprintf(stderr, "impossible de lire les limites du ventilateur %d\n", fan);
        return 1;
    }
    if (rpm < mn) rpm = mn;   // on ne descend jamais sous le minimum Apple
    if (rpm > mx) rpm = mx;
    if (!set_manual(fan)) {
        fprintf(stderr, "le SMC refuse le mode manuel pour le ventilateur %d\n", fan);
        return 1;
    }
    if (!write_num(kTg, rpm)) {
        fprintf(stderr, "écriture de la vitesse cible refusée\n");
        return 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (geteuid() != 0) {
        fprintf(stderr, "fanpilot-helper doit être root (setuid) pour écrire dans le SMC\n");
        return 2;
    }
    if (argc == 2 && !strcmp(argv[1], "procs")) {
        // Lecture seule : "pid<TAB>pid_responsable<TAB>cpu_ns<TAB>energy_nj<TAB>chemin" par ligne.
        static ProcSample buf[8192];
        int count = proc_snapshot(buf, 8192);
        for (int i = 0; i < count; i++) {
            for (char *c = buf[i].path; *c; c++) if (*c == '\t' || *c == '\n') *c = ' ';
            printf("%d\t%d\t%llu\t%llu\t%s\n", buf[i].pid, buf[i].responsible_pid, (unsigned long long)buf[i].cpu_ns,
                   (unsigned long long)buf[i].energy_nj, buf[i].path);
        }
        return 0;
    }
    if (smc_open(&conn) != KERN_SUCCESS) {
        fprintf(stderr, "impossible d'ouvrir AppleSMC\n");
        return 2;
    }
    int n = fan_count();
    int rc = 64;

    if (argc == 2 && !strcmp(argv[1], "auto-all")) {
        rc = 0;
        for (int i = 0; i < n; i++) {
            char key[5]; snprintf(key, sizeof key, "F%dMd", i);
            if (!write_num(key, 0)) rc = 1;
        }
        if (has_key("Ftst")) write_num("Ftst", 0);
    } else if (argc >= 3) {
        char *end;
        long fan = strtol(argv[2], &end, 10);
        if (*end || fan < 0 || fan >= n) {
            fprintf(stderr, "ventilateur invalide (0..%d)\n", n - 1);
            rc = 64;
        } else if (argc == 3 && !strcmp(argv[1], "auto")) {
            rc = cmd_auto((int)fan);
        } else if (argc == 4 && !strcmp(argv[1], "set")) {
            double rpm = strtod(argv[3], &end);
            rc = (*end || !isfinite(rpm) || !(rpm > 0)) ? 64 : cmd_set((int)fan, rpm);   // refuse aussi NaN / infini
        }
    }
    if (rc == 64)
        fprintf(stderr, "usage: %s set <ventilo> <rpm> | auto <ventilo> | auto-all | procs\n", argv[0]);
    smc_close(conn);
    return rc;
}
