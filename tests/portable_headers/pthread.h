#pragma once

#if defined(_WIN32)
#include <mutex>

struct pthread_mutex_t {
    std::mutex value;
};

#define PTHREAD_MUTEX_INITIALIZER {}

inline int pthread_mutex_lock(pthread_mutex_t *mutex) {
    mutex->value.lock();
    return 0;
}

inline int pthread_mutex_unlock(pthread_mutex_t *mutex) {
    mutex->value.unlock();
    return 0;
}
#else
#include_next <pthread.h>
#endif
