// Statistiques cumulées par processus (temps CPU + énergie), via proc_pid_rusage.
#ifndef FANPILOT_PROCS_H
#define FANPILOT_PROCS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int32_t pid;
    int32_t responsible_pid;   // app « responsable » (ex: Firefox pour ses services XPC)
    uint64_t cpu_ns;      // temps CPU cumulé (utilisateur + système), en nanosecondes
    uint64_t energy_nj;   // énergie cumulée estimée par le noyau, en nanojoules
    char path[1024];      // chemin de l'exécutable (ou nom du processus)
} ProcSample;

// Remplit `out` (capacité `max`) et retourne le nombre d'entrées.
// Sans root, seuls les processus de l'utilisateur courant sont lisibles.
int proc_snapshot(ProcSample *out, int max);

#ifdef __cplusplus
}
#endif

#endif
