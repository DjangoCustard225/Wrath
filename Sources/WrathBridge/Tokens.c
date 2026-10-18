#include "WrathBridge.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <pthread.h>
struct WrathToken { atomic_int cancelled; pthread_mutex_t lock; pthread_cond_t changed; int paused; };
WrathToken *wrath_token_create(void) {
    WrathToken *token=calloc(1,sizeof(WrathToken));
    if(token) {
        atomic_init(&token->cancelled,0);
        if(pthread_mutex_init(&token->lock,NULL)) { free(token); return NULL; }
        if(pthread_cond_init(&token->changed,NULL)) { pthread_mutex_destroy(&token->lock); free(token); return NULL; }
    }
    return token;
}
void wrath_token_cancel(WrathToken *token) {
    if(!token) return;
    atomic_store(&token->cancelled,1);
    pthread_mutex_lock(&token->lock);
    token->paused=0;
    pthread_cond_broadcast(&token->changed);
    pthread_mutex_unlock(&token->lock);
}
void wrath_token_set_paused(WrathToken *token,int paused) {
    if(!token) return;
    pthread_mutex_lock(&token->lock);
    token->paused=paused && !atomic_load(&token->cancelled);
    if(!token->paused) pthread_cond_broadcast(&token->changed);
    pthread_mutex_unlock(&token->lock);
}
int wrath_wait_if_paused(WrathToken *token) {
    if(!token) return 0;
    pthread_mutex_lock(&token->lock);
    while(token->paused && !atomic_load(&token->cancelled)) pthread_cond_wait(&token->changed,&token->lock);
    int cancelled=atomic_load(&token->cancelled);
    pthread_mutex_unlock(&token->lock);
    return cancelled;
}
void wrath_token_free(WrathToken *token) {
    if(!token) return;
    pthread_cond_destroy(&token->changed);
    pthread_mutex_destroy(&token->lock);
    free(token);
}
void wrath_free(void *pointer) { free(pointer); }
int wrath_is_cancelled(WrathToken *token) { return token && atomic_load(&token->cancelled); }
