/*
 * Minimal cJSON compatibility stub.
 *
 * Mosquitto 2.1 reorganised its headers so that the broker plugin API
 * (<mosquitto/broker_plugin.h>) transitively includes <mosquitto.h>, which in
 * turn pulls in <mosquitto/libcommon_cjson.h>. That header declares a single
 * prototype:
 *
 *     cJSON *mosquitto_properties_to_json(const mosquitto_property *properties);
 *
 * This plugin never calls that function, so the full cJSON library is not
 * required to build it — only the `cJSON` type needs to exist for the
 * declaration to compile. This forward declaration provides exactly that.
 *
 * When building in an environment that has the real cJSON development headers
 * installed (as a normal mosquitto 2.1 dev setup does), that header is used
 * instead and this stub is never reached.
 */
#ifndef MOSQUITTO_MESSAGE_LOGGER_CJSON_STUB_H
#define MOSQUITTO_MESSAGE_LOGGER_CJSON_STUB_H

typedef struct cJSON cJSON;

#endif /* MOSQUITTO_MESSAGE_LOGGER_CJSON_STUB_H */
