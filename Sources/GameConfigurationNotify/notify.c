#include "GameConfigurationNotify.h"
#include <notify.h>
uint32_t SVConfigurationRegister(const char *name, int32_t *token) { return notify_register_check(name, token); }
uint32_t SVConfigurationWrite(int32_t token, uint64_t value) { return notify_set_state(token, value); }
uint32_t SVConfigurationRead(int32_t token, uint64_t *value) { return notify_get_state(token, value); }
void SVConfigurationCancel(int32_t token) { notify_cancel(token); }
