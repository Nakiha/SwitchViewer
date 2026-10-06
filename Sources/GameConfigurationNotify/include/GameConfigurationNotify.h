#pragma once
#include <stdint.h>
uint32_t SVConfigurationRegister(const char *name, int32_t *token);
uint32_t SVConfigurationWrite(int32_t token, uint64_t value);
uint32_t SVConfigurationRead(int32_t token, uint64_t *value);
void SVConfigurationCancel(int32_t token);
