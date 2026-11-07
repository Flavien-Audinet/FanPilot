// Accès bas niveau au SMC (System Management Controller) d'Apple via IOKit.
#ifndef FANPILOT_SMC_H
#define FANPILOT_SMC_H

#include <stdint.h>
#include <stdbool.h>
#include <IOKit/IOKitLib.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char key[5];        // clé SMC à 4 caractères + '\0'
    char type[5];       // type de donnée ("flt ", "ui8 ", "sp78", ...)
    uint32_t size;      // taille en octets
    uint8_t bytes[32];  // données brutes
} SMCValue;

// Ouvre / ferme la connexion au service AppleSMC.
kern_return_t smc_open(io_connect_t *conn);
void smc_close(io_connect_t conn);

// Lit une clé (ex: "F0Ac"). Retourne KERN_SUCCESS si la clé existe.
kern_return_t smc_read(io_connect_t conn, const char *key, SMCValue *out);

// Lecture rapide d'une clé dont on connaît déjà la taille et le type (1 appel noyau au lieu de 2).
// `val` doit provenir d'un smc_read précédent (on réutilise val->key / val->size / val->type).
kern_return_t smc_read_fast(io_connect_t conn, SMCValue *val);

// Écrit une clé (nécessite les droits root). val->size doit correspondre à la taille de la clé.
kern_return_t smc_write(io_connect_t conn, const SMCValue *val);

// Nombre total de clés et lecture du nom de la clé n°index (énumération).
uint32_t smc_key_count(io_connect_t conn);
kern_return_t smc_key_at_index(io_connect_t conn, uint32_t index, char out[5]);

// Interprète une valeur numérique selon son type. Retourne false si type inconnu.
bool smc_value_to_double(const SMCValue *val, double *out);

// Remplit val->bytes à partir d'un double selon val->type / val->size.
bool smc_value_from_double(SMCValue *val, double v);

#ifdef __cplusplus
}
#endif

#endif
