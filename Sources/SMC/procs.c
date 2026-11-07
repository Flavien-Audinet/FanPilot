#include "procs.h"
#include <libproc.h>
#include <sys/resource.h>
#include <mach/mach_time.h>
#include <string.h>
#include <stdlib.h>

// Fonction privée mais exportée par libSystem (utilisée par le Moniteur d'activité).
extern pid_t responsibility_get_pid_responsible_for_pid(pid_t);

int proc_snapshot(ProcSample *out, int max) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);   // ri_*_time est en ticks mach sur Apple Silicon

    int cap = proc_listallpids(NULL, 0) + 64;
    if (cap < 256) cap = 4096;
    pid_t *pids = calloc((size_t)cap, sizeof(pid_t));
    if (!pids) return 0;
    int n = proc_listallpids(pids, cap * (int)sizeof(pid_t));

    int count = 0;
    for (int i = 0; i < n && count < max; i++) {
        struct rusage_info_v6 ru;
        if (proc_pid_rusage(pids[i], RUSAGE_INFO_V6, (rusage_info_t *)&ru) != 0) continue;
        ProcSample *s = &out[count];
        s->pid = pids[i];
        s->responsible_pid = pids[i] > 0 ? responsibility_get_pid_responsible_for_pid(pids[i]) : 0;
        s->cpu_ns = (ru.ri_user_time + ru.ri_system_time) * tb.numer / tb.denom;
        s->energy_nj = ru.ri_energy_nj;
        s->path[0] = 0;
        if (proc_pidpath(pids[i], s->path, sizeof s->path) <= 0) {
            if (pids[i] == 0) strcpy(s->path, "kernel_task");
            else proc_name(pids[i], s->path, sizeof s->path);
        }
        if (!s->path[0]) continue;
        count++;
    }
    free(pids);
    return count;
}
