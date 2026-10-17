#include "WrathBridge.h"
#include <stdatomic.h>
#include <stdlib.h>
struct WrathToken { atomic_int cancelled; };
WrathToken *wrath_token_create(void) {
    WrathToken *token=calloc(1,sizeof(WrathToken));
    if(token) atomic_init(&token->cancelled,0);
    return token;
}
void wrath_token_cancel(WrathToken *token) { if(token) atomic_store(&token->cancelled,1); }
void wrath_token_free(WrathToken *token) { free(token); }
void wrath_free(void *pointer) { free(pointer); }
int wrath_is_cancelled(WrathToken *token) { return token && atomic_load(&token->cancelled); }
